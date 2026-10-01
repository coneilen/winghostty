[CmdletBinding()]
param(
    [string] $OutputPath,
    [ValidateSet('ClientRelease', 'HostedServerCpu')]
    [string] $Profile = 'ClientRelease'
)

$ErrorActionPreference = 'Stop'

function Assert-ClientReleaseRunnerProfile([string] $RunnerEnvironment, $ProductType) {
    if (($ProductType -isnot [int] -and $ProductType -isnot [uint32] -and $ProductType -isnot [long]) -or
        $RunnerEnvironment -cne 'self-hosted' -or $ProductType -ne 1) {
        throw 'Client release proof requires a self-hosted Windows client, not hosted Windows Server CPU evidence.'
    }
}

function Initialize-HostedRunnerNative {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ('WinghosttyHostedRunnerNative' -as [type]) { return }
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class WinghosttyHostedRunnerNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct OSVERSIONINFOEX {
        public uint size, major, minor, build, platform;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string csd;
        public ushort serviceMajor, serviceMinor, suite;
        public byte productType, reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int x,y; public uint data,flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT key;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION value; }
    [DllImport("ntdll.dll")] private static extern int RtlGetVersion(ref OSVERSIONINFOEX value);
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll")] private static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern bool GetUserObjectInformationW(IntPtr obj, int index, StringBuilder value, int length, ref int needed);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    public static OSVERSIONINFOEX Os() {
        var value = new OSVERSIONINFOEX(); value.size = (uint)Marshal.SizeOf(typeof(OSVERSIONINFOEX));
        if (RtlGetVersion(ref value) != 0) throw new InvalidOperationException("RtlGetVersion failed");
        return value;
    }
    private static string Name(IntPtr obj) {
        if (obj == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        int needed = 0; GetUserObjectInformationW(obj, 2, null, 0, ref needed);
        var value = new StringBuilder(Math.Max(needed / 2, 32));
        if (!GetUserObjectInformationW(obj, 2, value, value.Capacity * 2, ref needed))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return value.ToString();
    }
    public static string ThreadDesktop() { return Name(GetThreadDesktop(GetCurrentThreadId())); }
    public static string Station() { return Name(GetProcessWindowStation()); }
    public static string InputDesktop() {
        IntPtr desktop = OpenInputDesktop(0, false, 1);
        if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { return Name(desktop); } finally { CloseDesktop(desktop); }
    }
    public static uint InputK() {
        var down = new INPUT(); down.type = 1; down.value.key.scan = 75; down.value.key.flags = 4;
        var up = down; up.value.key.flags |= 2;
        return SendInput(2, new INPUT[] { down, up }, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
}

function Get-HostedRunnerWorker {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -Property ProcessId,ParentProcessId,CreationDate,ExecutablePath -ErrorAction Stop
    for ($depth = 0; $depth -lt 24; $depth++) {
        $parentId = [int]$current.ParentProcessId
        if ($parentId -le 0) { break }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$parentId" -Property ProcessId,ParentProcessId,CreationDate,ExecutablePath -ErrorAction Stop
        if ($null -eq $parent -or $parent.CreationDate -gt $current.CreationDate) {
            throw 'Trusted runner ancestry is unavailable or was reused.'
        }
        if ($parent.ExecutablePath -match '\\bin\\Runner\.Worker\.exe$') {
            $worker = Get-Process -Id $parentId -ErrorAction Stop
            if ($worker.Path -ine $parent.ExecutablePath -or
                -not (Test-HostedProcessCreationBinding $worker.StartTime $parent.CreationDate)) {
                throw 'Runner.Worker ancestry path/creation time changed.'
            }
            return @{
                path = $worker.Path
                version = (Get-Item -LiteralPath $worker.Path).VersionInfo.FileVersion
                process_id = $parentId
                started_at = $worker.StartTime.ToUniversalTime().ToString('o')
                cim_started_at = $parent.CreationDate.ToUniversalTime().ToString('o')
            }
        }
        $current = $parent
    }
    throw 'No trusted Runner.Worker.exe exists in this step process ancestry.'
}

function Invoke-HostedDesktopCanary {
    $form = [Windows.Forms.Form]::new()
    $edit = [Windows.Forms.TextBox]::new()
    $form.Text = 'Winghostty owned CI capability canary'
    $form.ClientSize = [Drawing.Size]::new(320,160)
    $form.BackColor = [Drawing.Color]::Magenta
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $edit.Location = [Drawing.Point]::new(8,8)
    $edit.Size = [Drawing.Size]::new(280,24)
    $form.Controls.Add($edit)
    $result = @{ owner_pid=$PID; cleanup_available=$null; remaining_windows=$null }
    Invoke-HostedLifecycle -Payload @{canary=$result} -Operation {
        $form.Show()
        $edit.Focus() | Out-Null
        [Windows.Forms.Application]::DoEvents()
        [void][WinghosttyHostedRunnerNative]::SetForegroundWindow($form.Handle)
        Start-Sleep -Milliseconds 200
        [Windows.Forms.Application]::DoEvents()
        $result.hwnd = $form.Handle.ToInt64()
        [uint32]$owner = 0
        [void][WinghosttyHostedRunnerNative]::GetWindowThreadProcessId($form.Handle, [ref]$owner)
        $result.observed_owner_pid = $owner
        $foreground = [WinghosttyHostedRunnerNative]::GetForegroundWindow()
        [uint32]$foregroundOwner = 0
        [void][WinghosttyHostedRunnerNative]::GetWindowThreadProcessId($foreground, [ref]$foregroundOwner)
        $result.foreground_hwnd = $foreground.ToInt64()
        $result.foreground_owner_pid = $foregroundOwner
        if ($owner -ne $PID -or $foreground -ne $form.Handle -or $foregroundOwner -ne $PID) {
            throw 'Canary cannot prove current owned foreground HWND; refusing capture/input.'
        }
        $origin = $form.PointToScreen([Drawing.Point]::new(0,0))
        $result.capture_hit_owners=@()
        foreach ($x in @(2,160,317)) {
            foreach ($y in @(2,80,157)) {
                $point=[InteractiveWin11MessageNativeV2+POINT]::new()
                $point.X=$origin.X+$x;$point.Y=$origin.Y+$y
                $hit=[InteractiveWin11MessageNativeV2]::WindowFromPoint($point)
                [uint32]$hitOwner=0
                [void][WinghosttyHostedRunnerNative]::GetWindowThreadProcessId($hit,[ref]$hitOwner)
                $result.capture_hit_owners += $hitOwner
                if ($hitOwner -ne $PID) { throw 'Canary capture rectangle is occluded by a non-owned HWND; refusing foreign pixels.' }
            }
        }
        $bitmap = [Drawing.Bitmap]::new(320,160)
        try {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try { $graphics.CopyFromScreen($origin.X,$origin.Y,0,0,$bitmap.Size) }
            finally { $graphics.Dispose() }
            $result.capture_width = $bitmap.Width
            $result.capture_height = $bitmap.Height
            $result.sampled_pixels = 0
            $result.matching_pixels = 0
            foreach ($x in @(60,120,180,240)) {
                foreach ($y in @(65,90,115,140)) {
                    $pixel = $bitmap.GetPixel($x,$y)
                    $result.sampled_pixels++
                    if ($pixel.R -ge 220 -and $pixel.G -le 40 -and $pixel.B -ge 220) { $result.matching_pixels++ }
                }
            }
        } finally { $bitmap.Dispose() }
        $foreground = [WinghosttyHostedRunnerNative]::GetForegroundWindow()
        [uint32]$owner = 0
        [void][WinghosttyHostedRunnerNative]::GetWindowThreadProcessId($form.Handle,[ref]$owner)
        if ($foreground -ne $form.Handle -or $owner -ne $PID -or -not $edit.Focused) {
            throw 'Canary ownership/focus changed immediately before SendInput.'
        }
        $result.input_requested = 2
        $result.input_returned = [WinghosttyHostedRunnerNative]::InputK()
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        do {
            [Windows.Forms.Application]::DoEvents()
            if ($edit.Text -ceq 'K') { break }
            Start-Sleep -Milliseconds 10
        } while ([DateTime]::UtcNow -lt $deadline)
        $result.input_received = $(if ($edit.Text -ceq 'K') { 1 } else { 0 })
    } -CleanupSteps @(
        @{name='canary close';action={ $form.Close() }},
        @{name='canary edit disposal';action={ $edit.Dispose() }},
        @{name='canary form disposal';action={ $form.Dispose() }},
        @{name='canary window proof';action={
            if (-not $result.ContainsKey('hwnd') -or $result.hwnd -le 0) { throw 'Canary window identity was never available.' }
            $result.remaining_windows = $(if ([WinghosttyHostedRunnerNative]::IsWindow([IntPtr]$result.hwnd)) { 1 } else { 0 })
            $result.cleanup_available = $true
        }}
    ) -EvidenceWriter { param($failure,$errors) }
    return $result
}

if ($Profile -eq 'HostedServerCpu') {
    . (Join-Path $PSScriptRoot 'assert-hosted-interactive-evidence.ps1')
    . (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\interactive-win11-lib.ps1')
    $evidence = [ordered]@{
        schema_version='winghostty.hosted-runner-provenance.v1'; profile='HOSTEDWINDOWSSERVERCPU'
        status='error'; failure=$null; canary=$null
    }
    $primary = $null
    try {
        if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
            $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64') {
            throw 'Hosted capability proof requires an actual GitHub-hosted Windows X64 step.'
        }
        Initialize-HostedRunnerNative
        $worker = Get-HostedRunnerWorker
        $os = [WinghosttyHostedRunnerNative]::Os()
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try { $isSystem = $identity.IsSystem } finally { $identity.Dispose() }
        $expectedCommit = $env:WINGHOSTTY_EXPECTED_CHECKOUT_SHA
        if (-not $expectedCommit) { $expectedCommit = $env:GITHUB_SHA }
        $checkedOutCommit = (& git -C $env:GITHUB_WORKSPACE rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the actual checkout SHA.' }
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $evidence.runner_environment = $env:RUNNER_ENVIRONMENT
        $evidence.runner_os = $env:RUNNER_OS
        $evidence.runner_arch = $env:RUNNER_ARCH
        $evidence.runner_name = $env:RUNNER_NAME
        $evidence.runner_version = $worker.version
        $evidence.worker_path = $worker.path
        $evidence.worker_process_id = $worker.process_id
        $evidence.worker_started_at = $worker.started_at
        $evidence.worker_cim_started_at = $worker.cim_started_at
        $evidence.worker_creation_precision_ticks = 10
        $evidence.worker_ancestor_verified = $true
        $evidence.windows_product_type = [int]$os.productType
        $evidence.windows_build = [int]$os.build
        $evidence.image_os = $env:ImageOS
        $evidence.image_version = $env:ImageVersion
        $evidence.process_session_id = $session
        $evidence.active_console_session_id = [long][WinghosttyHostedRunnerNative]::WTSGetActiveConsoleSessionId()
        $evidence.input_desktop = [WinghosttyHostedRunnerNative]::InputDesktop()
        $evidence.thread_desktop = [WinghosttyHostedRunnerNative]::ThreadDesktop()
        $evidence.window_station = [WinghosttyHostedRunnerNative]::Station()
        $evidence.is_system = $isSystem
        $evidence.explorer_count = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session).Count
        $evidence.repository = $env:GITHUB_REPOSITORY
        $evidence.run_id = $env:GITHUB_RUN_ID
        $evidence.run_attempt = $env:GITHUB_RUN_ATTEMPT
        $evidence.commit = $expectedCommit
        $evidence.checked_out_commit = $checkedOutCommit
        if ($session -le 0 -or $session -ne $evidence.active_console_session_id -or $isSystem -or
            $evidence.input_desktop -cne 'Default' -or $evidence.thread_desktop -cne 'Default' -or
            $evidence.window_station -cne 'WinSta0' -or $os.productType -ne 3 -or $os.build -lt 26100) {
            throw 'Hosted native desktop unavailable: typed session/desktop/OS guards failed before capture or input.'
        }
        $evidence.canary = Invoke-HostedDesktopCanary
        Assert-HostedRunnerObservation $evidence
        $evidence.status = 'pass'
    } catch {
        $primary = $_
        $evidence.failure = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message }
        if ($_.Exception.Data.Contains('canary')) { $evidence.canary = $_.Exception.Data['canary'] }
        if ($_.Exception.Data.Contains('hosted_secondary_failures')) { $evidence.secondary_failures=$_.Exception.Data['hosted_secondary_failures'] }
    } finally {
        if ($OutputPath) {
            try {
                [IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath)) | Out-Null
                $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
            } catch {
                if ($primary) { $primary.Exception.Data['evidence_failure'] = $_.Exception.Message }
                else { $primary = $_ }
            }
        }
    }
    if ($primary) { throw $primary }
    Write-Host 'HOSTEDWINDOWSSERVERCPU runner/owned native desktop canary: PASS (not Windows 11 client proof)'
    return
}

