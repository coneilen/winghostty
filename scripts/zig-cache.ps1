function Resolve-WinghosttyZigCachePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    $root = [System.IO.Path]::GetFullPath($RepoRoot)
    $local = $env:ZIG_LOCAL_CACHE_DIR
    if ([string]::IsNullOrWhiteSpace($local)) {
        $local = Join-Path $root ".zig-cache"
    } elseif (-not [System.IO.Path]::IsPathRooted($local)) {
        $local = Join-Path $root $local
    }
    $local = [System.IO.Path]::GetFullPath($local)

    $global = $env:ZIG_GLOBAL_CACHE_DIR
    if ([string]::IsNullOrWhiteSpace($global)) {
        $global = Join-Path $root ".zig-global-cache"
    } elseif (-not [System.IO.Path]::IsPathRooted($global)) {
        $global = Join-Path $root $global
    }
    $global = [System.IO.Path]::GetFullPath($global)

    if (-not [string]::Equals(
            [System.IO.Path]::GetPathRoot($local),
            [System.IO.Path]::GetPathRoot($global),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        # Zig 0.15.2's Windows build runner cannot relativize a generated
        # path on one volume against a child cwd on another volume.
        $localParent = Split-Path -Parent $local
        if ([string]::IsNullOrWhiteSpace($localParent)) {
            $localParent = [System.IO.Path]::GetPathRoot($local)
        }
        $global = Join-Path $localParent ".zig-global-cache"
    }

    [pscustomobject]@{
        Local  = $local
        Global = $global
    }
}

function Set-WinghosttyZigCacheEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    $paths = Resolve-WinghosttyZigCachePaths -RepoRoot $RepoRoot
    $env:ZIG_LOCAL_CACHE_DIR = $paths.Local
    $env:ZIG_GLOBAL_CACHE_DIR = $paths.Global
    New-Item -ItemType Directory -Force -Path $paths.Local, $paths.Global | Out-Null
    return $paths
}
