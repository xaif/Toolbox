import Foundation

/// The remote phones get when they open the link. Sends `/command` and follows `/events`.
/// Turn the dial to scroll, tap its middle to play or pause, swipe sideways for the next or previous cue.
enum TeleprompterRemotePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="theme-color" content="#000000">
    <title>Teleprompter Remote</title>
    <style>
    :root { --bg:#000; --card:#1c1c1e; --line:rgba(255,255,255,.12); --text:#f5f5f7; --muted:#98989f; --accent:#30d158; --warn:#ff9f0a; }
    * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
    html, body { margin:0; background:var(--bg); color:var(--text); font:16px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { padding:max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) max(24px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left)); user-select:none; -webkit-user-select:none; }
    header { margin-bottom:18px; }
    #title { font-size:20px; font-weight:700; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    #status { display:flex; align-items:center; gap:8px; color:var(--muted); font-size:14px; margin-top:4px; }
    #dot { width:9px; height:9px; border-radius:50%; background:#555; flex:none; }
    #left { margin-left:auto; font-variant-numeric:tabular-nums; }
    #bar { height:4px; border-radius:2px; background:var(--line); margin-top:12px; overflow:hidden; }
    #fill { height:100%; width:0; background:var(--text); transition:width .25s linear; }
    #dial { position:relative; width:min(74vw, 320px); aspect-ratio:1; margin:8px auto 6px; border-radius:50%; background:radial-gradient(circle at 50% 35%, #2c2c2e, #111 70%); border:1px solid var(--line); touch-action:none; }
    #ring { position:absolute; inset:0; border-radius:50%; }
    #tick { position:absolute; top:7%; left:50%; width:10px; height:10px; margin-left:-5px; border-radius:50%; background:var(--muted); }
    #play { position:absolute; inset:30%; border-radius:50%; border:none; background:var(--text); color:#000; font-size:34px; display:flex; align-items:center; justify-content:center; }
    #play.closed { font-size:17px; font-weight:600; }
    .hint { text-align:center; color:var(--muted); font-size:13px; margin:6px 0 18px; }
    .row { display:flex; gap:10px; margin-bottom:10px; align-items:center; }
    .row button { flex:1; }
    button { font:inherit; color:var(--text); background:var(--card); border:1px solid var(--line); border-radius:14px; min-height:50px; padding:0 12px; }
    button:active { opacity:.6; }
    button:disabled { opacity:.35; }
    #wpm { flex:1.2; text-align:center; font-weight:600; font-variant-numeric:tabular-nums; }
    h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:22px 4px 8px; }
    #cues { list-style:none; margin:0; padding:0; background:var(--card); border-radius:14px; overflow:hidden; border:1px solid var(--line); }
    #cues li { padding:14px 16px; border-top:1px solid var(--line); display:flex; gap:12px; }
    #cues li:first-child { border-top:none; }
    #cues li .n { color:var(--muted); font-variant-numeric:tabular-nums; min-width:1.5em; }
    #cues li.on { background:rgba(48,209,88,.16); }
    #cues li.on .n { color:var(--accent); }
    #nocues { color:var(--muted); padding:14px 16px; }
    #banner { display:none; position:fixed; left:16px; right:16px; bottom:max(16px, env(safe-area-inset-bottom)); background:#3a2a00; color:#ffd66b; padding:12px 14px; border-radius:12px; font-size:14px; text-align:center; }
    </style>
    </head>
    <body>
    <header>
      <div id="title">Teleprompter</div>
      <div id="status"><span id="dot"></span><span id="state">Connecting…</span><span id="left"></span></div>
      <div id="bar"><div id="fill"></div></div>
    </header>
    <div id="dial"><div id="ring"><div id="tick"></div></div><button id="play" aria-label="Play or pause">▶</button></div>
    <p class="hint">Turn the ring to scroll · Tap the middle to play or pause<br>Swipe left or right for the next or previous cue</p>
    <div class="row"><button id="slower" aria-label="Slower">−</button><div id="wpm">– wpm</div><button id="faster" aria-label="Faster">+</button></div>
    <div class="row"><button id="previous">⏮ Cue</button><button id="back" disabled>↩ Back</button><button id="next">Cue ⏭</button></div>
    <div class="row"><button id="restart">Start Over</button><button id="close">Close Prompter</button></div>
    <h2>Cues</h2>
    <ol id="cues"></ol>
    <div id="banner">Disconnected. Trying to reconnect…</div>
    <script>
    const $ = id => document.getElementById(id);
    const LINES_PER_TURN = 10;
    let state = null, cuesKey = "";

    function send(action, extra) {
      fetch("command", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(Object.assign({ action }, extra || {})) }).catch(() => {});
    }
    function tap(id, action) { $(id).addEventListener("click", () => { if (navigator.vibrate) navigator.vibrate(8); send(action); }); }
    tap("slower", "slower"); tap("faster", "faster"); tap("previous", "previous"); tap("next", "next");
    tap("back", "back"); tap("restart", "restart"); tap("close", "hide");
    $("play").addEventListener("click", () => { if (navigator.vibrate) navigator.vibrate(10); send(state && !state.showing ? "show" : "toggle"); });

    function render(s) {
      state = s;
      $("title").textContent = s.title || "Teleprompter";
      let text, color = "#555";
      if (!s.showing) text = "Prompter closed";
      else if (s.countdown) { text = "Starting in " + s.countdown; color = "var(--warn)"; }
      else if (s.finished) text = "The end";
      else if (!s.playing) { text = "Paused"; color = "var(--warn)"; }
      else if (s.moving) { text = "Scrolling"; color = "var(--accent)"; }
      else if (s.listening && !s.speaking) { text = "Waiting for your voice"; color = "var(--accent)"; }
      else { text = "Paused while you hover"; color = "var(--warn)"; }
      $("state").textContent = text;
      $("dot").style.background = color;
      const m = Math.floor(s.secondsLeft / 60), sec = s.secondsLeft % 60;
      $("left").textContent = s.showing ? m + ":" + String(sec).padStart(2, "0") + " left" : "";
      $("fill").style.width = (s.progress * 100) + "%";
      const play = $("play");
      play.className = s.showing ? "" : "closed";
      play.textContent = !s.showing ? "Show" : s.playing ? "❚❚" : "▶";
      $("wpm").textContent = s.wpm + " wpm";
      $("back").disabled = !s.canGoBack;
      for (const id of ["previous", "next", "restart", "close", "slower", "faster"]) $(id).disabled = !s.showing;
      const key = s.cues.join("\n");
      if (key !== cuesKey) {
        cuesKey = key;
        const list = $("cues");
        list.innerHTML = "";
        if (!s.cues.length) { const li = document.createElement("li"); li.id = "nocues"; li.textContent = s.showing ? "Start a line with # in your script to add cues." : "Show the prompter to see its cues."; list.append(li); }
        s.cues.forEach((title, i) => {
          const li = document.createElement("li");
          const n = document.createElement("span"); n.className = "n"; n.textContent = i + 1;
          const t = document.createElement("span"); t.textContent = title;
          li.append(n, t);
          li.addEventListener("click", () => { if (navigator.vibrate) navigator.vibrate(8); send("cue", { index: i }); });
          list.append(li);
        });
      }
      [...$("cues").children].forEach((li, i) => li.classList.toggle("on", s.showing && i === s.cue && s.cues.length > 1));
    }

    // The dial: turning it clockwise scrolls forward.
    const dial = $("dial");
    let lastAngle = null, rotation = 0, pending = 0, timer = null, travelled = 0;
    function angleOf(e) {
      const r = dial.getBoundingClientRect();
      return Math.atan2(e.clientY - (r.top + r.height / 2), e.clientX - (r.left + r.width / 2));
    }
    function flush() {
      timer = null;
      if (Math.abs(pending) < 0.02) return;
      send("scroll", { lines: Math.round(pending * 100) / 100 });
      pending = 0;
    }
    dial.addEventListener("pointerdown", e => {
      if (e.target === $("play")) return;
      dial.setPointerCapture(e.pointerId);
      lastAngle = angleOf(e); travelled = 0;
    });
    dial.addEventListener("pointermove", e => {
      if (lastAngle === null) return;
      const angle = angleOf(e);
      let d = angle - lastAngle;
      if (d > Math.PI) d -= 2 * Math.PI;
      if (d < -Math.PI) d += 2 * Math.PI;
      lastAngle = angle; rotation += d;
      const before = Math.floor(travelled);
      travelled += Math.abs(d) / (2 * Math.PI) * LINES_PER_TURN;
      if (Math.floor(travelled) !== before && navigator.vibrate) navigator.vibrate(4);
      pending += d / (2 * Math.PI) * LINES_PER_TURN;
      $("ring").style.transform = "rotate(" + rotation + "rad)";
      if (!timer) timer = setTimeout(flush, 60);
    });
    const end = () => { lastAngle = null; flush(); };
    dial.addEventListener("pointerup", end);
    dial.addEventListener("pointercancel", end);

    // Sideways swipes outside the dial move between cues.
    let swipe = null;
    document.addEventListener("touchstart", e => {
      if (dial.contains(e.target) || e.touches.length !== 1) { swipe = null; return; }
      swipe = { x: e.touches[0].clientX, y: e.touches[0].clientY };
    }, { passive: true });
    document.addEventListener("touchend", e => {
      if (!swipe || !state || !state.showing) return;
      const t = e.changedTouches[0], dx = t.clientX - swipe.x, dy = t.clientY - swipe.y;
      swipe = null;
      if (Math.abs(dx) > 70 && Math.abs(dy) < 45) { if (navigator.vibrate) navigator.vibrate(10); send(dx < 0 ? "next" : "previous"); }
    }, { passive: true });

    function connect() {
      const events = new EventSource("events");
      events.addEventListener("state", e => { $("banner").style.display = "none"; render(JSON.parse(e.data)); });
      events.onopen = () => { $("banner").style.display = "none"; };
      events.onerror = () => { $("banner").style.display = "block"; };
    }
    connect();
    </script>
    </body>
    </html>
    """#
}
