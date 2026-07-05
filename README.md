# PulseNet

A lightweight, real-time dashboard for anyone who depends on a stable connection. Whether you are mid-match and wondering why your shots are not registering, on a video call that keeps breaking up, or just trying to figure out why your internet feels slow, this tool gives you a clear picture of what your connection is actually doing — over WiFi or Ethernet.

No installation required. Runs entirely on your machine using PowerShell and your default browser.

---

## What it shows

| Metric | What it means |
|---|---|
| **Receive / Transmit** | Your adapter's negotiated link speed (Mbps) |
| **RSSI / Signal** | How strong the WiFi signal is at your location *(WiFi only)* |
| **Latency** | How long it takes a packet to reach Google's DNS and come back (ms) |
| **Jitter** | How much the latency fluctuates - high jitter causes choppy calls and gaming lag |
| **Gateway ping** | How fast your router responds - isolates whether problems are local or internet-side |
| **DNS resolve** | How long it takes to look up a domain name |
| **Loss streak** | How many consecutive polling intervals had no internet reply |
| **Access point** | Which router/access point you're connected to (useful if you have multiple) *(WiFi only)* |
| **Adapter errors** | Low-level network card errors and discarded packets |

PulseNet automatically detects whether you're connected over WiFi or Ethernet and only shows the metrics that apply — WiFi-specific cards (RSSI, signal, access point) are hidden on a wired connection.

All metrics are logged over time and shown as scrollable charts so you can look back and spot when things went wrong.

---

## Traffic tab

Switch to the **Traffic** tab (next to Signal in the header) to see what's actually talking on your network:

| View | What it shows |
|---|---|
| **Hosts / Apps / Countries / Protocols** | Active connections grouped four ways, with estimated bandwidth per app and host |
| **Long-lived** | Connections that have stayed open a while, sorted by age |
| **Matrix** | Which apps are talking to which countries |
| **Tags** | Known hosts are labelled (tracker, ads, CDN, cloud, gaming, chat, storage, etc.) and show a plain-English description on hover, e.g. hovering `api.anthropic.com` shows "Anthropic API (Claude)" |

Bandwidth figures are an estimate (prefixed `~`) — Windows has no public API for true per-process byte counts without an elevated ETW session, so PulseNet approximates it by weighting adapter-level throughput by each app/host's share of active connections.

### Contributing host tags

The tag/description list lives in [`data/tracker-rules.json`](data/tracker-rules.json) and is maintained by hand — it can't possibly cover every service everyone runs. If you spot an untagged host you recognize, please open a PR adding an entry. Each rule looks like:

```json
{ "pattern": "example\\.com", "tag": "cloud", "desc": "What this service actually is" }
```

- `pattern` is a case-insensitive regex matched against the hostname (or the ISP/org string from GeoIP lookup if `"matchOrg": true` is set).
- `tag` drives the small colored pill shown on the host row.
- `desc` is the tooltip text shown on hover.

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

`watch.ps1` detects whether your active adapter is WiFi or Ethernet, collects the relevant connection metrics every 2 seconds using built-in Windows tools (`netsh`, `ping`, `Get-NetAdapter`, `Get-NetAdapterStatistics`), and writes them to `data/wifi-data.json`.

`traffic-watch.ps1` polls active TCP connections, resolves hostnames and GeoIP/org info for remote IPs, and writes them to `data/traffic-data.json` on the same interval.

`TrayMonitor.ps1` runs both collectors silently in the background, starts a local web server on `http://localhost:8765`, and manages the tray icon.

The dashboard (`dashboard.html`) reads `data/wifi-data.json` every 2 seconds and updates the charts and cards live. The traffic dashboard (`traffic.html`) does the same with `data/traffic-data.json`.
