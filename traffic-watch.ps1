# traffic-watch.ps1
# Run alongside watch.ps1 — writes data/traffic-data.json every 3 seconds.
# No extra dependencies required. GeoIP via ip-api.com (free, no key).

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "data\traffic-data.json"

Write-Host "Traffic monitor running. Output: $outputFile"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$dnsCache      = @{}   # ip -> hostname
$geoCache      = @{}   # ip -> {country, countryCode, org}
$iconCache     = @{}   # exePath -> base64 PNG string (persists across polls)
$connFirstSeen  = @{}   # "localPort|remoteIp|remotePort" -> unix timestamp
$connSeenCycles = @{}   # "localPort|remoteIp|remotePort" -> poll cycles seen
$lastGeoBatch  = [DateTime]::MinValue
$geoCooldown   = 60    # seconds between GeoIP batch calls

# T1 — adapter-level bandwidth tracking
$prevAdapterRx = $null
$prevAdapterTx = $null
$sessionRx     = 0
$sessionTx     = 0
$appBytes      = @{}   # appName -> {rx, tx} session cumulative (estimated)
$hostBytes     = @{}   # ip -> {rx, tx} session cumulative (estimated)

$portNames = @{
    80    = "HTTP"
    443   = "HTTPS"
    53    = "DNS"
    22    = "SSH"
    25    = "SMTP"
    587   = "SMTP"
    465   = "SMTP"
    110   = "POP3"
    143   = "IMAP"
    993   = "IMAPS"
    995   = "POP3S"
    3306  = "MySQL"
    5432  = "PostgreSQL"
    1433  = "MSSQL"
    6379  = "Redis"
    27017 = "MongoDB"
    3389  = "RDP"
    5900  = "VNC"
    8080  = "HTTP-Alt"
    8443  = "HTTPS-Alt"
    5228  = "FCM"
    5229  = "FCM"
    5230  = "FCM"
    1935  = "RTMP"
    8883  = "MQTT"
    51820 = "WireGuard"
    1194  = "OpenVPN"
    500   = "IKE/VPN"
    4500  = "IKE-NAT"
    3478  = "STUN/TURN"
    3479  = "STUN/TURN"
    19302 = "STUN"
    19303 = "STUN"
    19304 = "STUN"
    19305 = "STUN"
    6881  = "BitTorrent"
    6969  = "BitTorrent"
}

$browserExes = @('chrome','msedge','brave','opera','vivaldi','thorium','waterfox')

function Get-BrowserSubType($cmdLine) {
    if (-not $cmdLine) { return 'browser' }
    if ($cmdLine -match '--type=(\S+)') {
        switch ($Matches[1]) {
            'renderer'         {
                if ($cmdLine -match '--extension-process') { return 'extension' }
                return 'renderer'
            }
            'gpu-process'      { return 'GPU' }
            'utility'          {
                if ($cmdLine -match 'NetworkService') { return 'network-service' }
                return 'utility'
            }
            'crashpad-handler' { return 'crashpad' }
            default            { return $Matches[1] }
        }
    }
    return 'browser'
}

function Get-ProcessMap {
    $map = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $pPath = try { $_.MainModule.FileName }                            catch { $null }
        $pDesc = try { $_.MainModule.FileVersionInfo.FileDescription }     catch { $null }
        $map[[string]$_.Id] = [ordered]@{
            name    = $_.ProcessName
            desc    = $pDesc
            exePath = $pPath
        }
    }
    return $map
}

function Refresh-DnsCache {
    Get-DnsClientCache -ErrorAction SilentlyContinue |
        Where-Object { ($_.Type -eq 1 -or $_.Type -eq 28) -and $_.Data -and $_.Entry } |
        ForEach-Object {
            $ip   = $_.Data.Trim()
            $name = $_.Entry.Trim().TrimEnd('.')
            if ($ip -and $name -and -not $script:dnsCache.ContainsKey($ip)) {
                $script:dnsCache[$ip] = $name
            }
        }
}

