$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$fixture = Join-Path $repoRoot ".zig-cache\download-test-$([guid]::NewGuid())"
$downloadDir = Join-Path $fixture "downloads"
$globalCacheDir = Join-Path $fixture "global"
$portFile = Join-Path $fixture "port.txt"
$payload = "lengthless dependency bytes"
$zigExe = "Invoke-TestZig"
$seeded = New-Object 'System.Collections.Generic.List[string]'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot "scripts\fetch-zig-deps.ps1"), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Dependency seeder has parse errors: $errors" }
$definition = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-Seed"
}, $true)
if (-not $definition) { throw "Invoke-Seed is missing" }
. ([scriptblock]::Create($definition.Extent.Text))

function Invoke-TestZig {
    if ($args.Count -ne 4 -or $args[0] -ne "fetch" -or
        $args[1] -ne "--global-cache-dir" -or $args[2] -ne $globalCacheDir) {
        throw "Seeder lost the configured Zig global cache"
    }
    if ([IO.File]::ReadAllText($args[3]) -cne $payload) {
        throw "Seeder passed incomplete download bytes to Zig"
    }
    $seeded.Add($args[3])
    $global:LASTEXITCODE = 0
}

try {
    New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
    $server = Start-Job -ArgumentList $portFile, $payload -ScriptBlock {
        param($portFile, $payload)
        $ErrorActionPreference = "Stop"
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        [IO.File]::WriteAllText($portFile, [string]$listener.LocalEndpoint.Port)
        try {
            while ($true) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 50
                    continue
                }
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 5000
                    $reader = New-Object IO.StreamReader($stream)
                    $request = $reader.ReadLine()
                    if (-not $request) { continue }
                    while ($reader.ReadLine()) { }
                    $path = $request.Split(" ")[1]
                    $status = "200 OK"
                    $headers = "Connection: close`r`n"
                    $body = $payload
                    switch ($path) {
                        "/redirect" { $status = "302 Found"; $headers += "Location: /lengthless`r`nContent-Length: 0`r`n"; $body = "" }
                        "/missing" { $status = "404 Not Found"; $headers += "Content-Length: 0`r`n"; $body = "" }
                        "/truncated" { $headers += "Content-Length: 1024`r`n" }
                        "/chunked" {
                            $headers += "Transfer-Encoding: chunked`r`n"
                            $body = ("{0:x}`r`n{1}`r`n0`r`n`r`n" -f $payload.Length, $payload)
                        }
                    }
                    if ($request.StartsWith("HEAD ")) { $body = "" }
                    $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`n$headers`r`n$body")
                    $stream.Write($response, 0, $response.Length)
                }
                finally { $client.Dispose() }
            }
        }
        finally { $listener.Stop() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $portFile) -and [DateTime]::UtcNow -lt $deadline) {
        if ($server.State -eq "Failed") { Receive-Job $server -ErrorAction Stop }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $portFile)) { throw "Loopback download fixture did not start" }
    $baseUrl = "http://127.0.0.1:$([IO.File]::ReadAllText($portFile))"

    foreach ($path in @("lengthless", "chunked", "redirect")) {
        Invoke-Seed @{ Url = "$baseUrl/$path"; File = "$path.tar.gz" }
        if ($seeded.Count -ne [array]::IndexOf(@("lengthless", "chunked", "redirect"), $path) + 1) {
            throw "Download was not passed to Zig: $path"
        }
    }
    foreach ($path in @("missing", "truncated")) {
        $rejected = $false
        try { Invoke-Seed @{ Url = "$baseUrl/$path"; File = "$path.tar.gz" } }
        catch { $rejected = $true }
        if (-not $rejected -or (Test-Path (Join-Path $downloadDir "$path.tar.gz"))) {
            throw "Failed download was accepted or cached: $path"
        }
    }
    Invoke-Seed @{ Url = "$baseUrl/missing"; File = "optional.tar.gz"; Optional = $true }
    if ($seeded.Count -ne 3 -or @(Get-ChildItem $downloadDir -Filter "*.partial").Count -ne 0) {
        throw "Failed download reached Zig or left a partial archive"
    }
    Invoke-Seed @{ Url = "$baseUrl/missing"; File = "lengthless.tar.gz" }
    if ($seeded.Count -ne 4) { throw "Existing archive was not reused" }
    Write-Host "Dependency download regression tests passed."
}
finally {
    if ($server) {
        Stop-Job $server
        Remove-Job $server -Force
    }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
