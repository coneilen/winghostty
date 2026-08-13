$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$devWindows = Join-Path $repoRoot "scripts\dev-windows.cmd"
$source = Join-Path $repoRoot "test\windows\win32-host-api-smoke.c"
$object = Join-Path $repoRoot "zig-out\win32-host-api-smoke-$PID.obj"
$executable = Join-Path $repoRoot "zig-out\win32-host-api-smoke-$PID.exe"
$library = Join-Path $repoRoot "zig-out\lib\winghostty-win32-host.lib"

function Invoke-DevWindows {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $devWindows @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $($Arguments -join ' ')"
    }
}

try {
    Invoke-DevWindows @("zig", "build", "-Demit-win32-host=true")
    if (-not (Test-Path -LiteralPath $library -PathType Leaf)) {
        throw "Missing host library: $library"
    }
    Invoke-DevWindows @(
        "zig", "cc", "-target", "x86_64-windows-msvc",
        "-c", $source, "-o", $object
    )
    Invoke-DevWindows @(
        "zig", "cc", "-target", "x86_64-windows-msvc",
        $object, $library, "-luser32", "-lkernel32", "-o", $executable
    )
    & $executable
    if ($LASTEXITCODE -ne 0) {
        throw "Win32 host API smoke executable failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Item -LiteralPath $object, $executable -Force -ErrorAction SilentlyContinue
}

Write-Host "Win32 host API one/two-surface lifecycle smoke passed."
