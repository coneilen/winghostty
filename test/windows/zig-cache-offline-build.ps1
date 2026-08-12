$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\..\scripts\zig-cache.ps1")

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$originalGlobal = $env:ZIG_GLOBAL_CACHE_DIR
$originalLocal = $env:ZIG_LOCAL_CACHE_DIR
$fixture = Join-Path $repoRoot ".zig-cache-offline-fixture"
$libxevArchive = "libxev-34fa50878aec6e5fa8f532867001ab3c36fae23e.tar.gz"
$libxevPackage = "libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs"

try {
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $repoRoot ".zig-cache"
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $repoRoot ".zig-global-cache"
    $paths = Set-WinghosttyZigCacheEnvironment -RepoRoot $repoRoot

    $archivePath = Join-Path $paths.Local "downloads\$libxevArchive"
    $packagePath = Join-Path $paths.Global "p\$libxevPackage"
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Missing seeded dependency archive: $archivePath. Run fetch-zig-deps.ps1 first."
    }
    if (-not (Test-Path -LiteralPath $packagePath -PathType Container)) {
        throw "Missing seeded dependency package: $packagePath. Run fetch-zig-deps.ps1 first."
    }

    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $fixture | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $fixture "build.zig"), @'
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.dependency("libxev", .{});
    const exe = b.addExecutable(.{
        .name = "cache-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(exe);
}
'@, $utf8)
    [IO.File]::WriteAllText((Join-Path $fixture "build.zig.zon"), @'
.{
    .name = .cache_consumer,
    .version = "0.0.0",
    .fingerprint = 0xc8e5b0b6b8740506,
    .paths = .{""},
    .dependencies = .{
        .libxev = .{
            .url = "http://127.0.0.1:9/libxev.tar.gz",
            .hash = "libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs",
        },
    },
}
'@, $utf8)
    [IO.File]::WriteAllText((Join-Path $fixture "main.zig"), "pub fn main() void {}$([Environment]::NewLine)", $utf8)

    $zigExe = if ($env:ZIG_HOME) {
        Join-Path $env:ZIG_HOME "zig.exe"
    } else {
        (Get-Command zig.exe -ErrorAction Stop).Source
    }
    $fixtureLocal = Join-Path $fixture ".zig-cache"
    Push-Location $fixture
    try {
        & $zigExe build `
            --global-cache-dir $paths.Global `
            --cache-dir $fixtureLocal
        if ($LASTEXITCODE -ne 0) {
            throw "Offline cache-consumption build failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    $env:ZIG_GLOBAL_CACHE_DIR = $originalGlobal
    $env:ZIG_LOCAL_CACHE_DIR = $originalLocal
}

Write-Host "Zig offline cache-consumption regression test passed."
