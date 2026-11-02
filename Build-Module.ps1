<#
.SYNOPSIS
    Builds the KernelSU/Magisk module zip (module\ + domains.txt + dnsproxy linux arm64/arm7)
    and the standalone PC page SplitDNS-PC.html.

.EXAMPLE
    .\Build-Module.ps1
.EXAMPLE
    .\Build-Module.ps1 -DnsproxyVersion v0.86.0 -Out D:\splitdns.zip
.EXAMPLE
    .\Build-Module.ps1 -PageOnly -PageOut _site/index.html     # GitHub Pages
#>
[CmdletBinding()]
param(
    [string]$DnsproxyVersion = 'v0.86.0',
    [string]$Out = (Join-Path $PSScriptRoot 'splitdns-module.zip'),
    [string]$PageOut = (Join-Path $PSScriptRoot 'SplitDNS-PC.html'),
    [switch]$PageOnly
)

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'module'

# Standalone page for a PC browser: lists and default config inlined (file:// cannot fetch them)
$lists = [ordered]@{}
Get-ChildItem (Join-Path $src 'lists') -File | ForEach-Object { $lists[$_.Name] = [IO.File]::ReadAllText($_.FullName) }
$data = "<script>window.__lists = {0};`nwindow.__defaultConf = {1};</script>" -f `
    ($lists | ConvertTo-Json -Compress), ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'domains.txt')) | ConvertTo-Json -Compress)
$page = [IO.File]::ReadAllText((Join-Path $src 'webroot/index.html')).Replace('<!--PC-DATA-->', $data)
$pageDir = Split-Path -Parent ([IO.Path]::GetFullPath($PageOut))
New-Item -ItemType Directory -Force $pageDir | Out-Null
[IO.File]::WriteAllText([IO.Path]::GetFullPath($PageOut), $page, [Text.UTF8Encoding]::new($false))
Write-Host "Built $PageOut"

if ($PageOnly) { return }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$cache = Join-Path $PSScriptRoot ".dnsproxy-$DnsproxyVersion"
New-Item -ItemType Directory -Force $cache | Out-Null

# dnsproxy has no Android builds; the static linux ones run fine there
$bins = [ordered]@{ 'dnsproxy-arm64' = 'linux-arm64'; 'dnsproxy-arm' = 'linux-arm7' }
foreach ($name in $bins.Keys) {
    $bin = Join-Path $cache $name
    if (Test-Path $bin) { continue }
    $plat = $bins[$name]
    $tgz = Join-Path $cache "dnsproxy-$plat.tar.gz"
    $url = "https://github.com/AdguardTeam/dnsproxy/releases/download/$DnsproxyVersion/dnsproxy-$plat-$DnsproxyVersion.tar.gz"
    Write-Host "Downloading $url"
    curl.exe -fsSL -o $tgz $url
    if ($LASTEXITCODE) { throw "download failed: $url" }
    $x = Join-Path $cache "x-$plat"
    New-Item -ItemType Directory -Force $x | Out-Null
    tar.exe -xzf $tgz -C $x
    if ($LASTEXITCODE) { throw "extract failed: $tgz" }
    Move-Item (Join-Path $x "$plat/dnsproxy") $bin
    Remove-Item -Recurse -Force $x, $tgz
}

if (Test-Path $Out) { Remove-Item -Force $Out }
$zip = [System.IO.Compression.ZipFile]::Open($Out, 'Create')
try {
    function Add-Entry([string]$entryName, [byte[]]$bytes) {
        $e = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $s = $e.Open(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
    }
    function Add-Text([string]$entryName, [string]$file) {
        # Shell scripts must have LF line endings
        $text = [IO.File]::ReadAllText($file) -replace "`r`n", "`n"
        Add-Entry $entryName ([Text.UTF8Encoding]::new($false).GetBytes($text))
    }

    # Stray archives in module\ are not part of the module
    Get-ChildItem -Recurse -File $src | Where-Object Extension -ne '.zip' | ForEach-Object {
        Add-Text ($_.FullName.Substring($src.Length + 1) -replace '\\', '/') $_.FullName
    }
    Add-Text 'domains.txt' (Join-Path $PSScriptRoot 'domains.txt')
    foreach ($name in $bins.Keys) {
        Add-Entry "bin/$name" ([IO.File]::ReadAllBytes((Join-Path $cache $name)))
    }
}
finally { $zip.Dispose() }

Write-Host "Built $Out"