if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Interactive runner preflight must run inside GitHub Actions.' }
if ($env:RUNNER_OS -ne 'Windows') { throw "Interactive runner OS must be Windows; got '$($env:RUNNER_OS)'." }
if ($env:RUNNER_ARCH -ne 'X64') { throw "Interactive runner architecture must be X64; got '$($env:RUNNER_ARCH)'." }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_NAME)) { throw 'RUNNER_NAME is required for provenance.' }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'RUNNER_TEMP is required for runner version validation.' }

$minimumRunnerVersion = [version]'2.327.1'
$runnerRoot = Split-Path -Parent (Split-Path -Parent $env:RUNNER_TEMP)
$runnerWorkerPath = Join-Path $runnerRoot 'bin\Runner.Worker.exe'
if (-not (Test-Path -LiteralPath $runnerWorkerPath -PathType Leaf)) {
    throw "Runner.Worker.exe was not found at the expected runner root: $runnerWorkerPath"
}
$runnerVersionText = (Get-Item -LiteralPath $runnerWorkerPath).VersionInfo.FileVersion
[version]$runnerVersion = $null
if (-not [version]::TryParse($runnerVersionText, [ref]$runnerVersion)) {
    throw "Runner.Worker.exe has an invalid file version '$runnerVersionText': $runnerWorkerPath"
}
if ($runnerVersion -lt $minimumRunnerVersion) {
    throw "Interactive runner $runnerVersion is older than required version $minimumRunnerVersion."
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class WinghosttyRunnerNative {
    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder value, int length, ref int needed);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr desktop);

    public static string GetInputDesktopName() {
        const uint DesktopReadObjects = 0x0001;
        const int UoiName = 2;
        IntPtr desktop = OpenInputDesktop(0, false, DesktopReadObjects);
        if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            int needed = 0;
            GetUserObjectInformationW(desktop, UoiName, null, 0, ref needed);
            var value = new StringBuilder(Math.Max(needed / 2, 32));
            if (!GetUserObjectInformationW(desktop, UoiName, value, value.Capacity * 2, ref needed)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return value.ToString();
        } finally {
            CloseDesktop(desktop);
        }
    }
}
'@

$processSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$activeSessionRaw = [WinghosttyRunnerNative]::WTSGetActiveConsoleSessionId()
$activeSession = if ($activeSessionRaw -eq [uint32]::MaxValue) { -1 } else { [int]$activeSessionRaw }
$inputDesktop = [WinghosttyRunnerNative]::GetInputDesktopName()
$windowsBuild = [Environment]::OSVersion.Version.Build
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $clientOs = Get-CimInstance Win32_OperatingSystem -Property ProductType -ErrorAction Stop
    Assert-ClientReleaseRunnerProfile $env:RUNNER_ENVIRONMENT $clientOs.ProductType
    if ($windowsBuild -lt 22000) { throw "Interactive runner must run Windows 11; build is $windowsBuild." }
    if ($processSession -le 0) { throw "Interactive runner is in non-interactive session $processSession." }
    if ($processSession -ne $activeSession) {
        throw "Interactive runner session $processSession is not the active console session $activeSession."
    }
    if ($identity.IsSystem) { throw 'Interactive runner must not run as LocalSystem.' }
    if ($inputDesktop -ne 'Default') { throw "Interactive runner input desktop must be Default; got '$inputDesktop'." }

    $expectedCommit = if ([string]::IsNullOrWhiteSpace($env:WINGHOSTTY_EXPECTED_CHECKOUT_SHA)) {
        $env:GITHUB_SHA
    } else {
        $env:WINGHOSTTY_EXPECTED_CHECKOUT_SHA
    }
    $checkedOutCommit = (& git -C $env:GITHUB_WORKSPACE rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $checkedOutCommit -ne $expectedCommit) {
        throw "Interactive runner checkout $checkedOutCommit does not match expected commit $expectedCommit."
    }

    $explorer = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $processSession)
    if ($explorer.Count -eq 0) { throw "No Explorer shell is running in interactive session $processSession." }

    $evidence = [ordered]@{
        schema_version = 'winghostty.interactive-runner-provenance.v1'
        captured_at = [DateTimeOffset]::UtcNow.ToString('o')
        runner_name = $env:RUNNER_NAME
        runner_os = $env:RUNNER_OS
        runner_arch = $env:RUNNER_ARCH
        runner_version = $runnerVersion.ToString()
        windows_build = $windowsBuild
        input_desktop = $inputDesktop
        runner_environment = $env:RUNNER_ENVIRONMENT
        machine_name = [Environment]::MachineName
        user = $identity.Name
        process_session_id = $processSession
        active_console_session_id = $activeSession
        repository = $env:GITHUB_REPOSITORY
        workflow = $env:GITHUB_WORKFLOW
        run_id = $env:GITHUB_RUN_ID
        run_attempt = $env:GITHUB_RUN_ATTEMPT
        commit = $expectedCommit
        checked_out_commit = $checkedOutCommit
        github_sha = $env:GITHUB_SHA
    }
    if ($OutputPath) {
        $parent = Split-Path -Parent $OutputPath
        if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
        $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
    }
    Write-Host "Interactive runner provenance: PASS ($($env:RUNNER_NAME), runner $runnerVersion, session $processSession, $($identity.Name))"
}
finally {
    $identity.Dispose()
}
