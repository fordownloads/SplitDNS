#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Applies per-domain DNS servers from domains.txt as Windows NRPT rules.

.DESCRIPTION
    Removes every NRPT rule tagged with -Tag, then creates new ones from the file.
    File syntax is like hosts, but the first column is a DNS server (or several, comma-separated):

        9.9.9.10,149.112.112.10  google.com .google.com   # comment

    Lines commented out ("#@ ...", disabled groups in the WebUI) are ignored.

    "name" = exact name, ".name" = its subdomains, "*" = everything (NRPT ".").

.EXAMPLE
    .\Apply-SplitDns.ps1
.EXAMPLE
    .\Apply-SplitDns.ps1 -Path D:\cfg\domains.txt
.EXAMPLE
    .\Apply-SplitDns.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'domains.txt'),
    [string]$Tag = 'splitdns-bypass',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$old = @(Get-DnsClientNrptRule | Where-Object Comment -eq $Tag)
foreach ($r in $old) { Remove-DnsClientNrptRule -Name $r.Name -Force }
Write-Host "Removed $($old.Count) rule(s) tagged '$Tag'"

if ($Remove) {
    Clear-DnsClientCache
    return
}

if (-not (Test-Path -LiteralPath $Path)) { throw "Config not found: $Path" }

# Namespace -> ordered list of servers
$map = [ordered]@{}
$owner = @{}
$lineNo = 0
foreach ($raw in Get-Content -LiteralPath $Path) {
    $lineNo++
    $line = ($raw -replace '#.*').Trim()
    if (-not $line) { continue }

    $first, $names = $line -split '\s+'
    # "a,b" = several servers; NRPT takes plain IPs only, DoH/DoT URLs are skipped
    $servers = @(foreach ($s in $first -split ',' | Where-Object { $_ }) {
        $ip = $null
        if ([ipaddress]::TryParse($s, [ref]$ip)) { $s }
        else { Write-Warning "line ${lineNo}: '$s' is not an IP address, skipped" }
    })
    if (-not $servers) { continue }
    if (-not $names) {
        Write-Warning "line ${lineNo}: no names after $first, skipped"
        continue
    }

    foreach ($n in $names) {
        $ns = if ($n -eq '*') { '.' } else { $n.ToLowerInvariant() }
        if ($ns -ne '.' -and $ns -notmatch '^\.?[a-z0-9_-]+(\.[a-z0-9_-]+)*\.?$') {
            Write-Warning "line ${lineNo}: bad name '$n', skipped"
            continue
        }
        # A name listed on several lines belongs to the first one (upper group wins)
        if ($owner.Contains($ns)) { continue }
        $owner[$ns] = $lineNo
        $map[$ns] = $servers
    }
}

foreach ($ns in $map.Keys) {
    Add-DnsClientNrptRule -Namespace $ns -NameServers $map[$ns] -Comment $Tag | Out-Null
}
Clear-DnsClientCache

$applied = @(Get-DnsClientNrptPolicy | Where-Object { $map.Contains($_.Namespace) })
Write-Host "Added $($map.Count) rule(s), effective now: $($applied.Count)"
if ($applied.Count -lt $map.Count) {
    Write-Warning 'Not all rules are effective. A Group Policy NRPT may be overriding local rules.'
}
$map.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{ Namespace = $_.Key; Servers = $_.Value -join ', ' }
} | Format-Table -AutoSize
