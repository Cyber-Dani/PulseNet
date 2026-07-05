# TrayMonitor.ps1
# Runs the WiFi collector and a local HTTP server, then shows a system tray icon.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Windows Job Object wrapper: any process assigned to a job created with
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is terminated the instant the job's last
# handle closes. Since only this process holds that handle, killing this
# process by any means (Stop-Process -Force, Task Manager, a crash) closes
# the handle and the OS cascades the kill to both collectors immediately —
# unlike Process.Start()'d children, which would otherwise be orphaned.
Add-Type -Name JobObject -Namespace PulseNet -MemberDefinition @'
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr a, string lpName);
    [DllImport("kernel32.dll")]
    public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
'@

function New-KillOnCloseJob {
    # JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144 bytes on 64-bit Windows
    # (JOBOBJECT_BASIC_LIMIT_INFORMATION's 64 bytes + IO_COUNTERS' 48 bytes +
    # four trailing SIZE_T fields); only LimitFlags (offset 0x10, value 0x2000
    # = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) needs to be non-zero.
    $job = [PulseNet.JobObject]::CreateJobObject([IntPtr]::Zero, $null)
    $infoSize = 144
    $info = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($infoSize)
    try {
        for ($i = 0; $i -lt $infoSize; $i++) {
            [System.Runtime.InteropServices.Marshal]::WriteByte($info, $i, 0)
        }
        [System.Runtime.InteropServices.Marshal]::WriteInt32($info, 0x10, 0x2000)
        [PulseNet.JobObject]::SetInformationJobObject($job, 9, $info, $infoSize) | Out-Null
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info)
    }
    return $job
}

function Add-ProcessToJob($job, $process) {
    [PulseNet.JobObject]::AssignProcessToJobObject($job, $process.Handle) | Out-Null
}

$killOnCloseJob = New-KillOnCloseJob

$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$watchScript    = Join-Path $scriptDir "watch.ps1"
$trafficScript  = Join-Path $scriptDir "traffic-watch.ps1"
$wifiDataFile   = Join-Path $scriptDir "data\wifi-data.json"
$trafficDataFile = Join-Path $scriptDir "data\traffic-data.json"
$sessionsDir    = Join-Path $scriptDir "sessions"
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

