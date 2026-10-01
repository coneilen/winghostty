#requires -Version 7.3
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$checker = Join-Path $PSScriptRoot 'assert-hosted-interactive-evidence.ps1'
if (-not (Test-Path -LiteralPath $checker)) {
    throw 'RED: hosted profile producer/validator is absent.'
}
. $checker

$script:checks = 0
if ((Get-Content (Join-Path $repoRoot 'scripts\dev-windows.cmd') -Raw) -notmatch '(?m)^:resolve-installed-vs\s*$') {
    throw 'RED: actual batch wrapper has no installed VS discovery; hosted win25-vs2026 cannot bootstrap.'
}
function Assert-Rejected([scriptblock] $Action, [string] $Reason) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw "Accepted invalid evidence: $Reason" }
    $script:checks++
}
function Copy-Fixture($Value) {
    ConvertFrom-HostedJson ($Value | ConvertTo-Json -Depth 40)
}

$runner = @{
    schema_version = 'winghostty.hosted-runner-provenance.v1'
    profile = 'HOSTEDWINDOWSSERVERCPU'
    runner_environment = 'github-hosted'; runner_os = 'Windows'; runner_arch = 'X64'
    runner_name = 'Hosted Agent'; runner_version = '2.330.0'
    worker_path = 'D:\a\runner\bin\Runner.Worker.exe'; worker_ancestor_verified = $true
    worker_process_id=99;worker_started_at='2026-10-01T10:00:00.0000001Z'
    worker_cim_started_at='2026-10-01T10:00:00.0000000Z';worker_creation_precision_ticks=10
    windows_product_type = 3; windows_build = 26100
    process_session_id = 1; active_console_session_id = 1
    input_desktop = 'Default'; thread_desktop = 'Default'; window_station = 'WinSta0'
    is_system = $false; explorer_count = 1
    repository = 'coneilen/winghostty'; run_id = '123'; run_attempt = '1'
    commit = 'a' * 40; checked_out_commit = 'a' * 40
    canary = @{
        owner_pid = 100; hwnd = 1234; observed_owner_pid = 100
        foreground_hwnd = 1234; foreground_owner_pid = 100
        capture_width = 320; capture_height = 160; sampled_pixels = 16; matching_pixels = 16
        capture_hit_owners=@(100,100,100,100,100,100,100,100,100)
        input_requested = 2; input_returned = 2; input_received = 1
        cleanup_available = $true; remaining_windows = 0
    }
}
Assert-HostedRunnerObservation $runner
$script:checks++
foreach ($mutation in @(
    @{ Key = 'schema_version'; Value = 'winghostty.interactive-runner-provenance.v1' },
    @{ Key = 'profile'; Value = 'Windows11' },
    @{ Key = 'runner_environment'; Value = 'self-hosted' },
    @{ Key = 'runner_arch'; Value = 'ARM64' },
    @{ Key = 'windows_product_type'; Value = 1 },
    @{ Key = 'windows_build'; Value = 20348 },
    @{ Key = 'worker_ancestor_verified'; Value = $false },
    @{ Key = 'runner_version'; Value = '2.327.0' },
    @{ Key = 'is_system'; Value = $true },
    @{ Key = 'explorer_count'; Value = 0 },
    @{ Key = 'thread_desktop'; Value = 'Winlogon' },
    @{ Key = 'process_session_id'; Value = 0 },
    @{ Key = 'checked_out_commit'; Value = 'b' * 40 }
)) {
    $bad = Copy-Fixture $runner
    $bad[$mutation.Key] = $mutation.Value
    Assert-Rejected { Assert-HostedRunnerObservation $bad } $mutation.Key
}
foreach ($key in @('owner_pid','hwnd','observed_owner_pid','foreground_owner_pid','sampled_pixels','matching_pixels','input_requested','input_returned','input_received')) {
    $bad = Copy-Fixture $runner
    $bad.canary[$key] = 0
    Assert-Rejected { Assert-HostedRunnerObservation $bad } "zero canary $key"
    $bad.canary.Remove($key)
    Assert-Rejected { Assert-HostedRunnerObservation $bad } "missing canary $key"
}
$bad = Copy-Fixture $runner
$bad.canary.cleanup_available = $null
Assert-Rejected { Assert-HostedRunnerObservation $bad } 'unknown canary cleanup'
$bad = Copy-Fixture $runner
$bad.canary.remaining_windows = 1
Assert-Rejected { Assert-HostedRunnerObservation $bad } 'leaked canary'

$cleanup = @{
    available = $true; observed_process_count = 3; remaining_process_count = 0
    processes = @(
        @{ process_id = 10; parent_id = 1; started_at = '2026-10-01T10:00:00Z' },
        @{ process_id = 11; parent_id = 10; started_at = '2026-10-01T10:00:01Z' },
        @{ process_id = 12; parent_id = 11; started_at = '2026-10-01T10:00:02Z' }
    )
}
Assert-HostedCleanup $cleanup
$script:checks++
foreach ($value in @($null, $false)) {
    $bad = Copy-Fixture $cleanup; $bad.available = $value
    Assert-Rejected { Assert-HostedCleanup $bad } 'unknown cleanup availability'
}
foreach ($key in @('observed_process_count','remaining_process_count','processes')) {
    $bad = Copy-Fixture $cleanup; $bad.Remove($key)
    Assert-Rejected { Assert-HostedCleanup $bad } "absent $key"
}
$bad = Copy-Fixture $cleanup; $bad.processes = @(); $bad.observed_process_count = 0
Assert-Rejected { Assert-HostedCleanup $bad } 'vacuous cleanup'
$bad = Copy-Fixture $cleanup; $bad.remaining_process_count = 1
Assert-Rejected { Assert-HostedCleanup $bad } 'owned descendant leak'
$bad = Copy-Fixture $cleanup; $bad.processes[1].started_at = 'invalid'
Assert-Rejected { Assert-HostedCleanup $bad } 'invalid identity timestamp'

$lock = Get-Content (Join-Path $PSScriptRoot 'fixtures\hosted-opengl-lock.json') -Raw | ConvertFrom-Json -AsHashtable
Assert-HostedOpenGLLock $lock
$script:checks++
$bad = Copy-Fixture $lock; $bad.asset_url = 'https://github.com/pal1000/mesa-dist-win/releases/latest/download/mesa.7z'
Assert-Rejected { Assert-HostedOpenGLLock $bad } 'unpinned asset'
$bad = Copy-Fixture $lock; $bad.runtime_files += '..\opengl32.dll'
Assert-Rejected { Assert-HostedOpenGLLock $bad } 'deployment traversal'
$bad = Copy-Fixture $lock; $bad.runtime_files = @('x64\opengl32.dll')
Assert-Rejected { Assert-HostedOpenGLLock $bad } 'missing megadriver'

$graphics = @{
    vendor = 'Mesa'; renderer = 'llvmpipe (LLVM 21.1.8, 256 bits)'
    version = '4.5 (Compatibility Profile) Mesa 26.2.3'; glsl_version = '4.50'
    functions = @('glCreateShader','glCompileShader','glCreateProgram','glLinkProgram','glGenFramebuffers','glBindFramebuffer','glBufferData','glTexStorage2D','glBindVertexArray')
    module_path = 'D:\a\repo\zig-out\bin\opengl32.dll'
    module_sha256 = 'c' * 64
}
Assert-HostedGraphicsObservation $graphics 'D:\a\repo\zig-out\bin\opengl32.dll' ('c' * 64)
$script:checks++
foreach ($mutation in @(
    @{Key='renderer';Value='GDI Generic'}, @{Key='version';Value='1.1'},
    @{Key='glsl_version';Value='1.10'}, @{Key='functions';Value=@('glCreateShader')},
    @{Key='module_path';Value='C:\Windows\System32\opengl32.dll'},
    @{Key='module_sha256';Value=('d' * 64)}
)) {
    $bad = Copy-Fixture $graphics; $bad[$mutation.Key] = $mutation.Value
    Assert-Rejected { Assert-HostedGraphicsObservation $bad 'D:\a\repo\zig-out\bin\opengl32.dll' ('c' * 64) } "graphics $($mutation.Key)"
}
Assert-HostedShaderPixels @{ width=100; height=100; sampled_pixels=16; magenta_pixels=16; png_bytes=1000;dominant_color=@{r=255;g=0;b=255;count=16} }
$script:checks++
foreach ($key in @('width','height','sampled_pixels','magenta_pixels','png_bytes')) {
    $bad = @{ width=100; height=100; sampled_pixels=16; magenta_pixels=16; png_bytes=1000;dominant_color=@{r=255;g=0;b=255;count=16} }; $bad[$key] = 0
    Assert-Rejected { Assert-HostedShaderPixels $bad } "missing/blank/wrong-color shader $key"
}
Assert-HostedWorkflowSource (Get-Content (Join-Path $repoRoot '.github\workflows\test.yml') -Raw)
$script:checks++
foreach ($replacement in @(
    @('runs-on: windows-2025','runs-on: windows-2022'),
    @('name: Windows 11 Interactive Composite','name: Bypass'),
    @('-Profile HostedServerCpu','-Profile ClientRelease'),
    @('timeout-minutes: 60','timeout-minutes: 5'),
    @('head.repo.full_name == github.repository','head.repo.full_name != github.repository')
)) {
    $bad = (Get-Content (Join-Path $repoRoot '.github\workflows\test.yml') -Raw).Replace($replacement[0],$replacement[1])
    Assert-Rejected { Assert-HostedWorkflowSource $bad } "workflow $($replacement[0])"
}

