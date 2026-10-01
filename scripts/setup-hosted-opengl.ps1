#requires -Version 7.3
[CmdletBinding()]
param(
    [string] $ApplicationDirectory,
    [string] $OutputPath,
    [switch] $Probe
)

function Get-HostedPeImports([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 512 -or [BitConverter]::ToUInt16($bytes,0) -ne 0x5a4d) { throw 'Invalid PE image.' }
    $pe = [BitConverter]::ToInt32($bytes,0x3c)
    if ($pe -lt 0 -or $pe + 264 -gt $bytes.Length -or
        [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x8664 -or
        [BitConverter]::ToUInt16($bytes,$pe+24) -ne 0x20b) { throw 'Mesa deployment requires valid native x64 PE32+ images.' }
    $sections = [BitConverter]::ToUInt16($bytes,$pe+6)
    $optionalSize = [BitConverter]::ToUInt16($bytes,$pe+20)
    $sectionStart = $pe + 24 + $optionalSize
    function Resolve-Rva([uint32] $Rva) {
        for ($i=0; $i -lt $sections; $i++) {
            $offset = $sectionStart + 40*$i
            if ($offset+40 -gt $bytes.Length) { throw 'Truncated PE section table.' }
            $address = [BitConverter]::ToUInt32($bytes,$offset+12)
            $size = [BitConverter]::ToUInt32($bytes,$offset+16)
            if ($Rva -ge $address -and $Rva -lt ([long]$address+$size)) {
                $result = [long][BitConverter]::ToUInt32($bytes,$offset+20) + $Rva - $address
                if ($result -lt 0 -or $result -ge $bytes.Length) { throw 'PE RVA escapes file.' }
                return [int]$result
            }
        }
        throw 'PE RVA is not file-backed.'
    }
    $result = @{ architecture='X64'; imports=@(); delay_imports=@() }
    foreach ($directory in @(@{index=1;size=20;name=12;key='imports'},@{index=13;size=32;name=4;key='delay_imports'})) {
        $rva = [BitConverter]::ToUInt32($bytes,$pe+24+112+8*$directory.index)
        if ($rva -eq 0) { continue }
        $offset = Resolve-Rva $rva
        for ($count=0; $count -lt 256; $count++) {
            if ($offset+$directory.size -gt $bytes.Length) { throw 'Truncated PE imports.' }
            $nameRva = [BitConverter]::ToUInt32($bytes,$offset+$directory.name)
            if ($nameRva -eq 0) { break }
            if ($directory.index -eq 13 -and [BitConverter]::ToUInt32($bytes,$offset) -ne 1) { throw 'Unsupported non-RVA delay import.' }
            $nameStart = Resolve-Rva $nameRva
            $end = $nameStart
            while ($end -lt $bytes.Length -and $bytes[$end] -ne 0 -and $end-$nameStart -lt 256) { $end++ }
            if ($end -ge $bytes.Length -or $bytes[$end] -ne 0) { throw 'Unterminated PE DLL import.' }
            $result[$directory.key] += [Text.Encoding]::ASCII.GetString($bytes,$nameStart,$end-$nameStart)
            $offset += $directory.size
        }
        if ($count -ge 256) { throw 'Unbounded PE import table.' }
    }
    return $result
}

function Assert-HostedPeClosure($Lock, [string] $Directory) {
    $records = @()
    foreach ($relative in $Lock.runtime_files) {
        $path = Join-Path $Directory (Split-Path -Leaf $relative)
        $name = Split-Path -Leaf $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne $Lock.runtime_sha256[$name]) { throw "Pinned runtime DLL digest mismatch: $name" }
        $imports = Get-HostedPeImports $path
        foreach ($dependency in @($imports.imports) + @($imports.delay_imports)) {
            if ($dependency -iin @($Lock.system_imports)) {
                if (-not (Test-Path -LiteralPath (Join-Path ([Environment]::SystemDirectory) $dependency) -PathType Leaf)) {
                    throw "Missing inbox dependency: $dependency"
                }
            } elseif ($dependency -iin @($Lock.runtime_sha256.Keys)) {
                if (-not (Test-Path -LiteralPath (Join-Path $Directory $dependency) -PathType Leaf)) { throw "Missing application-local dependency: $dependency" }
            } else { throw "Unreviewed static/delay dependency: $dependency" }
        }
        if (@($imports.delay_imports).Count -ne @($Lock.delay_imports).Count) { throw 'Mesa delay-import closure changed.' }
        $records += @{name=$name;sha256=$hash;architecture=$imports.architecture;imports=$imports.imports;delay_imports=$imports.delay_imports}
    }
    return $records
}

