// ------------------------------------------------------------------ reading area
// Markdown and text files open on the board itself, in a reading area docked on the right: one
// tab per file, kept until you close it (✕ or a middle click), across reloads. The board moves
// over to make room — the drawer, the conversation windows and dialogs sit to its left — so a
// document reads beside the chat that named it. Narrow it by dragging its left edge; ⟩ tucks it
// into a tab at the window's edge without closing anything.
//
// Every local link to a .md / .markdown / .txt file comes here: in conversations, on cards, the
// task card, PROJECT.md, the secretary's memory and reports. A link inside a document opens in
// the same tab (← → go back and forth); ⌘-click opens a new tab. Other files and web links open as
// before. The file is read again when its tab is shown and every few seconds while it is, so an
// edit made elsewhere shows up; "Open in editor" hands the file to its app for editing.
//
// Markdown is rendered by markdown-it (vendor/markdown-it.min.js, MIT). Raw HTML in a file is never
// put on the page: the html_block / html_inline renderers below escape it (an HTML comment shows
// as a quiet note), and images show as links. Fenced blocks go through the board's own templates
// (markdown()), so a ```diff in a document reads like one in a chat.

const RD_KEY = "hq-reader";
const RD_POLL_MS = 3000;
const RD_MIN_W = 360;
// The width starts at a bit under half the window; dragging the edge sets it for good.
const rd = { tabs: [], active: -1, collapsed: false, width: Math.round(Math.min(640, window.innerWidth * 0.45)) };
// A tab: { path, back: [], fwd: [], doc: {text, mtime, size} | null, err, scroll }.

