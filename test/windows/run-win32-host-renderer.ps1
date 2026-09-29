param(
    [ValidateRange(1, 32)]
    [int] $RepeatCount = 3
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$devWindows = Join-Path $repoRoot "scripts\dev-windows.cmd"
$source = Join-Path $repoRoot "test\windows\win32-host-renderer.c"
$runDirectory = Join-Path $repoRoot "zig-out\win32-host-renderer-$PID"
$object = Join-Path $runDirectory "win32-host-renderer.obj"
$executable = Join-Path $runDirectory "win32-host-renderer.exe"
$library = Join-Path $repoRoot "zig-out\lib\winghostty-win32-host.lib"
$vtLibrary = Join-Path $repoRoot "zig-out\lib\ghostty-vt.lib"
$vtRuntime = Join-Path $runDirectory "ghostty-vt.dll"

function Invoke-DevWindows {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    & $devWindows @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

try {
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    Invoke-DevWindows @("zig", "build", "-Demit-win32-host=true")
    Invoke-DevWindows @("zig", "build", "-Demit-lib-vt=true")
    if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
        throw "Missing host library: $library"
    }
    if (-not (Test-Path -LiteralPath $vtLibrary -PathType Leaf)) {
        throw "Missing libghostty-vt import library: $vtLibrary"
    }
    if (-not (Test-Path -LiteralPath $vtRuntime -PathType Leaf)) {
        Copy-Item (Join-Path $repoRoot "zig-out\bin\ghostty-vt.dll") $vtRuntime
    }
    Invoke-DevWindows @(
        "zig", "cc", "-target", "x86_64-windows-msvc",
        "-I", (Join-Path $repoRoot "include"),
        "-c", $source, "-o", $object
    )
    Invoke-DevWindows @(
        "zig", "cc", "-target", "x86_64-windows-msvc",
        $object, $library, $vtLibrary, "-luser32", "-lgdi32", "-lopengl32",
        "-lkernel32", "-limm32", "-loleaut32", "-lole32",
        "-luiautomationcore", "-lws2_32", "-lbcrypt", "-o", $executable
    )
    for ($iteration = 1; $iteration -le $RepeatCount; $iteration++) {
        Write-Host "Win32 host renderer external contract run $iteration/$RepeatCount."
        & $executable
        if ($LASTEXITCODE -ne 0) {
            throw "Win32 host renderer executable failed on run $iteration with exit code $LASTEXITCODE."
        }
    }
}
finally {
    Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Win32 host renderer external contract passed ($RepeatCount fresh processes)."
