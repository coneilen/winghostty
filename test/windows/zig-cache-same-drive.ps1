$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\scripts\zig-cache.ps1")

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$originalGlobal = $env:ZIG_GLOBAL_CACHE_DIR
$originalLocal = $env:ZIG_LOCAL_CACHE_DIR

try {
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $repoRoot ".zig-cache"
    $foreignDrive = if ([System.IO.Path]::GetPathRoot($repoRoot) -eq "C:\") {
        "D:\"
    } else {
        "C:\"
    }
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $foreignDrive "winghostty-zig-global-cache"

    $paths = Resolve-WinghosttyZigCachePaths -RepoRoot $repoRoot
    $localDrive = [System.IO.Path]::GetPathRoot($paths.Local)
    $globalDrive = [System.IO.Path]::GetPathRoot($paths.Global)
    if (-not [string]::Equals($localDrive, $globalDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Zig cache paths are on different drives: local=$($paths.Local), global=$($paths.Global)"
    }
    $expectedGlobal = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ".zig-global-cache"))
    if ($paths.Global -ne $expectedGlobal) {
        throw "Cross-drive global cache was not relocated to the repository: $($paths.Global)"
    }

    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $foreignDrive "winghostty-zig-local-cache"
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path ([System.IO.Path]::GetPathRoot($repoRoot)) "winghostty-zig-global-cache"
    $paths = Resolve-WinghosttyZigCachePaths -RepoRoot $repoRoot
    $localDrive = [System.IO.Path]::GetPathRoot($paths.Local)
    $globalDrive = [System.IO.Path]::GetPathRoot($paths.Global)
    if (-not [string]::Equals($localDrive, $globalDrive, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Explicit Zig cache paths are on different drives: local=$($paths.Local), global=$($paths.Global)"
    }
}
finally {
    $env:ZIG_GLOBAL_CACHE_DIR = $originalGlobal
    $env:ZIG_LOCAL_CACHE_DIR = $originalLocal
}

Write-Host "Zig cache same-drive regression test passed."
