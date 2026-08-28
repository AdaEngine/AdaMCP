import React, { useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

const tabs = ["Frame", "ECS", "Render", "Display", "Hangs", "Memory", "GPU", "Symbols"];

function App() {
  const [targets, setTargets] = useState([]);
  const [selectedTarget, setSelectedTarget] = useState(null);
  const [capabilities, setCapabilities] = useState(null);
  const [metrics, setMetrics] = useState(null);
  const [history, setHistory] = useState([]);
  const [captures, setCaptures] = useState([]);
  const [activeCapture, setActiveCapture] = useState(null);
  const [selectedCapture, setSelectedCapture] = useState(null);
  const [selectedTab, setSelectedTab] = useState("Frame");
  const [error, setError] = useState(null);
  const [status, setStatus] = useState("Discovering AdaEngine apps");

  function runAction(promise) {
    promise.catch((reason) => setError(reason.message));
  }

  async function refreshTargets() {
    const data = await api("/api/targets");
    setTargets(data.targets ?? []);
    if (data.selectedTarget) {
      setSelectedTarget(data.selectedTarget);
    } else if (data.targets?.length === 1) {
      await chooseTarget(data.targets[0].id);
    } else {
      setStatus(data.targets?.length ? "Select a target" : "No live AdaEngine app found");
    }
  }

  async function chooseTarget(id) {
    setError(null);
    const data = await api("/api/select", { method: "POST", body: { id } });
    setSelectedTarget(data.selectedTarget);
    setStatus(`Connected to ${data.selectedTarget.serverName || data.selectedTarget.processName}`);
    await Promise.all([refreshCapabilities(), refreshCaptures()]);
  }

  async function refreshCapabilities() {
    setCapabilities(await api("/api/capabilities"));
  }

  async function refreshCaptures() {
    const data = await api("/api/captures");
    setCaptures(data.captures ?? []);
  }

  async function startCapture() {
    setError(null);
    const capture = await api("/api/captures", {
      method: "POST",
      body: { preset: "frame", durationMs: 5_000, frameBudgetMs: 16.67 }
    });
    setActiveCapture(capture);
    setStatus("Recording detailed frame capture");
  }

  async function stopCapture() {
    if (!activeCapture?.id) return;
    const capture = await api(`/api/captures/${activeCapture.id}/stop`, { method: "POST" });
    setActiveCapture(null);
    setSelectedCapture(capture);
    setStatus("Capture completed");
    await refreshCaptures();
  }

  async function openCapture(id) {
    setSelectedCapture(await api(`/api/captures/${id}`));
  }

  async function deleteCapture(id) {
    await api(`/api/captures/${id}`, { method: "DELETE" });
    if (selectedCapture?.manifest?.id === id) {
      setSelectedCapture(null);
    }
    await refreshCaptures();
  }

  useEffect(() => {
    refreshTargets().catch((reason) => setError(reason.message));
  }, []);

  useEffect(() => {
    if (!selectedTarget) return undefined;
    const events = new EventSource("/api/events");
    events.addEventListener("metrics", (event) => {
      const snapshot = JSON.parse(event.data);
      setMetrics(snapshot);
      const p95 = snapshot.summary?.frameTime?.p95Ms ?? 0;
      setHistory((values) => [...values.slice(-79), p95]);
      const nextActive = snapshot.activeCapture;
      setActiveCapture((previous) => {
        if (previous && !nextActive) {
          setStatus("Capture completed");
          refreshCaptures().catch(() => {});
        }
        return nextActive;
      });
    });
    events.addEventListener("profiler-error", (event) => {
      setError(JSON.parse(event.data).error);
    });
    return () => events.close();
  }, [selectedTarget?.id]);

  const summary = metrics?.summary;
  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <Logo />
          <div>
            <span className="eyebrow">AdaEngine observability</span>
            <h1>AdaMCP Profiler</h1>
          </div>
        </div>
        <div className="topbar-actions">
          <label className="target-field" htmlFor="target-select">
            <span>Target</span>
            <select id="target-select" value={selectedTarget?.id ?? ""} onChange={(event) => runAction(chooseTarget(event.target.value))}>
              <option value="" disabled>Select a running app</option>
              {targets.map((target) => <option key={target.id} value={target.id}>{target.serverName || target.processName}</option>)}
            </select>
          </label>
          <button className={activeCapture ? "capture-button recording" : "capture-button"} onClick={() => runAction(activeCapture ? stopCapture() : startCapture())} disabled={!selectedTarget}>
            <span className="record-dot" aria-hidden="true" />
            {activeCapture ? "Stop capture" : "Record 5 seconds"}
          </button>
        </div>
      </header>

      <main>
        <section className="status-strip" aria-live="polite">
          <div><span className={selectedTarget ? "live-dot" : "idle-dot"} />{status}</div>
          <div className="mono">{selectedTarget ? `PID ${selectedTarget.pid ?? "remote"}` : "Waiting for discovery"}</div>
        </section>

        {error && <div className="error-banner" role="alert"><strong>Profiler error</strong><span>{error}</span><button onClick={() => setError(null)} aria-label="Dismiss error">×</button></div>}

        <section className="metric-grid" aria-label="Live performance overview">
          <MetricCard label="Frame p95" value={formatMs(summary?.frameTime?.p95Ms)} detail={`${summary?.budgetMissCount ?? 0} budget misses`} intent={(summary?.frameTime?.p95Ms ?? 0) > 16.67 ? "danger" : "good"} />
          <MetricCard label="Frame p50" value={formatMs(summary?.frameTime?.p50Ms)} detail={`max ${formatMs(summary?.frameTime?.maxMs)}`} />
          <MetricCard label="Frame rate" value={`${formatNumber(summary?.fps, 1)} fps`} detail={`${summary?.frameCount ?? 0} sampled frames`} intent={(summary?.fps ?? 60) < 55 ? "warning" : "good"} />
          <MetricCard label="Memory footprint" value={formatBytes(metrics?.memory?.footprintBytes ?? metrics?.memory?.residentBytes)} detail={`peak ${formatBytes(metrics?.memory?.peakFootprintBytes ?? metrics?.memory?.peakResidentBytes)}`} />
        </section>

        <section className="workspace-grid">
          <div className="primary-column">
            <section className="panel timeline-overview">
              <div className="panel-heading">
                <div><span className="eyebrow">Live frame budget</span><h2>Frame-time pressure</h2></div>
                <span className="budget-label">16.67 ms budget</span>
              </div>
              <Sparkline values={history} budget={16.67} />
            </section>

            <section className="panel detail-panel">
              <div className="tabs" role="tablist" aria-label="Profiler detail categories">
                {tabs.map((tab) => <button key={tab} role="tab" aria-selected={selectedTab === tab} onClick={() => setSelectedTab(tab)}>{tab}</button>)}
              </div>
              <DetailTab tab={selectedTab} summary={selectedCapture?.summary ?? summary} capabilities={capabilities} />
            </section>

            {selectedCapture && <PerfettoPanel capture={selectedCapture} />}
          </div>

          <aside className="side-column">
            <section className="panel">
              <div className="panel-heading"><div><span className="eyebrow">Runtime surface</span><h2>Capabilities</h2></div></div>
              <CapabilityList capabilities={capabilities?.providers} />
            </section>
            <section className="panel sessions-panel">
              <div className="panel-heading"><div><span className="eyebrow">Local artifacts</span><h2>Captures</h2></div><button className="icon-button" onClick={() => runAction(refreshCaptures())} aria-label="Refresh captures"><RefreshIcon /></button></div>
              {captures.length === 0 ? <EmptyState /> : <div className="session-list">{captures.map((capture) => <div key={capture.id} className="session-row"><button className="session-open" onClick={() => runAction(openCapture(capture.id))}><span><strong>{capture.preset}</strong><small>{formatDate(capture.startedAt)}</small></span><span className="mono">{formatMs(capture.durationMs)}</span></button><button className="session-delete" onClick={() => runAction(deleteCapture(capture.id))} aria-label={`Delete capture ${capture.id}`}>×</button></div>)}</div>}
            </section>
          </aside>
        </section>
      </main>
    </div>
  );
}

