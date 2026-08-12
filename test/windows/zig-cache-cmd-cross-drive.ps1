$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$repoDrive = [System.IO.Path]::GetPathRoot($repoRoot)
$foreignDrive = @(
    Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.Root -and -not [string]::Equals($_.Root, $repoDrive, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
)[0]
if ($null -eq $foreignDrive) {
    throw "Cross-drive CMD cache regression requires a second filesystem drive."
}

$originalGlobal = $env:ZIG_GLOBAL_CACHE_DIR
$originalLocal = $env:ZIG_LOCAL_CACHE_DIR
$local = Join-Path $foreignDrive.Root "winghostty-zig-cmd-local-$PID\child"
$global = Join-Path $repoRoot ".zig-cmd-global-$PID"

try {
    $env:ZIG_LOCAL_CACHE_DIR = $local
    $env:ZIG_GLOBAL_CACHE_DIR = $global

    foreach ($scriptName in @("dev-windows.cmd", "fetch-zig-deps.cmd")) {
        $scriptPath = Join-Path $repoRoot "scripts\$scriptName"
        $command = 'call "' + $scriptPath + '" --print-cache-paths'
        $originalErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = @(& cmd.exe /d /s /c $command 2>&1)
            $probeExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $originalErrorActionPreference
        }
        if ($probeExitCode -ne 0) {
            throw "$scriptName cache probe failed with exit code $probeExitCode.`n$($output -join "`n")"
        }

        $resolvedLocal = [System.IO.Path]::GetFullPath($local)
        $localLine = @($output | Where-Object { $_ -match "^ZIG_LOCAL_CACHE_DIR=" }) | Select-Object -Last 1
        $globalLine = @($output | Where-Object { $_ -match "^ZIG_GLOBAL_CACHE_DIR=" }) | Select-Object -Last 1
        if ($null -eq $localLine -or $null -eq $globalLine) {
            throw "$scriptName cache probe did not report both cache paths.`n$($output -join "`n")"
        }

        $reportedLocal = $localLine -replace "^ZIG_LOCAL_CACHE_DIR=", ""
        $reportedGlobal = $globalLine -replace "^ZIG_GLOBAL_CACHE_DIR=", ""
        $localParent = Split-Path -Parent $resolvedLocal
        if ([string]::IsNullOrWhiteSpace($localParent)) {
            $localParent = [System.IO.Path]::GetPathRoot($resolvedLocal)
        }
        $expectedGlobal = [System.IO.Path]::GetFullPath((Join-Path $localParent ".zig-global-cache"))
        if ($reportedLocal -ne $resolvedLocal) {
            throw "$scriptName did not resolve the explicit local cache: expected=$resolvedLocal actual=$reportedLocal"
        }
        if ($reportedGlobal -ne $expectedGlobal) {
            throw "$scriptName used the wrong cross-drive global cache: expected=$expectedGlobal actual=$reportedGlobal"
        }
        if ([System.IO.Path]::GetPathRoot($reportedGlobal) -eq [System.IO.Path]::GetPathRoot($global)) {
            throw "$scriptName retained the caller's global-cache volume instead of following the local cache."
        }
    }
}
finally {
    $env:ZIG_GLOBAL_CACHE_DIR = $originalGlobal
    $env:ZIG_LOCAL_CACHE_DIR = $originalLocal
}

Write-Host "CMD cross-drive Zig cache regression test passed."
