# TrayMonitor.ps1
# Runs the WiFi collector and a local HTTP server, then shows a system tray icon.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$watchScript    = Join-Path $scriptDir "watch.ps1"
$trafficScript  = Join-Path $scriptDir "traffic-watch.ps1"
$wifiDataFile   = Join-Path $scriptDir "data\wifi-data.json"
$trafficDataFile = Join-Path $scriptDir "data\traffic-data.json"
$staleThresholdSec = 30   # both collectors poll every 2-3s; a longer silence means a hang, not just a slow cycle
$port           = 8765
$url            = "http://localhost:$port/dashboard.html"
$logFile        = Join-Path $scriptDir "traymonitor.log"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# Kill any leftover processes from a previous session.
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object {
        $_.ProcessId -ne $PID -and (
            $_.CommandLine -like '*TrayMonitor.ps1*' -or
            $_.CommandLine -like '*watch.ps1*'       -or
            $_.CommandLine -like '*traffic-watch.ps1*'
        )
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Clear stale data from the previous session before anything else starts,
# so the browser never sees old timestamps on a fresh open.
'{}' | Out-File -FilePath (Join-Path $scriptDir "data\wifi-data.json")   -Encoding UTF8 -NoNewline
'{}' | Out-File -FilePath (Join-Path $scriptDir "data\traffic-data.json") -Encoding UTF8 -NoNewline

# -- Shared state between HTTP runspace and main thread --
$syncHash = [hashtable]::Synchronized(@{ LastHeartbeat = [DateTime]::Now })

# -- HTTP server (runs on its own thread via a runspace) --
$httpRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$httpRunspace.Open()
$httpRunspace.SessionStateProxy.SetVariable('scriptDir', $scriptDir)
$httpRunspace.SessionStateProxy.SetVariable('port', $port)
$httpRunspace.SessionStateProxy.SetVariable('syncHash', $syncHash)

$httpScript = {
    $mimeMap = @{
        '.html' = 'text/html; charset=utf-8'
        '.json' = 'application/json'
        '.js'   = 'application/javascript'
        '.css'  = 'text/css'
        '.png'  = 'image/png'
        '.ico'  = 'image/x-icon'
    }

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()

    while ($listener.IsListening) {
        try {
            $ctx  = $listener.GetContext()
            $req  = $ctx.Request
            $res  = $ctx.Response

            $reqPath = $req.Url.LocalPath.TrimStart('/')
            if ($reqPath -eq '') { $reqPath = 'dashboard.html' }

            # Heartbeat endpoint — browser pings this to signal the tab is open
            if ($reqPath -eq 'heartbeat') {
                $syncHash.LastHeartbeat = [DateTime]::Now
                $res.StatusCode = 204
                $res.OutputStream.Close()
                continue
            }

            # Prevent path traversal
            $filePath = [System.IO.Path]::GetFullPath((Join-Path $scriptDir $reqPath))
            if (-not $filePath.StartsWith($scriptDir)) {
                $res.StatusCode = 403
                $res.OutputStream.Close()
                continue
            }

            if (Test-Path $filePath -PathType Leaf) {
                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                $ext   = [System.IO.Path]::GetExtension($filePath).ToLower()
                $res.ContentType      = if ($mimeMap[$ext]) { $mimeMap[$ext] } else { 'application/octet-stream' }
                $res.ContentLength64  = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } else {
                $res.StatusCode = 404
            }
            $res.OutputStream.Close()
        } catch { }
    }
}

$httpPipeline = [System.Management.Automation.PowerShell]::Create()
$httpPipeline.Runspace = $httpRunspace
$httpPipeline.AddScript($httpScript) | Out-Null
$httpPipeline.BeginInvoke() | Out-Null

# -- Collector processes (no console window) --
function Start-Hidden($script) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $psi.WindowStyle    = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

Write-Log "PulseNet starting"
$script:watchProc   = Start-Hidden $watchScript
$script:trafficProc = Start-Hidden $trafficScript
Write-Log "Collectors started (watch PID $($script:watchProc.Id), traffic PID $($script:trafficProc.Id))"

# A collector counts as "just (re)started" for one grace period so we don't flag it
# stale before its first write has even landed.
$script:watchStartedAt   = [DateTime]::Now
$script:trafficStartedAt = [DateTime]::Now

function Test-CollectorStale($dataFile, $startedAt) {
    if (((Get-Date) - $startedAt).TotalSeconds -lt $staleThresholdSec) { return $false }
    if (-not (Test-Path $dataFile)) { return $true }
    $age = ((Get-Date) - (Get-Item $dataFile).LastWriteTime).TotalSeconds
    return $age -gt $staleThresholdSec
}

# -- System tray icon --
$tray         = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = [System.Drawing.SystemIcons]::Network
$tray.Text    = "PulseNet"
$tray.Visible = $true

$menu     = New-Object System.Windows.Forms.ContextMenuStrip
$header   = New-Object System.Windows.Forms.ToolStripMenuItem "PulseNet"
$header.Enabled = $false
$openItem = New-Object System.Windows.Forms.ToolStripMenuItem "Open Dashboard"
$stopItem = New-Object System.Windows.Forms.ToolStripMenuItem "Stop && Exit"

$menu.Items.Add($header)   | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$menu.Items.Add($openItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$menu.Items.Add($stopItem) | Out-Null

$tray.ContextMenuStrip = $menu

$tray.add_DoubleClick({ Start-Process $url })
$openItem.add_Click({  Start-Process $url })

$stopItem.add_Click({
    Write-Log "Stopped by user"
    $script:watchProc   | Stop-Process -Force -ErrorAction SilentlyContinue
    $script:trafficProc | Stop-Process -Force -ErrorAction SilentlyContinue
    $tray.Visible = $false
    Stop-Process -Id $PID -Force
})

# Open dashboard and show balloon tip
Start-Process $url

$tray.BalloonTipTitle = "PulseNet Running"
$tray.BalloonTipText  = "Double-click the tray icon to open the dashboard."
$tray.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
$tray.ShowBalloonTip(4000)

# Shut down when the browser tab has been closed for >60 seconds.
# Sleep detection: if the timer fires but wall-clock time jumped by more than
# 60s, the system was asleep — reset the heartbeat so a sleep never looks like
# a closed tab.
$script:lastTick = [DateTime]::Now
$heartbeatTimer = New-Object System.Windows.Forms.Timer
$heartbeatTimer.Interval = 10000
$heartbeatTimer.add_Tick({
    $now     = [DateTime]::Now
    $elapsed = ($now - $script:lastTick).TotalSeconds
    $script:lastTick = $now

    if ($elapsed -gt 60) {
        Write-Log "System wake detected (${elapsed}s gap) - heartbeat reset"
        $syncHash.LastHeartbeat = $now
        return
    }

    $age = ($now - $syncHash.LastHeartbeat).TotalSeconds
    if ($age -gt 60) {
        Write-Log "Heartbeat timeout ($([int]$age)s) - shutting down"
        $script:watchProc   | Stop-Process -Force -ErrorAction SilentlyContinue
        $script:trafficProc | Stop-Process -Force -ErrorAction SilentlyContinue
        $tray.Visible = $false
        Stop-Process -Id $PID -Force
    }
})
$heartbeatTimer.Start()

# Watchdog: restart collector processes if they die unexpectedly.
$watchdogTimer = New-Object System.Windows.Forms.Timer
$watchdogTimer.Interval = 15000
$watchdogTimer.add_Tick({
    try {
        if ($script:watchProc -and $script:watchProc.HasExited) {
            Write-Log "[watchdog] watch.ps1 exited (code $($script:watchProc.ExitCode)) - restarting"
            $script:watchProc = Start-Hidden $watchScript
            $script:watchStartedAt = [DateTime]::Now
        } elseif (Test-CollectorStale $wifiDataFile $script:watchStartedAt) {
            Write-Log "[watchdog] watch.ps1 output stale (no write in ${staleThresholdSec}s) - killing and restarting"
            $script:watchProc | Stop-Process -Force -ErrorAction SilentlyContinue
            $script:watchProc = Start-Hidden $watchScript
            $script:watchStartedAt = [DateTime]::Now
        }
        if ($script:trafficProc -and $script:trafficProc.HasExited) {
            Write-Log "[watchdog] traffic-watch.ps1 exited (code $($script:trafficProc.ExitCode)) - restarting"
            $script:trafficProc = Start-Hidden $trafficScript
            $script:trafficStartedAt = [DateTime]::Now
        } elseif (Test-CollectorStale $trafficDataFile $script:trafficStartedAt) {
            Write-Log "[watchdog] traffic-watch.ps1 output stale (no write in ${staleThresholdSec}s) - killing and restarting"
            $script:trafficProc | Stop-Process -Force -ErrorAction SilentlyContinue
            $script:trafficProc = Start-Hidden $trafficScript
            $script:trafficStartedAt = [DateTime]::Now
        }
    } catch {
        Write-Log "[watchdog] error: $($_.Exception.Message)"
    }
})
$watchdogTimer.Start()

[System.Windows.Forms.Application]::Run()
