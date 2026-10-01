#requires -Version 7.3
[CmdletBinding()]
param(
    [string] $EvidencePath,
    [string] $RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

function ConvertFrom-HostedJson([string] $Json) {
    $options=[Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth=40
    $document=[Text.Json.JsonDocument]::Parse($Json,$options)
    function Convert-HostedNode($Node) {
        switch ($Node.ValueKind.ToString()) {
            'Object' {
                $object=[hashtable]::new([StringComparer]::Ordinal)
                foreach ($property in $Node.EnumerateObject()) {
                    if ($object.ContainsKey($property.Name)) { throw 'Duplicate JSON evidence property.' }
                    $object[$property.Name]=Convert-HostedNode $property.Value
                }
                return $object
            }
            'Array' {
                $items=[Collections.Generic.List[object]]::new()
                foreach ($item in $Node.EnumerateArray()) { $items.Add((Convert-HostedNode $item)) }
                return ,$items.ToArray()
            }
            'String' { return $Node.GetString() }
            'Number' {
                [long]$integer=0
                if ($Node.TryGetInt64([ref]$integer)) { return $integer }
                return $Node.GetDouble()
            }
            'True' { return $true }
            'False' { return $false }
            'Null' { return $null }
            default { throw 'Unsupported JSON evidence kind.' }
        }
    }
    try { return Convert-HostedNode $document.RootElement }
    finally { $document.Dispose() }
}

function Assert-HostedRequired {
    param($Object, [string[]] $Keys)
    if ($null -eq $Object -or $Object -isnot [System.Collections.IDictionary]) {
        throw 'Evidence must be a JSON object.'
    }
    foreach ($key in $Keys) {
        if (-not $Object.Contains($key) -or $null -eq $Object[$key]) {
            throw "Missing evidence field: $key"
        }
    }
}

function Assert-HostedIntegerFields($Object, [string[]] $Keys) {
    Assert-HostedRequired $Object $Keys
    foreach ($key in $Keys) {
        $value=$Object[$key]
        if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [uint32] -and $value -isnot [uint64] -and
            $value -isnot [int16] -and $value -isnot [uint16] -and $value -isnot [byte]) {
            throw "Evidence field must be an integer, not a coerced string/bool/float: $key"
        }
    }
}

function Assert-HostedBooleanFields($Object, [string[]] $Keys) {
    Assert-HostedRequired $Object $Keys
    foreach ($key in $Keys) {
        if ($Object[$key] -isnot [bool]) { throw "Evidence field must be a real boolean: $key" }
    }
}

function Invoke-HostedLifecycle {
    param(
        [Parameter(Mandatory)] [scriptblock] $Operation,
        [Parameter(Mandatory)] [object[]] $CleanupSteps,
        [Parameter(Mandatory)] [scriptblock] $EvidenceWriter,
        [hashtable] $Payload = @{}
    )
    $primary=$null
    $errors=[Collections.Generic.List[object]]::new()
    try { [void](& $Operation) } catch {
        $primary=$_
        $native=$_.Exception
        while ($null -ne $native) {
            if ($native.Data.Contains('hosted_secondary_failures')) {
                foreach ($errorMessage in $native.Data['hosted_secondary_failures']) {
                    $errors.Add(@{phase='native cleanup';type=$native.GetType().FullName;message=[string]$errorMessage})
                }
            }
            $native=$native.InnerException
        }
    }
    foreach ($step in $CleanupSteps) {
        try { [void](& $step.action) }
        catch { $errors.Add(@{phase=$step.name;type=$_.Exception.GetType().FullName;message=$_.Exception.Message}) }
    }
    try { [void](& $EvidenceWriter $primary @($errors)) }
    catch { $errors.Add(@{phase='evidence';type=$_.Exception.GetType().FullName;message=$_.Exception.Message}) }
    if ($primary) {
        $primary.Exception.Data['hosted_secondary_failures']=@($errors)
        foreach ($key in $Payload.Keys) { $primary.Exception.Data[$key]=$Payload[$key] }
        throw $primary
    }
    if ($errors.Count -gt 0) {
        $failure=[InvalidOperationException]::new('Hosted cleanup/evidence failed: '+(($errors | ForEach-Object { "$($_.phase): $($_.message)" }) -join '; '))
        $failure.Data['hosted_secondary_failures']=@($errors)
        foreach ($key in $Payload.Keys) { $failure.Data[$key]=$Payload[$key] }
        throw $failure
    }
}

function Assert-HostedRunnerObservation($Observation) {
    Assert-HostedRequired $Observation @(
        'schema_version','profile','runner_environment','runner_os','runner_arch','runner_name',
        'runner_version','worker_path','worker_ancestor_verified','worker_process_id','worker_started_at','worker_cim_started_at','worker_creation_precision_ticks','windows_product_type','windows_build',
        'process_session_id','active_console_session_id','input_desktop','thread_desktop','window_station',
        'is_system','explorer_count','repository','run_id','run_attempt','commit','checked_out_commit','canary'
    )
    Assert-HostedIntegerFields $Observation @('worker_process_id','worker_creation_precision_ticks','windows_product_type','windows_build','process_session_id','active_console_session_id','explorer_count')
    Assert-HostedBooleanFields $Observation @('worker_ancestor_verified','is_system')
    foreach ($key in @('schema_version','profile','runner_environment','runner_os','runner_arch','runner_name','runner_version','worker_path','input_desktop','thread_desktop','window_station','repository','run_id','run_attempt','commit','checked_out_commit')) {
        if ($Observation[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Observation[$key])) { throw "Runner field must be a nonempty string: $key" }
    }
    [DateTimeOffset]$workerNative=[DateTimeOffset]::MinValue
    [DateTimeOffset]$workerCim=[DateTimeOffset]::MinValue
    if ($Observation.worker_process_id -le 0 -or $Observation.worker_creation_precision_ticks -ne 10 -or
        $Observation.worker_started_at -isnot [string] -or $Observation.worker_cim_started_at -isnot [string] -or
        -not [DateTimeOffset]::TryParse($Observation.worker_started_at,[ref]$workerNative) -or
        -not [DateTimeOffset]::TryParse($Observation.worker_cim_started_at,[ref]$workerCim) -or
        $workerNative.UtcTicks -lt $workerCim.UtcTicks -or $workerNative.UtcTicks -ge $workerCim.UtcTicks+10) {
        throw 'Runner.Worker identity is outside the actual CIM one-microsecond truncation interval.'
    }
    if ($Observation.schema_version -cne 'winghostty.hosted-runner-provenance.v1' -or
        $Observation.profile -cne 'HOSTEDWINDOWSSERVERCPU' -or
        $Observation.runner_environment -cne 'github-hosted' -or
        $Observation.runner_os -cne 'Windows' -or $Observation.runner_arch -cne 'X64' -or
        $Observation.windows_product_type -ne 3 -or $Observation.windows_build -lt 26100 -or
        $Observation.is_system -cne $false -or $Observation.worker_ancestor_verified -cne $true -or
        $Observation.worker_path -notmatch '\\bin\\Runner\.Worker\.exe$' -or
        [version]$Observation.runner_version -lt [version]'2.327.1' -or
        $Observation.process_session_id -le 0 -or
        $Observation.process_session_id -ne $Observation.active_console_session_id -or
        $Observation.explorer_count -le 0 -or
        $Observation.input_desktop -cne 'Default' -or $Observation.thread_desktop -cne 'Default' -or
        $Observation.window_station -cne 'WinSta0' -or
        $Observation.commit -notmatch '^[0-9a-f]{40}$' -or
        $Observation.commit -cne $Observation.checked_out_commit -or
        $Observation.run_id -notmatch '^[1-9][0-9]*$' -or $Observation.run_attempt -notmatch '^[1-9][0-9]*$') {
        throw 'Hosted Server CPU provenance does not meet the real runner/desktop/checkout floor.'
    }
    $canary = $Observation.canary
    Assert-HostedRequired $canary @(
        'owner_pid','hwnd','observed_owner_pid','foreground_hwnd','foreground_owner_pid',
        'capture_width','capture_height','capture_hit_owners','sampled_pixels','matching_pixels',
        'input_requested','input_returned','input_received','cleanup_available','remaining_windows'
    )
    Assert-HostedIntegerFields $canary @('owner_pid','hwnd','observed_owner_pid','foreground_hwnd','foreground_owner_pid','capture_width','capture_height','sampled_pixels','matching_pixels','input_requested','input_returned','input_received','remaining_windows')
    Assert-HostedBooleanFields $canary @('cleanup_available')
    if (@($canary.capture_hit_owners).Count -ne 9) { throw 'Canary capture rectangle hit ownership is unavailable.' }
    foreach ($owner in $canary.capture_hit_owners) {
        if (($owner -isnot [int] -and $owner -isnot [long] -and $owner -isnot [uint32]) -or $owner -ne $canary.owner_pid) {
            throw 'Canary capture point is not owned by the retained canary process.'
        }
    }
    if ($canary.owner_pid -le 0 -or $canary.hwnd -le 0 -or
        $canary.observed_owner_pid -ne $canary.owner_pid -or
        $canary.foreground_hwnd -ne $canary.hwnd -or $canary.foreground_owner_pid -ne $canary.owner_pid -or
        $canary.capture_width -le 0 -or $canary.capture_height -le 0 -or
        $canary.sampled_pixels -le 0 -or $canary.matching_pixels -ne $canary.sampled_pixels -or
        $canary.input_requested -le 0 -or $canary.input_returned -ne $canary.input_requested -or
        $canary.input_received -le 0 -or $canary.cleanup_available -cne $true -or
        $canary.remaining_windows -ne 0) {
        throw 'Owned native foreground/capture/input canary did not complete and clean up.'
    }
}

function Assert-HostedCleanup($Cleanup) {
    Assert-HostedRequired $Cleanup @('available','observed_process_count','remaining_process_count','processes')
    Assert-HostedBooleanFields $Cleanup @('available')
    Assert-HostedIntegerFields $Cleanup @('observed_process_count','remaining_process_count')
    if ($Cleanup.available -cne $true -or $Cleanup.observed_process_count -le 0 -or
        $Cleanup.remaining_process_count -ne 0 -or
        @($Cleanup.processes).Count -ne $Cleanup.observed_process_count) {
        throw 'Owned process cleanup is unavailable, empty, partial, or leaked.'
    }
    $identities = [Collections.Generic.HashSet[string]]::new()
    foreach ($process in $Cleanup.processes) {
        Assert-HostedRequired $process @('process_id','parent_id','started_at')
        Assert-HostedIntegerFields $process @('process_id','parent_id')
        if ($process.started_at -isnot [string]) { throw 'Process creation timestamp must be an explicit string.' }
        [DateTimeOffset]$started = [DateTimeOffset]::MinValue
        if ($process.process_id -le 0 -or $process.parent_id -lt 0 -or
            -not [DateTimeOffset]::TryParse($process.started_at, [ref]$started) -or
            -not $identities.Add("$($process.process_id)|$($started.UtcTicks)")) {
            throw 'Process cleanup contains invalid or duplicate PID/creation-time bindings.'
        }
    }
}

function Assert-HostedOpenGLLock($Lock) {
    Assert-HostedRequired $Lock @('schema_version','profile','architecture','release','asset_url','asset_sha256','asset_bytes','driver','deployment','runtime_files','runtime_sha256','system_imports','delay_imports','notice_files','notices','sources')
    Assert-HostedIntegerFields $Lock @('asset_bytes')
    Assert-HostedRequired $Lock.runtime_sha256 @('opengl32.dll','libgallium_wgl.dll')
    $expectedUrl = "https://github.com/pal1000/mesa-dist-win/releases/download/$($Lock.release)/mesa3d-$($Lock.release)-release-msvc.7z"
    if ($Lock.schema_version -cne 'winghostty.hosted-opengl-lock.v1' -or
        $Lock.profile -cne 'HOSTEDWINDOWSSERVERCPU' -or $Lock.architecture -cne 'X64' -or
        $Lock.release -notmatch '^\d+\.\d+\.\d+$' -or $Lock.asset_url -cne $expectedUrl -or
        $Lock.asset_sha256 -notmatch '^[0-9a-f]{64}$' -or $Lock.asset_bytes -le 0 -or
        $Lock.driver -cne 'llvmpipe' -or $Lock.deployment -cne 'application-local-only' -or
        (@($Lock.runtime_files) -join '|') -cne 'x64\opengl32.dll|x64\libgallium_wgl.dll' -or
        @($Lock.notice_files).Count -le 0 -or @($Lock.sources).Count -lt 3) {
        throw 'Mesa lock must pin the reviewed x64 WGL llvmpipe dependency closure and notices.'
    }
    if (@($Lock.runtime_sha256.Keys).Count -ne 2 -or @($Lock.delay_imports).Count -ne 0) { throw 'Unreviewed Mesa dependency closure.' }
    foreach ($name in @('opengl32.dll','libgallium_wgl.dll')) {
        if ($Lock.runtime_sha256[$name] -notmatch '^[0-9a-f]{64}$') { throw 'Missing pinned DLL SHA256.' }
    }
    $inbox=@('ADVAPI32.dll','GDI32.dll','KERNEL32.dll','ntdll.dll','ole32.dll','SHELL32.dll','USER32.dll','VERSION.dll')
    if ((@($Lock.system_imports | Sort-Object) -join '|') -ine (@($inbox | Sort-Object) -join '|')) { throw 'Unknown system dependency allowance.' }
    $noticeNames=@($Lock.notices | ForEach-Object name)
    if ($noticeNames.Count -ne 6 -or (@($noticeNames | Sort-Object -Unique) -join '|') -cne (@($Lock.notice_files | Sort-Object) -join '|')) {
        throw 'The full pinned notice/build-information record is required.'
    }
    foreach ($notice in $Lock.notices) {
        Assert-HostedRequired $notice @('name','url','sha256')
        if ($notice.name -notmatch '^[a-zA-Z0-9.-]+$' -or $notice.sha256 -notmatch '^[0-9a-f]{64}$' -or
            $notice.url -notmatch '^https://raw\.githubusercontent\.com/(?:pal1000/mesa-dist-win/26\.2\.3/|chaotic-cx/mesa-mirror/mesa-26\.2\.3/|llvm/llvm-project/llvmorg-23\.1\.2/|facebook/zstd/v1\.5\.7/|madler/zlib/v1\.3\.2/)') {
            throw 'Notice source is not the reviewed immutable version pin.'
        }
    }
}

function Assert-HostedGraphicsObservation($Graphics, [string] $ExpectedPath, [string] $ExpectedHash) {
    Assert-HostedRequired $Graphics @('vendor','renderer','version','glsl_version','functions','module_path','module_sha256')
    $version = [regex]::Match($Graphics.version, '^(\d+)\.(\d+)')
    $glsl = [regex]::Match($Graphics.glsl_version, '^(\d+)\.(\d+)')
    if ($Graphics.vendor -notmatch 'Mesa' -or $Graphics.renderer -notmatch '^llvmpipe\b' -or
        -not $version.Success -or -not $glsl.Success -or
        [version]$version.Value -lt [version]'4.3' -or [version]$glsl.Value -lt [version]'4.30' -or
        $Graphics.module_path -ine $ExpectedPath -or $Graphics.module_sha256 -cne $ExpectedHash) {
        throw 'Actual loaded WGL/GL/GLSL implementation is not the pinned application-local Mesa CPU driver.'
    }
    foreach ($function in @('glCreateShader','glCompileShader','glCreateProgram','glLinkProgram','glGenFramebuffers','glBindFramebuffer','glBufferData','glTexStorage2D','glBindVertexArray')) {
        if ($function -cnotin @($Graphics.functions)) { throw "Missing actual GL entrypoint: $function" }
    }
}

function Assert-HostedShaderPixels($Pixels) {
    Assert-HostedRequired $Pixels @('width','height','sampled_pixels','magenta_pixels','png_bytes','dominant_color')
    Assert-HostedIntegerFields $Pixels @('width','height','sampled_pixels','magenta_pixels','png_bytes')
    Assert-HostedIntegerFields $Pixels.dominant_color @('r','g','b','count')
    if ($Pixels.width -le 0 -or $Pixels.height -le 0 -or $Pixels.png_bytes -le 0 -or
        $Pixels.sampled_pixels -ne 16 -or $Pixels.magenta_pixels -le 0 -or
        $Pixels.magenta_pixels -gt $Pixels.sampled_pixels -or
        $Pixels.dominant_color.count -le 0 -or $Pixels.dominant_color.count -gt $Pixels.magenta_pixels -or
        $Pixels.dominant_color.r -lt 220 -or $Pixels.dominant_color.r -gt 255 -or
        $Pixels.dominant_color.g -lt 0 -or $Pixels.dominant_color.g -gt 40 -or
        $Pixels.dominant_color.b -lt 220 -or $Pixels.dominant_color.b -gt 255) {
        throw 'Shader screenshot is missing, empty, or fails R>=220 G<=40 B>=220.'
    }
}

function Assert-HostedWorkflowSource([string] $Source) {
    $match = [regex]::Match($Source, '(?ms)^  windows-interactive:\r?\n.*?(?=^  \S|\z)')
    if (-not $match.Success) { throw 'Required job windows-interactive is absent.' }
    $job = $match.Value
    if ($job -notmatch '(?m)^    runs-on: windows-2025\s*$' -or
        $job -notmatch '(?m)^    name: Windows 11 Interactive Composite\s*$') { throw 'Hosted runner/check identity changed.' }
    foreach ($text in @(
        'name: Windows 11 Interactive Composite','runs-on: windows-2025','timeout-minutes: 60',
        'head.repo.full_name == github.repository',"github.event_name == 'schedule'",
        "github.ref == 'refs/heads/main'",'inputs.run_interactive_win11',
        '-Profile HostedServerCpu','run-hosted-interactive.ps1',
        'assert-hosted-interactive-evidence.ps1','retention-days: 14','include-hidden-files: true'
    )) {
        if (-not $job.Contains($text, [StringComparison]::Ordinal)) { throw "Hosted workflow binding missing: $text" }
    }
    if ($job -match '(?m)^\s*(?:continue-on-error:\s*true|runs-on:.*self-hosted)' -or
        $job -match '(?i)MESA_GL_VERSION_OVERRIDE|MESA_GLSL_VERSION_OVERRIDE') {
        throw 'Hosted job must not waive failures or synthesize driver versions.'
    }
    foreach ($name in @('Prove interactive runner provenance','Hosted profile headless contract tests','Run interactive Win11 composite','Verify complete hosted Server CPU evidence')) {
        $steps=[regex]::Matches($job,'(?ms)^      - name: '+[regex]::Escape($name)+'\r?\n.*?(?=^      - name:|\z)')
        if ($steps.Count -ne 1 -or $steps[0].Value -match '(?m)^        (?:if|continue-on-error):' -or
            $steps[0].Value -notmatch '(?m)^        shell: pwsh\s*$') {
            throw "Hosted proof step cannot be conditional/waived/replaced: $name"
        }
    }
}

function Get-HostedPngPixels([string] $Path, [object[]] $SamplePoints) {
    $bytes=[IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8 -or [Convert]::ToHexString($bytes[0..7]) -cne '89504E470D0A1A0A') { throw 'Shader artifact is not a nonempty PNG.' }
    Add-Type -AssemblyName System.Drawing
    $image=[Drawing.Bitmap]::FromFile($Path)
    try {
        $pixels=@{width=$image.Width;height=$image.Height;sampled_pixels=0;magenta_pixels=0;png_bytes=$bytes.Length;sample_points=@();dominant_color=$null}
        $counts=@{};$dominantCount=0;$dominantArgb=0
        $ordinal=0
        foreach ($column in 1..4) {
            foreach ($row in 1..4) {
                $x=[int]($image.Width*$column/5)
                $y=[int]($image.Height*$row/5)
                if ($SamplePoints) {
                    if ($SamplePoints.Count -ne 16) { throw 'Shader must preserve the existing ordered 4-by-4 surface sampling points.' }
                    Assert-HostedIntegerFields $SamplePoints[$ordinal] @('x','y')
                    if ($SamplePoints[$ordinal].x -ne $x -or $SamplePoints[$ordinal].y -ne $y) { throw 'Shader sampling ROI/point drifted from the actual harness.' }
                }
                if ($x -lt 0 -or $x -ge $image.Width -or $y -lt 0 -or $y -ge $image.Height) { throw 'Shader sample point is outside the actual PNG.' }
                $pixels.sample_points+=@{x=$x;y=$y}
                $ordinal++
                $color=$image.GetPixel($x,$y)
                $pixels.sampled_pixels++
                if ($color.R -ge 220 -and $color.G -le 40 -and $color.B -ge 220) { $pixels.magenta_pixels++ }
                $argb=$color.ToArgb()
                $counts[$argb]=1+[int]$counts[$argb]
                if ($counts[$argb] -gt $dominantCount) { $dominantCount=$counts[$argb];$dominantArgb=$argb }
            }
        }
        $dominant=[Drawing.Color]::FromArgb($dominantArgb)
        $pixels.dominant_color=@{r=[int]$dominant.R;g=[int]$dominant.G;b=[int]$dominant.B;count=$dominantCount}
        return $pixels
    } finally { $image.Dispose() }
}

function Assert-HostedArtifact($Artifact, [string] $Root) {
    Assert-HostedRequired $Artifact @('path','sha256')
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Artifact.path))
    if ([IO.Path]::IsPathRooted($Artifact.path) -or
        -not $path.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -or
        $Artifact.sha256 -notmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Item -LiteralPath $path).Length -le 0 -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Artifact.sha256) {
        throw "Missing, escaping, empty, or hash-mismatched artifact: $($Artifact.path)"
    }
    return $path
}

