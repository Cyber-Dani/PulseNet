# PulseNet

A real-time dashboard showing what your network connection is actually doing, over WiFi or Ethernet (link speed, latency, jitter, packet loss, and active traffic).

Runs locally using PowerShell and your default browser. No installation required.

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

PulseNet automatically detects whether you're connected over WiFi or Ethernet and only shows the metrics that apply - WiFi-specific cards (RSSI, signal, access point) are hidden on a wired connection.

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

Bandwidth figures are an estimate (prefixed `~`) - Windows has no public API for true per-process byte counts without an elevated ETW session, so PulseNet approximates it by weighting adapter-level throughput by each app/host's share of active connections.

### Contributing host tags

The tag/description list lives in [`data/tracker-rules.json`](data/tracker-rules.json) and is maintained by hand - it can't possibly cover every service everyone runs. If you spot an untagged host you recognize, please open a PR adding an entry. Each rule looks like:

```json
{ "pattern": "example\\.com", "tag": "cloud", "desc": "What this service actually is" }
```

- `pattern` is a case-insensitive regex matched against the hostname (or the ISP/org string from GeoIP lookup if `"matchOrg": true` is set).
- `tag` drives the small colored pill shown on the host row.
- `desc` is the tooltip text shown on hover.

---

## History tab

Every time PulseNet (re)starts, the session that just ended is archived to `sessions/`. Switch to the **History** tab to browse past sessions:

- The session list shows start time, duration, average ping, loss/spike counts, and average signal, sorted newest first - the most recent session is selected automatically so you see a chart immediately.
- Click any session to view its charts and event log read-only, exactly as they looked live.
- **Download** produces the same `.txt` report as the live dashboard; **Delete** (or **Delete all**) removes archived sessions you no longer need.

Sessions shorter than 5 data points aren't archived, and everything is stored locally in `sessions/` - nothing leaves your machine.

---

## Insights tab

The **Insights** tab looks across all your saved sessions (up to the last 50) to surface patterns a single session can't show on its own:

- **Event frequency over time** - a daily bar chart of loss/spike counts, to see whether things are getting better or worse.
- **Time of day** - an hourly breakdown, useful for spotting recurring ISP congestion or maintenance windows.
- **Local link vs. WAN vs. router** - buckets every loss/spike by likely cause, so you know whether to chase a cable or escalate to your ISP.
- **Top correlated apps/hosts** - which app or host was most often active right around a loss or spike, across every session.
- **Session list** - headline stats per session, linking into the History tab for a closer look.

Needs at least two saved sessions to show anything meaningful.

---

## How to start

1. **Download the repository** - click the green **Code** button on GitHub and choose **Download ZIP**.

2. **Unpack the ZIP** - right-click the downloaded file and choose **Extract All…**, then pick a folder you'll remember (e.g. your Desktop or Documents).

3. **Double-click `Start-PulseNet.bat`** inside the extracted folder.

The dashboard will open in your browser automatically.

> **Don't panic if a terminal window briefly flashes up**, that's completely normal. It's just Windows showing the startup script before it moves to the background.

> If Windows shows a security warning, click **More info → Run anyway**. The scripts are local and unsigned.

---

## How to stop

Close the browser tab - PulseNet detects this and shuts itself down automatically within a few minutes.

If you end the PowerShell process directly instead (e.g. via Task Manager), everything stops immediately - both collectors are tied to that process's lifetime, so there's nothing left running in the background.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (built into Windows - no install needed)
- Any up-to-date browser (Chrome, Edge, Firefox)

---

## How it works

`watch.ps1` detects whether your active adapter is WiFi or Ethernet, collects the relevant connection metrics every 2 seconds using built-in Windows tools (`netsh`, `ping`, `Get-NetAdapter`, `Get-NetAdapterStatistics`), and writes them to `data/wifi-data.json`.

`traffic-watch.ps1` polls active TCP connections, resolves hostnames and GeoIP/org info for remote IPs, and writes them to `data/traffic-data.json` on the same interval.

`TrayMonitor.ps1` runs both collectors silently in the background and starts a local web server on `http://localhost:8765`. Before each (re)start it archives the previous session's data to `sessions/` and exposes it over that same server for the History and Insights tabs.

The dashboard (`dashboard.html`) reads `data/wifi-data.json` every 2 seconds and updates the charts and cards live. The traffic dashboard (`traffic.html`) does the same with `data/traffic-data.json`. The History (`history.html`) and Insights (`insights.html`) tabs read from `sessions/` via the server instead, since that data isn't part of the live poll loop.
