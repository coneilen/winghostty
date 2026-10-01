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
$pngPath=Join-Path $fixtureRoot 'fixture.png'
Add-Type -AssemblyName System.Drawing
$bitmap=[Drawing.Bitmap]::new(16,16)
try {
    foreach ($x in 0..15) { foreach ($y in 0..15) { $bitmap.SetPixel($x,$y,[Drawing.Color]::Magenta) } }
    $bitmap.Save($pngPath,[Drawing.Imaging.ImageFormat]::Png)
} finally { $bitmap.Dispose() }
$sourcePaths=@(
    '.github\workflows\test.yml','scripts\setup-hosted-opengl.ps1','scripts\interactive-win11-lib.ps1',
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
$tokens=$null;$errors=$null
$outerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-hosted-interactive.ps1'),[ref]$tokens,[ref]$errors)
$finalizerCalls=@($outerAst.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Complete-HostedInteractiveRun'
},$true))
if ($finalizerCalls.Count -ne 1 -or $finalizerCalls[0].Parent.Parent -isnot [Management.Automation.Language.StatementBlockAst]) {
    throw 'The tested finalizer is not the actual outer production finally path.'
}
$script:checks++

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