function Get-AppIconB64($exePath) {
    if (-not $exePath) { return $null }
    if ($script:iconCache.ContainsKey($exePath)) { return $script:iconCache[$exePath] }
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
        $src  = $icon.ToBitmap()
        $bmp  = New-Object System.Drawing.Bitmap(16, 16)
        $g    = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, 16, 16)
        $g.Dispose(); $src.Dispose(); $icon.Dispose()
        $ms  = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $b64 = [Convert]::ToBase64String($ms.ToArray())
        $ms.Dispose()
        $script:iconCache[$exePath] = $b64
        return $b64
    } catch {
        $script:iconCache[$exePath] = $null
        return $null
    }
}

function Get-ActiveAdapterStats {
    try {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match '802\.11|802\.3' } |
                   Sort-Object -Property @{Expression = { if ($_.PhysicalMediaType -match '802\.3') { 0 } else { 1 } }} |
                   Select-Object -First 1
        if ($adapter) {
            return Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
        }
    } catch {}
    return $null
}

function Update-GeoCache($ips) {
    if (-not $ips -or $ips.Count -eq 0) { return }
    $uncached = @($ips | Where-Object { -not $geoCache.ContainsKey($_) })
    if ($uncached.Count -eq 0) { return }
    for ($i = 0; $i -lt $uncached.Count; $i += 100) {
        $chunk = $uncached[$i..[Math]::Min($i + 99, $uncached.Count - 1)]
        try {
            $body    = ($chunk | ForEach-Object { "{`"query`":`"$_`"}" }) -join ","
            $body    = "[$body]"
            $results = Invoke-RestMethod `
                -Uri "http://ip-api.com/batch?fields=query,country,countryCode,org,status" `
                -Method POST -Body $body -ContentType "application/json" -TimeoutSec 8
            foreach ($r in $results) {
                if ($r.status -eq "success") {
                    # Strip the leading "AS12345 " prefix from org to get a clean name
                    $orgName = if ($r.org) { $r.org -replace '^AS\d+\s+', '' } else { $null }
                    $geoCache[$r.query] = @{ country = $r.country; code = $r.countryCode; org = $orgName }
                } else {
                    $geoCache[$r.query] = @{ country = "Local/Private"; code = "LAN"; org = $null }
                }
            }
        } catch {
            foreach ($ip in $chunk) { $geoCache[$ip] = @{ country = "Unknown"; code = "?" } }
        }
    }
}

while ($true) {
    Refresh-DnsCache
    $processMap = Get-ProcessMap

    $rawConns = Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object {
            $_.State -in @('Established','TimeWait','CloseWait') -and
            $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0$|::%)'
        }

    # Build pid -> subType map for browser processes via command-line args
    $pidSubType    = @{}   # pidStr -> subType label
    $browserPidSet = [System.Collections.Generic.HashSet[string]]::new()
    $processMap.GetEnumerator() |
        Where-Object { $_.Value.name -in $script:browserExes } |
        ForEach-Object { $browserPidSet.Add($_.Key) | Out-Null }
    if ($browserPidSet.Count -gt 0) {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $browserPidSet.Contains([string]$_.ProcessId) } |
            ForEach-Object {
                $pidSubType[[string]$_.ProcessId] = Get-BrowserSubType $_.CommandLine
            }
    }

    $nowTs = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

    $appMap          = @{}   # appName -> {count, ips, ports}
    $appExeMap       = @{}   # appName -> exePath (first seen per poll)
    $hostMap         = @{}   # ip -> {count, apps, ports}
    $protoMap        = @{}   # knownProto -> {count, apps Set}
    $unknownPortMap  = @{}   # port (int) -> {count, apps Set}
    $browserBreakdown = @{}  # appName -> subType -> {count, pids Set}
    $connList        = [System.Collections.Generic.List[object]]::new()
    $seenConnKeys    = [System.Collections.Generic.HashSet[string]]::new()
    $newThisPoll     = 0
    $newConnsByApp   = @{}   # appName -> count of new connections this poll

    foreach ($c in $rawConns) {
        $pidStr = [string]$c.OwningProcess
        $proc   = $processMap[$pidStr]
        $app    = if ($proc) { $proc.name } else { "Unknown" }
        $ip     = $c.RemoteAddress
        $port   = $c.RemotePort

        # Track exe path for icon (first occurrence wins)
        if ($proc -and $proc.exePath -and -not $appExeMap.ContainsKey($app)) {
            $appExeMap[$app] = $proc.exePath
        }

        # Browser sub-type breakdown
        $st = $pidSubType[$pidStr]
        if ($st) {
            if (-not $browserBreakdown.ContainsKey($app)) { $browserBreakdown[$app] = @{} }
            if (-not $browserBreakdown[$app].ContainsKey($st)) {
                $browserBreakdown[$app][$st] = @{ count = 0; pids = [System.Collections.Generic.HashSet[int]]::new() }
            }
            $browserBreakdown[$app][$st].count++
            $browserBreakdown[$app][$st].pids.Add($c.OwningProcess) | Out-Null
        }

        $knownProto = if ($portNames.ContainsKey($port)) { $portNames[$port] } else { $null }
        $connKey    = "$($c.LocalPort)|$ip|$port"
        $seenConnKeys.Add($connKey) | Out-Null
        if (-not $script:connFirstSeen.ContainsKey($connKey)) {
            $script:connFirstSeen[$connKey] = $nowTs
            $newThisPoll++
            if (-not $newConnsByApp.ContainsKey($app)) { $newConnsByApp[$app] = 0 }
            $newConnsByApp[$app]++
        }
        if (-not $script:connSeenCycles.ContainsKey($connKey)) { $script:connSeenCycles[$connKey] = 0 }
        $script:connSeenCycles[$connKey]++

        $connList.Add([ordered]@{
            localPort  = $c.LocalPort
            remoteIp   = $ip
            remotePort = $port
            protocol   = if ($knownProto) { $knownProto } else { "Other" }
            state      = $c.State.ToString()
            pid        = $c.OwningProcess
            app        = $app
            firstSeen  = $script:connFirstSeen[$connKey]
            seenCycles = $script:connSeenCycles[$connKey]
        })

        # App aggregation
        if (-not $appMap.ContainsKey($app)) {
            $appMap[$app] = @{ count = 0; ips = [System.Collections.Generic.HashSet[string]]::new(); ports = [System.Collections.Generic.HashSet[int]]::new() }
        }
        $appMap[$app].count++
        $appMap[$app].ips.Add($ip)     | Out-Null
        $appMap[$app].ports.Add($port) | Out-Null

        # Host aggregation
        if (-not $hostMap.ContainsKey($ip)) {
            $hostMap[$ip] = @{ count = 0; apps = [System.Collections.Generic.HashSet[string]]::new(); ports = [System.Collections.Generic.HashSet[int]]::new() }
        }
        $hostMap[$ip].count++
        $hostMap[$ip].apps.Add($app)   | Out-Null
        $hostMap[$ip].ports.Add($port) | Out-Null

        # Protocol aggregation — named vs unknown port
        if ($knownProto) {
            if (-not $protoMap.ContainsKey($knownProto)) {
                $protoMap[$knownProto] = @{ count = 0; apps = [System.Collections.Generic.HashSet[string]]::new() }
            }
            $protoMap[$knownProto].count++
            $protoMap[$knownProto].apps.Add($app) | Out-Null
        } else {
            if (-not $unknownPortMap.ContainsKey($port)) {
                $unknownPortMap[$port] = @{ count = 0; apps = [System.Collections.Generic.HashSet[string]]::new() }
            }
            $unknownPortMap[$port].count++
            $unknownPortMap[$port].apps.Add($app) | Out-Null
        }
    }

    # Prune firstSeen/seenCycles entries for connections that no longer exist
    @($script:connFirstSeen.Keys) | Where-Object { -not $seenConnKeys.Contains($_) } | ForEach-Object { $script:connFirstSeen.Remove($_) }
    @($script:connSeenCycles.Keys) | Where-Object { -not $seenConnKeys.Contains($_) } | ForEach-Object { $script:connSeenCycles.Remove($_) }

    # T1 — adapter-level bandwidth delta + connection-share weighting (estimated per-app/host bytes)
    $wifiStats  = Get-ActiveAdapterStats
    $intervalRx = 0
    $intervalTx = 0
    if ($wifiStats -and $null -ne $script:prevAdapterRx) {
        $intervalRx = [Math]::Max(0, $wifiStats.ReceivedBytes - $script:prevAdapterRx)
        $intervalTx = [Math]::Max(0, $wifiStats.SentBytes     - $script:prevAdapterTx)
        $script:sessionRx += $intervalRx
        $script:sessionTx += $intervalTx
    }
    if ($wifiStats) {
        $script:prevAdapterRx = $wifiStats.ReceivedBytes
        $script:prevAdapterTx = $wifiStats.SentBytes
    }

    $totalConns = $connList.Count
    foreach ($app in $appMap.Keys) {
        $share = if ($totalConns -gt 0) { $appMap[$app].count / $totalConns } else { 0 }
        if (-not $script:appBytes.ContainsKey($app)) { $script:appBytes[$app] = @{ rx = 0L; tx = 0L } }
        $script:appBytes[$app].rx += [long]($intervalRx * $share)
        $script:appBytes[$app].tx += [long]($intervalTx * $share)
    }
    foreach ($ip in $hostMap.Keys) {
        $share = if ($totalConns -gt 0) { $hostMap[$ip].count / $totalConns } else { 0 }
        if (-not $script:hostBytes.ContainsKey($ip)) { $script:hostBytes[$ip] = @{ rx = 0L; tx = 0L } }
        $script:hostBytes[$ip].rx += [long]($intervalRx * $share)
        $script:hostBytes[$ip].tx += [long]($intervalTx * $share)
    }

    # GeoIP batch on cooldown
    $allIps = @($hostMap.Keys)
    if ($allIps.Count -gt 0 -and ([DateTime]::Now - $lastGeoBatch).TotalSeconds -ge $geoCooldown) {
        Update-GeoCache $allIps
        $lastGeoBatch = [DateTime]::Now
    }

    $maxAppConns  = if ($appMap.Count)  { ($appMap.Values  | ForEach-Object { $_.count } | Measure-Object -Maximum).Maximum } else { 1 }
    $maxHostConns = if ($hostMap.Count) { ($hostMap.Values | ForEach-Object { $_.count } | Measure-Object -Maximum).Maximum } else { 1 }
    if (-not $maxAppConns)  { $maxAppConns  = 1 }
    if (-not $maxHostConns) { $maxHostConns = 1 }

    $appsOut = $appMap.GetEnumerator() |
        Sort-Object { $_.Value.count } -Descending |
        ForEach-Object {
            $appName = $_.Key
            $exePath = $appExeMap[$appName]
            $iconB64 = Get-AppIconB64 $exePath

            $children = $null
            if ($browserBreakdown.ContainsKey($appName)) {
                $children = @($browserBreakdown[$appName].GetEnumerator() |
                    Sort-Object { $_.Value.count } -Descending |
                    ForEach-Object {
                        $st      = $_.Key
                        $cnt     = $_.Value.count
                        $pidCnt  = $_.Value.pids.Count
                        $label   = switch ($st) {
                            'renderer'        { if ($pidCnt -gt 1) { "renderer x$pidCnt" } else { "renderer" } }
                            'network-service' { "network service" }
                            'GPU'             { "GPU process" }
                            'extension'       { if ($pidCnt -gt 1) { "extension x$pidCnt" } else { "extension" } }
                            'utility'         { "utility" }
                            'browser'         { "browser" }
                            'crashpad'        { $null }  # skip — never makes connections
                            default           { $st }
                        }
                        if ($label) {
                            [ordered]@{ subType = $st; label = $label; connections = $cnt; processes = $pidCnt }
                        }
                    } | Where-Object { $_ })
            }

            $ab = $script:appBytes[$appName]
            $entry = [ordered]@{
                name        = $appName
                connections = $_.Value.count
                pct         = [Math]::Round(($_.Value.count / $maxAppConns) * 100)
                hosts       = $_.Value.ips.Count
                ports       = @($_.Value.ports)
                iconB64     = $iconB64
                rxBytes     = if ($ab) { $ab.rx } else { 0L }
                txBytes     = if ($ab) { $ab.tx } else { 0L }
                newConns    = if ($newConnsByApp.ContainsKey($appName)) { $newConnsByApp[$appName] } else { 0 }
            }
            if ($children -and $children.Count -gt 0) { $entry.children = $children }
            $entry
        }

    $hostsOut = $hostMap.GetEnumerator() |
        Sort-Object { $_.Value.count } -Descending |
        ForEach-Object {
            $ip  = $_.Key
            $geo = $geoCache[$ip]
            $hb  = $script:hostBytes[$ip]
            [ordered]@{
                ip          = $ip
                hostname    = if ($dnsCache.ContainsKey($ip)) { $dnsCache[$ip] } else { $ip }
                connections = $_.Value.count
                pct         = [Math]::Round(($_.Value.count / $maxHostConns) * 100)
                apps        = @($_.Value.apps)
                ports       = @($_.Value.ports)
                country     = if ($geo) { $geo.country }     else { $null }
                countryCode = if ($geo) { $geo.code }        else { $null }
                org         = if ($geo) { $geo.org }         else { $null }
                rxBytes     = if ($hb) { $hb.rx } else { 0L }
                txBytes     = if ($hb) { $hb.tx } else { 0L }
            }
        }

    $countryMap = @{}
    foreach ($h in $hostsOut) {
        $cn = if ($h.country) { $h.country } else { "Unknown" }
        $cc = if ($h.countryCode) { $h.countryCode } else { "?" }
        if (-not $countryMap.ContainsKey($cn)) {
            $countryMap[$cn] = @{ name = $cn; code = $cc; connections = 0 }
        }
        $countryMap[$cn].connections += $h.connections
    }
    $countriesOut = @($countryMap.Values | Sort-Object { $_.connections } -Descending)

    # Protocol list: named protocols first, then individual unknown ports (>=2 conns),
    # then a single residual "Other" row for singletons.
    $protosList = [System.Collections.Generic.List[object]]::new()
    $protoMap.GetEnumerator() | Sort-Object { $_.Value.count } -Descending | ForEach-Object {
        $protosList.Add([ordered]@{
            protocol    = $_.Key
            connections = $_.Value.count
            apps        = @($_.Value.apps)
            isPort      = $false
        })
    }

    $otherTotal = 0
    $otherApps  = [System.Collections.Generic.HashSet[string]]::new()
    $unknownPortMap.GetEnumerator() | Sort-Object { $_.Value.count } -Descending | ForEach-Object {
        if ($_.Value.count -ge 2) {
            $protosList.Add([ordered]@{
                protocol    = ":$($_.Key)"
                connections = $_.Value.count
                apps        = @($_.Value.apps)
                isPort      = $true
            })
        } else {
            $otherTotal += $_.Value.count
            foreach ($a in $_.Value.apps) { $otherApps.Add($a) | Out-Null }
        }
    }
    if ($otherTotal -gt 0) {
        $protosList.Add([ordered]@{
            protocol    = "Other"
            connections = $otherTotal
            apps        = @($otherApps)
            isPort      = $false
        })
    }
    $protosOut = @($protosList | Sort-Object { $_.connections } -Descending)

    $ts = $nowTs

    $output = [ordered]@{
        updated     = $ts
        totals      = [ordered]@{
            connections = $connList.Count
            apps        = $appMap.Count
            hosts       = $hostMap.Count
        }
        bandwidth   = [ordered]@{
            intervalRx = $intervalRx
            intervalTx = $intervalTx
            sessionRx  = $script:sessionRx
            sessionTx  = $script:sessionTx
        }
        newConns    = $newThisPoll
        apps        = @($appsOut)
        hosts       = @($hostsOut)
        countries   = $countriesOut
        protocols   = $protosOut
        connections = @($connList | Select-Object -First 200)
    } | ConvertTo-Json -Depth 5

    $output | Out-File -FilePath $outputFile -Encoding UTF8 -NoNewline

    Write-Host "$(Get-Date -Format 'HH:mm:ss')  Conns:$($connList.Count)  Apps:$($appMap.Count)  Hosts:$($hostMap.Count)  Countries:$($countryMap.Count)"

    Start-Sleep -Seconds 3
}