function Assert-HostedInteractiveEvidence($Evidence, [string] $Root, [string] $SourceRoot) {
    Assert-HostedRequired $Evidence @('schema_version','profile','status','scope','runner','graphics','deployment','groups','cleanup','sources','secondary_failures','event_name')
    if (-not $Evidence.Contains('failure')) { throw 'Failure state is absent.' }
    if ($Evidence.schema_version -cne 'winghostty.hosted-interactive-evidence.v1' -or
        $Evidence.profile -cne 'HOSTEDWINDOWSSERVERCPU' -or $Evidence.status -cne 'pass' -or
        $Evidence.scope -cne 'Server CPU core GUI/render/shader correctness; NOT Windows 11 client or hardware/release proof' -or
        $null -ne $Evidence.failure -or @($Evidence.secondary_failures).Count -ne 0) {
        throw 'Hosted evidence is not a complete passing Server CPU profile.'
    }
    Assert-HostedRunnerObservation $Evidence.runner
    Assert-HostedCleanup $Evidence.cleanup
    $lock = ConvertFrom-HostedJson (Get-Content (Join-Path $SourceRoot 'test\windows\fixtures\hosted-opengl-lock.json') -Raw)
    Assert-HostedOpenGLLock $lock
    Assert-HostedRequired $Evidence.deployment @('directory','files','lock_sha256')
    if ($Evidence.deployment.directory -ine (Join-Path $SourceRoot 'zig-out\bin')) { throw 'Deployment is outside the actual CI application directory.' }
    if ($Evidence.deployment.lock_sha256 -cne (Get-FileHash (Join-Path $SourceRoot 'test\windows\fixtures\hosted-opengl-lock.json')).Hash.ToLowerInvariant()) {
        throw 'Mesa deployment is not bound to the checked-out lock.'
    }
    $glPath = Join-Path $Evidence.deployment.directory 'opengl32.dll'
    if ((@($Evidence.deployment.files | ForEach-Object name | Sort-Object) -join '|') -cne 'libgallium_wgl.dll|opengl32.dll') {
        throw 'Deployment must record exactly the two locked x64 WGL DLLs.'
    }
    foreach ($file in $Evidence.deployment.files) {
        Assert-HostedRequired $file @('name','sha256','architecture','imports','delay_imports')
        $expectedImports = if ($file.name -ceq 'opengl32.dll') {
            @('libgallium_wgl.dll','GDI32.dll','KERNEL32.dll')
        } else { @($lock.system_imports) }
        if ($file.architecture -cne 'X64' -or $file.sha256 -cne $lock.runtime_sha256[$file.name] -or
            (@($file.imports | Sort-Object) -join '|') -ine (@($expectedImports | Sort-Object) -join '|') -or
            @($file.delay_imports).Count -ne 0) { throw 'Deployment static/delay imports, architecture, or hashes differ from the reviewed lock.' }
    }
    $gl = @($Evidence.deployment.files | Where-Object name -CEQ 'opengl32.dll')
    if ($gl.Count -ne 1) { throw 'Missing exact Mesa loader deployment record.' }
    Assert-HostedGraphicsObservation $Evidence.graphics $glPath $lock.runtime_sha256['opengl32.dll']
    $expected = @('smoke','key-input','new-tab','resize','undo','accessibility','palette-theme','session-restore','shaders')
    if (@($Evidence.groups).Count -lt 9 -or (@($Evidence.groups | Select-Object -First 9 | ForEach-Object name) -join '|') -cne ($expected -join '|')) {
        throw 'All eight PR groups plus shader validation must complete in order.'
    }
    $full = @('full-composite','accessibility-soak','palette-high-contrast','session-restore-full')
    $expectedGroups = if ($Evidence.event_name -ceq 'pull_request') { $expected } else { $expected + $full }
    if ($Evidence.event_name -cnotin @('pull_request','push','schedule','workflow_dispatch') -or
        (@($Evidence.groups | ForEach-Object name) -join '|') -cne ($expectedGroups -join '|')) {
        throw 'Event-specific suite is incomplete, duplicated or collapsed to quick mode.'
    }
    foreach ($group in $Evidence.groups) {
        Assert-HostedRequired $group @('name','harness','harness_sha256','status','exit_code','artifacts','observed_app_count','observed_window_count','loaded_modules','owned_windows','cleanup')
        Assert-HostedIntegerFields $group @('exit_code','observed_app_count','observed_window_count')
        $expectedHarness = switch ($group.name) {
            'full-composite' { 'test\windows\flagship\Invoke-InteractiveWin11.ps1' }
            'accessibility-soak' { 'test\windows\interactive-win11-accessibility.ps1' }
            'palette-high-contrast' { 'test\windows\interactive-win11-palette-theme.ps1' }
            'session-restore-full' { 'test\windows\interactive-win11-session-restore.ps1' }
            default { "test\windows\interactive-win11-$($group.name).ps1" }
        }
        if ($group.status -cne 'pass' -or $group.exit_code -ne 0 -or
            $group.observed_app_count -le 0 -or $group.observed_window_count -le 0 -or
            $group.harness -cne $expectedHarness -or @($group.artifacts).Count -eq 0 -or
            @($group.loaded_modules).Count -ne $group.observed_app_count -or
            @($group.owned_windows).Count -ne $group.observed_window_count -or
            $group.harness_sha256 -cne (Get-FileHash (Join-Path $SourceRoot $group.harness)).Hash.ToLowerInvariant()) {
            throw "Partial or unbound real harness completion: $($group.name)"
        }
        Assert-HostedCleanup $group.cleanup
        foreach ($window in $group.owned_windows) {
            Assert-HostedRequired $window @('hwnd','process_id','started_at')
            Assert-HostedIntegerFields $window @('hwnd','process_id')
            if ($window.hwnd -le 0 -or @($group.loaded_modules | Where-Object {
                $_.process_id -eq $window.process_id -and $_.started_at -ceq $window.started_at
            }).Count -ne 1) { throw 'Window is not bound to one retained app identity.' }
        }
        foreach ($artifact in $group.artifacts) { [void](Assert-HostedArtifact $artifact $Root) }
        foreach ($module in $group.loaded_modules) {
            Assert-HostedRequired $module @('process_id','started_at','application_path','application_sha256','path','sha256','megadriver_path','megadriver_sha256')
            Assert-HostedIntegerFields $module @('process_id')
            $bound = @($group.cleanup.processes | Where-Object {
                $_.process_id -eq $module.process_id -and
                    ([DateTimeOffset]$module.started_at).UtcTicks -ge ([DateTimeOffset]$_.started_at).UtcTicks -and
                    ([DateTimeOffset]$module.started_at).UtcTicks -lt ([DateTimeOffset]$_.started_at).UtcTicks+10
            })
            if ($bound.Count -ne 1 -or $module.process_id -le 0 -or
                $module.application_path -ine (Join-Path $Evidence.deployment.directory 'winghostty.exe') -or
                $module.application_sha256 -notmatch '^[0-9a-f]{64}$' -or $module.path -ine $glPath -or
                $module.sha256 -cne $lock.runtime_sha256['opengl32.dll'] -or
                $module.megadriver_path -ine (Join-Path $Evidence.deployment.directory 'libgallium_wgl.dll') -or
                $module.megadriver_sha256 -cne $lock.runtime_sha256['libgallium_wgl.dll']) {
                throw 'Harness did not load the pinned application-local OpenGL loader.'
            }
        }
    }
    $shader = $Evidence.groups[8]
    Assert-HostedRequired $shader @('shader_pixels','screenshot')
    Assert-HostedRequired $shader.shader_pixels @('sample_points','roi')
    Assert-HostedIntegerFields $shader.shader_pixels.roi @('left','top','width','height')
    Assert-HostedShaderPixels $shader.shader_pixels
    $pngPath=Assert-HostedArtifact $shader.screenshot $Root
    $actualPixels=Get-HostedPngPixels $pngPath $shader.shader_pixels.sample_points
    Assert-HostedShaderPixels $actualPixels
    foreach ($key in @('width','height','sampled_pixels','magenta_pixels','png_bytes')) {
        if ($shader.shader_pixels[$key] -ne $actualPixels[$key]) { throw "Shader pixel record disagrees with actual PNG: $key" }
    }
    foreach ($key in @('r','g','b','count')) {
        if ($shader.shader_pixels.dominant_color[$key] -ne $actualPixels.dominant_color[$key]) { throw "Dominant RGB record disagrees with actual PNG: $key" }
    }
    if ($shader.shader_pixels.roi.width -ne $actualPixels.width -or $shader.shader_pixels.roi.height -ne $actualPixels.height) { throw 'Owned sampling ROI dimensions disagree with actual PNG.' }
    Assert-HostedRequired $shader.shader_pixels @('process_id','started_at','hwnd')
    Assert-HostedIntegerFields $shader.shader_pixels @('process_id','hwnd')
    if ($shader.shader_pixels.started_at -isnot [string]) { throw 'Shader capture creation identity must be a string.' }
    if (@($shader.owned_windows | Where-Object {
        $_.process_id -eq $shader.shader_pixels.process_id -and $_.started_at -ceq $shader.shader_pixels.started_at -and $_.hwnd -eq $shader.shader_pixels.hwnd
    }).Count -ne 1) { throw 'Shader PNG is not correlated to its retained app/HWND capture.' }
    $expectedSources=@(
        '.github\workflows\test.yml','scripts\setup-hosted-opengl.ps1','scripts\interactive-win11-lib.ps1',
        'test\windows\interactive-win11-stateful-lib.ps1','test\windows\interactive-win11-pr-smoke.ps1',
        'test\windows\run-hosted-interactive.ps1','test\windows\assert-interactive-runner.ps1',
        'test\windows\assert-hosted-interactive-evidence.ps1','test\windows\fixtures\hosted-opengl-lock.json'
    )
    if ((@($Evidence.sources | ForEach-Object path | Sort-Object) -join '|') -cne (@($expectedSources | Sort-Object) -join '|')) {
        throw 'Exact suite/helper/workflow/lock source-binding set is missing, duplicated or escaping.'
    }
    foreach ($source in $Evidence.sources) {
        Assert-HostedRequired $source @('path','sha256')
        if ($source.sha256 -cne (Get-FileHash (Join-Path $SourceRoot $source.path)).Hash.ToLowerInvariant()) {
            throw "Suite source hash mismatch: $($source.path)"
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if (-not $EvidencePath) { throw 'EvidencePath is required; unavailable native proof is not a pass.' }
    $evidence = ConvertFrom-HostedJson (Get-Content -LiteralPath $EvidencePath -Raw)
    if ($evidence -is [Collections.IDictionary] -and $evidence.Contains('fixture_only')) { throw 'Synthetic headless fixtures are never source-CI native evidence.' }
    $head=(& git -C $RepoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $env:GITHUB_ACTIONS -cne 'true' -or
        $evidence.runner.commit -cne $head -or
        $evidence.runner.commit -cne $env:WINGHOSTTY_EXPECTED_CHECKOUT_SHA -or
        $evidence.runner.repository -cne $env:GITHUB_REPOSITORY -or
        $evidence.runner.run_id -cne $env:GITHUB_RUN_ID -or
        $evidence.runner.run_attempt -cne $env:GITHUB_RUN_ATTEMPT) { throw 'Hosted evidence does not bind the exact source-CI repository/SHA/run/attempt.' }
    Assert-HostedInteractiveEvidence $evidence (Split-Path -Parent $EvidencePath) $RepoRoot
    Write-Host 'HOSTEDWINDOWSSERVERCPU evidence: PASS (historical required-check name; not Windows 11 client/release proof)'
}
