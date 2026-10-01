#requires -Version 7.3
[CmdletBinding()]
param(
    [ValidateSet('pull_request','push','schedule','workflow_dispatch')]
    [string] $EventName,
    [string] $OutputDirectory
)

function Get-HostedOwnedProcesses($Known, [object[]] $Table, [scriptblock] $RetainIdentity) {
    if ($Table.Count -eq 0) { throw 'Process-table availability is unknown; empty is not zero owned helpers.' }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($entry in $Table) {
            $parentId=[int]$entry.ParentProcessId
            if (@($Known.Values | Where-Object { $_.process_id -eq $entry.ProcessId -or $_.process_id -eq $parentId }).Count -eq 0) { continue }
            $created=([datetime]$entry.CreationDate).ToUniversalTime()
            $identity="$([int]$entry.ProcessId)|$($created.Ticks)"
            $retained=@($Known.Values | Where-Object {
                $_.process_id -eq $entry.ProcessId -and
                    (Test-HostedProcessCreationBinding ([datetime]$_.started_at) $created)
            })
            if ($retained.Count -gt 1) { throw 'Ambiguous current owned process generation identity.' }
            if ($retained.Count -eq 1) { continue }
            $parents=@($Known.Values | Where-Object { $_.process_id -eq $parentId -and $created -ge ([datetime]$_.started_at).ToUniversalTime() })
            $currentParents=@($Table | Where-Object ProcessId -EQ $parentId)
            if ($currentParents.Count -gt 1) { throw 'Ambiguous current census parent PID identity.' }
            if ($currentParents.Count -eq 1 -and $created -ge ([datetime]$currentParents[0].CreationDate).ToUniversalTime()) {
                $parents=@($parents | Where-Object {
                    Test-HostedProcessCreationBinding ([datetime]$_.started_at) ([datetime]$currentParents[0].CreationDate)
                })
            } else {
                $parents=@($parents | Where-Object {
                    $candidateStart=([datetime]$_.started_at).ToUniversalTime().Ticks
                    $_.ContainsKey('pid_reserved_through') -and
                        $created.Ticks -ge $candidateStart -and
                        $created.Ticks -le ([datetime]$_.pid_reserved_through).ToUniversalTime().Ticks
                })
                if ($parents.Count -eq 0 -and @($Known.Values | Where-Object {
                    $_.process_id -eq $parentId -and $created -ge ([datetime]$_.started_at).ToUniversalTime()
                }).Count -gt 0) {
                    $failure=[InvalidOperationException]::new('Hosted parent generation has no current identity or retained-handle reservation covering the child creation time.')
                    $failure.Data['owned_guard_state']=@{
                        child_pid=[int]$entry.ProcessId;child_started_at=$created.ToString('o');parent_pid=$parentId
                        current_parent_count=$currentParents.Count
                    }
                    throw $failure
                }
            }
            if ($parents.Count -gt 1) {
                $failure=[InvalidOperationException]::new('Ambiguous/reused hosted parent PID generation identity.')
                $failure.Data['owned_guard_state']=@{
                    child_pid=[int]$entry.ProcessId;child_started_at=$created.ToString('o');parent_pid=$parentId
                    parent_candidates=@($parents);current_parent_count=$currentParents.Count
                }
                throw $failure
            }
            if ($parents.Count -eq 1) {
                $record=@{process_id=[int]$entry.ProcessId;parent_id=$parentId;started_at=$created.ToString('o')}
                if ($RetainIdentity) {
                    $record=& $RetainIdentity $entry
                    if ($record.process_id -ne $entry.ProcessId -or $record.parent_id -ne $parentId -or
                        -not (Test-HostedProcessCreationBinding ([datetime]$record.started_at) $created)) {
                        throw 'Retained descendant handle does not match its observed PID/parent/creation interval.'
                    }
                    $identity="$($record.process_id)|$(([datetime]$record.started_at).ToUniversalTime().Ticks)"
                }
                $Known[$identity]=$record
                $changed=$true
            }
        }
    }
    return $Known
}

