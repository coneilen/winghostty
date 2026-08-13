$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$devWindows = Join-Path $repoRoot "scripts\dev-windows.cmd"
$source = Join-Path $repoRoot "test\windows\win32-host-api-contract.c"
$object = Join-Path $repoRoot "zig-out\win32-host-api-contract-$PID.obj"

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $object) | Out-Null

try {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $devWindows zig cc -target x86_64-windows-msvc -c $source -o $object
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw "External Win32 host API contract failed with exit code ${exitCode}."
    }
}
finally {
    Remove-Item -LiteralPath $object -Force -ErrorAction SilentlyContinue
}

Write-Host "Win32 host API external compile contract passed."