function MetricCard({ label, value, detail, intent = "neutral" }) {
  return <article className={`metric-card ${intent}`}><span>{label}</span><strong>{value}</strong><small>{detail}</small></article>;
}

function Sparkline({ values, budget }) {
  const width = 900;
  const height = 190;
  const max = Math.max(budget * 2, ...values, 1);
  const points = values.map((value, index) => `${(index / Math.max(values.length - 1, 1)) * width},${height - (value / max) * height}`).join(" ");
  const budgetY = height - (budget / max) * height;
  return <div className="chart-wrap"><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Live p95 frame duration history"><defs><linearGradient id="area" x1="0" x2="0" y1="0" y2="1"><stop offset="0%" stopColor="#38bdf8" stopOpacity=".38"/><stop offset="100%" stopColor="#38bdf8" stopOpacity="0"/></linearGradient></defs><line className="budget-line" x1="0" x2={width} y1={budgetY} y2={budgetY}/>{points && <><polygon className="chart-area" points={`0,${height} ${points} ${width},${height}`} /><polyline className="chart-line" points={points}/></>}</svg><span className="chart-axis top">{formatMs(max)}</span><span className="chart-axis bottom">0 ms</span></div>;
}

function DetailTab({ tab, summary, capabilities }) {
  if (["Hangs", "GPU", "Symbols"].includes(tab)) {
    const key = tab === "Hangs" ? "hangs" : tab === "GPU" ? "gpuCounters" : "symbolication";
    return <UnsupportedPanel title={tab} capability={capabilities?.providers?.[key]} />;
  }
  if (tab === "Memory") return <UnsupportedPanel title="Allocation stacks" capability={capabilities?.providers?.allocations} note="Live resident and peak footprint remain available above." />;
  if (tab === "ECS") return <HotspotTable title="ECS systems by total CPU work" rows={summary?.systemHotspots} />;
  if (tab === "Render") return <HotspotTable title="Render nodes by total CPU work" rows={summary?.renderNodeHotspots} />;
  if (tab === "Display") return <div className="detail-summary"><SummaryValue label="Samples" value={summary?.display?.sampleCount ?? 0}/><SummaryValue label="Interval p95" value={formatMs(summary?.display?.interval?.p95Ms)}/><SummaryValue label="Dropped" value={summary?.display?.droppedFrameCount ?? 0}/></div>;
  return <div className="detail-summary"><SummaryValue label="Critical path p95" value={formatMs(summary?.criticalPathMs)}/><SummaryValue label="Total system work" value={formatMs(summary?.totalSystemWorkMs)}/><SummaryValue label="Budget misses" value={summary?.budgetMissCount ?? 0}/></div>;
}

