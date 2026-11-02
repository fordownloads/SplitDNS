<#
.SYNOPSIS
    Resolves a list of hosts through several DNS servers and shows the answers side by side.

.DESCRIPTION
    Host list: one name per line, "#" starts a comment.
    A server is either an IP (plain DNS over UDP, sent directly: NRPT, hosts and the
    system cache are not involved) or a DoH JSON endpoint URL
    (https://cloudflare-dns.com/dns-query, https://dns.google/resolve).

    The table shows the first address and how many more there are; -Csv saves all of them.

    Match column:  =  all servers returned the same addresses
                   ~  answers differ but share at least one address
                   !  some server's answer shares nothing with the others (spoofing / geo-DNS)
                   ?  fewer than two servers returned addresses
                   =? / ~? / !?  same, among the servers that answered; others returned nothing
    A plain-DNS server that does not answer over UDP is retried over TCP.

.EXAMPLE
    .\Compare-Dns.ps1 hosts.txt
.EXAMPLE
    .\Compare-Dns.ps1 -Name www.google.com,yt3.ggpht.com -Type AAAA
.EXAMPLE
    .\Compare-Dns.ps1 hosts.txt -Servers 192.168.1.1,109.120.132.43,https://dns.google/resolve -Csv out.csv
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path = (Join-Path $PSScriptRoot 'hosts.txt'),
    [string[]]$Name,
    [string[]]$Servers = @('37.230.192.51'),
    [ValidateSet('A', 'AAAA')]
    [string]$Type = 'A',
    [string]$Csv,
    [int]$TimeoutMs = 500,
    [int]$ThrottleLimit = 16
)

$ErrorActionPreference = 'Stop'

# Minimal DNS client: one UDP query, returns addresses or throws with the rcode name
function Invoke-RawDns([string]$HostName, [string]$Server, [int]$QType, [int]$TimeoutMs) {
    $id = Get-Random -Maximum 65535
    $q = [System.Collections.Generic.List[byte]]::new()
    $q.AddRange([byte[]]@(($id -shr 8), ($id -band 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0))
    foreach ($label in $HostName.TrimEnd('.').Split('.')) {
        $b = [Text.Encoding]::ASCII.GetBytes($label)
        $q.Add($b.Length); $q.AddRange($b)
    }
    $q.AddRange([byte[]]@(0, 0, $QType, 0, 1))

    $ip = [ipaddress]::Parse($Server)
    $ep = [System.Net.IPEndPoint]::new($ip, 53)
    $r = $null
    $udp = [System.Net.Sockets.UdpClient]::new($ip.AddressFamily)
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        [void]$udp.Send($q.ToArray(), $q.Count, $ep)
        $remote = $null
        do { $r = $udp.Receive([ref]$remote) } while ((([int]$r[0] -shl 8) -bor $r[1]) -ne $id)
        if ($r[2] -band 2) { $r = $null }   # truncated: retry over TCP
    }
    catch [System.Net.Sockets.SocketException] { $r = $null }
    finally { $udp.Dispose() }

    if (-not $r) {
        # Some servers only answer over TCP; same query with a 2-byte length prefix
        $tcp = [System.Net.Sockets.TcpClient]::new($ip.AddressFamily)
        try {
            if (-not $tcp.ConnectAsync($ip, 53).Wait($TimeoutMs)) { throw 'timeout' }
            $s = $tcp.GetStream()
            $s.ReadTimeout = $TimeoutMs
            $msg = [byte[]]@(($q.Count -shr 8), ($q.Count -band 255)) + $q.ToArray()
            $s.Write($msg, 0, $msg.Length)
            $read = { param($n) $buf = [byte[]]::new($n); $o = 0
                while ($o -lt $n) { $k = $s.Read($buf, $o, $n - $o); if (-not $k) { throw 'timeout' }; $o += $k }
                , $buf }
            $lenBuf = & $read 2
            $r = & $read ((([int]$lenBuf[0]) -shl 8) -bor $lenBuf[1])
        }
        catch { throw 'timeout' }
        finally { $tcp.Dispose() }
    }

    $rcode = $r[3] -band 15
    if ($rcode) { throw (@{ 1 = 'FORMERR'; 2 = 'SERVFAIL'; 3 = 'NXDOMAIN'; 5 = 'REFUSED' }[$rcode] ?? "rcode $rcode") }

    function Skip-Name([int]$p) {
        while ($r[$p] -ne 0) {
            if (($r[$p] -band 0xC0) -eq 0xC0) { return $p + 2 }
            $p += $r[$p] + 1
        }
        $p + 1
    }
    $p = Skip-Name 12
    $p += 4
    # [int] casts: -shl on a [byte] stays 8-bit
    $an = ([int]$r[6] -shl 8) -bor $r[7]
    for ($i = 0; $i -lt $an; $i++) {
        $p = Skip-Name $p
        $t = ([int]$r[$p] -shl 8) -bor $r[$p + 1]
        $len = ([int]$r[$p + 8] -shl 8) -bor $r[$p + 9]
        $p += 10
        if ($t -eq $QType) { [ipaddress]::new([byte[]]$r[$p..($p + $len - 1)]).ToString() }
        $p += $len
    }
}

