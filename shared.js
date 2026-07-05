// Shared diagnosis/classification helpers used by dashboard.html, history.html
// and insights.html so loss/spike interpretation stays consistent everywhere
// a session (live or archived) is displayed.

// ── Theme picker ──────────────────────────────────────────────────
// Shared across every page (dashboard/traffic/history/insights) so the theme
// stays consistent no matter which tab you switch to. Pages that render
// Chart.js charts can define their own `updateChartTheme()` — it's called
// after a switch if present, otherwise skipped.
const THEMES = [
  { id: 'midnight',   name: 'Midnight',   bg: '#0d0f12', surface: '#13161b', accent: '#3b82f6' },
  { id: 'dusk',       name: 'Dusk',       bg: '#171e2d', surface: '#1e2740', accent: '#3bb8c8' },
  { id: 'ember',      name: 'Ember',      bg: '#140e0b', surface: '#1e1511', accent: '#e07548' },
  { id: 'daylight',   name: 'Daylight',   bg: '#f0f2f6', surface: '#ffffff', accent: '#3b82f6' },
  { id: 'arctic',     name: 'Arctic',     bg: '#e0eff8', surface: '#f2f9fc', accent: '#1a8fb0' },
  { id: 'sakura',     name: 'Sakura',     bg: '#fdf0f4', surface: '#ffffff', accent: '#c83868' },
  { id: 'lavender',   name: 'Lavender',   bg: '#f2eef8', surface: '#faf8ff', accent: '#7048c8' },
  { id: 'terracotta', name: 'Terracotta', bg: '#fdf4ee', surface: '#fffaf6', accent: '#2ab098' },
];

function buildThemePicker() {
  document.getElementById('theme-menu').innerHTML = THEMES.map(t => `
    <div class="theme-swatch" id="swatch-${t.id}" onclick="setTheme('${t.id}')">
      <div class="swatch-preview">
        <div class="swatch-bg"     style="background:${t.bg}"></div>
        <div class="swatch-bottom">
          <div class="swatch-surface" style="background:${t.surface}"></div>
          <div class="swatch-accent"  style="background:${t.accent}"></div>
        </div>
      </div>
      <div class="swatch-label">${t.name}</div>
    </div>`).join('');
}

function setTheme(id) {
  document.documentElement.setAttribute('data-theme', id);
  localStorage.setItem('wfm-theme', id);
  document.querySelectorAll('.theme-swatch').forEach(el => el.classList.remove('active'));
  const s = document.getElementById('swatch-' + id);
  if (s) s.classList.add('active');
  document.getElementById('theme-menu').classList.remove('open');
  if (typeof updateChartTheme === 'function') updateChartTheme();
}

function toggleThemePicker(e) {
  e.stopPropagation();
  document.getElementById('theme-menu').classList.toggle('open');
}

document.addEventListener('click', () => {
  document.getElementById('theme-menu')?.classList.remove('open');
});

// Human-readable explanation for a single history point, used in event logs.
function diagnose(p) {
  const ae = p.adapterErrors;
  const aeTotal = ae ? (ae.rxErrors||0)+(ae.txErrors||0)+(ae.rxDiscards||0)+(ae.txDiscards||0) : 0;

  if (p.loss) {
    if (p.connType === 'unknown')
      return 'Your network adapter reported no active link at that moment. This points to a local cable, port, or driver/power-saving issue on this PC — not your router or ISP.';
    if (p.gatewayLoss)
      return 'Your router was also unreachable. The problem is between your router and your ISP, or the router itself went down.';
    if (p.roamed)
      return 'Connection dropped during an access point switch. The handoff between access points did not complete cleanly.';
    if (aeTotal > 0)
      return 'Your Wi-Fi adapter reported errors during the drop. This points to a possible driver or hardware issue.';
    if (p.rssi != null && p.rssi < -72)
      return 'Signal was weak at the time of the drop. You may be too far from the router.';
    return 'Your router was reachable but the internet was not. This is likely a temporary ISP or WAN issue.';
  }

  if (p.spike) {
    const gwFast = !p.gatewayLoss && p.gatewayMs != null && p.gatewayMs < 20;
    if (gwFast)
      return 'Your router responded quickly but the internet was slow. Congestion is likely on the ISP side.';
    if (p.jitter != null && p.jitter > 20)
      return 'High latency with unstable jitter. This suggests local network congestion or wireless interference.';
    return 'Brief latency spike. This is likely temporary network congestion.';
  }

  if (p.roamed)
    return 'Your device switched to a different access point.';

  if (aeTotal > 0)
    return 'Your Wi-Fi adapter reported transmission errors. This may be caused by interference or a driver issue.';

  return null;
}