# Archive the outgoing session (if any) into sessions/ before wiping the live
# data files, so PDR 1 (session history) and PDR 8 (cross-session insights)
# have something to read. Best-effort: a missing/malformed prior data file
# must never block the new session from starting.
function Save-OutgoingSession {
    try {
        if (-not (Test-Path $wifiDataFile)) { return }
        $wifi = Get-Content $wifiDataFile -Raw | ConvertFrom-Json
        if (-not $wifi.history -or $wifi.history.Count -lt 5) { return }

        if (-not (Test-Path $sessionsDir)) {
            New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null
        }

        $points = $wifi.history
        $start  = [DateTimeOffset]::FromUnixTimeSeconds([int64]$points[0].ts).LocalDateTime
        $end    = [DateTimeOffset]::FromUnixTimeSeconds([int64]$points[-1].ts).LocalDateTime
        $stamp  = $start.ToString("yyyy-MM-ddTHH-mm-ss")

        $trafficHistory = @()
        if (Test-Path $trafficDataFile) {
            try {
                $traffic = Get-Content $trafficDataFile -Raw | ConvertFrom-Json
                if ($traffic.history) { $trafficHistory = $traffic.history }
            } catch { }
        }

        $session = [ordered]@{
            updated        = $wifi.updated
            pingTarget     = $wifi.pingTarget
            spikeMs        = $wifi.spikeMs
            history        = $points
            trafficHistory = $trafficHistory
        }
        $session | ConvertTo-Json -Depth 12 -Compress |
            Out-File -FilePath (Join-Path $sessionsDir "$stamp.json") -Encoding UTF8 -NoNewline

        $pings   = @($points | Where-Object { $_.ping -ne $null })
        $rssis   = @($points | Where-Object { $_.rssi -ne $null })
        $lossCount  = @($points | Where-Object { $_.loss }).Count
        $spikeCount = @($points | Where-Object { $_.spike }).Count
        $roamCount  = @($points | Where-Object { $_.roamed }).Count
        $connTypeBreakdown = @{}
        foreach ($p in $points) {
            $ct = if ($p.connType) { $p.connType } else { 'unknown' }
            $connTypeBreakdown[$ct] = ($connTypeBreakdown[$ct] + 1)
        }

        $summary = [ordered]@{
            filename           = "$stamp.json"
            start              = $start.ToString("o")
            duration           = [int]($end - $start).TotalSeconds
            pointCount         = $points.Count
            avgPing            = if ($pings.Count)  { [math]::Round((($pings   | Measure-Object -Property ping -Sum).Sum / $pings.Count), 1) } else { $null }
            avgSignal          = if ($rssis.Count)   { [math]::Round((($rssis  | Measure-Object -Property rssi -Sum).Sum / $rssis.Count), 1) } else { $null }
            lossCount          = $lossCount
            spikeCount         = $spikeCount
            roamCount          = $roamCount
            connTypeBreakdown  = $connTypeBreakdown
        }
        $summary | ConvertTo-Json -Depth 5 -Compress |
            Out-File -FilePath (Join-Path $sessionsDir "$stamp.summary.json") -Encoding UTF8 -NoNewline

        Write-Log "Archived session $stamp.json ($($points.Count) points, $lossCount losses, $spikeCount spikes)"
    } catch {
        Write-Log "Session archive failed: $($_.Exception.Message)"
    }
}
Save-OutgoingSession

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
$httpRunspace.SessionStateProxy.SetVariable('sessionsDir', $sessionsDir)

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

            # -- Session history / insights endpoints (PDR 1 / PDR 8) --
            if ($reqPath -eq 'sessions' -or $reqPath.StartsWith('sessions/')) {
                $sessionName = if ($reqPath -eq 'sessions') { '' } else { $reqPath.Substring('sessions/'.Length) }

                if ($req.HttpMethod -eq 'GET' -and $sessionName -eq '') {
                    # List all sessions from their summary files, newest first.
                    $list = @()
                    if (Test-Path $sessionsDir) {
                        Get-ChildItem -Path $sessionsDir -Filter '*.summary.json' | Sort-Object Name -Descending | ForEach-Object {
                            try { $list += (Get-Content $_.FullName -Raw | ConvertFrom-Json) } catch { }
                        }
                    }
                    # ConvertTo-Json collapses a 1-element array into a bare object instead of
                    # a JSON array, which would break the frontend's Array methods — force array
                    # syntax explicitly rather than relying on -AsArray (not present on PS 5.1).
                    $json = if ($list.Count -eq 0) { '[]' }
                            elseif ($list.Count -eq 1) { '[' + ($list[0] | ConvertTo-Json -Depth 5 -Compress) + ']' }
                            else { $list | ConvertTo-Json -Depth 5 -Compress }
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = 'application/json'
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    $res.OutputStream.Close()
                    continue
                }

                if ($req.HttpMethod -eq 'DELETE' -and $sessionName -eq '') {
                    # Delete all sessions.
                    if (Test-Path $sessionsDir) {
                        Get-ChildItem -Path $sessionsDir -Filter '*.json' | Remove-Item -Force -ErrorAction SilentlyContinue
                    }
                    $res.StatusCode = 204
                    $res.OutputStream.Close()
                    continue
                }

                # Path-traversal guard: resolved path must stay inside sessionsDir.
                $sessionPath = [System.IO.Path]::GetFullPath((Join-Path $sessionsDir $sessionName))
                if (-not $sessionPath.StartsWith($sessionsDir)) {
                    $res.StatusCode = 403
                    $res.OutputStream.Close()
                    continue
                }

                if ($req.HttpMethod -eq 'GET') {
                    if (Test-Path $sessionPath -PathType Leaf) {
                        $bytes = [System.IO.File]::ReadAllBytes($sessionPath)
                        $res.ContentType = 'application/json'
                        $res.ContentLength64 = $bytes.Length
                        $res.OutputStream.Write($bytes, 0, $bytes.Length)
                    } else {
                        $res.StatusCode = 404
                    }
                    $res.OutputStream.Close()
                    continue
                }

                if ($req.HttpMethod -eq 'DELETE') {
                    Remove-Item -Path $sessionPath -Force -ErrorAction SilentlyContinue
                    $summaryPath = $sessionPath -replace '\.json$', '.summary.json'
                    Remove-Item -Path $summaryPath -Force -ErrorAction SilentlyContinue
                    $res.StatusCode = 204
                    $res.OutputStream.Close()
                    continue
                }

                $res.StatusCode = 405
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
# Every collector (initial start and watchdog restarts alike) goes through
# here, so assigning it to $killOnCloseJob here covers all of them: if this
# PowerShell process dies for any reason, Windows kills these along with it.
function Start-Hidden($script) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $psi.WindowStyle    = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    Add-ProcessToJob $killOnCloseJob $proc
    return $proc
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

# Shut down when the browser tab has been closed for a while.
# Threshold is generous (not 60s) because backgrounding a tab — switching to
# another window/tab without closing it — makes Chrome/Edge throttle its
# setInterval heartbeat down to as little as once a minute, or suspend it
# entirely; a tight timeout would kill the monitor while the tab is still
# open just because the user tabbed away.
# Sleep detection: if the timer fires but wall-clock time jumped by more than
# 60s, the system was asleep — reset the heartbeat so a sleep never looks like
# a closed tab.
$heartbeatTimeoutSec = 300
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
    if ($age -gt $heartbeatTimeoutSec) {
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
