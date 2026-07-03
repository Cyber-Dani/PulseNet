# watch.ps1
# Run this in PowerShell as: .\watch.ps1
# It writes data/wifi-data.json every 2 seconds.
# Keep this window open while you use the dashboard.

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "data\wifi-data.json"

Write-Host "PulseNet running. Output: $outputFile"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

$history      = @()
$maxHistory   = 43200  # 24 hours at 2-second poll interval
$pingTarget   = "8.8.8.8"
$spikeMs      = 150   # latency threshold for a spike (ms)
$lossStreak   = 0
$dnsTarget    = "google.com"
$jitterPings  = 4     # pings per interval for jitter measurement
$prevBssid    = $null # track AP roaming

# Detect default gateway once (refresh if it changes)
function Get-Gateway {
    $gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
           Sort-Object RouteMetric | Select-Object -First 1).NextHop
    return $gw
}

$gateway = Get-Gateway

# Fetch the most recent WiFi disconnect event from the System log (non-blocking, best-effort)
function Get-LastDisconnectReason {
    try {
        $evt = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            Id           = 20003   # WLAN AutoConfig disconnect
            StartTime    = (Get-Date).AddMinutes(-2)
        } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($evt) {
            $reason = ($evt.Message -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
            return @{ ts = [int][double]::Parse((Get-Date $evt.TimeCreated -UFormat %s)); reason = $reason }
        }
    } catch {}
    return $null
}

# Read WiFi adapter error/discard counters
function Get-AdapterStats {
    try {
        $wifiAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                       Where-Object { $_.PhysicalMediaType -match '802\.11' -and $_.Status -eq 'Up' } |
                       Select-Object -First 1
        if ($wifiAdapter) {
            $stats = Get-NetAdapterStatistics -Name $wifiAdapter.Name -ErrorAction SilentlyContinue
            if ($stats) {
                return @{
                    rxErrors   = [long]$stats.ReceivedPacketErrors
                    txErrors   = [long]$stats.OutboundPacketErrors
                    rxDiscards = [long]$stats.ReceivedDiscardedPackets
                    txDiscards = [long]$stats.OutboundDiscardedPackets
                }
            }
        }
    } catch {}
    return $null
}

$ping = New-Object System.Net.NetworkInformation.Ping
$prevAdapterStats = $null