. (Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1')
if (-not (Get-Command Get-HostedFileSha256 -ErrorAction SilentlyContinue)) {
    throw 'RED: hosted app evidence depends on unavailable Get-FileHash in the actual PS5.1 child.'
}
. (Join-Path $PSScriptRoot 'run-hosted-interactive.ps1')
. (Join-Path $repoRoot 'scripts\setup-hosted-opengl.ps1')
$tokens=$null;$errors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'assert-interactive-runner.ps1'),[ref]$tokens,[ref]$errors)
$clientFunction=@($runnerAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-ClientReleaseRunnerProfile'},$true))
if ($clientFunction.Count -ne 1) { throw 'Missing exact client release profile production helper.' }
. ([scriptblock]::Create($clientFunction[0].Extent.Text))
Assert-ClientReleaseRunnerProfile 'self-hosted' 1
$script:checks++
Assert-Rejected { Assert-ClientReleaseRunnerProfile 'github-hosted' 1 } 'hosted client label is not self-hosted release proof'
Assert-Rejected { Assert-ClientReleaseRunnerProfile 'self-hosted' 3 } 'Server cannot claim client release proof'
Assert-Rejected { Assert-ClientReleaseRunnerProfile 'self-hosted' '1' } 'client OS product type must be typed'
$observation=@{
    alive=$true;identity_matched=$true;process_id=100;hwnd=1234;owner_pid=100;module_verified=$true
    visible=$true;width=320;height=160;foreground_owner_pid=100;foreground_root=1234;root_hwnd=1234
    hit_owners=@(100,100,100,100,100)
}
$script:mockInputs=0
Invoke-HostedOwnedPrimitive $observation { $script:mockInputs++ } -Capture
if ($script:mockInputs -ne 1) { throw 'Valid owned primitive was not executed.' }
$script:checks++
foreach ($mutation in @(
    @{key='alive';value=$false},@{key='identity_matched';value=$false},
    @{key='owner_pid';value=200},@{key='module_verified';value=$false},
    @{key='module_verified';value=$null},@{key='foreground_owner_pid';value=200},
    @{key='width';value=0},@{key='height';value=0},@{key='visible';value=$false},
    @{key='hit_owners';value=@(100,100,200,100,100)},@{key='hwnd';value=0}
)) {
    $bad=Copy-Fixture $observation
    $bad[$mutation.key]=$mutation.value
    $script:mockInputs=0
    Assert-Rejected { Invoke-HostedOwnedPrimitive $bad { $script:mockInputs++ } -Capture } $mutation.key
    if ($script:mockInputs -ne 0) { throw 'An invalid guard executed mock input/capture.' }
}
$savedProfile=$env:WINGHOSTTY_HOSTED_PROFILE
try {
    $env:WINGHOSTTY_HOSTED_PROFILE=$null
    Assert-HostedCaptureWindow ([IntPtr]1234)
    Assert-HostedInteractiveWindow ([IntPtr]1234) ([Diagnostics.Process]::new()) -Capture
    $script:checks++
} finally { $env:WINGHOSTTY_HOSTED_PROFILE=$savedProfile }

$rootCreated=[datetime]'2026-10-01T10:00:00Z'
$snapshot=@(
    [pscustomobject]@{ProcessId=100;ParentProcessId=1;CreationDate=$rootCreated},
    [pscustomobject]@{ProcessId=101;ParentProcessId=100;CreationDate=$rootCreated.AddSeconds(1)}
)
$unrelated=[pscustomobject]@{ProcessId=999;ParentProcessId=1;CreationDate=$rootCreated}
$clean=Get-HostedSnapshotCleanup $snapshot @($unrelated)
Assert-HostedCleanup $clean
$script:checks++
$live=Get-HostedSnapshotCleanup $snapshot @(
    $unrelated,
    [pscustomobject]@{ProcessId=102;ParentProcessId=101;CreationDate=$rootCreated.AddSeconds(2)},
    [pscustomobject]@{ProcessId=103;ParentProcessId=102;CreationDate=$rootCreated.AddSeconds(3)}
)
if ($live.remaining_process_count -ne 2 -or $live.observed_process_count -ne 4) { throw 'Actual descendant cleanup counts were not retained.' }
Assert-Rejected { Assert-HostedCleanup $live } 'late/grandchild leaks'
Assert-Rejected { Get-HostedSnapshotCleanup $snapshot @() } 'CIM absent is not zero'
Assert-Rejected { Get-HostedSnapshotCleanup @() @($unrelated) } 'snapshot absent is not zero'
$reused=Get-HostedSnapshotCleanup $snapshot @(
    $unrelated,
    [pscustomobject]@{ProcessId=100;ParentProcessId=1;CreationDate=$rootCreated.AddMinutes(1)},
    [pscustomobject]@{ProcessId=104;ParentProcessId=100;CreationDate=$rootCreated.AddMinutes(2)}
)
Assert-HostedCleanup $reused
$script:checks++
$known=@{'root'=@{process_id=100;parent_id=1;started_at=$rootCreated.ToString('o')}}
$live=Get-HostedOwnedCleanup $known @(
    $snapshot[0],$snapshot[1],
    [pscustomobject]@{ProcessId=102;ParentProcessId=101;CreationDate=$rootCreated.AddSeconds(2)}
)
if ($live.remaining_process_count -ne 3 -or $live.observed_process_count -ne 3) { throw 'Owned phase tree failed to close transitively.' }
$script:checks++
Assert-Rejected { Get-HostedOwnedCleanup $known @() } 'unavailable final phase table'
$scalarKnown=@{root=@{process_id=100;parent_id=1;started_at=$rootCreated.AddTicks(9).ToString('o')}}
$scalar=Get-HostedOwnedProcesses $scalarKnown $snapshot[0]
if ($scalar.Count -ne 1) { throw 'A one-row census duplicated the retained native root using its CIM-rounded key.' }
$script:checks++
Assert-Rejected {
    Get-HostedOwnedProcesses @{root=@{process_id=100;parent_id=1;started_at=$rootCreated.ToString('o')}} $snapshot {
        param($entry)
        @{process_id=[int]$entry.ProcessId;parent_id=[int]$entry.ParentProcessId
            started_at=([datetime]$entry.CreationDate).AddMilliseconds(1).ToString('o')}
    }
} 'retained descendant must reject a native generation outside its source microsecond interval'
$generations=@{
    old=@{process_id=200;parent_id=100;started_at=$rootCreated.AddSeconds(1).ToString('o');pid_reserved_through=$rootCreated.AddSeconds(9).ToString('o')}
    current=@{process_id=200;parent_id=100;started_at=$rootCreated.AddSeconds(10).ToString('o');pid_reserved_through=$rootCreated.AddSeconds(12).ToString('o')}
}
$generationTable=@(
    [pscustomobject]@{ProcessId=200;ParentProcessId=100;CreationDate=$rootCreated.AddSeconds(10)},
    [pscustomobject]@{ProcessId=201;ParentProcessId=200;CreationDate=$rootCreated.AddSeconds(11)}
)
# Extracted from the failed 0084161 source; usable in depth-one CI checkouts.
$oldObserverText=@'
function Get-HostedOwnedProcesses($Known, [object[]] $Table) {
    if ($Table.Count -eq 0) { throw 'Process-table availability is unknown; empty is not zero owned helpers.' }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($entry in $Table) {
            $parentId=[int]$entry.ParentProcessId
            if (@($Known.Values | Where-Object { $_.process_id -eq $entry.ProcessId -or $_.process_id -eq $parentId }).Count -eq 0) { continue }
            $created=([datetime]$entry.CreationDate).ToUniversalTime()
            $identity="$([int]$entry.ProcessId)|$($created.Ticks)"
            if ($Known.ContainsKey($identity)) { continue }
            $parents=@($Known.Values | Where-Object { $_.process_id -eq $parentId -and $created -ge ([datetime]$_.started_at).ToUniversalTime() })
            if ($parents.Count -gt 1) { throw 'Ambiguous/reused hosted parent PID identity.' }
            if ($parents.Count -eq 1) {
                $currentParents=@($Table | Where-Object ProcessId -EQ $parentId)
                if ($currentParents.Count -eq 1 -and
                    -not (Test-HostedProcessCreationBinding ([datetime]$parents[0].started_at) ([datetime]$currentParents[0].CreationDate))) {
                    continue
                }
                $Known[$identity]=@{process_id=[int]$entry.ProcessId;parent_id=$parentId;started_at=$created.ToString('o')}
                $changed=$true
            }
        }
    }
    return $Known
}
'@
$oldTokens=$null;$oldErrors=$null
$oldObserverAst=[Management.Automation.Language.Parser]::ParseInput($oldObserverText,[ref]$oldTokens,[ref]$oldErrors)
$oldObserver=@($oldObserverAst.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-HostedOwnedProcesses'
},$true))
if ($oldObserver.Count -ne 1) { throw 'Failed source observer is not uniquely bound.' }
. ([scriptblock]::Create(($oldObserver[0].Extent.Text -replace '^function Get-HostedOwnedProcesses','function Get-FailedHostedOwnedProcesses')))
Assert-Rejected { Get-FailedHostedOwnedProcesses (Copy-Fixture $generations) $generationTable } 'actual failed observer checks history before current generation (RED)'
$generationResult=Get-HostedOwnedProcesses $generations $generationTable
if (@($generationResult.Values | Where-Object process_id -EQ 201).Count -ne 1) {
    throw 'Current census generation was not bound before historical PID ambiguity.'
}
$script:checks++
$duplicateGeneration=Copy-Fixture $generations
$duplicateGeneration.clone=Copy-Fixture $generations.current
Assert-Rejected { Get-HostedOwnedProcesses $duplicateGeneration $generationTable } 'genuinely overlapping retained identity must not be deduplicated'
$missingParent=@([pscustomobject]@{ProcessId=202;ParentProcessId=200;CreationDate=$rootCreated.AddSeconds(5)})
$historical=Get-HostedOwnedProcesses (Copy-Fixture $generations) $missingParent
if (@($historical.Values | Where-Object process_id -EQ 202).Count -ne 1) { throw 'Bounded historical generation failed to retain a late-observed child.' }
$script:checks++
$survivingOldChild=Get-HostedOwnedProcesses (Copy-Fixture $generations) @(
    $generationTable[0],$missingParent[0]
)
if (@($survivingOldChild.Values | Where-Object process_id -EQ 202).Count -ne 1) {
    throw 'A late-observed child predating the current PID generation lost its bounded historical owner.'
}
$script:checks++
$unknownGeneration=@(
    [pscustomobject]@{ProcessId=200;ParentProcessId=999;CreationDate=$rootCreated.AddSeconds(20)},
    [pscustomobject]@{ProcessId=203;ParentProcessId=200;CreationDate=$rootCreated.AddSeconds(21)}
)
$unknown=Get-HostedOwnedProcesses (Copy-Fixture $generations) $unknownGeneration
if (@($unknown.Values | Where-Object process_id -EQ 203).Count -ne 0) { throw 'A foreign current parent generation was adopted as an owned descendant.' }
$script:checks++
Assert-Rejected {
    Get-HostedOwnedProcesses (Copy-Fixture $generations) @(
        [pscustomobject]@{ProcessId=204;ParentProcessId=200;CreationDate=$rootCreated.AddMinutes(2)}
    )
} 'absent latest parent is unbounded history, not proof against unobserved foreign PID reuse'
$gap=Copy-Fixture $generations
Assert-Rejected {
    Get-HostedOwnedProcesses $gap @(
        [pscustomobject]@{ProcessId=205;ParentProcessId=200;CreationDate=$rootCreated.AddSeconds(9).AddMilliseconds(500)}
    )
} 'next owned generation alone cannot prove the intervening PID reservation gap'
$acquisitionEntry=[pscustomobject]@{ProcessId=201;ParentProcessId=100;CreationDate=$rootCreated.AddSeconds(1)}
$acquisitionParent=@{process_id=100;parent_id=1;started_at=$rootCreated.ToString('o');pid_reserved_through=$rootCreated.AddSeconds(5).ToString('o')}
$acquisitionSnapshot=@($snapshot[0],$acquisitionEntry)
$missingAcquire={
    [CmdletBinding()]param($id)
    $exception=[Microsoft.PowerShell.Commands.ProcessCommandException]::new('Controlled exact ProcessNotFound acquisition race')
    $record=[Management.Automation.ErrorRecord]::new($exception,'NoProcessFoundForGivenId',[Management.Automation.ErrorCategory]::ObjectNotFound,$id)
    $PSCmdlet.ThrowTerminatingError($record)
}
$gone=Get-HostedRetainedIdentity $acquisitionEntry $acquisitionParent $acquisitionSnapshot @{} `
    -AcquireProcess $missingAcquire -FreshCensus { $snapshot[0] }
if ($gone.identity_capture -cne 'cim-observed-then-confirmed-absent' -or
    $gone.disappearance_proof.fresh_pid_count -ne 0 -or $gone.disappearance_proof.surviving_related_count -ne 0 -or
    $gone.ContainsKey('pid_reserved_through')) {
    throw 'Confirmed snapshot-to-acquisition exit fabricated a native handle or unbounded PID reservation.'
}
$script:checks++
foreach ($fresh in @(
    @($snapshot[0],$acquisitionEntry),
    @($snapshot[0],[pscustomobject]@{ProcessId=201;ParentProcessId=999;CreationDate=$rootCreated.AddMinutes(1)}),
    @($snapshot[0],[pscustomobject]@{ProcessId=202;ParentProcessId=201;CreationDate=$rootCreated.AddSeconds(2)}),
    @()
)) {
    Assert-Rejected {
        Get-HostedRetainedIdentity $acquisitionEntry $acquisitionParent $acquisitionSnapshot @{} `
            -AcquireProcess $missingAcquire -FreshCensus { $fresh }
    } 'missing acquisition is not exit proof with present/reused PID, surviving related descendant, or unavailable census'
}
$unreservedParent=Copy-Fixture $acquisitionParent
$unreservedParent.Remove('pid_reserved_through')
Assert-Rejected {
    Get-HostedRetainedIdentity $acquisitionEntry $unreservedParent $acquisitionSnapshot @{} `
        -AcquireProcess $missingAcquire -FreshCensus { $snapshot[0] }
} 'gone PID still requires an actual owned-parent reservation covering its observed creation'
$accessFailure=[UnauthorizedAccessException]::new('Controlled process handle access denial')
$script:freshAcquisitionQueries=0
try {
    Get-HostedRetainedIdentity $acquisitionEntry $acquisitionParent $acquisitionSnapshot @{} `
        -AcquireProcess {throw $accessFailure} -FreshCensus {$script:freshAcquisitionQueries++;$snapshot[0]}
    throw 'Access denial was accepted as process exit.'
} catch {
    if (-not [object]::ReferenceEquals($_.Exception,$accessFailure) -or $script:freshAcquisitionQueries -ne 0) {
        throw 'Non-ProcessNotFound acquisition error was masked or waived by fresh-census fallback.'
    }
}
$script:checks++
try {
    Get-HostedRetainedIdentity $acquisitionEntry $acquisitionParent $acquisitionSnapshot @{} `
        -AcquireProcess $missingAcquire -FreshCensus {throw [IO.IOException]::new('Controlled unavailable fresh census')}
    throw 'Missing acquisition plus unavailable census was accepted.'
} catch {
    if ($_.Exception -isnot [Microsoft.PowerShell.Commands.ProcessCommandException] -or
        @($_.Exception.Data['hosted_secondary_failures']).Count -ne 1 -or
        $_.Exception.Data['owned_guard_state'].fresh_census_available -ne $null) {
        throw 'Acquisition primary/census secondary/unknown availability was not preserved.'
    }
}
$script:checks++
$observedGrandchild=[pscustomobject]@{ProcessId=202;ParentProcessId=201;CreationDate=$rootCreated.AddSeconds(2)}
Assert-Rejected {
    Get-HostedRetainedIdentity $acquisitionEntry $acquisitionParent (@($acquisitionSnapshot)+@($observedGrandchild)) @{} `
        -AcquireProcess $missingAcquire -FreshCensus {
            @($snapshot[0],[pscustomobject]@{ProcessId=203;ParentProcessId=202;CreationDate=$rootCreated.AddSeconds(3)})
        }
} 'a surviving descendant of an observed vanished intermediary is not zero-owned exit closure'