function HotspotTable({ title, rows = [] }) {
  return <div><h3 className="table-title">{title}</h3>{rows.length === 0 ? <p className="muted">No detailed spans captured yet.</p> : <div className="hotspot-table" role="table"><div className="table-row table-header" role="row"><span>Name</span><span>Total</span><span>p95</span><span>Max</span></div>{rows.map((row) => <div className="table-row" role="row" key={row.name}><strong title={row.name}>{row.name}</strong><span>{formatMs(row.totalMs)}</span><span>{formatMs(row.p95Ms)}</span><span>{formatMs(row.maxMs)}</span></div>)}</div>}</div>;
}

function UnsupportedPanel({ title, capability, note }) {
  return <div className="unsupported"><LockIcon/><div><h3>{title} provider is unavailable</h3><p>{capability?.provider && capability.provider !== "unavailable" ? capability.provider : "This provider is reserved for a later macOS capture increment."}</p>{note && <p>{note}</p>}</div></div>;
}

function SummaryValue({ label, value }) { return <div><span>{label}</span><strong>{value}</strong></div>; }

function CapabilityList({ capabilities = {} }) {
  return <div className="capability-list">{Object.entries(capabilities).map(([name, capability]) => <div key={name}><span><i className={capability.supported ? "cap-dot supported" : "cap-dot"}/>{humanize(name)}</span><small>{capability.provider}</small></div>)}</div>;
}