const rdIsDoc = (p) => /\.(md|markdown|mdown|mkd|txt|text)(?::\d+(?::\d+)?)?$/i.test(String(p || "").replace(/[#?].*$/, ""));
const rdName = (p) => String(p).split("/").pop() || p;
const rdDir = (p) => String(p).replace(/\/[^/]*$/, "") || "/";
const rdCur = () => rd.tabs[rd.active] || null;

function rdSave() {
  savePref(RD_KEY, JSON.stringify({
    tabs: rd.tabs.map((t) => ({ path: t.path, back: t.back.slice(-20), fwd: t.fwd.slice(0, 20) })),
    active: rd.active, collapsed: rd.collapsed, width: rd.width,
  }));
}
function rdLoad() {
  try {
    const s = JSON.parse(pref(RD_KEY, "{}"));
    rd.tabs = (s.tabs || []).filter((t) => t && t.path).map((t) => ({ path: t.path, back: t.back || [], fwd: t.fwd || [], doc: null, err: "", scroll: 0 }));
    rd.active = Math.min(Math.max(0, s.active | 0), rd.tabs.length - 1);
    rd.collapsed = Boolean(s.collapsed);
    if (s.width) rd.width = s.width;
  } catch (e) { /* nothing kept */ }
}

// ---- markdown-it, made safe and wired to the board's links
let rdMd = null;
function rdMarkdown() {
  if (rdMd || !window.markdownit) return rdMd;
  const md = window.markdownit({ html: true, linkify: true, breaks: false, typographer: false });
  // html: true only so a comment or tag is a token of its own: it is escaped here, never kept.
  md.renderer.rules.html_block = (tokens, i) => {
    const c = tokens[i].content;
    const m = /^\s*<!--([\s\S]*?)-->\s*$/.exec(c);
    // A comment's lines lose the indent they had in the source.
    const note = m ? m[1].split("\n").map((l) => l.trim()).join("\n").trim() : "";
    return m ? (note ? `<div class="rd-cmt">${esc(note)}</div>` : "") : `<p class="rd-raw">${esc(c)}</p>`;
  };
  md.renderer.rules.html_inline = (tokens, i) => {
    const c = tokens[i].content;
    return /^<!--/.test(c) ? `<span class="rd-cmt">${esc(c.replace(/^<!--|-->$/g, "").trim())}</span>` : esc(c);
  };
  md.renderer.rules.link_open = (tokens, i, opts, env) => {
    const href = tokens[i].attrGet("href") || "";
    if (/^(https?:|mailto:)/i.test(href)) return `<a href="#" data-action="link" data-url="${esc(href)}" title="${esc(href)}">`;
    if (href.startsWith("#")) return `<a href="#" data-action="rd-anchor" data-id="${esc(rdSlug(decodeURIComponent(href.slice(1))))}">`;
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) return `<a class="rd-dead" title="${esc(href)}">`;
    return `<a href="#" class="path" data-action="link" data-path="${esc(rdJoin(env.dir, href))}" title="${esc(href)}">`;
  };
  md.renderer.rules.image = (tokens, i, opts, env) => {
    const t = tokens[i], src = t.attrGet("src") || "", alt = t.content || rdName(src);
    return /^https?:/i.test(src)
      ? `<a href="#" class="rd-img" data-action="link" data-url="${esc(src)}">🖼 ${esc(alt)}</a>`
      : `<a href="#" class="rd-img path" data-action="link" data-path="${esc(rdJoin(env.dir, src))}">🖼 ${esc(alt)}</a>`;
  };
  // Code blocks through the board's own renderer: templates (```diff, ```draft) and clickable URLs.
  md.renderer.rules.fence = (tokens, i, opts, env) => {
    const t = tokens[i], info = (t.info || "").trim().split(/\s+/)[0];
    if (/^```/m.test(t.content)) return `<pre><code>${linkifyCode(t.content.replace(/\n$/, ""))}</code></pre>`;
    return markdown("```" + info + "\n" + t.content + "```", `rd|${env.path}`);
  };
  md.renderer.rules.code_block = (tokens, i) => `<pre><code>${linkifyCode(tokens[i].content.replace(/\n$/, ""))}</code></pre>`;
  md.renderer.rules.heading_open = (tokens, i) => {
    const inl = tokens[i + 1];
    return `<${tokens[i].tag} id="rd-h-${esc(rdSlug(inl ? inl.content : ""))}">`;
  };
  rdMd = md;
  return md;
}
const rdSlug = (s) => String(s).toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/\s+/g, "-");
// A link in a document, made a path: relative to the document's folder, `#…` and `?…` dropped.
function rdJoin(dir, href) {
  let h = String(href).replace(/[#?].*$/, "");
  try { h = decodeURIComponent(h); } catch (e) { /* keep it as written */ }
  if (!h) return "";
  if (h.startsWith("/") || h.startsWith("~")) return h;
  const out = (dir || "").split("/");
  for (const part of h.split("/")) {
    if (part === "..") { if (out.length > 1) out.pop(); } else if (part && part !== ".") out.push(part);
  }
  return out.join("/") || "/";
}

// Front matter (a task card's YAML head) as a small table above the document.
function rdFront(text) {
  const m = /^---\n([\s\S]*?)\n---\n?/.exec(text);
  if (!m) return { meta: "", body: text };
  const rows = m[1].split("\n").map((l) => /^([\w-]+):\s*(.*)$/.exec(l)).filter(Boolean)
    .map(([, k, v]) => `<tr><th>${esc(k)}</th><td>${inline(v.replace(/\s+#\s.*$/, "").replace(/^"(.*)"$/, "$1"))}</td></tr>`);
  return { meta: rows.length ? `<table class="rd-front">${rows.join("")}</table>` : "", body: text.slice(m[0].length) };
}

function rdRender(tab) {
  const d = tab.doc;
  if (!d) return tab.err ? `<div class="rd-err">${esc(tab.err)}</div>` : `<div class="empty">${T("Loading…", "加载中…")}</div>`;
  if (!/\.(md|markdown|mdown|mkd)$/i.test(tab.path)) return `<pre class="rd-txt">${linkifyCode(d.text)}</pre>`;
  const md = rdMarkdown();
  if (!md) return `<div class="md">${markdown(d.text, `rd|${tab.path}`)}</div>`;
  const { meta, body } = rdFront(d.text);
  // Task-list items, as GitHub draws them.
  const html = md.render(body, { dir: rdDir(tab.path), path: tab.path })
    .replace(/<li>(<p>)?\[([ xX])\]\s/g, (_, p, x) => `<li class="task-li">${p || ""}<span class="tick">${x === " " ? "☐" : "☑"}</span> `);
  return meta + html;
}

// ---- opening, reading, closing
async function rdFetch(tab, force) {
  try {
    const args = { path: tab.path, cwd: "" };
    if (!force && tab.doc) args.since = tab.doc.mtime;
    const r = await apiObj("read-doc", args);
    tab.err = "";
    if (r.unchanged) return false;
    tab.doc = { text: r.text || "", mtime: r.mtime, size: r.size };
    return true;
  } catch (e) {
    tab.doc = null;
    tab.err = String(e.message || e);
    return true;
  }
}

// Open `raw` (as written; relative to `cwd`) in the reading area: its tab if it has one, else a
// new tab — or, from inside the reading area without ⌘, in place of the document showing.
async function openDoc(raw, cwd, opt = {}) {
  let r;
  try { r = await apiObj("read-doc", { path: raw, cwd: cwd || "" }); }
  catch (e) { return toast(String(e.message || e), true); }
  const path = r.path;
  const doc = { text: r.text || "", mtime: r.mtime, size: r.size };
  const cur = rdCur();
  if (cur) cur.scroll = rdScrollTop();
  const have = rd.tabs.findIndex((t) => t.path === path);
  if (have >= 0) {
    rd.active = have;
    rd.tabs[have].doc = doc;
    rd.tabs[have].err = "";
  } else if (opt.inPlace && cur) {
    cur.back.push(cur.path);
    cur.fwd = [];
    Object.assign(cur, { path, doc, err: "", scroll: 0 });
  } else {
    rd.tabs.splice(rd.active + 1, 0, { path, back: [], fwd: [], doc, err: "", scroll: 0 });
    rd.active += 1;
  }
  rd.collapsed = false;
  rdSave();
  drawReader({ scrollTop: have >= 0 ? rd.tabs[have].scroll : 0 });
}

async function rdShow(i) {
  const cur = rdCur();
  if (cur) cur.scroll = rdScrollTop();
  rd.active = i;
  rdSave();
  const t = rdCur();
  drawReader({ scrollTop: t.scroll });
  if (await rdFetch(t)) drawReader({ keepScroll: true });
}

function rdClose(i) {
  const cur = rdCur();
  if (cur) cur.scroll = rdScrollTop();
  rd.tabs.splice(i, 1);
  if (rd.active >= rd.tabs.length || i < rd.active) rd.active = Math.max(0, rd.active - 1);
  if (!rd.tabs.length) rd.active = -1;
  rdSave();
  const t = rdCur();
  drawReader({ scrollTop: t ? t.scroll : 0 });
  if (t && !t.doc) rdFetch(t).then((changed) => changed && drawReader({ keepScroll: true }));
}

async function rdGo(dir) {
  const t = rdCur();
  if (!t) return;
  const from = dir < 0 ? t.back : t.fwd, to = dir < 0 ? t.fwd : t.back;
  if (!from.length) return;
  const path = dir < 0 ? from.pop() : from.shift();
  dir < 0 ? to.unshift(t.path) : to.push(t.path);
  Object.assign(t, { path, doc: null, err: "", scroll: 0 });
  rdSave();
  drawReader({ scrollTop: 0 });
  await rdFetch(t, true);
  drawReader({ scrollTop: 0 });
}

// ---- drawing
const rdScrollTop = () => { const b = $("#reader .rd-body"); return b ? b.scrollTop : 0; };
function readerWidth() { return Math.round(Math.max(RD_MIN_W, Math.min(rd.width, window.innerWidth * 0.7))); }

function drawReader(opt = {}) {
  const el = $("#reader"), pill = $("#reader-pill");
  if (!el || !pill) return;
  const showing = rd.tabs.length > 0 && !rd.collapsed;
  document.body.classList.toggle("reading", showing);
  document.body.style.setProperty("--reader-w", `${readerWidth()}px`);
  pill.hidden = !(rd.tabs.length && rd.collapsed);
  pill.innerHTML = rd.tabs.length ? `<span class="rp-ico">📄</span><span class="rp-n">${rd.tabs.length}</span>` : "";
  pill.title = T(`Reading area: ${rd.tabs.length} open — click to show`, `阅读区：开着 ${rd.tabs.length} 个文档——点开`);
  if (!showing) { el.hidden = true; el.innerHTML = ""; return; }
  const keep = opt.keepScroll ? rdScrollTop() : opt.scrollTop || 0;
  const t = rdCur();
  const tabs = rd.tabs.map((x, i) => `<div class="rd-tab ${i === rd.active ? "on" : ""}" role="tab" aria-selected="${i === rd.active}" data-action="rd-tab" data-i="${i}" title="${esc(tildePath(x.path))}">
      <span class="rd-tn">${esc(rdName(x.path))}</span><button class="rd-x" data-action="rd-close" data-i="${i}" title="${T("Close", "关闭")}" aria-label="${T("Close", "关闭")}">✕</button></div>`).join("");
  el.innerHTML = `<div class="rd-grip" title="${T("Drag to resize", "拖动调整宽度")}"></div>
    <div class="rd-tabs" role="tablist">${tabs}<span class="rd-sp"></span>
      <button class="ibtn rd-hide" data-action="rd-collapse" title="${T("Tuck the reading area away (documents stay open)", "收起阅读区（文档不关）")}" aria-label="${T("Hide", "收起")}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg></button></div>
    <div class="rd-bar">
      <button class="ibtn" data-action="rd-back" ${t.back.length ? "" : "disabled"} title="${T("Back", "后退")}" aria-label="${T("Back", "后退")}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 6l-6 6 6 6"/></svg></button>
      <button class="ibtn" data-action="rd-fwd" ${t.fwd.length ? "" : "disabled"} title="${T("Forward", "前进")}" aria-label="${T("Forward", "前进")}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg></button>
      <span class="rd-path" title="${esc(t.path)}">\u200e${esc(tildePath(t.path))}\u200e</span>
      <button class="btn small ghost" data-action="rd-copy-path" title="${T("Copy the path", "复制路径")}">${T("Copy path", "复制路径")}</button>
      <button class="btn small" data-action="rd-edit" title="${T("Open in its editor to change it — the reading area shows your edits", "用编辑器打开来修改——改完这里会跟着更新")}">${T("Open in editor", "用编辑器打开")}</button>
    </div>
    <div class="rd-body"><article class="rd-doc md">${rdRender(t)}</article></div>`;
  el.hidden = false;
  const body = el.querySelector(".rd-body");
  if (body) body.scrollTop = keep;
  const on = el.querySelector(".rd-tab.on");
  if (on) on.scrollIntoView({ block: "nearest", inline: "nearest" });
}

// ---- events
async function readerAction(action, d, ev) {
  switch (action) {
    case "rd-tab":
      if (ev.target.closest(".rd-x")) return true;
      return rdShow(Number(d.i)), true;
    case "rd-close": return rdClose(Number(d.i)), true;
    case "rd-collapse": rd.collapsed = true; rdSave(); return drawReader(), true;
    case "rd-expand": {
      rd.collapsed = false; rdSave();
      const t = rdCur();
      drawReader({ scrollTop: t ? t.scroll : 0 });
      if (t && (await rdFetch(t))) drawReader({ keepScroll: true });
      return true;
    }
    case "rd-back": return rdGo(-1), true;
    case "rd-fwd": return rdGo(1), true;
    case "rd-edit": { const t = rdCur(); if (t) act2("openPath", { path: t.path }); return true; }
    case "rd-copy-path": { const t = rdCur(); if (t) copyText(t.path, T("Path copied", "已复制路径")); return true; }
    case "rd-anchor": {
      const h = document.getElementById(`rd-h-${d.id}`);
      if (h) h.scrollIntoView({ block: "start", behavior: "smooth" });
      return true;
    }
  }
  return false;
}

// Whether the last click was in the reading area: Esc then doesn't close the window beside it.
let rdPressed = false;
document.addEventListener("mousedown", (ev) => { rdPressed = Boolean(ev.target.closest && ev.target.closest("#reader")); }, true);
const rdFocused = () => rdPressed && rd.tabs.length > 0 && !rd.collapsed;

// A middle click closes a tab, as in a browser.
document.addEventListener("auxclick", (ev) => {
  const tab = ev.button === 1 && ev.target.closest && ev.target.closest("#reader .rd-tab");
  if (tab) { ev.preventDefault(); rdClose(Number(tab.dataset.i)); }
});
// Dragging the left edge sets the width (kept for next time).
document.addEventListener("mousedown", (ev) => {
  if (!ev.target.closest || !ev.target.closest("#reader .rd-grip") || ev.button !== 0) return;
  ev.preventDefault();
  document.body.classList.add("rd-resizing");
  const move = (e) => {
    rd.width = Math.max(RD_MIN_W, Math.min(window.innerWidth - e.clientX, window.innerWidth * 0.7));
    document.body.style.setProperty("--reader-w", `${readerWidth()}px`);
  };
  const up = () => {
    document.removeEventListener("mousemove", move);
    document.removeEventListener("mouseup", up);
    document.body.classList.remove("rd-resizing");
    rdSave();
  };
  document.addEventListener("mousemove", move);
  document.addEventListener("mouseup", up);
});
window.addEventListener("resize", () => { if (rd.tabs.length) document.body.style.setProperty("--reader-w", `${readerWidth()}px`); });

// The document showing is read again every few seconds (only when it changed is it redrawn), and
// when the board comes back to the front.
async function rdPoll() {
  const t = rdCur();
  if (!t || rd.collapsed || document.hidden) return;
  // Not while text in it is selected: a redraw would drop the selection.
  const sel = window.getSelection();
  if (sel && String(sel).trim() && sel.anchorNode && $("#reader") && $("#reader").contains(sel.anchorNode)) return;
  if (await rdFetch(t)) drawReader({ keepScroll: true });
}
setInterval(rdPoll, RD_POLL_MS);
window.addEventListener("focus", rdPoll);

rdLoad();
drawReader();
if (rdCur() && !rd.collapsed) rdFetch(rdCur(), true).then(() => drawReader({ scrollTop: 0 }));