$script:attempts=[Collections.Generic.List[string]]::new()
$original=[InvalidOperationException]::new('original controlled harness failure')
try {
    Invoke-HostedLifecycle -Operation { throw $original } -CleanupSteps @(
        @{name='first';action={ $script:attempts.Add('first'); throw 'cleanup one' }},
        @{name='second';action={ $script:attempts.Add('second'); throw 'cleanup two' }}
    ) -EvidenceWriter { param($primary,$errors) $script:attempts.Add('writer'); throw 'writer failed' }
    throw 'Lifecycle swallowed the primary failure.'
} catch {
    if (-not [object]::ReferenceEquals($_.Exception,$original) -or
        @($_.Exception.Data['hosted_secondary_failures']).Count -ne 3 -or
        ($script:attempts -join '|') -cne 'first|second|writer') {
        throw 'Lifecycle replaced the primary or failed to attempt/preserve every cleanup/evidence secondary.'
    }
}
$script:checks++
Assert-Rejected {
    Invoke-HostedLifecycle -Operation {} -CleanupSteps @(@{name='cleanup';action={throw 'failed'}}) -EvidenceWriter {}
} 'cleanup cannot turn a successful operation into a pass'

$fixtureRoot=Join-Path $repoRoot '.sandbox\hosted-headless-contracts'
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$logPath=Join-Path $fixtureRoot 'fixture.log'
[IO.File]::WriteAllText($logPath,'Synthetic headless contract fixture; NOT native GUI evidence.')
$hashFixture=Join-Path $fixtureRoot 'hash-abc.bin'
[IO.File]::WriteAllBytes($hashFixture,[Text.Encoding]::ASCII.GetBytes('abc'))
if ((Get-HostedFileSha256 $hashFixture) -cne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' -or
    (Get-HostedFileSha256 $hashFixture) -cne (Get-FileHash $hashFixture).Hash.ToLowerInvariant()) {
    throw 'Streaming SHA256 changed exact file-byte hash semantics.'
}
$script:checks++
Assert-Rejected { Get-HostedFileSha256 (Join-Path $fixtureRoot 'hash-absent.bin') } 'missing hash file must preserve explicit IO failure'
$ps5Transport=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
. $env:WINGHOSTTY_TRANSPORT_LIB
$PSModuleAutoLoadingPreference='None'
function Get-FileHash { throw 'Unavailable legacy command must not be used.' }
$hash=Get-HostedFileSha256 $env:WINGHOSTTY_TRANSPORT_HASH_FILE
if ($hash -cne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') { throw 'PS5 streaming hash mismatch' }
$record=@{
    process_id=123;started_ticks=456;started_at='2026-10-01T10:00:00.0000000Z'
    module_sha256=$hash;windows=@(789);secondary_failures=@()
    cleanup=@{available=$true;observed_process_count=1;remaining_process_count=0;processes=@(@{process_id=123;parent_id=1;started_at='2026-10-01T10:00:00.0000000Z'})}
    fixture_only=$true
}
Save-HostedProcessEvidence $record
$path=Join-Path $env:WINGHOSTTY_HOSTED_EVIDENCE_DIR 'transport\process-123-456.json'
$read=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
if ($read.module_sha256 -cne $hash -or $read.cleanup.available -ne $true -or $read.windows[0] -ne 789 -or
    $read.fixture_only -ne $true) { throw 'Actual PS5 owned record JSON transport failed' }
[Console]::WriteLine('Actual PS5 shared hash/owned-record JSON writer/read transport: PASS (inert records; no native calls)')
'@
$transportEnvironment=@{}
foreach ($name in @('WINGHOSTTY_TRANSPORT_LIB','WINGHOSTTY_TRANSPORT_HASH_FILE','WINGHOSTTY_HOSTED_EVIDENCE_DIR','WINGHOSTTY_HOSTED_STAGE')) {
    $transportEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
}
try {
    $env:WINGHOSTTY_TRANSPORT_LIB=Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
    $env:WINGHOSTTY_TRANSPORT_HASH_FILE=$hashFixture
    $env:WINGHOSTTY_HOSTED_EVIDENCE_DIR=Join-Path $fixtureRoot 'ps5-transport'
    $env:WINGHOSTTY_HOSTED_STAGE='transport'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps5Transport))
    & powershell.exe -NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw 'Actual production PS5 transport control failed.' }
    $script:checks++
} finally {
    foreach ($name in $transportEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$transportEnvironment[$name]) }
}
$pngPath=Join-Path $fixtureRoot 'fixture.png'
Add-Type -AssemblyName System.Drawing
$bitmap=[Drawing.Bitmap]::new(16,16)
try {
    foreach ($x in 0..15) { foreach ($y in 0..15) { $bitmap.SetPixel($x,$y,[Drawing.Color]::Magenta) } }
    $bitmap.Save($pngPath,[Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
$sourcePaths=@(
    '.github\workflows\test.yml','scripts\dev-windows.cmd','scripts\setup-hosted-opengl.ps1','scripts\interactive-win11-lib.ps1',
    'test\windows\interactive-win11-stateful-lib.ps1','test\windows\interactive-win11-pr-smoke.ps1',
    'test\windows\run-hosted-interactive.ps1','test\windows\assert-interactive-runner.ps1',
    'test\windows\assert-hosted-interactive-evidence.ps1','test\windows\fixtures\hosted-opengl-lock.json'
)
$suite=@{
    schema_version='winghostty.hosted-interactive-evidence.v1';profile='HOSTEDWINDOWSSERVERCPU';status='pass'
    scope='Server CPU core GUI/render/shader correctness; NOT Windows 11 client or hardware/release proof'
    fixture_only=$true;event_name='pull_request';failure=$null;secondary_failures=@();runner=(Copy-Fixture $runner)
    graphics=(Copy-Fixture $graphics);cleanup=(Copy-Fixture $cleanup);groups=@()
    deployment=@{
        directory=(Join-Path $repoRoot 'zig-out\bin')
        lock_sha256=(Get-FileHash (Join-Path $PSScriptRoot 'fixtures\hosted-opengl-lock.json')).Hash.ToLowerInvariant()
        files=@(
            @{name='opengl32.dll';sha256=$lock.runtime_sha256['opengl32.dll'];architecture='X64';imports=@('libgallium_wgl.dll','GDI32.dll','KERNEL32.dll');delay_imports=@()},
            @{name='libgallium_wgl.dll';sha256=$lock.runtime_sha256['libgallium_wgl.dll'];architecture='X64';imports=@($lock.system_imports);delay_imports=@()}
        )
    }
    sources=@($sourcePaths | ForEach-Object { @{path=$_;sha256=(Get-FileHash (Join-Path $repoRoot $_)).Hash.ToLowerInvariant()} })
}
$suite.graphics.module_path=Join-Path $suite.deployment.directory 'opengl32.dll'
$suite.graphics.module_sha256=$lock.runtime_sha256['opengl32.dll']
foreach ($name in @('smoke','key-input','new-tab','resize','undo','accessibility','palette-theme','session-restore','shaders')) {
    $harness="test\windows\interactive-win11-$name.ps1"
    $suite.groups+=@{
        name=$name;harness=$harness;harness_sha256=(Get-FileHash (Join-Path $repoRoot $harness)).Hash.ToLowerInvariant()
        status='pass';exit_code=0;observed_app_count=1;observed_window_count=1
        artifacts=@(@{path='fixture.log';sha256=(Get-FileHash $logPath).Hash.ToLowerInvariant()})
        cleanup=(Copy-Fixture $cleanup)
        owned_windows=@(@{hwnd=1234;process_id=10;started_at=$cleanup.processes[0].started_at})
        loaded_modules=@(@{
            process_id=10;started_at=$cleanup.processes[0].started_at
            application_path=(Join-Path $suite.deployment.directory 'winghostty.exe');application_sha256=('e'*64)
            path=$suite.graphics.module_path;sha256=$suite.graphics.module_sha256
            megadriver_path=(Join-Path $suite.deployment.directory 'libgallium_wgl.dll')
            megadriver_sha256=$lock.runtime_sha256['libgallium_wgl.dll']
        })
    }
}
$suite.groups[8].shader_pixels=Get-HostedPngPixels $pngPath
$suite.groups[8].shader_pixels.process_id=10
$suite.groups[8].shader_pixels.started_at=$cleanup.processes[0].started_at
$suite.groups[8].shader_pixels.hwnd=1234
$suite.groups[8].shader_pixels.roi=@{left=0;top=0;width=16;height=16}
$suite.groups[8].screenshot=@{path='fixture.png';sha256=(Get-FileHash $pngPath).Hash.ToLowerInvariant()}
Assert-HostedInteractiveEvidence $suite $fixtureRoot $repoRoot
$script:checks++
$suite | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $fixtureRoot 'example-fixture-only.json') -Encoding utf8NoBOM
foreach ($key in @('groups','cleanup','runner','graphics','deployment','sources')) {
    $bad=Copy-Fixture $suite; $bad.Remove($key)
    Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } "missing suite $key"
}
$bad=Copy-Fixture $suite; $bad.groups=$bad.groups[0..7]
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'missing ninth shader'
$bad=Copy-Fixture $suite; $bad.groups[0].name='key-input'
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'duplicate group'
foreach ($key in @('observed_app_count','observed_window_count')) {
    $bad=Copy-Fixture $suite; $bad.groups[0][$key]=0
    Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } "zero $key"
    $bad.groups[0][$key]=999
    Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } "unobserved $key"
}
$bad=Copy-Fixture $suite; $bad.groups[8].screenshot.path='absent.png'
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'missing PNG'
foreach ($key in @('process_id','hwnd')) {
    foreach ($value in @([string]$suite.groups[8].shader_pixels[$key],[double]$suite.groups[8].shader_pixels[$key],$true)) {
        $bad=Copy-Fixture $suite;$bad.groups[8].shader_pixels[$key]=$value
        Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } "wrong shader capture integer type $key"
    }
}
$bad=Copy-Fixture $suite;$bad.groups[8].shader_pixels.started_at=[DateTimeOffset]$cleanup.processes[0].started_at
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'shader identity must be an explicit string'
$bad=Copy-Fixture $suite; $bad.groups[0].artifacts[0].sha256='0'*64
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'unbound group artifact'
$bad=Copy-Fixture $suite; $bad.groups[0].harness_sha256='0'*64
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'harness source mismatch'
$bad=Copy-Fixture $suite; $bad.groups[0].cleanup.available=$null
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'unknown group cleanup'
$bad=Copy-Fixture $suite; $bad.groups[0].loaded_modules[0].started_at='2026-10-01T11:00:00Z'
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'module process reused'
$bad=Copy-Fixture $suite; $bad.sources=$bad.sources[0..7]
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'partial source binding set'
$bad=Copy-Fixture $suite; $bad.sources[0].path='..\foreign'
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'escaping source'
$bad=Copy-Fixture $suite; $bad.event_name='schedule'
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'non-PR collapsed to quick mode'
$wrong=Join-Path $fixtureRoot 'wrong.png'
$bitmap=[Drawing.Bitmap]::new(16,16)
try { $bitmap.Save($wrong,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
$bad=Copy-Fixture $suite; $bad.groups[8].screenshot=@{path='wrong.png';sha256=(Get-FileHash $wrong).Hash.ToLowerInvariant()}
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'real PNG wrong color despite forged positive counters'
foreach ($value in @('True','0',0.0,$true)) {
    foreach ($key in @('windows_build','process_session_id','worker_process_id','explorer_count')) {
        $bad=Copy-Fixture $runner;$bad[$key]=$value
        Assert-Rejected { Assert-HostedRunnerObservation $bad } "wrong integer type $key"
    }
    foreach ($key in @('observed_process_count','remaining_process_count')) {
        $bad=Copy-Fixture $cleanup;$bad[$key]=$value
        Assert-Rejected { Assert-HostedCleanup $bad } "wrong cleanup integer type $key"
    }
}
foreach ($value in @('True','False',1,0,1.0)) {
    foreach ($key in @('worker_ancestor_verified','is_system')) {
        $bad=Copy-Fixture $runner;$bad[$key]=$value
        Assert-Rejected { Assert-HostedRunnerObservation $bad } "wrong boolean type $key"
    }
    $bad=Copy-Fixture $cleanup;$bad.available=$value
    Assert-Rejected { Assert-HostedCleanup $bad } 'wrong availability boolean type'
}
foreach ($value in @(1,1.0,$true)) {
    $bad=Copy-Fixture $runner;$bad.run_id=$value
    Assert-Rejected { Assert-HostedRunnerObservation $bad } 'run identity must be an explicit string'
}
foreach ($milliseconds in @(1,9)) {
    $bad=Copy-Fixture $runner
    $bad.worker_started_at=([DateTimeOffset]$runner.worker_cim_started_at).AddMilliseconds($milliseconds).ToString('o')
    Assert-Rejected { Assert-HostedRunnerObservation $bad } 'worker PID reuse inside former ten-millisecond waiver'
    if (Test-HostedProcessCreationBinding $rootCreated.AddMilliseconds($milliseconds) $rootCreated) { throw 'Native/CIM binding adopted a reused process.' }
    $bad=Copy-Fixture $suite
    $bad.groups[0].loaded_modules[0].started_at=([DateTimeOffset]$cleanup.processes[0].started_at).AddMilliseconds($milliseconds).ToString('o')
    $bad.groups[0].owned_windows[0].started_at=$bad.groups[0].loaded_modules[0].started_at
    Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'module PID reuse inside former ten-millisecond waiver'
}
if (-not (Test-HostedProcessCreationBinding $rootCreated.AddTicks(9) $rootCreated) -or
    (Test-HostedProcessCreationBinding $rootCreated.AddTicks(10) $rootCreated)) {
    throw 'CIM binding is not exactly the supported half-open microsecond truncation interval.'
}
$script:checks++
Assert-Rejected { ConvertFrom-HostedJson '{"status":"pass","status":"error"}' } 'duplicate JSON keys'
Assert-Rejected { ConvertFrom-HostedJson ('{"x":'*45+'0'+'}'*45) } 'excess evidence nesting'
$bad=Copy-Fixture $suite
$bad.groups[0].harness='test\windows\interactive-win11-key-input.ps1'
$bad.groups[0].harness_sha256=(Get-FileHash (Join-Path $repoRoot $bad.groups[0].harness)).Hash.ToLowerInvariant()
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'valid hash but wrong canonical harness'
foreach ($key in @('runtime_sha256','system_imports','delay_imports','notices')) {
    $bad=Copy-Fixture $lock;$bad.Remove($key)
    Assert-Rejected { Assert-HostedOpenGLLock $bad } "missing consumed lock field $key"
}
$bad=Copy-Fixture $suite;$bad.deployment.files[0].sha256='c'*64;$bad.graphics.module_sha256='c'*64
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'self-reported loader hash differs from lock'
$bad=Copy-Fixture $suite;$bad.groups[8].shader_pixels.sample_points[0].x=-1
Assert-Rejected { Assert-HostedInteractiveEvidence $bad $fixtureRoot $repoRoot } 'ROI sample outside the retained surface'
$full=Copy-Fixture $suite;$full.event_name='schedule'
foreach ($phase in @(
    @{name='full-composite';harness='test\windows\flagship\Invoke-InteractiveWin11.ps1'},
    @{name='accessibility-soak';harness='test\windows\interactive-win11-accessibility.ps1'},
    @{name='palette-high-contrast';harness='test\windows\interactive-win11-palette-theme.ps1'},
    @{name='session-restore-full';harness='test\windows\interactive-win11-session-restore.ps1'}
)) {
    $group=Copy-Fixture $suite.groups[0];$group.name=$phase.name;$group.harness=$phase.harness
    $group.harness_sha256=(Get-FileHash (Join-Path $repoRoot $phase.harness)).Hash.ToLowerInvariant()
    $full.groups+=$group
}
Assert-HostedInteractiveEvidence $full $fixtureRoot $repoRoot
$script:checks++
$partial=Join-Path $fixtureRoot 'dominant-magenta.png'
$bitmap=[Drawing.Bitmap]::FromFile($pngPath)
try {
    foreach ($point in $suite.groups[8].shader_pixels.sample_points[0..3]) { $bitmap.SetPixel($point.x,$point.y,[Drawing.Color]::Black) }
    $bitmap.Save($partial,[Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
$pixels=Get-HostedPngPixels $partial
Assert-HostedShaderPixels $pixels
if ($pixels.magenta_pixels -ne 12) { throw 'Existing dominant-color shader semantics changed to an all-image/all-sample requirement.' }
$script:checks++
$clientPixel=Copy-Fixture $observation
$clientPixel.client_x=1;$clientPixel.client_y=1;$clientPixel.client_width=320;$clientPixel.client_height=160
Assert-HostedClientPixelObservation $clientPixel
$script:checks++
$bad=Copy-Fixture $clientPixel;$bad.client_x=320
Assert-Rejected { Assert-HostedClientPixelObservation $bad } 'window-DC sample is outside owned client ROI'
$bad=Copy-Fixture $clientPixel;$bad.owner_pid=200
Assert-Rejected { Assert-HostedClientPixelObservation $bad } 'window-DC HWND ownership changed'
$bad=Copy-Fixture $observation;$bad.module_verified='True'
Assert-Rejected { Invoke-HostedOwnedPrimitive $bad {} -Capture } 'string boolean cannot authorize primitive'

$script:finalizerAttempts=[Collections.Generic.List[string]]::new()
$finalizerException=[InvalidOperationException]::new('actual outer primary fixture')
$primaryRecord=$null
try { throw $finalizerException } catch { $primaryRecord=$_ }
$finalizerResult=@{status='pass';secondary_failures=@()}
$finalizerErrors=[Collections.Generic.List[object]]::new()
$oldWarnings=$WarningPreference
try {
    $WarningPreference='Stop'
    try {
        Complete-HostedInteractiveRun -Result $finalizerResult -OldEnvironment @{ONE='one';TWO='two'} `
            -Primary $primaryRecord -Secondary $finalizerErrors `
            -CleanupProof { $script:finalizerAttempts.Add('cleanup');throw 'unavailable actual cleanup seam' } `
            -SourceBindings { $script:finalizerAttempts.Add('sources');throw 'source writer failed' } `
            -EvidenceValidator { throw 'Validator must not replace an existing primary or cleanup error.' } `
            -RestoreVariable {param($key,$value) $script:finalizerAttempts.Add("environment $key");throw 'restore failed'} `
            -SummaryWriter { $script:finalizerAttempts.Add('summary');throw [IO.IOException]::new('summary IO failed') } `
            -DiagnosticWriter {param($errorRecord) $script:finalizerAttempts.Add('warning');Write-Warning 'controlled diagnostic failure'} `
            -ResultWriter { $script:finalizerAttempts.Add('result');throw [IO.IOException]::new('result IO failed') }
        throw 'Actual outer finalizer swallowed the primary.'
    } catch {
        if (-not [object]::ReferenceEquals($_.Exception,$finalizerException) -or
            @($_.Exception.Data['hosted_secondary_failures']).Count -ne 11 -or
            $finalizerResult.status -cne 'error' -or
            @($script:finalizerAttempts | Where-Object { $_ -like 'environment *' }).Count -ne 2 -or
            ($script:finalizerAttempts | Select-Object -Last 1) -cne 'result') {
            throw 'Actual outer production finalizer masked the original or skipped an independent step.'
        }
        foreach ($secondaryFailure in $_.Exception.Data['hosted_secondary_failures']) {
            Assert-HostedRequired $secondaryFailure @('phase','type','message')
        }
    }
} finally { $WarningPreference=$oldWarnings }
$script:checks++
$validationFailure=[InvalidOperationException]::new('actual retained PNG validation failed')
$validationResult=@{status='pass';failure=$null;secondary_failures=@()}
$validationErrors=[Collections.Generic.List[object]]::new()
$script:writtenValidationStatus=$null
try {
    Complete-HostedInteractiveRun -Result $validationResult -OldEnvironment @{} -Primary $null -Secondary $validationErrors `
        -CleanupProof {} -SourceBindings {} -RestoreVariable {} -SummaryWriter {} -DiagnosticWriter {} `
        -EvidenceValidator {throw $validationFailure} -ResultWriter {$script:writtenValidationStatus=$validationResult.status}
    throw 'Finalizer accepted invalid complete evidence.'
} catch {
    if (-not [object]::ReferenceEquals($_.Exception,$validationFailure) -or
        $script:writtenValidationStatus -cne 'error' -or $null -eq $validationResult.failure) {
        throw 'Strict validation failure emitted success-shaped evidence or lost its identity.'
    }
}
$script:checks++
$tokens=$null;$errors=$null
$outerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-hosted-interactive.ps1'),[ref]$tokens,[ref]$errors)
$finalizerCalls=@($outerAst.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Complete-HostedInteractiveRun'
},$true))
if ($finalizerCalls.Count -ne 1 -or $finalizerCalls[0].Parent.Parent -isnot [Management.Automation.Language.StatementBlockAst]) {
    throw 'The tested finalizer is not the actual outer production finally path.'
}
$script:checks++

$vsFixture=Join-Path $fixtureRoot 'installed-vs'
[IO.Directory]::CreateDirectory($vsFixture) | Out-Null
$fakeProgramFiles=Join-Path $vsFixture 'Program Files'
$fakeProgramFilesX86=Join-Path $vsFixture 'Program Files (x86)'
$installer=Join-Path $fakeProgramFilesX86 'Microsoft Visual Studio\Installer'
[IO.Directory]::CreateDirectory($installer) | Out-Null
$fakeVswhere=Join-Path $installer 'vswhere.exe'
$fixtureZig=Join-Path $vsFixture 'zig-existence-only'
[IO.Directory]::CreateDirectory($fixtureZig) | Out-Null
[IO.File]::WriteAllText((Join-Path $fixtureZig 'zig.exe'),'Existence-only inert fixture; never execute or claim a Zig version.')
if (-not (Test-Path $fakeVswhere)) {
    $compilerScript=@'
Add-Type -OutputType ConsoleApplication -OutputAssembly $env:WINGHOSTTY_VSWHERE_STUB_PATH -TypeDefinition @"
using System;
public static class VswhereDiscoveryFixture {
    public static int Main(string[] args) {
        string actual=String.Join("|",args);
        string expected="-products|*|-requires|Microsoft.VisualStudio.Component.VC.Tools.x86.x64|-latest|-property|installationPath";
        if (actual != expected) return 17;
        Console.Write(Environment.GetEnvironmentVariable("WINGHOSTTY_VSWHERE_FIXTURE_OUTPUT"));
        return Int32.Parse(Environment.GetEnvironmentVariable("WINGHOSTTY_VSWHERE_FIXTURE_EXIT"));
    }
}
"@
'@
    $savedStub=$env:WINGHOSTTY_VSWHERE_STUB_PATH
    try {
        $env:WINGHOSTTY_VSWHERE_STUB_PATH=$fakeVswhere
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compilerScript))
        & powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $fakeVswhere)) { throw 'Headless discovery tool fixture compilation failed.' }
    } finally { $env:WINGHOSTTY_VSWHERE_STUB_PATH=$savedStub }
}
$newVsRoot=Join-Path $fakeProgramFiles 'Microsoft Visual Studio\18\Enterprise'
$newShell=Join-Path $newVsRoot 'Common7\Tools\VsDevCmd.bat'
$legacyRoot=Join-Path $fakeProgramFiles 'Microsoft Visual Studio\2022\Community'
$legacyShell=Join-Path $legacyRoot 'Common7\Tools\VsDevCmd.bat'
if ([IO.File]::Exists($legacyShell)) { [IO.File]::Delete($legacyShell) }
[IO.Directory]::CreateDirectory((Split-Path -Parent $newShell)) | Out-Null
[IO.File]::WriteAllText($newShell,"@echo off`r`necho FIXTURE_VS_SHELL`r`nexit /b 0`r`n")
function Invoke-VsDiscoveryFixture([string] $Output, [int] $ExitCode=0) {
    $saved=@{}
    foreach ($name in @('ProgramFiles','ProgramFiles(x86)','ZIG_HOME','WINGHOSTTY_VSWHERE_FIXTURE_OUTPUT','WINGHOSTTY_VSWHERE_FIXTURE_EXIT')) {
        $saved[$name]=[Environment]::GetEnvironmentVariable($name)
    }
    try {
        [Environment]::SetEnvironmentVariable('ProgramFiles',$fakeProgramFiles)
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)',$fakeProgramFilesX86)
        $env:WINGHOSTTY_VSWHERE_FIXTURE_OUTPUT=$Output
        $env:WINGHOSTTY_VSWHERE_FIXTURE_EXIT=[string]$ExitCode
        $env:ZIG_HOME=$fixtureZig
        $batchCommand='set "ProgramFiles='+$fakeProgramFiles+'" & set "ProgramFiles(x86)='+$fakeProgramFilesX86+'" & call "'+
            (Join-Path $repoRoot 'scripts\dev-windows.cmd')+'" --print-cache-paths'
        $text=@(& $env:ComSpec /d /c $batchCommand 2>&1)
        return @{exit_code=$LASTEXITCODE;text=($text -join "`n")}
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    }
}
$discovered=Invoke-VsDiscoveryFixture $newVsRoot
if ($discovered.exit_code -ne 0 -or $discovered.text -notmatch 'FIXTURE_VS_SHELL' -or
    $discovered.text -notmatch 'ZIG_LOCAL_CACHE_DIR=') { throw "Actual wrapper failed installed current VS layout: $($discovered.text)" }