function Get-HostedOwnedCleanup($Known, [object[]] $Table) {
    [void](Get-HostedOwnedProcesses $Known $Table)
    $live=0
    foreach ($entry in $Table) {
        if (@($Known.Values | Where-Object process_id -EQ $entry.ProcessId).Count -eq 0) { continue }
        $identity="$([int]$entry.ProcessId)|$(([datetime]$entry.CreationDate).ToUniversalTime().Ticks)"
        $matched=@($Known.Values | Where-Object {
            $_.process_id -eq $entry.ProcessId -and
                (Test-HostedProcessCreationBinding ([datetime]$_.started_at) ([datetime]$entry.CreationDate))
        })
        if ($matched.Count -gt 1) { throw 'Ambiguous live owned process identity.' }
        if ($matched.Count -eq 1) { $live++ }
    }
    return @{available=$true;observed_process_count=$Known.Count;remaining_process_count=$live;processes=@($Known.Values)}
}

function Invoke-HostedHarnessProcess([string] $Script, [string[]] $Arguments, [string] $LogPath, $Known, [hashtable] $Runtime) {
    $heldHandles=@{}
    if ($null -eq $Runtime) {
        $Runtime=@{
            start={
                param($scriptPath,$scriptArguments)
                $start=[Diagnostics.ProcessStartInfo]::new()
                $start.FileName=(Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
                $start.UseShellExecute=$false
                $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
                foreach ($argument in @('-NoLogo','-NoProfile','-File',$scriptPath)+$scriptArguments) { $start.ArgumentList.Add($argument) }
                [Diagnostics.Process]::Start($start)
            }
            census={
                $table=@(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate -OperationTimeoutSec 5 -ErrorAction Stop)
                foreach ($key in $heldHandles.Keys) {
                    if ($Known.ContainsKey($key)) { $Known[$key].pid_reserved_through=[DateTime]::UtcNow.ToString('o') }
                }
                $table
            }
            retain={
                param($entry)
                $owned=Get-Process -Id $entry.ProcessId -ErrorAction Stop
                [void]$owned.Handle
                $nativeStarted=$owned.StartTime.ToUniversalTime()
                if (-not (Test-HostedProcessCreationBinding $nativeStarted ([datetime]$entry.CreationDate))) {
                    $owned.Dispose()
                    throw 'Descendant PID changed before its identity handle could be retained.'
                }
                $key="$($owned.Id)|$($nativeStarted.Ticks)"
                $heldHandles[$key]=$owned
                @{process_id=$owned.Id;parent_id=[int]$entry.ParentProcessId;started_at=$nativeStarted.ToString('o');pid_reserved_through=[DateTime]::UtcNow.ToString('o')}
            }
            release={
                foreach ($key in @($heldHandles.Keys)) {
                    try {
                        $Known[$key].pid_reserved_through=[DateTime]::UtcNow.ToString('o')
                        if (-not [object]::ReferenceEquals($heldHandles[$key],$process)) { $heldHandles[$key].Dispose() }
                    } catch { $secondary.Add("retained handle release: $($_.Exception.Message)") }
                }
            }
            stop_root={
                param($root,$rootHandle,$rootStarted)
                Stop-InteractiveWin11RootHandle -Process $root -RootProcessHandle $rootHandle -RootStartedAt $rootStarted
            }
            stop_descendant={
                param($entry)
                $owned=Get-Process -Id $entry.ProcessId -ErrorAction Stop
                if (-not (Test-HostedProcessCreationBinding $owned.StartTime ([datetime]$entry.CreationDate))) {
                    throw 'Owned descendant PID was reused before cleanup.'
                }
                [void]$owned.Handle
                Stop-Process -Id $owned.Id -ErrorAction Stop
                if (-not $owned.WaitForExit(15000)) { throw 'Owned descendant termination exceeded 15 seconds.' }
            }
        }
    }
    foreach ($name in @('start','census','retain','release','stop_root','stop_descendant')) {
        if ($Runtime[$name] -isnot [scriptblock]) { throw "Hosted phase runtime is incomplete: $name" }
    }
    $process=& $Runtime.start $Script $Arguments
    $handle=$process.Handle
    $started=$process.StartTime.ToUniversalTime()
    $Known["$($process.Id)|$($started.Ticks)"]=@{process_id=$process.Id;parent_id=$PID;started_at=$started.ToString('o')}
    $heldHandles["$($process.Id)|$($started.Ticks)"]=$process
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    $primary=$null
    $secondary=[Collections.Generic.List[string]]::new()
    $deadline=[DateTime]::UtcNow.AddMinutes(45)
    try {
        while (-not $process.WaitForExit(200)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Hosted harness phase exceeded its bounded deadline.' }
            $table=@(& $Runtime.census)
            [void](Get-HostedOwnedProcesses $Known $table $Runtime.retain)
        }
        if ($process.ExitCode -ne 0) { throw "Actual harness exited $($process.ExitCode): $(Split-Path -Leaf $Script)" }
    } catch { $primary=$_ }
    finally {
        try {
            if (-not $process.HasExited) {
                [void](& $Runtime.stop_root $process $handle $started)
            }
        } catch { $secondary.Add("root cleanup: $($_.Exception.Message)") }
        try {
            # Only terminate identity-matched descendants of our retained phase
            # roots. Never query or print foreign command lines/UI contents.
            $table=@(& $Runtime.census)
            [void](Get-HostedOwnedProcesses $Known $table $Runtime.retain)
            foreach ($entry in $table | Sort-Object CreationDate -Descending) {
                $matches=@($Known.Values | Where-Object {
                    $_.process_id -eq $entry.ProcessId -and (Test-HostedProcessCreationBinding ([datetime]$_.started_at) ([datetime]$entry.CreationDate))
                })
                if ($matches.Count -gt 1) { throw 'Ambiguous retained descendant generation before cleanup.' }
                if ($matches.Count -eq 0) { continue }
                try {
                    [void](& $Runtime.stop_descendant $entry)
                } catch { $secondary.Add("descendant $($entry.ProcessId) cleanup: $($_.Exception.Message)") }
            }
        } catch { $secondary.Add("descendant cleanup: $($_.Exception.Message)") }
        try {
            if (-not $stdout.Wait(5000) -or -not $stderr.Wait(5000)) { throw 'Owned harness output streams did not close.' }
            [IO.File]::WriteAllText($LogPath,$stdout.Result+"`n"+$stderr.Result)
        } catch { $secondary.Add("harness evidence: $($_.Exception.Message)") }
        try { [void](& $Runtime.release) } catch { $secondary.Add("retained handle disposal: $($_.Exception.Message)") }
        try { $process.Dispose() } catch { $secondary.Add("root handle disposal: $($_.Exception.Message)") }
    }
    if ($primary) {
        $primary.Exception.Data['hosted_secondary_failures']=@($secondary)
        throw $primary
    }
    if ($secondary.Count -gt 0) { throw "Hosted phase secondary failures: $($secondary -join '; ')" }
}

function Get-HostedGroupEvidence($Group, [string] $Root) {
    $directory=Join-Path $Root "processes\$($Group.name)"
    $records=@(Get-ChildItem -LiteralPath $directory -Filter 'process-*.json' -ErrorAction Stop |
        ForEach-Object { ConvertFrom-HostedJson (Get-Content -LiteralPath $_.FullName -Raw) })
    if ($records.Count -eq 0) { throw "No actual retained app evidence for $($Group.name)." }
    $known=@{}; $modules=@(); $windows=@{}
    foreach ($record in $records) {
        if (@($record.secondary_failures).Count -gt 0) { throw "Owned cleanup secondary failures: $($record.secondary_failures -join '; ')" }
        Assert-HostedCleanup $record.cleanup
        foreach ($identity in $record.cleanup.processes) { $known["$($identity.process_id)|$($identity.started_at)"]=$identity }
        foreach ($window in $record.windows) {
            $windows["$($record.process_id)|$($record.started_at)|$window"]=@{process_id=$record.process_id;started_at=$record.started_at;hwnd=[long]$window}
        }
        $modules+=@{
            process_id=$record.process_id;started_at=$record.started_at
            application_path=$record.application_path;application_sha256=$record.application_sha256
            path=$record.module_path;sha256=$record.module_sha256
            megadriver_path=$record.megadriver_path;megadriver_sha256=$record.megadriver_sha256
        }
    }
    $Group.observed_app_count=$records.Count
    $Group.observed_window_count=$windows.Count
    $Group.loaded_modules=$modules
    $Group.owned_windows=@($windows.Values)
    $Group.cleanup=@{available=$true;observed_process_count=$known.Count;remaining_process_count=0;processes=@($known.Values)}
    $Group.artifacts=@(Get-ChildItem -LiteralPath $directory -File | ForEach-Object {
        @{path=[IO.Path]::GetRelativePath($Root,$_.FullName);sha256=(Get-FileHash $_.FullName).Hash.ToLowerInvariant()}
    })
    return $Group
}

function Complete-HostedInteractiveRun {
    param(
        [hashtable] $Result,
        [hashtable] $OldEnvironment,
        $Primary,
        [Collections.Generic.List[object]] $Secondary,
        [scriptblock] $CleanupProof,
        [scriptblock] $SourceBindings,
        [Parameter(Mandatory)] [scriptblock] $EvidenceValidator,
        [scriptblock] $RestoreVariable,
        [scriptblock] $SummaryWriter,
        [scriptblock] $ResultWriter,
        [scriptblock] $DiagnosticWriter
    )
    foreach ($step in @(
        @{name='final cleanup proof';action=$CleanupProof},
        @{name='suite source bindings';action=$SourceBindings}
    )) {
        try { [void](& $step.action) }
        catch { $Secondary.Add(@{phase=$step.name;type=$_.Exception.GetType().FullName;message=$_.Exception.Message}) }
    }
    foreach ($key in $OldEnvironment.Keys) {
        try { [void](& $RestoreVariable $key $OldEnvironment[$key]) }
        catch { $Secondary.Add(@{phase="environment restore $key";type=$_.Exception.GetType().FullName;message=$_.Exception.Message}) }
    }
    if (-not $Primary -and $Secondary.Count -eq 0) {
        try { [void](& $EvidenceValidator) }
        catch {
            $Primary=$_
            $Result.failure=@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
        }
    }
    if ($Primary -or $Secondary.Count -gt 0) { $Result.status='error' }
    try { [void](& $SummaryWriter) }
    catch { $Secondary.Add(@{phase='job summary';type=$_.Exception.GetType().FullName;message=$_.Exception.Message}) }
    $diagnosticCount=$Secondary.Count
    for ($index=0;$index -lt $diagnosticCount;$index++) {
        try { [void](& $DiagnosticWriter $Secondary[$index]) }
        catch { $Secondary.Add(@{phase='secondary diagnostic';type=$_.Exception.GetType().FullName;message=$_.Exception.Message}) }
    }
    $Result.secondary_failures=@($Secondary)
    if ($Secondary.Count -gt 0) { $Result.status='error' }
    try { [void](& $ResultWriter) }
    catch { $Secondary.Add(@{phase='final evidence write';type=$_.Exception.GetType().FullName;message=$_.Exception.Message}) }
    if ($Primary) {
        $Primary.Exception.Data['hosted_secondary_failures']=@($Secondary)
        throw $Primary
    }
    if ($Secondary.Count -gt 0) {
        $failure=[InvalidOperationException]::new('Hosted finalization failed: '+(($Secondary | ForEach-Object { "$($_.phase): $($_.message)" }) -join '; '))
        $failure.Data['hosted_secondary_failures']=@($Secondary)
        throw $failure
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference='Stop'
    $repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'assert-hosted-interactive-evidence.ps1')
    . (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or -not $EventName) {
        throw 'Hosted suite is only executable on the actual GitHub-hosted source-CI runner.'
    }
    if (-not $OutputDirectory) { $OutputDirectory=Join-Path $repoRoot '.sandbox\hosted-ci\evidence' }
    $OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
    if ($OutputDirectory -ine (Join-Path $repoRoot '.sandbox\hosted-ci\evidence')) { throw 'Evidence must stay in this job workspace.' }
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    $result=@{
        schema_version='winghostty.hosted-interactive-evidence.v1';profile='HOSTEDWINDOWSSERVERCPU'
        scope='Server CPU core GUI/render/shader correctness; NOT Windows 11 client or hardware/release proof'
        historical_required_check_name='Windows 11 Interactive Composite'
        status='error';failure=$null;secondary_failures=@();groups=@();runner=$null;graphics=$null
        deployment=$null;cleanup=@{available=$null;observed_process_count=$null;remaining_process_count=$null;processes=@()}
        sources=@();event_name=$EventName
    }
    $primary=$null
    $secondary=[Collections.Generic.List[object]]::new()
    $known=@{}
    $oldEnvironment=@{}
    foreach ($key in @('WINGHOSTTY_HOSTED_PROFILE','WINGHOSTTY_HOSTED_APP_PATH','WINGHOSTTY_HOSTED_GL_SHA256','WINGHOSTTY_HOSTED_GALLIUM_SHA256','WINGHOSTTY_HOSTED_EVIDENCE_DIR','WINGHOSTTY_HOSTED_STAGE','GALLIUM_DRIVER')) {
        $oldEnvironment[$key]=[Environment]::GetEnvironmentVariable($key)
    }
    try {
        $runnerPath=Join-Path $OutputDirectory 'runner.json'
        & (Join-Path $PSScriptRoot 'assert-interactive-runner.ps1') -Profile HostedServerCpu -OutputPath $runnerPath
        $result.runner=ConvertFrom-HostedJson (Get-Content $runnerPath -Raw)
        & (Join-Path $repoRoot 'scripts\dev-windows.cmd') zig build -Demit-exe=true
        if ($LASTEXITCODE -ne 0) { throw 'Default CI application build failed.' }
        $deploymentPath=Join-Path $OutputDirectory 'deployment.json'
        # Probe in a separate process: unloading Mesa before the next shader
        # build avoids DLL file locks and preserves per-executable provenance.
        & pwsh.exe -NoProfile -File (Join-Path $repoRoot 'scripts\setup-hosted-opengl.ps1') -OutputPath $deploymentPath -Probe
        if ($LASTEXITCODE -ne 0) { throw 'Pinned Mesa deployment/real GL capability probe failed.' }
        $result.deployment=ConvertFrom-HostedJson (Get-Content $deploymentPath -Raw)
        $result.graphics=$result.deployment.graphics
        $env:WINGHOSTTY_HOSTED_PROFILE='HOSTEDWINDOWSSERVERCPU'
        $env:WINGHOSTTY_HOSTED_APP_PATH=Join-Path $repoRoot 'zig-out\bin\winghostty.exe'
        $env:WINGHOSTTY_HOSTED_GL_SHA256=@($result.deployment.files | Where-Object name -CEQ 'opengl32.dll')[0].sha256
        $env:WINGHOSTTY_HOSTED_GALLIUM_SHA256=@($result.deployment.files | Where-Object name -CEQ 'libgallium_wgl.dll')[0].sha256
        $env:WINGHOSTTY_HOSTED_EVIDENCE_DIR=Join-Path $OutputDirectory 'processes'
        $env:GALLIUM_DRIVER='llvmpipe'
        $summaryPath=Join-Path $OutputDirectory 'pr-groups.json'
        Invoke-HostedHarnessProcess (Join-Path $PSScriptRoot 'interactive-win11-pr-smoke.ps1') @('-ResetState','-SummaryPath',$summaryPath) (Join-Path $OutputDirectory 'pr-suite.log') $known
        $summary=ConvertFrom-HostedJson (Get-Content $summaryPath -Raw)
        if ($summary.schema_version -cne 'winghostty.pr-smoke-groups.v1' -or @($summary.groups).Count -ne 8) { throw 'Actual eight-group PR summary is incomplete.' }
        foreach ($group in $summary.groups) { $result.groups+=Get-HostedGroupEvidence $group $OutputDirectory }

        & (Join-Path $repoRoot 'scripts\dev-windows.cmd') zig build -Demit-exe=true -Dcustom-shaders=true
        if ($LASTEXITCODE -ne 0) { throw 'Shader-enabled CI application build failed.' }
        & pwsh.exe -NoProfile -File (Join-Path $repoRoot 'scripts\setup-hosted-opengl.ps1') -OutputPath (Join-Path $OutputDirectory 'shader-deployment.json') -Probe
        if ($LASTEXITCODE -ne 0) { throw 'Shader executable Mesa staging/probe failed.' }
        $env:WINGHOSTTY_HOSTED_STAGE='shaders'
        $shaderPath=Join-Path $PSScriptRoot 'interactive-win11-shaders.ps1'
        Invoke-HostedHarnessProcess $shaderPath @('-ResetState') (Join-Path $OutputDirectory 'shaders.log') $known
        $shader=Get-HostedGroupEvidence @{
            name='shaders';harness='test\windows\interactive-win11-shaders.ps1'
            harness_sha256=(Get-FileHash $shaderPath).Hash.ToLowerInvariant();status='pass';exit_code=0
        } $OutputDirectory
        $capture=ConvertFrom-HostedJson (Get-Content (Join-Path $OutputDirectory 'processes\shaders\shader-capture.json') -Raw)
        $captureCopy=Join-Path $OutputDirectory 'shader-surface.png'
        Copy-Item -LiteralPath $capture.screenshot -Destination $captureCopy
        if ((Get-FileHash $captureCopy).Hash.ToLowerInvariant() -cne $capture.screenshot_sha256) { throw 'Shader PNG changed after the owned capture.' }
        $shader.shader_pixels=$capture
        $shader.screenshot=@{path='shader-surface.png';sha256=$capture.screenshot_sha256}
        $result.groups+=$shader

        if ($EventName -ne 'pull_request') {
            foreach ($phase in @(
                @{name='full-composite';script='flagship\Invoke-InteractiveWin11.ps1';args=@('-Rebuild','-ResetState','-IncludeForegroundHarness')},
                @{name='accessibility-soak';script='interactive-win11-accessibility.ps1';args=@('-ResetState','-TimeoutSeconds','120','-IdleSoakSeconds','600')},
                @{name='palette-high-contrast';script='interactive-win11-palette-theme.ps1';args=@('-ResetState','-ExerciseHighContrast')},
                @{name='session-restore-full';script='interactive-win11-session-restore.ps1';args=@('-ResetState')}
            )) {
                $env:WINGHOSTTY_HOSTED_STAGE=$phase.name
                $path=Join-Path $PSScriptRoot $phase.script
                Invoke-HostedHarnessProcess $path $phase.args (Join-Path $OutputDirectory "$($phase.name).log") $known
                $result.groups+=Get-HostedGroupEvidence @{
                    name=$phase.name;harness="test\windows\$($phase.script)"
                    harness_sha256=(Get-FileHash $path).Hash.ToLowerInvariant();status='pass';exit_code=0
                } $OutputDirectory
            }
        }
        $result.status='pass'
    } catch {
        $primary=$_
        $result.failure=@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
        if ($_.Exception.Data.Contains('owned_guard_state')) { $result.failure.guard_state=$_.Exception.Data['owned_guard_state'] }
        if ($_.Exception.Data.Contains('hosted_secondary_failures')) {
            foreach ($errorMessage in $_.Exception.Data['hosted_secondary_failures']) {
                if ($errorMessage -is [Collections.IDictionary]) { $secondary.Add($errorMessage) }
                else { $secondary.Add(@{phase='harness cleanup/evidence';type='System.InvalidOperationException';message=[string]$errorMessage}) }
            }
        }
    } finally {
        Complete-HostedInteractiveRun -Result $result -OldEnvironment $oldEnvironment -Primary $primary -Secondary $secondary -CleanupProof {
            $table=@(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate -OperationTimeoutSec 5 -ErrorAction Stop)
            $result.cleanup=Get-HostedOwnedCleanup $known $table
            Assert-HostedCleanup $result.cleanup
        } -SourceBindings {
            foreach ($path in @(
                '.github\workflows\test.yml','scripts\dev-windows.cmd','scripts\setup-hosted-opengl.ps1','scripts\interactive-win11-lib.ps1',
                'test\windows\interactive-win11-stateful-lib.ps1','test\windows\interactive-win11-pr-smoke.ps1',
                'test\windows\run-hosted-interactive.ps1','test\windows\assert-interactive-runner.ps1',
                'test\windows\assert-hosted-interactive-evidence.ps1','test\windows\fixtures\hosted-opengl-lock.json'
            )) {
                $result.sources+=@{path=$path;sha256=(Get-FileHash (Join-Path $repoRoot $path)).Hash.ToLowerInvariant()}
            }
        } -EvidenceValidator {
            Assert-HostedInteractiveEvidence $result $OutputDirectory $repoRoot
        } -RestoreVariable {
            param($key,$value)
            [Environment]::SetEnvironmentVariable($key,$value)
        } -SummaryWriter {
        if ($env:GITHUB_STEP_SUMMARY) {
            @"
## HOSTEDWINDOWSSERVERCPU: $($result.status)
Historical required check: **Windows 11 Interactive Composite** (name compatibility only).
Actual profile: GitHub-hosted Windows Server 2025 X64, application-local Mesa llvmpipe CPU.
Completed real groups: $($result.groups.Count). Missing desktop, GL, pixels, groups or cleanup proof fails closed.
**NOT** Windows 11 client, physical GPU/pacing/reset, Snap/Mica, native ARM64, release, or GraphCode macOS parity proof.
"@ | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
        }
        } -DiagnosticWriter {
            param($errorRecord)
            Write-Warning "HOSTED_SECONDARY_FAILURE $($errorRecord.phase): $($errorRecord.message)" -WarningAction Continue
        } -ResultWriter {
            $result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result.json') -Encoding utf8NoBOM
        }
    }
}