// Machine-readable category for a loss/spike point, for aggregation across
// many sessions (Insights widget 3: local-link vs WAN vs router breakdown).
// Mirrors diagnose()'s branching but returns a short code instead of prose.
function classify(p) {
  const ae = p.adapterErrors;
  const aeTotal = ae ? (ae.rxErrors||0)+(ae.txErrors||0)+(ae.rxDiscards||0)+(ae.txDiscards||0) : 0;

  if (p.loss) {
    if (p.connType === 'unknown') return 'local-link';
    if (p.gatewayLoss) return 'router-down';
    if (p.roamed) return 'roam';
    if (aeTotal > 0) return 'adapter-error';
    if (p.rssi != null && p.rssi < -72) return 'weak-signal';
    return 'wan-issue';
  }

  if (p.spike) {
    const gwFast = !p.gatewayLoss && p.gatewayMs != null && p.gatewayMs < 20;
    if (gwFast) return 'spike-congestion';
    if (p.jitter != null && p.jitter > 20) return 'spike-jitter';
    return 'spike-generic';
  }

  return null;
}

function statLine(vals) {
  if (!vals.length) return 'n/a';
  const sorted = [...vals].sort((a, b) => a - b);
  const avg = vals.reduce((s, v) => s + v, 0) / vals.length;
  const pct = p => sorted[Math.min(Math.floor(p * sorted.length / 100), sorted.length - 1)];
  return `avg=${avg.toFixed(1)} min=${sorted[0]} max=${sorted[sorted.length-1]} p5=${pct(5)} p95=${pct(95)}`;
}