$script:checks++
foreach ($case in @(
    @{output=($newVsRoot+"`r`n"+$newVsRoot);exit=0;reason='ambiguous'},
    @{output=(Join-Path $vsFixture 'missing installation');exit=0;reason='unavailable'},
    @{output=$newVsRoot;exit=9;reason='failed'}
)) {
    $result=Invoke-VsDiscoveryFixture $case.output $case.exit
    if ($result.exit_code -eq 0 -or $result.text -notmatch $case.reason -or $result.text -match 'FIXTURE_VS_SHELL') {
        throw "Actual wrapper accepted $($case.reason) installed discovery."
    }
    $script:checks++
}
$missing=Invoke-VsDiscoveryFixture ''
if ($missing.exit_code -eq 0 -or $missing.text -notmatch 'Missing VS Dev shell bootstrap') { throw "No installed or legacy VS must fail explicitly: $($missing.text)" }
$script:checks++
[IO.Directory]::CreateDirectory((Split-Path -Parent $legacyShell)) | Out-Null
[IO.File]::WriteAllText($legacyShell,"@echo off`r`necho FIXTURE_LEGACY_VS_SHELL`r`nexit /b 0`r`n")
$legacy=Invoke-VsDiscoveryFixture ''
if ($legacy.exit_code -ne 0 -or $legacy.text -notmatch 'FIXTURE_LEGACY_VS_SHELL') { throw 'Registered discovery absence must preserve existing legacy fallback.' }
$script:checks++

