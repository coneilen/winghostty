$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$devWindows = Join-Path $repoRoot "scripts\dev-windows.cmd"
$source = Join-Path $repoRoot "test\windows\win32-host-api-contract.c"
$objects = @(
    Join-Path $repoRoot "zig-out\win32-host-api-contract-c-$PID.obj"
    Join-Path $repoRoot "zig-out\win32-host-api-contract-c-short-enums-$PID.obj"
    Join-Path $repoRoot "zig-out\win32-host-api-contract-cpp-$PID.obj"
    Join-Path $repoRoot "zig-out\win32-host-api-contract-cpp-short-enums-$PID.obj"
)

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $objects[0]) | Out-Null

function Invoke-Compile {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Object
    )

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $devWindows @Arguments -c $source -o $Object
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw "External Win32 host API layout contract failed with exit code ${exitCode}: $($Arguments -join ' ')"
    }
}

try {
    Invoke-Compile `
        -Arguments @("zig", "cc", "-target", "x86_64-windows-msvc") `
        -Object $objects[0]
    Invoke-Compile `
        -Arguments @("zig", "cc", "-target", "x86_64-windows-msvc", "-fshort-enums") `
        -Object $objects[1]
    Invoke-Compile `
        -Arguments @("zig", "c++", "-target", "x86_64-windows-msvc", "-x", "c++") `
        -Object $objects[2]
    Invoke-Compile `
        -Arguments @("zig", "c++", "-target", "x86_64-windows-msvc", "-x", "c++", "-fshort-enums") `
        -Object $objects[3]
}
finally {
    Remove-Item -LiteralPath $objects -Force -ErrorAction SilentlyContinue
}

Write-Host "Win32 host API C/C++ layout contracts passed, including -fshort-enums."
