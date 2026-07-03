# PulseNet

A lightweight, real-time dashboard for anyone who depends on a stable connection. Whether you are mid-match and wondering why your shots are not registering, on a video call that keeps breaking up, or just trying to figure out why your internet feels slow, this tool gives you a clear picture of what your WiFi is actually doing.

No installation required. Runs entirely on your machine using PowerShell and your default browser.

---

## What it shows

| Metric | What it means |
|---|---|
| **Receive / Transmit** | How fast your adapter is exchanging data with the router (Mbps) |
| **RSSI / Signal** | How strong the WiFi signal is at your location |
| **Latency** | How long it takes a packet to reach Google's DNS and come back (ms) |
| **Jitter** | How much the latency fluctuates - high jitter causes choppy calls and gaming lag |
| **Gateway ping** | How fast your router responds - isolates whether problems are local or internet-side |
| **DNS resolve** | How long it takes to look up a domain name |
| **Loss streak** | How many consecutive polling intervals had no internet reply |
| **Access point** | Which router/access point you're connected to (useful if you have multiple) |
| **Adapter errors** | Low-level WiFi card errors and discarded packets |

All metrics are logged over time and shown as scrollable charts so you can look back and spot when things went wrong.

---

## How to start

1. **Download the repository** — click the green **Code** button on GitHub and choose **Download ZIP**.

2. **Unpack the ZIP** — right-click the downloaded file and choose **Extract All…**, then pick a folder you'll remember (e.g. your Desktop or Documents).

3. **Double-click `Start-PulseNet.bat`** inside the extracted folder.

A tray icon will appear in your taskbar and the dashboard will open in your browser automatically.

> **Don't panic if a terminal window briefly flashes up**, that's completely normal. It's just Windows showing the startup script before it moves to the background.

> If Windows shows a security warning, click **More info → Run anyway**. The scripts are local and unsigned.

---

## How to stop

Either close the browser tab (PulseNet will shut down automatically within about a minute) or right-click the tray icon and choose **Stop & Exit** to stop it immediately.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (built into Windows - no install needed)
- Any up-to-date browser (Chrome, Edge, Firefox)

---

## How it works

`watch.ps1` collects WiFi metrics every 2 seconds using built-in Windows tools (`netsh`, `ping`, `Get-NetAdapterStatistics`) and writes them to `data/wifi-data.json`.

`TrayMonitor.ps1` runs `watch.ps1` silently in the background, starts a local web server on `http://localhost:8765`, and manages the tray icon.

The dashboard (`dashboard.html`) reads `data/wifi-data.json` every 2 seconds and updates the charts and cards live.