// Builds and downloads the same WIFI_REPORT .txt format for any {current, history,
// updated, spikeMs, pingTarget} payload — used for both the live dashboard and
// archived sessions in history.html, since they share the same on-disk schema.
function downloadReportFor(data) {
  const { current: c, history: h, updated } = data;
  const ts = new Date(updated * 1000).toISOString();
  const span = h.length > 1 ? Math.round((h[h.length-1].ts - h[0].ts) / 60) + 'm' : '0m';

  const pingVals = h.filter(p => !p.loss && p.ping != null).map(p => p.ping);
  const lossCount = h.filter(p => p.loss).length;
  const spikeCount = h.filter(p => p.spike).length;
  const lossPct = h.length ? ((lossCount / h.length) * 100).toFixed(1) : '0.0';

  const gwVals    = h.filter(p => !p.gatewayLoss && p.gatewayMs != null).map(p => p.gatewayMs);
  const dnsVals   = h.filter(p => !p.dnsLoss && p.dnsMs != null).map(p => p.dnsMs);
  const jitterVals = h.filter(p => p.jitter != null).map(p => p.jitter);
  const gwLossCount   = h.filter(p => p.gatewayLoss).length;
  const dnsLossCount  = h.filter(p => p.dnsLoss).length;
  const roamCount     = h.filter(p => p.roamed).length;
  const adapterErrTotal = h.reduce((s, p) => {
    const ae = p.adapterErrors;
    return s + (ae ? (ae.rxErrors||0)+(ae.txErrors||0)+(ae.rxDiscards||0)+(ae.txDiscards||0) : 0);
  }, 0);
  const disconnectEvents = h.filter(p => p.disconnectEvent).map(p =>
    `  ${new Date(p.disconnectEvent.ts * 1000).toISOString()} ${p.disconnectEvent.reason}`
  );
  const bssidChanges = h.filter(p => p.roamed).map(p =>
    `  ${new Date(p.ts * 1000).toISOString()} -> ${(p.bssid || '?').toUpperCase()}`
  );
  const c2 = c || h[h.length - 1] || {};

  const lines = [
    `WIFI_REPORT v3`,
    `ts:${ts} connType:${c2.connType || 'unknown'}` + (c2.connType === 'wifi'
      ? ` ssid:${c2.ssid} bssid:${c2.bssid || '?'} band:${c2.band} ch:${c2.ch} radio:${c2.radio}`
      : ` linkSpeed:${c2.linkSpeed || '?'}`),
    `gateway:${c2.gateway || 'unknown'} samples:${h.length} span:${span} spike_threshold:${data.spikeMs || 150}ms ping_target:${data.pingTarget || '8.8.8.8'}`,
    ``,
    `# stats (rx/tx in Mbps, rssi in dBm, sig in %, ping/gateway/dns/jitter in ms)`,
    `rx         ${statLine(h.map(p => p.rx))}`,
    `tx         ${statLine(h.map(p => p.tx))}`,
    ...(c2.connType === 'wifi' ? [
      `rssi       ${statLine(h.map(p => p.rssi))}`,
      `sig        ${statLine(h.map(p => p.sig))}`,
    ] : []),
    `ping       ${pingVals.length ? statLine(pingVals) : 'n/a'} spikes:${spikeCount} loss:${lossCount}(${lossPct}%)`,
    `jitter     ${jitterVals.length ? statLine(jitterVals) : 'n/a'}`,
    `gateway_ms ${gwVals.length ? statLine(gwVals) : 'n/a'} loss:${gwLossCount}`,
    `dns_ms     ${dnsVals.length ? statLine(dnsVals) : 'n/a'} loss:${dnsLossCount}`,
    `roams:${roamCount} adapter_errors_total:${adapterErrTotal}`,
    ``,
    `# current`,
    `rx:${c2.rx} tx:${c2.tx} rssi:${c2.rssi} sig:${c2.sig} ping:${c2.ping ?? 'loss'} jitter:${c2.jitter ?? '?'} gw:${c2.gatewayMs ?? 'loss'} dns:${c2.dnsMs ?? 'loss'} streak:${c2.lossStreak}`,
    ``,
    bssidChanges.length ? `# ap roam events\n${bssidChanges.join('\n')}\n` : `# no ap roams`,
    disconnectEvents.length ? `# windows disconnect events\n${disconnectEvents.join('\n')}\n` : `# no windows disconnect events captured`,
    ``,
    `# history ts,rx,tx,rssi,sig,ping,pingMin,pingMax,jitter,spike,loss,gatewayMs,gatewayLoss,dnsMs,dnsLoss,lossStreak,bssid,roamed,adapterErrTotal`,
    ...h.map(p => {
      const ae = p.adapterErrors;
      const aeT = ae ? (ae.rxErrors||0)+(ae.txErrors||0)+(ae.rxDiscards||0)+(ae.txDiscards||0) : 0;
      return [
        p.ts, p.rx, p.tx, p.rssi, p.sig,
        p.ping ?? '', p.pingMin ?? '', p.pingMax ?? '', p.jitter ?? '',
        p.spike ? 1 : 0, p.loss ? 1 : 0,
        p.gatewayMs ?? '', p.gatewayLoss ? 1 : 0,
        p.dnsMs ?? '', p.dnsLoss ? 1 : 0,
        p.lossStreak ?? 0, p.bssid || '', p.roamed ? 1 : 0, aeT
      ].join(',');
    })
  ];

  const blob = new Blob([lines.join('\n')], { type: 'text/plain' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `wifi-report-${ts.slice(0,19).replace(/:/g,'-')}.txt`;
  a.click();
  URL.revokeObjectURL(a.href);
}

// Nearest traffic snapshot to a given timestamp, within an 8s tolerance
// (traffic polls every 3s so anything further away isn't a reliable match).
function nearestTrafficSnapshot(trafficHistory, ts) {
  if (!trafficHistory || !trafficHistory.length) return null;
  let best = null, bestDiff = Infinity;
  for (const snap of trafficHistory) {
    const diff = Math.abs(snap.ts - ts);
    if (diff < bestDiff) { best = snap; bestDiff = diff; }
  }
  return (best && bestDiff <= 8) ? best : null;
}