if (-not $Name) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Host list not found: $Path" }
    $Name = Get-Content -LiteralPath $Path | ForEach-Object { ($_ -replace '#.*').Trim() } | Where-Object { $_ }
}
$Name = @($Name | ForEach-Object { $_ -split '[\s,]+' } | Where-Object { $_ } | Select-Object -Unique)

$labels = [ordered]@{}
foreach ($s in $Servers) {
    $labels[$s] = if ($s -match '^https?://([^/]+)') { "DoH $($Matches[1])" } else { $s }
}

$rawDns = ${function:Invoke-RawDns}.ToString()
$results = $Name | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
	Write-Host "-> $_"
    ${function:Invoke-RawDns} = $using:rawDns
    $hostName = $_
    $type = $using:Type
    $code = if ($type -eq 'A') { 1 } else { 28 }
    $answers = [ordered]@{}
    foreach ($s in $using:Servers) {
        try {
            if ($s -match '^https?://') {
                $uri = '{0}?name={1}&type={2}' -f $s, [uri]::EscapeDataString($hostName), $type
                $r = Invoke-RestMethod -Uri $uri -Headers @{ accept = 'application/dns-json' } -TimeoutSec ([math]::Ceiling($using:TimeoutMs / 1000))
                if ($r.Status -eq 3) { throw 'NXDOMAIN' }
                if ($r.Status) { throw "rcode $($r.Status)" }
                $ips = @($r.Answer | Where-Object type -eq $code | ForEach-Object data)
            }
            else {
                $ips = @(Invoke-RawDns $hostName $s $code $using:TimeoutMs)
            }
            $answers[$s] = @($ips | Sort-Object { [version]($_ -replace ':', '.' -replace '\.\.', '.0.') } -Unique -ErrorAction SilentlyContinue)
            if (-not $answers[$s]) { $answers[$s] = @($ips | Sort-Object -Unique) }
        }
        catch { $answers[$s] = "$($_.Exception.Message)" }
    }

    # Compare only the servers that answered; "?" suffix = some server gave no addresses
    $all = @($answers.Values | ForEach-Object { , @($_ | Where-Object { $_ -as [ipaddress] }) })
    $sets = @($all | Where-Object { $_.Count })
    $failed = if ($sets.Count -lt $all.Count) { '?' } else { '' }
    $match =
        if ($sets.Count -lt 2) { '?' }
        elseif (@($sets | ForEach-Object { $_ -join ',' } | Select-Object -Unique).Count -eq 1) { '=' }
        else {
            $lonely = $false
            for ($i = 0; $i -lt $sets.Count; $i++) {
                $others = for ($j = 0; $j -lt $sets.Count; $j++) { if ($j -ne $i) { $sets[$j] } }
                if (-not ($sets[$i] | Where-Object { $_ -in $others })) { $lonely = $true }
            }
            if ($lonely) { '!' } else { '~' }
        }
    if ($match -ne '?') { $match += $failed }
    [pscustomobject]@{ Host = $hostName; Match = $match; Answers = $answers }
}

$order = @{}; for ($i = 0; $i -lt $Name.Count; $i++) { $order[$Name[$i]] = $i }
$results = @($results | Sort-Object { $order[$_.Host] })

function Format-Answer($a, [switch]$Full) {
    $ips = @($a | Where-Object { $_ -as [ipaddress] })
    if (-not $ips) { if ($a -is [string]) { return $a } else { return '-' } }
    if ($Full -or $ips.Count -eq 1) { return $ips -join ' ' }
    '{0} (+{1})' -f $ips[0], ($ips.Count - 1)
}

$rows = foreach ($r in $results) {
    $o = [ordered]@{ Match = $r.Match; Host = $r.Host }
    foreach ($s in $Servers) { $o[$labels[$s]] = Format-Answer $r.Answers[$s] }
    [pscustomobject]$o
}
$rows | Format-Table -AutoSize | Out-Host

# Full table (all addresses) as CSV: always summary.txt, plus -Csv if given
$full = $results | ForEach-Object {
    $o = [ordered]@{ Match = $_.Match; Host = $_.Host }
    foreach ($s in $Servers) { $o[$labels[$s]] = Format-Answer $_.Answers[$s] -Full }
    [pscustomobject]$o
}
foreach ($f in @('summary.txt') + @($Csv | Where-Object { $_ })) {
    $full | Export-Csv -Path $f -NoTypeInformation -Encoding utf8
    Write-Host "Saved $f"
}

$summary = $results | Group-Object Match | ForEach-Object { "$($_.Name) $($_.Count)" }
Write-Host ("Match: " + ($summary -join ', '))