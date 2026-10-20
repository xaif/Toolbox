import Foundation

/// The page browsers get from Share on Wi-Fi. Self-contained, works on phones, and stays live
/// through an event stream. URLs are relative to the tokened folder the page is served from.
enum WiFiSharePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="color-scheme" content="light dark">
    <title>Shared from a Mac</title>
    <style>
    :root { --bg:#f5f5f7; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:rgba(0,0,0,.08); --accent:#0a7cff; --ok:#1f9d55; --bad:#d93025; }
    @media (prefers-color-scheme: dark) { :root { --bg:#111113; --card:#1c1c1f; --text:#f5f5f7; --muted:#9a9aa0; --line:rgba(255,255,255,.1); --accent:#3d9bff; } }
    * { box-sizing: border-box; }
    body { margin:0; font:16px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background:var(--bg); color:var(--text); }
    main { max-width:720px; margin:0 auto; padding:24px 16px calc(32px + env(safe-area-inset-bottom)); }
    header { display:flex; gap:14px; align-items:center; margin-bottom:20px; }
    .logo { width:48px; height:48px; border-radius:12px; background:linear-gradient(135deg,#3aa0ff,#0a6cff); display:grid; place-items:center; color:#fff; font-size:24px; flex:none; }
    h1 { font-size:22px; margin:0; }
    h2 { font-size:15px; margin:0; color:var(--muted); font-weight:600; text-transform:uppercase; letter-spacing:.04em; }
    .status { font-size:14px; color:var(--muted); display:flex; align-items:center; gap:6px; }
    .dot { width:8px; height:8px; border-radius:50%; background:var(--ok); }
    .dot.off { background:var(--bad); }
    section { background:var(--card); border-radius:16px; padding:16px; margin-bottom:16px; box-shadow:0 1px 2px var(--line); }
    .row { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:8px; }
    ul { list-style:none; margin:0; padding:0; }
    li { display:flex; align-items:center; gap:12px; padding:10px 0; border-top:1px solid var(--line); }
    li:first-child { border-top:none; }
    .icon { font-size:26px; width:34px; text-align:center; flex:none; }
    .meta { flex:1; min-width:0; }
    .name { display:block; color:var(--text); text-decoration:none; font-weight:500; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .sub { font-size:13px; color:var(--muted); }
    .button { display:inline-block; border:none; border-radius:999px; background:var(--accent); color:#fff; font:600 15px/1 inherit; padding:10px 16px; text-decoration:none; cursor:pointer; white-space:nowrap; }
    .button.small { padding:8px 14px; font-size:14px; }
    .muted { color:var(--muted); margin:8px 0 0; }
    .drop { display:flex; flex-direction:column; align-items:center; gap:4px; border:2px dashed var(--line); border-radius:14px; padding:26px 12px; margin-top:10px; cursor:pointer; text-align:center; }
    .drop.over { border-color:var(--accent); background:rgba(10,124,255,.06); }
    .drop input { display:none; }
    .drop strong { color:var(--accent); font-size:17px; }
    .drop span { color:var(--muted); font-size:14px; }
    progress { width:100%; height:6px; margin-top:6px; accent-color:var(--accent); }
    .done { color:var(--ok); font-size:14px; font-weight:600; }
    .failed { color:var(--bad); font-size:14px; }
    .banner { display:none; background:#fff3cd; color:#5c4400; border-radius:12px; padding:12px 14px; margin-bottom:16px; }
    footer { text-align:center; font-size:13px; color:var(--muted); margin-top:24px; }
    </style>
    </head>
    <body>
    <main>
      <header>
        <div class="logo">⇄</div>
        <div>
          <h1 id="title">Shared from a Mac</h1>
          <div class="status"><span id="dot" class="dot"></span><span id="status">Connected</span></div>
        </div>
      </header>
      <div id="banner" class="banner">The Mac stopped sharing. Ask for a new link to continue.</div>
      <section id="shared">
        <div class="row"><h2>Shared with you</h2><a id="zip" class="button small" href="all.zip" download>Download all</a></div>
        <ul id="files"></ul>
        <p id="empty" class="muted">Nothing is shared right now.</p>
      </section>
      <section id="upload" hidden>
        <h2>Send to this Mac</h2>
        <label id="drop" class="drop">
          <input id="picker" type="file" multiple>
          <strong>Choose files</strong>
          <span>or drop them here</span>
        </label>
        <ul id="uploads"></ul>
      </section>
      <footer>Sent directly over your local network. Nothing is uploaded to the internet.</footer>
    </main>
    <script>
    const $ = id => document.getElementById(id);
    const icons = { image:"🖼️", video:"🎬", audio:"🎵", pdf:"📄", archive:"🗜️", text:"📝" };
    function size(n) {
      const units = ["bytes","KB","MB","GB","TB"]; let i = 0;
      while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
      return (i === 0 ? n : n.toFixed(n < 10 ? 1 : 0)) + " " + units[i];
    }
    function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
    function render(state) {
      $("title").textContent = "Shared from " + state.host;
      document.title = $("title").textContent;
      const list = $("files"); list.replaceChildren();
      let total = 0;
      for (const f of state.files) {
        total += f.size;
        const li = el("li");
        li.append(el("span", "icon", icons[f.kind] || "📁"));
        const meta = el("div", "meta");
        const link = el("a", "name", f.name); link.href = "files/" + f.id + "/" + encodeURIComponent(f.name) + "?inline=1"; link.target = "_blank";
        meta.append(link, el("div", "sub", size(f.size)));
        const get = el("a", "button small", "Download"); get.href = "files/" + f.id + "/" + encodeURIComponent(f.name); get.download = f.name;
        li.append(meta, get);
        list.append(li);
      }
      $("empty").hidden = state.files.length > 0;
      $("zip").hidden = state.files.length < 2;
      $("zip").textContent = "Download all · " + size(total);
      $("upload").hidden = !state.uploads;
    }
    function setOnline(online) {
      $("dot").className = online ? "dot" : "dot off";
      $("status").textContent = online ? "Connected" : "Reconnecting…";
    }
    fetch("api/files").then(r => r.json()).then(render).catch(() => {});
    let failures = 0;
    const events = new EventSource("events");
    events.addEventListener("files", e => { failures = 0; setOnline(true); render(JSON.parse(e.data)); });
    events.onopen = () => { failures = 0; setOnline(true); $("banner").style.display = "none"; };
    events.onerror = () => {
      setOnline(false);
      if (++failures > 3) { $("banner").style.display = "block"; }
    };

    const queue = []; let busy = false;
    function enqueue(files) { for (const f of files) queue.push(f); next(); }
    function next() {
      if (busy || queue.length === 0) return;
      busy = true;
      const file = queue.shift();
      const li = el("li");
      li.append(el("span", "icon", "⬆️"));
      const meta = el("div", "meta");
      const bar = el("progress"); bar.max = 1; bar.value = 0;
      const sub = el("div", "sub", size(file.size));
      meta.append(el("span", "name", file.name), sub, bar);
      li.append(meta);
      $("uploads").prepend(li);
      const xhr = new XMLHttpRequest();
      xhr.open("PUT", "upload?name=" + encodeURIComponent(file.name));
      xhr.upload.onprogress = e => { if (e.lengthComputable) bar.value = e.loaded / e.total; };
      xhr.onload = () => {
        bar.remove();
        if (xhr.status === 200) { sub.className = "done"; sub.textContent = "Sent to the Mac ✓"; }
        else { sub.className = "failed"; sub.textContent = xhr.responseText || ("Failed (" + xhr.status + ")"); }
        busy = false; next();
      };
      xhr.onerror = () => { bar.remove(); sub.className = "failed"; sub.textContent = "Couldn't send. Check the connection."; busy = false; next(); };
      xhr.send(file);
    }
    $("picker").addEventListener("change", e => { enqueue(e.target.files); e.target.value = ""; });
    const drop = $("drop");
    ["dragenter","dragover"].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.add("over"); }));
    ["dragleave","drop"].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.remove("over"); }));
    drop.addEventListener("drop", e => enqueue(e.dataTransfer.files));
    </script>
    </body>
    </html>
    """#
}