while ($true) {
  try {
    $raw = netsh wlan show interfaces 2>$null

    $extract = {
        param($pattern)
        $match = $raw | Select-String -Pattern $pattern
        if ($match) { $match.Matches[0].Groups[1].Value.Trim() } else { $null }
    }

    $rx    = & $extract 'Receive rate \(Mbps\)\s*:\s*([\d.]+)'
    $tx    = & $extract 'Transmit rate \(Mbps\)\s*:\s*([\d.]+)'
    $rssi  = & $extract 'Rssi\s*:\s*([-\d]+)'
    $sig   = & $extract 'Signal\s*:\s*(\d+)%'
    $band  = & $extract 'Band\s*:\s*(.+)'
    $ch    = & $extract 'Channel\s*:\s*(\d+)'
    $radio = & $extract 'Radio type\s*:\s*(.+)'
    $ssid  = & $extract 'SSID\s*:\s*(.+)'
    $bssid = & $extract 'BSSID\s*:\s*([0-9a-fA-F:]{17})'

    # Detect AP roam
    $roamed = ($prevBssid -ne $null -and $bssid -ne $null -and $bssid -ne $prevBssid)
    $prevBssid = $bssid

    # Jitter: send $jitterPings in quick succession, measure spread
    $jitterSamples = @()
    $pingMs        = $null
    $pingLoss      = $false
    for ($i = 0; $i -lt $jitterPings; $i++) {
        try {
            $reply = $ping.Send($pingTarget, 1000)
            if ($reply.Status -eq 'Success') {
                $jitterSamples += [int]$reply.RoundtripTime
            } else {
                $pingLoss = $true
            }
        } catch {
            $pingLoss = $true
        }
    }
    if ($jitterSamples.Count -gt 0) {
        $pingMs = [int]($jitterSamples | Measure-Object -Average).Average
        # jitter = mean absolute deviation between consecutive samples
        $jitterMs = $null
        if ($jitterSamples.Count -ge 2) {
            $diffs = @()
            for ($i = 1; $i -lt $jitterSamples.Count; $i++) {
                $diffs += [Math]::Abs($jitterSamples[$i] - $jitterSamples[$i-1])
            }
            $jitterMs = [int]($diffs | Measure-Object -Average).Average
        }
        $pingMin = ($jitterSamples | Measure-Object -Minimum).Minimum
        $pingMax = ($jitterSamples | Measure-Object -Maximum).Maximum
    } else {
        $jitterMs = $null
        $pingMin  = $null
        $pingMax  = $null
        $pingLoss = $true
    }

    # Gateway (router) ping
    $gatewayMs   = $null
    $gatewayLoss = $false
    if ($gateway) {
        try {
            $gwReply = $ping.Send($gateway, 1000)
            if ($gwReply.Status -eq 'Success') {
                $gatewayMs = [int]$gwReply.RoundtripTime
            } else {
                $gatewayLoss = $true
            }
        } catch {
            $gatewayLoss = $true
        }
    }

    # DNS resolution time
    $dnsMs   = $null
    $dnsLoss = $false
    try {
        $dnsStart  = [System.Diagnostics.Stopwatch]::StartNew()
        $dnsResult = [System.Net.Dns]::GetHostAddresses($dnsTarget)
        $dnsStart.Stop()
        if ($dnsResult.Count -gt 0) {
            $dnsMs = [int]$dnsStart.ElapsedMilliseconds
        } else {
            $dnsLoss = $true
        }
    } catch {
        $dnsLoss = $true
    }

    # Adapter error/discard deltas since last sample
    $adapterNow    = Get-AdapterStats
    $adapterDelta  = $null
    if ($adapterNow -and $prevAdapterStats) {
        $adapterDelta = @{
            rxErrors   = $adapterNow.rxErrors   - $prevAdapterStats.rxErrors
            txErrors   = $adapterNow.txErrors   - $prevAdapterStats.txErrors
            rxDiscards = $adapterNow.rxDiscards  - $prevAdapterStats.rxDiscards
            txDiscards = $adapterNow.txDiscards  - $prevAdapterStats.txDiscards
        }
    }
    $prevAdapterStats = $adapterNow

    # Consecutive loss streak
    if ($pingLoss) { $lossStreak++ } else { $lossStreak = 0 }

    # Disconnect events — only query on loss to keep overhead low
    $disconnectEvent = $null
    if ($pingLoss -or $gatewayLoss) {
        $disconnectEvent = Get-LastDisconnectReason
    }

    # Refresh gateway if it went away
    if ($gatewayLoss) {
        $gateway = Get-Gateway
    }

    $ts = [int][double]::Parse((Get-Date -UFormat %s))

    $point = [ordered]@{
        ts              = $ts
        rx              = if ($rx)   { [double]$rx }   else { $null }
        tx              = if ($tx)   { [double]$tx }   else { $null }
        rssi            = if ($rssi) { [int]$rssi }    else { $null }
        sig             = if ($sig)  { [int]$sig }     else { $null }
        band            = $band
        ch              = $ch
        radio           = $radio
        ssid            = $ssid
        bssid           = $bssid
        roamed          = $roamed
        ping            = $pingMs
        pingMin         = $pingMin
        pingMax         = $pingMax
        jitter          = $jitterMs
        loss            = $pingLoss
        spike           = ($pingMs -ne $null -and $pingMs -ge $spikeMs)
        gateway         = $gateway
        gatewayMs       = $gatewayMs
        gatewayLoss     = $gatewayLoss
        dnsMs           = $dnsMs
        dnsLoss         = $dnsLoss
        lossStreak      = $lossStreak
        adapterErrors   = $adapterDelta
        disconnectEvent = $disconnectEvent
    }

    $history += $point
    if ($history.Count -gt $maxHistory) {
        $history = $history[($history.Count - $maxHistory)..($history.Count - 1)]
    }

    $json = [ordered]@{
        updated    = $ts
        current    = $point
        history    = $history
        spikeMs    = $spikeMs
        pingTarget = $pingTarget
    } | ConvertTo-Json -Depth 6

    $json | Out-File -FilePath $outputFile -Encoding UTF8 -NoNewline

    # Console status line
    $pingStatus = if ($pingLoss) { "LOSS(x$lossStreak)" } elseif ($pingMs -ge $spikeMs) { "SPIKE ${pingMs}ms" } else { "${pingMs}ms" }
    $jitStatus  = if ($jitterMs -ne $null) { "jitter:${jitterMs}ms" } else { "" }
    $gwStatus   = if ($gatewayLoss) { "GW:LOSS" } else { "GW:${gatewayMs}ms" }
    $dnsStatus  = if ($dnsLoss) { "DNS:LOSS" } else { "DNS:${dnsMs}ms" }
    $bssidShort = if ($bssid) { $bssid.ToUpper() } else { "?" }
    $roamFlag   = if ($roamed) { " ROAMED" } else { "" }
    $errTotal   = if ($adapterDelta) { $adapterDelta.rxErrors + $adapterDelta.txErrors + $adapterDelta.rxDiscards + $adapterDelta.txDiscards } else { 0 }
    $errFlag    = if ($errTotal -gt 0) { " ERR:rx=$($adapterDelta.rxErrors)/tx=$($adapterDelta.txErrors) DISC:rx=$($adapterDelta.rxDiscards)/tx=$($adapterDelta.txDiscards)" } else { "" }
    $wifiStatus = if ($rx) { "RX:${rx}  TX:${tx}  RSSI:${rssi}dBm  Sig:${sig}%  BSSID:$bssidShort" } else { "No interface" }
    Write-Host "$(Get-Date -Format 'HH:mm:ss')  $wifiStatus$roamFlag  Ping:$pingStatus  $jitStatus  $gwStatus  $dnsStatus$errFlag"

  } catch {
    Write-Host "$(Get-Date -Format 'HH:mm:ss')  [error] $($_.Exception.Message) — retrying in 2s"
  }
    Start-Sleep -Seconds 2
}