function PerfettoPanel({ capture }) {
  const iframeRef = useRef(null);
  const trace = capture.trace;
  useEffect(() => {
    if (!trace || !iframeRef.current) return undefined;
    const frame = iframeRef.current;
    const buffer = new TextEncoder().encode(JSON.stringify(trace)).buffer;
    const targetOrigin = "https://ui.perfetto.dev";
    const sendPing = () => frame.contentWindow?.postMessage("PING", targetOrigin);
    let timer;
    const handleMessage = (event) => {
      if (event.source !== frame.contentWindow || event.origin !== targetOrigin || event.data !== "PONG") {
        return;
      }
      clearInterval(timer);
      window.removeEventListener("message", handleMessage);
      frame.contentWindow?.postMessage({
        perfetto: {
          buffer,
          title: `AdaEngine ${capture.manifest?.id}`,
          fileName: `${capture.manifest?.id}.json`,
          localOnly: true,
          keepApiOpen: true
        }
      }, targetOrigin);
    };
    window.addEventListener("message", handleMessage);
    sendPing();
    timer = setInterval(sendPing, 100);
    return () => {
      clearInterval(timer);
      window.removeEventListener("message", handleMessage);
    };
  }, [capture.manifest?.id, trace]);
  return <section className="panel perfetto-panel"><div className="panel-heading"><div><span className="eyebrow">Detailed timeline</span><h2>Perfetto</h2></div><span className="local-badge">Trace stays local</span></div><iframe ref={iframeRef} title="Perfetto trace timeline" src="https://ui.perfetto.dev/#!/?mode=embedded" sandbox="allow-scripts allow-same-origin allow-downloads" /></section>;
}

function EmptyState() { return <div className="empty-state"><ArchiveIcon/><p>No captures yet</p><small>Record a bounded session to preserve a report and Perfetto trace.</small></div>; }

async function api(url, options = {}) {
  const response = await fetch(url, { ...options, headers: { "Content-Type": "application/json", ...(options.headers ?? {}) }, body: options.body ? JSON.stringify(options.body) : undefined });
  const body = response.status === 204 ? null : await response.json();
  if (!response.ok) throw new Error(body?.error ?? `Profiler request failed with HTTP ${response.status}`);
  return body;
}

const formatMs = (value) => `${formatNumber(value, 2)} ms`;
const formatNumber = (value, digits = 2) => Number(value ?? 0).toFixed(digits);
const formatBytes = (value) => value ? `${(value / 1_048_576).toFixed(1)} MB` : "0 MB";
const formatDate = (value) => value ? new Date(value).toLocaleString() : "Unknown date";
const humanize = (value) => value.replace(/([A-Z])/g, " $1").replace(/^./, (character) => character.toUpperCase());

function Logo() { return <svg className="logo" viewBox="0 0 40 40" aria-hidden="true"><path d="M7 30 18 7h5l10 23h-7l-2-5h-8l-2 5H7Zm11-11h4l-2-6-2 6Z"/><path d="M28 8h5v10h-5z"/></svg>; }
function RefreshIcon() { return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"/></svg>; }
function LockIcon() { return <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>; }
function ArchiveIcon() { return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16v13H4zM3 4h18v3H3zM9 11h6"/></svg>; }

createRoot(document.getElementById("root")).render(<React.StrictMode><App /></React.StrictMode>);