function Initialize-HostedOpenGLNative {
    if ('WinghosttyHostedOpenGL' -as [type]) { return }
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Collections.Generic;
using System.Text;
public static class WinghosttyHostedOpenGL {
    [StructLayout(LayoutKind.Sequential)]
    public struct PFD {
        public ushort size,version; public uint flags; public byte pixelType,colorBits,redBits,redShift,greenBits,greenShift,blueBits,blueShift,alphaBits,alphaShift,accumBits,accumRed,accumGreen,accumBlue,accumAlpha,depthBits,stencilBits,auxBuffers,layerType,reserved; public uint layerMask,visibleMask,damageMask;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true)] private static extern IntPtr GetProcAddress(IntPtr module,string name);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetModuleFileNameW(IntPtr module,StringBuilder value,int length);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint owner);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd,IntPtr dc);
    [DllImport("gdi32.dll")] private static extern int ChoosePixelFormat(IntPtr dc,ref PFD format);
    [DllImport("gdi32.dll")] private static extern bool SetPixelFormat(IntPtr dc,int index,ref PFD format);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr CreateContext(IntPtr dc);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate bool MakeCurrent(IntPtr dc,IntPtr rc);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate bool DeleteContext(IntPtr rc);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr WglProc([MarshalAs(UnmanagedType.LPStr)]string name);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr GetString(uint name);
    private static T Function<T>(IntPtr module,string name) where T:Delegate {
        IntPtr address = GetProcAddress(module,name);
        if (address == IntPtr.Zero) throw new InvalidOperationException("Missing actual WGL export: "+name);
        return Marshal.GetDelegateForFunctionPointer<T>(address);
    }
    private static IntPtr retainedModule;
    public static string LoadedModulePath() {
        if (retainedModule == IntPtr.Zero) throw new InvalidOperationException("No retained probe module");
        var value = new StringBuilder(32768);
        if (GetModuleFileNameW(retainedModule,value,value.Capacity) == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        return value.ToString();
    }
    public static void ReleaseModule() {
        if (retainedModule == IntPtr.Zero) return;
        if (!FreeLibrary(retainedModule)) throw new Win32Exception(Marshal.GetLastWin32Error());
        retainedModule=IntPtr.Zero;
    }
    public static string[] Probe(string path,IntPtr ownedHwnd) {
        if (retainedModule != IntPtr.Zero) throw new InvalidOperationException("Previous probe module was not released");
        IntPtr module = LoadLibraryExW(path,IntPtr.Zero,0x00000100 | 0x00001000);
        if (module == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        retainedModule=module;
        var create = Function<CreateContext>(module,"wglCreateContext");
        var current = Function<MakeCurrent>(module,"wglMakeCurrent");
        var delete = Function<DeleteContext>(module,"wglDeleteContext");
        var getProc = Function<WglProc>(module,"wglGetProcAddress");
        var getString = Function<GetString>(module,"glGetString");
        IntPtr dc = GetDC(ownedHwnd), rc = IntPtr.Zero;
        if (dc == IntPtr.Zero) throw new InvalidOperationException("Owned probe HDC unavailable");
        Exception primary=null;
        var cleanup=new List<string>();
        string[] result=null;
        try {
            var pfd = new PFD(); pfd.size = (ushort)Marshal.SizeOf(typeof(PFD)); pfd.version=1;
            pfd.flags=0x4 | 0x20 | 0x1; pfd.colorBits=32; pfd.alphaBits=8; pfd.depthBits=24;
            int format = ChoosePixelFormat(dc,ref pfd);
            if (format == 0 || !SetPixelFormat(dc,format,ref pfd)) throw new InvalidOperationException("WGL pixel format unavailable");
            rc=create(dc);
            if (rc == IntPtr.Zero || !current(dc,rc)) throw new InvalidOperationException("Real Mesa WGL context unavailable");
            string[] names = {"glCreateShader","glCompileShader","glCreateProgram","glLinkProgram","glGenFramebuffers","glBindFramebuffer","glBufferData","glTexStorage2D","glBindVertexArray"};
            foreach (string name in names) {
                long address = getProc(name).ToInt64();
                if (address == 0 || address == 1 || address == 2 || address == 3 || address == -1)
                    throw new InvalidOperationException("Real GL function unavailable: "+name);
            }
            result=new string[] {
                Marshal.PtrToStringAnsi(getString(0x1f00)),Marshal.PtrToStringAnsi(getString(0x1f01)),
                Marshal.PtrToStringAnsi(getString(0x1f02)),Marshal.PtrToStringAnsi(getString(0x8b8c)),String.Join("|",names)
            };
        } catch (Exception error) { primary=error; }
        finally {
            if (rc != IntPtr.Zero) {
                try { if (!current(IntPtr.Zero,IntPtr.Zero)) throw new InvalidOperationException("wglMakeCurrent detach failed"); }
                catch (Exception error) { cleanup.Add(error.Message); }
                try { if (!delete(rc)) throw new InvalidOperationException("wglDeleteContext failed"); }
                catch (Exception error) { cleanup.Add(error.Message); }
            }
            try { if (ReleaseDC(ownedHwnd,dc) == 0) throw new InvalidOperationException("ReleaseDC failed"); }
            catch (Exception error) { cleanup.Add(error.Message); }
        }
        if (primary != null) {
            primary.Data["hosted_secondary_failures"]=cleanup.ToArray();
            ExceptionDispatchInfo.Capture(primary).Throw();
        }
        if (cleanup.Count != 0) throw new InvalidOperationException("WGL cleanup failed: "+String.Join("; ",cleanup));
        return result;
    }
}
'@
}