$phaseRoot=Join-Path $fixtureRoot 'inert-phase'
[IO.Directory]::CreateDirectory($phaseRoot) | Out-Null
$phaseInput=Join-Path $phaseRoot 'input-fixture-only.json'
$modeledSuite=Copy-Fixture $suite
foreach ($group in $modeledSuite.groups) {
    $group.cleanup.processes[0].parent_id=900
    $nativeCapture=([DateTimeOffset]$group.loaded_modules[0].started_at).AddTicks(6).ToString('o')
    $group.loaded_modules[0].started_at=$nativeCapture
    $group.owned_windows[0].started_at=$nativeCapture
}
$modeledSuite | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $phaseInput -Encoding utf8NoBOM
$childTransport=Join-Path $phaseRoot 'inert-record-child.ps1'
[IO.File]::WriteAllText($childTransport,@'
param([string]$InputPath,[string]$LibPath,[string]$Root)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Import-Module Microsoft.PowerShell.Management -ErrorAction Stop
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
. $LibPath
$PSModuleAutoLoadingPreference='None'
function Get-FileHash { throw 'Legacy hash command is intentionally unavailable in this inert transport control.' }
$suite=Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
if ($suite.fixture_only -ne $true) { throw 'Child transport requires explicitly inert input.' }
foreach ($group in $suite.groups) {
    $module=$group.loaded_modules[0]
    $record=@{
        process_id=$module.process_id;started_at=$module.started_at
        started_ticks=([DateTimeOffset]$module.started_at).UtcTicks
        application_path=$module.application_path;application_sha256=$module.application_sha256
        module_path=$module.path;module_sha256=$module.sha256
        megadriver_path=$module.megadriver_path;megadriver_sha256=$module.megadriver_sha256
        windows=@($group.owned_windows[0].hwnd);cleanup=$group.cleanup
        secondary_failures=@();fixture_only=$true
    }
    $env:WINGHOSTTY_HOSTED_EVIDENCE_DIR=[IO.Path]::Combine($Root,'processes')
    $env:WINGHOSTTY_HOSTED_STAGE=$group.name
    Save-HostedProcessEvidence $record
}
[Console]::WriteLine('Inert actual PS5 child evidence writer: PASS; native capabilities not executed.')
'@)
$script:phasePolls=0;$script:phaseCensusCalls=0;$script:phaseDisposed=0
$nativeRoot=$rootCreated.AddSeconds(-1).AddTicks(7)
$cimRoot=$rootCreated.AddSeconds(-1)
$inertProcess=[pscustomobject]@{
    Id=900;Handle=[IntPtr]1;StartTime=$nativeRoot;HasExited=$false;ExitCode=0
    StandardOutput=$null;StandardError=$null
}
$inertProcess | Add-Member ScriptMethod WaitForExit {
    param($milliseconds)
    $script:phasePolls++
    if ($script:phasePolls -ge 2) { $this.HasExited=$true;return $true }
    return $false
}
$inertProcess | Add-Member ScriptMethod Dispose { $script:phaseDisposed++ }
$runtime=@{
    start={
        param($scriptPath,$arguments)
        $text=@(& powershell.exe -NoLogo -NoProfile -NonInteractive -File $scriptPath @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Actual inert PS5 child writer failed: $($text -join "`n")" }
        $stream=[pscustomobject]@{Value=($text -join "`n")}
        $stream | Add-Member ScriptMethod ReadToEndAsync { return [Threading.Tasks.Task]::FromResult([string]$this.Value) }
        $empty=[pscustomobject]@{Value=''}
        $empty | Add-Member ScriptMethod ReadToEndAsync { return [Threading.Tasks.Task]::FromResult([string]$this.Value) }
        $inertProcess.StandardOutput=$stream;$inertProcess.StandardError=$empty
        return $inertProcess
    }
    census={
        $script:phaseCensusCalls++
        if ($script:phaseCensusCalls -gt 1) { return $unrelated }
        @(
            [pscustomobject]@{ProcessId=900;ParentProcessId=$PID;CreationDate=$cimRoot},
            [pscustomobject]@{ProcessId=10;ParentProcessId=900;CreationDate=$rootCreated},
            [pscustomobject]@{ProcessId=11;ParentProcessId=10;CreationDate=$rootCreated.AddSeconds(1)},
            [pscustomobject]@{ProcessId=12;ParentProcessId=11;CreationDate=$rootCreated.AddSeconds(2)}
        ) + $generationTable
    }
    stop_root={ throw 'Positive inert phase unexpectedly requested root termination.' }
    stop_descendant={ throw 'Positive inert phase unexpectedly adopted a foreign or already-exited process.' }
    retain={
        param($entry,$parent,$observedTable)
        Get-HostedRetainedIdentity $entry $parent $observedTable @{} -FreshCensus {throw 'Live acquisition must not need a fresh census'} `
            -AcquireProcess {
                param($id)
                $record=[pscustomobject]@{Id=$id;Handle=[IntPtr]1;StartTime=([datetime]$entry.CreationDate).ToUniversalTime().AddTicks(6)}
                $record | Add-Member ScriptMethod Dispose {}
                $record
            }
    }
    release={}
}
$phaseKnown=Copy-Fixture $generations
$phaseLog=Join-Path $phaseRoot 'phase.log'
Invoke-HostedHarnessProcess $childTransport @(
    '-InputPath',$phaseInput,'-LibPath',(Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'),'-Root',$phaseRoot
) $phaseLog $phaseKnown $runtime
if ($script:phaseDisposed -ne 1 -or @($phaseKnown.Values | Where-Object process_id -EQ 900).Count -ne 1 -or
    (Get-Content $phaseLog -Raw) -notmatch 'Inert actual PS5 child evidence writer: PASS') {
    throw 'Actual phase entry/census/native-versus-CIM identity/PS5 output transport did not complete.'
}
$modeledSuite.groups=@($modeledSuite.groups | ForEach-Object {
    Get-HostedGroupEvidence @{name=$_.name;harness=$_.harness;harness_sha256=$_.harness_sha256;status='pass';exit_code=0} $phaseRoot
})
$modeledSuite.groups[8].shader_pixels=Copy-Fixture $suite.groups[8].shader_pixels
$modeledSuite.groups[8].shader_pixels.started_at=$modeledSuite.groups[8].loaded_modules[0].started_at
$modeledSuite.groups[8].screenshot=Copy-Fixture $suite.groups[8].screenshot
Copy-Item -LiteralPath $pngPath -Destination (Join-Path $phaseRoot 'fixture.png') -Force
$phaseErrors=[Collections.Generic.List[object]]::new()
Complete-HostedInteractiveRun -Result $modeledSuite -OldEnvironment @{} -Primary $null -Secondary $phaseErrors `
    -CleanupProof { $modeledSuite.cleanup=Get-HostedOwnedCleanup $phaseKnown @($unrelated);Assert-HostedCleanup $modeledSuite.cleanup } `
    -SourceBindings {} -RestoreVariable {} -SummaryWriter {} -DiagnosticWriter {} `
    -EvidenceValidator { Assert-HostedInteractiveEvidence $modeledSuite $phaseRoot $repoRoot } `
    -ResultWriter { $modeledSuite | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $phaseRoot 'result-fixture-only.json') -Encoding utf8NoBOM }
if ($modeledSuite.groups.Count -ne 9 -or $modeledSuite.cleanup.remaining_process_count -ne 0 -or
    $modeledSuite.fixture_only -ne $true) { throw 'Inert phase/PS5 record collector/finalizer/strict consumer did not complete nine existing fixtures.' }
$script:checks++
$savedStreams=@{out=$inertProcess.StandardOutput;err=$inertProcess.StandardError}
$phaseFailure=[InvalidOperationException]::new('inert actual phase census unavailable')
$faultRuntime=@{
    start={
        param($scriptPath,$arguments)
        $inertProcess.HasExited=$false
        $broken=[pscustomobject]@{}
        $broken | Add-Member ScriptMethod ReadToEndAsync {
            return [Threading.Tasks.Task]::FromException[string]([IO.IOException]::new('partial owned output'))
        }
        $inertProcess.StandardOutput=$broken
        return $inertProcess
    }
    census={ throw $phaseFailure }
    stop_root={ $inertProcess.HasExited=$true;throw 'root cleanup failure' }
    stop_descendant={ throw 'Unexpected descendant adoption from unavailable census.' }
    retain={ throw 'Unexpected retention from unavailable census.' }
    release={}
}
$script:phasePolls=0;$script:phaseDisposed=0
try {
    Invoke-HostedHarnessProcess 'inert-no-native.ps1' @() (Join-Path $phaseRoot 'fault-output.log') @{} $faultRuntime
    throw 'Actual phase swallowed primary census failure.'
} catch {
    if (-not [object]::ReferenceEquals($_.Exception,$phaseFailure) -or
        @($_.Exception.Data['hosted_secondary_failures']).Count -ne 3 -or $script:phaseDisposed -ne 1) {
        throw 'Actual phase lost original failure, partial-output secondary, or independent handle disposal.'
    }
} finally {
    $inertProcess.StandardOutput=$savedStreams.out;$inertProcess.StandardError=$savedStreams.err
}
$script:checks++
$partialRecord=Join-Path $phaseRoot 'processes\smoke\process-partial.json'
[IO.File]::WriteAllText($partialRecord,'{"process_id":')
try {
    Assert-Rejected {
        Get-HostedGroupEvidence @{name='smoke';harness='test\windows\interactive-win11-smoke.ps1'} $phaseRoot
    } 'partial actual child JSON must not become completed group evidence'
} finally { [IO.File]::Delete($partialRecord) }

function Assert-HostedSourceGuards([string] $Text, [string] $Context, [string[]] $Members, [int] $ExpectedCount) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "Invalid source: $Context" }
    $calls=@($ast.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Value -cin $Members
    },$true))
    if ($calls.Count -ne $ExpectedCount) { throw "Unexpected primitive count in ${Context}: $($calls.Count)" }
    foreach ($call in $calls) {
        $node=$call;$guarded=$false
        while ($null -ne $node.Parent) {
            if ($node.Parent -is [Management.Automation.Language.StatementBlockAst] -or
                $node.Parent -is [Management.Automation.Language.NamedBlockAst]) {
                foreach ($statement in $node.Parent.Statements) {
                    if ($statement.Extent.StartOffset -ge $node.Extent.StartOffset) { break }
                    $guards=@($statement.FindAll({param($candidate)
                        $candidate -is [Management.Automation.Language.CommandAst] -and
                            $candidate.GetCommandName() -cin @('Assert-HostedCaptureWindow','Assert-HostedClientPixel','Assert-HostedInteractiveWindow','Assert-AccessibilityInputOwner')
                    },$false))
                    if ($guards.Count -gt 0 -and $statement -is [Management.Automation.Language.PipelineAst]) { $guarded=$true;break }
                }
            }
            if ($guarded) { break }
            $node=$node.Parent
        }
        if (-not $guarded) { throw "Actual primitive lacks a dominating owned guard: $Context line $($call.Extent.StartLineNumber) $($call.Member.Value)" }
    }
}
foreach ($entry in @(
    @{path='test\windows\interactive-win11-shaders.ps1';members=@('CopyFromScreen');count=1},
    @{path='test\windows\interactive-win11-resize.ps1';members=@('CopyFromScreen');count=1},
    @{path='test\windows\interactive-win11-stateful-lib.ps1';members=@('CopyFromScreen');count=1},
    @{path='test\windows\interactive-win11-accessibility.ps1';members=@('TrySampleWindowClientPixel');count=9}
)) {
    $text=Get-Content (Join-Path $repoRoot $entry.path) -Raw
    Assert-HostedSourceGuards $text $entry.path $entry.members $entry.count
    $script:checks++
    $unguarded=$text -replace '(?m)^\s*Assert-Hosted(?:CaptureWindow|ClientPixel|InteractiveWindow).*\r?\n',''
    Assert-Rejected { Assert-HostedSourceGuards $unguarded $entry.path $entry.members $entry.count } "removed capture guards $($entry.path)"
}
$inputSource=Get-Content (Join-Path $PSScriptRoot 'interactive-win11-accessibility.ps1') -Raw
Assert-HostedSourceGuards $inputSource 'accessibility SendInput wrappers and nested Alt recovery' @('SendChord','SendUnicodeText','SendMouseClick','ForceForeground') 32
$script:checks++
if ($inputSource -match 'keybd_event|mouse_event' -or
    [regex]::Matches($inputSource,'(?m)^\s*int returned = unchecked\(\(int\)SendInput\(').Count -ne 1 -or
    $inputSource -notmatch '(?s)public static bool ForceForeground\(IntPtr hwnd\).*?Submit\(new INPUT') {
    throw 'Input primitive source audit changed: all native input must use the guarded wrappers, including nested Alt recovery.'
}
$script:checks++
Write-Host "hosted interactive headless contracts: PASS ($script:checks assertions; no native GUI operations)"
