#requires -Version 7.0

[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [string] $SummaryPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($Rebuild) {
    $originalZigGlobalCache = $env:ZIG_GLOBAL_CACHE_DIR
    $originalZigLocalCache = $env:ZIG_LOCAL_CACHE_DIR
    try {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if ($attempt -eq 2 -and $env:RUNNER_TEMP) {
                $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $env:RUNNER_TEMP "zig-global-cache-pr-smoke-retry-$PID"
                $env:ZIG_LOCAL_CACHE_DIR = Join-Path $env:RUNNER_TEMP "zig-local-cache-pr-smoke-retry-$PID"
            }

            $originalErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $buildOutput = @(& (Join-Path $repoRoot 'scripts\dev-windows.cmd') zig build -Demit-exe=true 2>&1)
                $buildExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $originalErrorActionPreference
            }
            $buildOutput | ForEach-Object { Write-Host $_ }
            if ($buildExitCode -eq 0) { break }

            $buildText = $buildOutput -join "`n"
            $cacheHydrationMiss = $buildText -match 'FileNotFound' -and $buildText -match 'zig-global-cache'
            if ($attempt -eq 2 -or -not $cacheHydrationMiss) {
                throw "PR smoke build failed with exit code $buildExitCode."
            }
            Write-Warning 'PR smoke build hit a transient Zig package-cache miss; retrying once with fresh temp cache directories.'
        }
    }
    finally {
        $env:ZIG_GLOBAL_CACHE_DIR = $originalZigGlobalCache
        $env:ZIG_LOCAL_CACHE_DIR = $originalZigLocalCache
    }
}

$childPowerShell = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if (-not $childPowerShell) {
    $childPowerShell = (Get-Process -Id $PID).Path
}

$groups = [Collections.Generic.List[object]]::new()
foreach ($harness in @(
    'interactive-win11-smoke.ps1',
    'interactive-win11-key-input.ps1',
    'interactive-win11-new-tab.ps1',
    'interactive-win11-resize.ps1',
    'interactive-win11-undo.ps1',
    'interactive-win11-accessibility.ps1',
    'interactive-win11-palette-theme.ps1',
    'interactive-win11-session-restore.ps1'
)) {
    $groupName = $harness -replace '^interactive-win11-', '' -replace '\.ps1$', ''
    $started = [DateTimeOffset]::UtcNow
    $oldStage = $env:WINGHOSTTY_HOSTED_STAGE
    if ($SummaryPath) {
        $env:WINGHOSTTY_HOSTED_STAGE = $groupName
    }
    $harnessArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-File'
        (Join-Path $PSScriptRoot $harness)
    )
    if ($ResetState) { $harnessArgs += '-ResetState' }
    if ($harness -eq 'interactive-win11-undo.ps1') {
        $harnessArgs += @('-TimeoutSeconds', '35')
    }

    try {
        & $childPowerShell @harnessArgs
        $exitCode = $LASTEXITCODE
        $groups.Add([ordered]@{
            name=$groupName;harness="test\windows\$harness"
            harness_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $harness)).Hash.ToLowerInvariant()
            started_at=$started.ToString('o');finished_at=[DateTimeOffset]::UtcNow.ToString('o')
            exit_code=$exitCode;status=$(if ($exitCode -eq 0) { 'pass' } else { 'fail' })
        })
        if ($SummaryPath) {
            $parent = Split-Path -Parent $SummaryPath
            if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
            @{schema_version='winghostty.pr-smoke-groups.v1';groups=@($groups)} |
                ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryPath -Encoding utf8NoBOM
        }
        if ($exitCode -ne 0) { throw "$harness failed with exit code $exitCode." }
    } finally {
        $env:WINGHOSTTY_HOSTED_STAGE = $oldStage
    }
}

Write-Host 'interactive Win11 PR smoke: PASS' -ForegroundColor Green