function Get-HostedOpenGLObservation([string] $Directory) {
    Initialize-HostedOpenGLNative
    Add-Type -AssemblyName System.Windows.Forms
    $form = [Windows.Forms.Form]::new()
    $observation=@{}
    Invoke-HostedLifecycle -Operation {
        $handle = $form.Handle
        [uint32]$owner=0
        if ([WinghosttyHostedOpenGL]::GetWindowThreadProcessId($handle,[ref]$owner) -eq 0 -or $owner -ne $PID) {
            throw 'The GL probe target HWND is not owned by this retained process.'
        }
        $path = Join-Path $Directory 'opengl32.dll'
        $values = [WinghosttyHostedOpenGL]::Probe($path,$handle)
        $loadedPath=[WinghosttyHostedOpenGL]::LoadedModulePath()
        $gallium=@([Diagnostics.Process]::GetCurrentProcess().Modules | Where-Object ModuleName -IEQ 'libgallium_wgl.dll')
        if ($loadedPath -ine $path -or $gallium.Count -ne 1 -or
            $gallium[0].FileName -ine (Join-Path $Directory 'libgallium_wgl.dll')) {
            throw 'GL probe loaded a different loader/megadriver path.'
        }
        $observation.vendor=$values[0];$observation.renderer=$values[1]
        $observation.version=$values[2];$observation.glsl_version=$values[3]
        $observation.functions=@($values[4] -split '\|');$observation.module_path=$loadedPath
        $observation.module_sha256=(Get-FileHash -LiteralPath $loadedPath).Hash.ToLowerInvariant()
        $observation.megadriver_path=$gallium[0].FileName
        $observation.megadriver_sha256=(Get-FileHash -LiteralPath $gallium[0].FileName).Hash.ToLowerInvariant()
    } -CleanupSteps @(
        @{name='GL probe form disposal';action={$form.Dispose()}},
        @{name='GL probe loader release';action={[WinghosttyHostedOpenGL]::ReleaseModule()}}
    ) -EvidenceWriter {}
    return $observation
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'test\windows\assert-hosted-interactive-evidence.ps1')
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_ARCH -cne 'X64') {
        throw 'Mesa staging/probe is restricted to the disposable hosted X64 CI job.'
    }
    if (-not $ApplicationDirectory) { $ApplicationDirectory = Join-Path $repoRoot 'zig-out\bin' }
    $ApplicationDirectory = [IO.Path]::GetFullPath($ApplicationDirectory)
    if ($ApplicationDirectory -ine (Join-Path $repoRoot 'zig-out\bin') -or
        -not (Test-Path (Join-Path $ApplicationDirectory 'winghostty.exe') -PathType Leaf)) {
        throw 'Mesa may only be staged next to this CI-built application, never system/global DLLs.'
    }
    foreach ($name in @('MESA_GL_VERSION_OVERRIDE','MESA_GLSL_VERSION_OVERRIDE','MESA_EXTENSION_OVERRIDE')) {
        if ([Environment]::GetEnvironmentVariable($name)) { throw "Forbidden capability override: $name" }
    }
    $primary=$null
    $deployment=@{
        profile='HOSTEDWINDOWSSERVERCPU';status='error';failure=$null;stage='lock/archive/dependency validation'
        directory=$ApplicationDirectory;files=$null;graphics=$null;secondary_failures=@()
    }
    try {
    $lockPath = Join-Path $repoRoot 'test\windows\fixtures\hosted-opengl-lock.json'
    $lock = ConvertFrom-HostedJson (Get-Content -LiteralPath $lockPath -Raw)
    Assert-HostedOpenGLLock $lock
    $scratch = Join-Path $repoRoot '.sandbox\hosted-ci\mesa'
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $archive = Join-Path $scratch 'mesa.7z'
    if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri $lock.asset_url -OutFile $archive }
    if ((Get-Item $archive).Length -ne $lock.asset_bytes -or
        (Get-FileHash $archive).Hash.ToLowerInvariant() -cne $lock.asset_sha256) { throw 'Pinned Mesa archive size/SHA256 mismatch.' }
    $sevenZip = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    if (-not (Test-Path $sevenZip -PathType Leaf)) { throw 'Hosted image 7-Zip tool is missing; no unbounded installer fallback.' }
    $unpacked = Join-Path $scratch 'unpacked'
    & $sevenZip x $archive "-o$unpacked" -y @($lock.runtime_files)
    if ($LASTEXITCODE -ne 0) { throw 'Pinned Mesa extraction failed.' }
    foreach ($relative in $lock.runtime_files) {
        $source = Join-Path $unpacked $relative
        $name = Split-Path -Leaf $source
        if ((Get-FileHash $source).Hash.ToLowerInvariant() -cne $lock.runtime_sha256[$name]) { throw "Extracted DLL hash mismatch: $name" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $ApplicationDirectory $name) -Force
    }
    $notices = Join-Path $scratch 'notices'
    [IO.Directory]::CreateDirectory($notices) | Out-Null
    foreach ($notice in $lock.notices) {
        $path = Join-Path $notices $notice.name
        Invoke-WebRequest -Uri $notice.url -OutFile $path
        if ((Get-FileHash $path).Hash.ToLowerInvariant() -cne $notice.sha256) { throw "Pinned notice hash mismatch: $($notice.name)" }
    }
    $files = @(Assert-HostedPeClosure $lock $ApplicationDirectory)
    $env:GALLIUM_DRIVER = 'llvmpipe'
    $deployment = @{
        profile='HOSTEDWINDOWSSERVERCPU';directory=$ApplicationDirectory;files=$files
        lock_sha256=(Get-FileHash $lockPath).Hash.ToLowerInvariant()
        archive_sha256=$lock.asset_sha256;notices=$lock.notices
        status='error';failure=$null;stage='real WGL/GL/GLSL capability probe';secondary_failures=@()
    }
    if ($Probe) {
        $graphics = Get-HostedOpenGLObservation $ApplicationDirectory
        $deployment.graphics = $graphics
        Assert-HostedGraphicsObservation $graphics (Join-Path $ApplicationDirectory 'opengl32.dll') $lock.runtime_sha256['opengl32.dll']
    }
    $deployment.status='pass'
    $deployment.stage='completed'
    } catch {
        $primary=$_
        $deployment.failure=@{type=$_.Exception.GetType().FullName;message=$_.Exception.Message}
        if ($_.Exception.Data.Contains('hosted_secondary_failures')) { $deployment.secondary_failures=$_.Exception.Data['hosted_secondary_failures'] }
    }
    finally {
    if ($OutputPath) {
        try {
            [IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath)) | Out-Null
            $deployment | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
        } catch {
            if ($primary) { $primary.Exception.Data['evidence_failure']=$_.Exception.Message }
            else { $primary=$_ }
        }
    }
    }
    if ($primary) { throw $primary }
    Write-Host 'Pinned application-local Mesa x64 WGL deployment: PASS (CPU llvmpipe; no hardware claim)'
}
