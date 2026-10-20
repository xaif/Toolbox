import Foundation

/// The whiteboard browsers get when they open an invite link. Draws exactly like
/// `WhiteboardRenderer` and syncs through `/op` (changes out) and `/events` (changes in).
enum WhiteboardPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">
    <meta name="color-scheme" content="light dark">
    <title>Whiteboard</title>
    \#(BrandMark.faviconLinks)
    <style>
    :root { --bar:#f2f2f5; --text:#1d1d1f; --muted:#6e6e73; --line:rgba(0,0,0,.1); --accent:#0a7cff; --page:#e6e6ea; }
    @media (prefers-color-scheme: dark) { :root { --bar:#1c1c1f; --text:#f5f5f7; --muted:#9a9aa0; --line:rgba(255,255,255,.12); --accent:#3d9bff; --page:#0d0d0f; } }
    * { box-sizing:border-box; }
    html, body { margin:0; height:100%; overflow:hidden; font:15px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background:var(--page); color:var(--text); }
    body { display:flex; flex-direction:column; }
    #bar { display:flex; flex-wrap:wrap; gap:6px 10px; align-items:center; padding:8px 10px calc(8px) max(10px, env(safe-area-inset-left)); background:var(--bar); border-bottom:1px solid var(--line); }
    .group { display:flex; gap:2px; background:rgba(127,127,127,.12); border-radius:10px; padding:2px; }
    button { border:none; background:none; color:var(--text); font:inherit; min-width:36px; height:34px; border-radius:8px; cursor:pointer; padding:0 8px; }
    button.on { background:var(--accent); color:#fff; }
    button:disabled { opacity:.35; }
    .swatch { width:24px; min-width:24px; height:24px; border-radius:50%; padding:0; border:2px solid rgba(127,127,127,.35); margin:5px 2px; }
    .swatch.on { outline:2px solid var(--accent); outline-offset:2px; }
    #people { margin-left:auto; color:var(--muted); font-size:14px; white-space:nowrap; }
    #stage { flex:1; position:relative; display:flex; align-items:center; justify-content:center; padding:10px; touch-action:none; }
    #board { position:relative; box-shadow:0 1px 6px rgba(0,0,0,.18); border-radius:8px; overflow:hidden; }
    #board canvas { position:absolute; inset:0; width:100%; height:100%; touch-action:none; }
    #banner { display:none; position:absolute; top:16px; left:50%; transform:translateX(-50%); background:#fff3cd; color:#5c4400; padding:10px 14px; border-radius:10px; font-size:14px; z-index:2; }
    </style>
    </head>
    <body>
    <div id="bar">
      <div class="group" id="tools"></div>
      <div class="group" id="colors"></div>
      <div class="group" id="sizes"></div>
      <div class="group"><button id="undo" title="Undo" disabled>↶</button></div>
      <span id="people">Connecting…</span>
    </div>
    <div id="stage">
      <div id="banner">Disconnected. Trying to reconnect…</div>
      <div id="board"><canvas id="bg"></canvas><canvas id="ink"></canvas></div>
    </div>
    <script>
    const ASPECT = 1.6;
    const me = "web-" + Math.random().toString(36).slice(2, 10);
    const tools = [["pen","✏️","Pen"],["highlighter","🖍️","Highlighter"],["eraser","🧽","Eraser"],["line","╱","Line"],["rectangle","▭","Rectangle"],["ellipse","◯","Ellipse"],["arrow","➝","Arrow"],["text","T","Text"]];
    const colors = ["#1E1E1E","#E03131","#F08C00","#2F9E44","#1971C2","#7048E8","#FFFFFF"];
    const widths = [0.0025, 0.005, 0.0125], textSizes = [0.015, 0.025, 0.04];
    let tool = "pen", color = colors[0], sizeIndex = 1;
    let elements = [], index = new Map(), background = "white", mine = [], counter = 0;
    const $ = id => document.getElementById(id);
    const bg = $("bg"), ink = $("ink"), board = $("board");
    let W = 0, H = 0, dpr = 1, dirty = true, scheduled = false;

    function button(parent, label, title, onClick) { const b = document.createElement("button"); b.textContent = label; b.title = title; b.onclick = onClick; parent.append(b); return b; }
    const toolButtons = tools.map(([id, label, title]) => button($("tools"), label, title, () => { tool = id; refreshBar(); }));
    const colorButtons = colors.map(c => { const b = button($("colors"), "", c, () => { color = c; refreshBar(); }); b.className = "swatch"; b.style.background = c; return b; });
    const sizeButtons = ["S","M","L"].map((label, i) => button($("sizes"), label, "Size " + label, () => { sizeIndex = i; refreshBar(); }));
    function refreshBar() {
      toolButtons.forEach((b, i) => b.className = tools[i][0] === tool ? "on" : "");
      colorButtons.forEach((b, i) => b.className = "swatch" + (colors[i] === color ? " on" : ""));
      sizeButtons.forEach((b, i) => b.className = i === sizeIndex ? "on" : "");
      $("undo").disabled = mine.length === 0;
    }
    refreshBar();

    function layout() {
      const stage = $("stage").getBoundingClientRect();
      const maxW = stage.width - 20, maxH = stage.height - 20;
      W = Math.max(50, Math.min(maxW, maxH * ASPECT)); H = W / ASPECT;
      board.style.width = W + "px"; board.style.height = H + "px";
      dpr = window.devicePixelRatio || 1;
      for (const c of [bg, ink]) { c.width = Math.round(W * dpr); c.height = Math.round(H * dpr); }
      invalidate();
    }
    new ResizeObserver(layout).observe($("stage"));
    layout();

    function strokeWidth(kind) { return widths[sizeIndex] * (kind === "highlighter" ? 3 : kind === "eraser" ? 4 : 1); }
    function pts(e) { const out = []; for (let i = 0; i + 1 < e.p.length; i += 2) out.push([e.p[i] * W, e.p[i + 1] * H]); return out; }
    function drawBackground() {
      const g = bg.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.fillStyle = background === "dark" ? "rgb(31,31,33)" : "#fff"; g.fillRect(0, 0, W, H);
      if (background === "grid") {
        const step = W / 32; g.strokeStyle = "rgba(51,102,204,0.13)"; g.lineWidth = Math.max(W / 1600, 0.5); g.beginPath();
        for (let x = step; x < W; x += step) { g.moveTo(x, 0); g.lineTo(x, H); }
        for (let y = step; y < H; y += step) { g.moveTo(0, y); g.lineTo(W, y); }
        g.stroke();
      }
    }
    function drawElement(g, e) {
      const p = pts(e); if (p.length === 0) return;
      const width = Math.max(e.w * W, 0.5);
      g.save(); g.strokeStyle = e.c; g.fillStyle = e.c; g.lineWidth = width; g.lineCap = "round"; g.lineJoin = "round";
      if (e.k === "pen" || e.k === "highlighter" || e.k === "eraser") {
        if (e.k === "highlighter") g.globalAlpha = 0.35;
        if (e.k === "eraser") g.globalCompositeOperation = "destination-out";
        g.beginPath(); g.moveTo(p[0][0], p[0][1]);
        if (p.length === 1) g.lineTo(p[0][0] + 0.01, p[0][1]);
        for (let i = 1; i < p.length; i++) { const a = p[i - 1], b = p[i]; g.quadraticCurveTo(a[0], a[1], (a[0] + b[0]) / 2, (a[1] + b[1]) / 2); }
        if (p.length > 1) g.lineTo(p[p.length - 1][0], p[p.length - 1][1]);
        g.stroke();
      } else if (e.k === "line" || e.k === "arrow") {
        const a = p[0], b = p[p.length - 1];
        g.beginPath(); g.moveTo(a[0], a[1]); g.lineTo(b[0], b[1]);
        if (e.k === "arrow") {
          const angle = Math.atan2(b[1] - a[1], b[0] - a[0]), head = Math.max(width * 4, W / 80);
          for (const side of [-0.45, 0.45]) { g.moveTo(b[0], b[1]); g.lineTo(b[0] - head * Math.cos(angle + side), b[1] - head * Math.sin(angle + side)); }
        }
        g.stroke();
      } else if (e.k === "rectangle" || e.k === "ellipse") {
        const a = p[0], b = p[p.length - 1], x = Math.min(a[0], b[0]), y = Math.min(a[1], b[1]), w = Math.abs(b[0] - a[0]), h = Math.abs(b[1] - a[1]);
        g.beginPath();
        if (e.k === "rectangle") g.rect(x, y, w, h); else g.ellipse(x + w / 2, y + h / 2, w / 2, h / 2, 0, 0, Math.PI * 2);
        g.stroke();
      } else if (e.k === "text") {
        g.font = "500 " + Math.max(width, 4) + "px -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif";
        g.textBaseline = "top";
        (e.t || "").split("\n").forEach((line, i) => g.fillText(line, p[0][0], p[0][1] + i * Math.max(width, 4) * 1.2));
      }
      g.restore();
    }
    function render() {
      scheduled = false;
      if (!dirty) return;
      dirty = false; drawBackground();
      const g = ink.getContext("2d"); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.clearRect(0, 0, W, H);
      for (const e of elements) drawElement(g, e);
    }
    // Animation frames pause in background tabs, so a timer backs them up.
    function invalidate() {
      dirty = true;
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(render); setTimeout(render, 100);
    }

    function insert(e) { if (index.has(e.id)) { elements[index.get(e.id)] = e; } else { index.set(e.id, elements.length); elements.push(e); } invalidate(); }
    function remove(ids) { const set = new Set(ids); elements = elements.filter(e => !set.has(e.id)); index = new Map(elements.map((e, i) => [e.id, i])); invalidate(); }
    function apply(op) {
      if (op.op === "add" && op.e) insert(op.e);
      else if (op.op === "append" && index.has(op.id)) { elements[index.get(op.id)].p.push(...op.p); invalidate(); }
      else if (op.op === "set" && index.has(op.id)) { elements[index.get(op.id)].p = op.p; invalidate(); }
      else if (op.op === "remove") remove(op.ids || []);
      else if (op.op === "clear") { elements = []; index = new Map(); mine = []; refreshBar(); invalidate(); }
      else if (op.op === "bg" && op.b) { background = op.b; invalidate(); }
    }

    // Changes go out one request at a time, in order; queued appends to the same mark are merged.
    const outbox = []; let sending = false;
    function post(op) {
      op.from = me;
      const last = outbox[outbox.length - 1];
      if (op.op === "append" && last && last.op === "append" && last.id === op.id) last.p.push(...op.p);
      else if (op.op === "set" && last && last.op === "set" && last.id === op.id) last.p = op.p;
      else outbox.push(op);
      pump();
    }
    function pump() {
      if (sending || outbox.length === 0) return;
      sending = true;
      const op = outbox.shift();
      fetch("op", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(op) })
        .catch(() => {}).finally(() => { sending = false; pump(); });
    }

    const round = v => Math.round(v * 10000) / 10000;
    function point(ev) { const r = ink.getBoundingClientRect(); return [round((ev.clientX - r.left) / r.width), round((ev.clientY - r.top) / r.height)]; }
    let active = null, start = null, pending = [], lastSend = 0;
    ink.addEventListener("pointerdown", ev => {
      ev.preventDefault();
      const p = point(ev);
      if (tool === "text") {
        const text = window.prompt("Text");
        if (!text) return;
        const e = { id: me + "-" + (++counter), k: "text", c: color, w: textSizes[sizeIndex], p: p, t: text };
        insert(e); post({ op: "add", e: JSON.parse(JSON.stringify(e)) }); mine.push(e.id); refreshBar();
        return;
      }
      ink.setPointerCapture(ev.pointerId);
      const shape = ["line","rectangle","ellipse","arrow"].includes(tool);
      active = { id: me + "-" + (++counter), k: tool, c: color, w: strokeWidth(tool), p: shape ? [...p, ...p] : [...p] };
      start = p; insert(active); post({ op: "add", e: JSON.parse(JSON.stringify(active)) });
    });
    ink.addEventListener("pointermove", ev => {
      if (!active) return;
      const coalesced = ev.getCoalescedEvents ? ev.getCoalescedEvents() : [];
      const events = coalesced.length ? coalesced : [ev];
      if (["line","rectangle","ellipse","arrow"].includes(active.k)) {
        active.p = [...start, ...point(ev)]; invalidate();
        if (Date.now() - lastSend > 40) { lastSend = Date.now(); post({ op: "set", id: active.id, p: active.p.slice() }); }
        return;
      }
      for (const e of events) {
        const p = point(e), n = active.p.length;
        if (Math.hypot(p[0] - active.p[n - 2], p[1] - active.p[n - 1]) < 0.0008) continue;
        active.p.push(...p); pending.push(...p);
      }
      invalidate();
      if (pending.length && Date.now() - lastSend > 40) { lastSend = Date.now(); post({ op: "append", id: active.id, p: pending }); pending = []; }
    });
    function finish() {
      if (!active) return;
      if (pending.length) post({ op: "append", id: active.id, p: pending });
      if (["line","rectangle","ellipse","arrow"].includes(active.k)) post({ op: "set", id: active.id, p: active.p.slice() });
      pending = []; mine.push(active.id); active = null; refreshBar();
    }
    ink.addEventListener("pointerup", finish);
    ink.addEventListener("pointercancel", finish);
    $("undo").onclick = () => {
      while (mine.length && !index.has(mine[mine.length - 1])) mine.pop();
      const id = mine.pop(); refreshBar();
      if (!id) return;
      remove([id]); post({ op: "remove", ids: [id] });
    };

    const events = new EventSource("events");
    events.addEventListener("snapshot", ev => {
      const s = JSON.parse(ev.data);
      elements = s.elements; index = new Map(elements.map((e, i) => [e.id, i])); background = s.background;
      document.title = "Whiteboard · " + s.host; setPeople(s.people); invalidate();
      $("banner").style.display = "none";
    });
    events.addEventListener("op", ev => { const op = JSON.parse(ev.data); if (op.from !== me) apply(op); });
    events.addEventListener("people", ev => setPeople(parseInt(ev.data, 10)));
    events.onerror = () => { $("banner").style.display = "block"; $("people").textContent = "Offline"; };
    function setPeople(n) { $("people").textContent = n === 1 ? "Just you" : n + " people here"; }
    </script>
    </body>
    </html>
    """#
}
