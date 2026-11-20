// HQ board. Everything is read from and written through the `hq` CLI via the
// native bridge (BoardWindow.swift); this page holds no state worth keeping.
"use strict";

const ORDER = ["waiting-on-me", "blocked", "active", "done", "abandoned"];
const LABEL = {
  "waiting-on-me": "Waiting on you", blocked: "Blocked", active: "Active",
  done: "Done", abandoned: "Abandoned",
};
const RESOLUTIONS = [
  ["do", "Do", "Yes / will do — the note says how"],
  ["drop", "Drop", "Won't do — stop tracking it"],
  ["later", "Ask later", "Need to ask someone else — revisit"],
  ["archive", "No context", "I can't answer this — park it"],
];
// Categories live in <root>/hq.json and are edited from the Categories panel.
const projects = () => (ui.board && Array.isArray(ui.board.projects) ? ui.board.projects : []);
const projectNames = () => projects().map((p) => p.name);
const categories = () => (ui.board && Array.isArray(ui.board.categories) ? ui.board.categories : []);
// Terminals the board can type into; anything else gets Jump only.
const SENDABLE = { orca: "Orca", iterm2: "iTerm2" };
const TERMINAL_NAME = { vscode: "VS Code", ghostty: "Ghostty", orca: "Orca", iterm2: "iTerm2" };

function pref(key, dflt) { try { return localStorage.getItem(key) ?? dflt; } catch (e) { return dflt; } }
function savePref(key, value) { try { localStorage.setItem(key, value); } catch (e) { /* private mode */ } }
const ui = {
  board: null, sessions: [], expanded: new Set(), peekOpen: new Set(), peeks: {},
  drafts: {}, showClosed: false, filter: "", newTask: false, busy: false, catsOpen: false, catRemove: {}, modal: null, recent: [], undoFn: null, msgOpen: new Set(), adding: new Set(), logAll: new Set(), resOpen: new Set(), projOpen: false, projRemove: {}, doneOpen: new Set(),
  groupBy: pref("hq-groupby", "project"), sgroupBy: pref("hq-sgroupby", "list"),
  scollapsed: new Set(JSON.parse(pref("hq-scollapsed", "[]"))), activeFirst: pref("hq-activefirst", "1") === "1", collapsed: new Set(JSON.parse(pref("hq-collapsed", "[]"))),
};

// ------------------------------------------------------------------ bridge
async function api(op, args = {}) {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hq;
  if (!h) throw new Error("Open this page from Claude Pet (Task Board…)");
  return h.postMessage(Object.assign({ op }, args));
}
async function apiJSON(op, args) { return JSON.parse(await api(op, args)); }

async function act(op, args, ok) {
  try {
    await api(op, args);
    if (ok) toast(ok);
  } catch (e) {
    toast(String(e.message || e), true);
  }
  await refresh();
}

// ------------------------------------------------------------------ helpers
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => (
  { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
function ago(iso) {
  if (!iso) return "";
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (isNaN(s)) return "";
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400 * 2) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}
function toast(msg, bad, undo) {
  const t = $("#toast");
  ui.undoFn = undo || null;
  t.innerHTML = `<span>${esc(msg)}</span>` +
    (undo ? ` <button class="btn small" data-action="undo-toast">Undo</button>` : "");
  t.className = bad ? "bad" : "";
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; ui.undoFn = null; }, undo ? 8000 : bad ? 6000 : 2200);
}

// Every one-click change that is easy to hit by accident can be taken back.
const RECENT_MS = 60 * 60 * 1000;
const FINISHED_SHOWN = 3;   // finished todos shown on a task before they fold
const TODO_STATE = { open: "open", done: "done", dropped: "drop", drop: "drop" };
async function changeTodo(task, i, to, from, text) {
  const label = { done: "Done", drop: "Won't do", open: "Reopened" }[to] || to;
  try {
    await api("todo", { task, index: i, state: to });
    if (to !== "open") ui.recent = ui.recent.filter((r) => !(r.task === task && r.i === i))
      .concat([{ task, i, text, to, from: TODO_STATE[from] || "open", at: Date.now() }]);
    else ui.recent = ui.recent.filter((r) => !(r.task === task && r.i === i));
    toast(`${label}: ${text}`, false, to === "open" ? null : () => undoTodo(task, i));
  } catch (e) { toast(String(e.message || e), true); }
  await refresh();
}
async function undoTodo(task, i) {
  const r = ui.recent.find((x) => x.task === task && x.i === i);
  ui.recent = ui.recent.filter((x) => x !== r);
  await act("todo", { task, index: i, state: r ? r.from : "open" }, "Undone");
}
const tasks = () => (ui.board ? ui.board.tasks : []);
const taskById = (id) => tasks().find((t) => t.id === id);
const isOpen = (t) => ["waiting-on-me", "blocked", "active"].includes(t.status);
const openAsks = (t) => (t.asks || []).filter((a) => a.state === "open");
const liveFor = (id) => ui.sessions.filter((s) => s.task === id);
const draft = (key) => ui.drafts[key] ?? "";
const list = (v) => (Array.isArray(v) ? v : []);

// ------------------------------------------------------------------ data
async function refresh() {
  try {
    const [board, sessions] = await Promise.all([apiJSON("board"), apiJSON("sessions")]);
    ui.board = board;
    ui.sessions = sessions;
    $("#error").hidden = true;
  } catch (e) {
    $("#error").textContent = String(e.message || e);
    $("#error").hidden = false;
  }
  render();
  if (ui.modal && ui.modal.type === "peek") refreshPeek();
}
window.hqRefresh = refresh;

// ------------------------------------------------------------------ render
function render() {
  // Never yank an open dropdown out from under the pointer.
  if (ui.dragging) return;
  const active = document.activeElement;
  if (active && active.tagName === "SELECT") return;
  const key = active && active.dataset ? active.dataset.key : null;
  const sel = key && "selectionStart" in active ? [active.selectionStart, active.selectionEnd] : null;
  // Peek panes are rebuilt every refresh; keep where the reader was (bottom = newest by default).
  const scrolls = {};
  document.querySelectorAll(".peek[data-sid]").forEach((p) => {
    scrolls[p.dataset.sid] = p.scrollHeight - p.scrollTop - p.clientHeight < 8 ? "bottom" : p.scrollTop;
  });

  renderCounts();
  $("#asks").innerHTML = renderAsks();
  $("#mytodos").innerHTML = renderMyTodos();
  $("#newtask-form").hidden = !ui.newTask;
  if (ui.newTask && !$("#newtask-form").dataset.drawn) {
    $("#newtask-form").innerHTML = renderNewTask();
    $("#newtask-form").dataset.drawn = "1";
  }
  $("#groupby").innerHTML = ["project", "status"].map((g) =>
    `<button class="${ui.groupBy === g ? "on" : ""}" data-action="group-by" data-g="${g}">${g === "project" ? "Project" : "Status"}</button>`).join("");
  $("#activefirst").hidden = ui.groupBy !== "project";
  $("#sgroupby").innerHTML = ["list", "project"].map((g) =>
    `<button class="${ui.sgroupBy === g ? "on" : ""}" data-action="sgroup-by" data-g="${g}">${g === "list" ? "List" : "Project"}</button>`).join("");
  // One button: by project it folds / unfolds every group; by status it closes open task cards.
  const groupKeys = [...new Set(tasks().map((t) => t.project || "(none)"))];
  const anyOpen = ui.groupBy === "project" ? groupKeys.some((k) => !ui.collapsed.has(k)) : ui.expanded.size > 0;
  $("#foldall").textContent = anyOpen ? "Collapse all" : "Expand all";
  $("#foldall").title = ui.groupBy === "project" ? "Fold or unfold every project group" : "Close every open task";
  $("#foldall").hidden = ui.groupBy === "status" && !anyOpen;
  $("#activefirst input").checked = ui.activeFirst;
  $("#projects-panel").hidden = !ui.projOpen;
  if (ui.projOpen) $("#projects-panel").innerHTML = renderProjects();
  $("#cats-panel").hidden = !ui.catsOpen;
  if (ui.catsOpen) $("#cats-panel").innerHTML = renderCategories();
  $("#tasks").innerHTML = renderTasks();
  $("#sessions").innerHTML = renderSessions();

  document.querySelectorAll(".peek[data-sid]").forEach((p) => {
    const v = scrolls[p.dataset.sid];
    p.scrollTop = v === undefined || v === "bottom" ? p.scrollHeight : v;
  });
  if (key) {
    const el = document.querySelector(`[data-key="${CSS.escape(key)}"]`);
    if (el) {
      el.focus();
      if (sel && el.setSelectionRange) el.setSelectionRange(sel[0], sel[1]);
    }
  }
}

function renderCounts() {
  const all = tasks();
  const asks = all.reduce((n, t) => n + openAsks(t).length, 0);
  const mine = all.filter(isOpen).reduce((n, t) => n + t.todos.filter((x) => x.state === "open" && x.owner === "me").length, 0);
  const legacy = all.filter((t) => isOpen(t) && t.waiting_on_me).length;
  const activeN = all.filter(isOpen).length;
  $("#counts").innerHTML =
    `<span><b>${asks}</b> asks</span><span><b>${mine + legacy}</b> your todos</span>` +
    `<span><b>${activeN}</b> open tasks</span>` +
    `<span><b>${ui.sessions.length}</b> live sessions</span>`;
}

function renderAsks() {
  const items = [];
  for (const t of tasks()) for (const a of openAsks(t)) items.push([t, a]);
  items.sort((x, y) => String(x[1].ts).localeCompare(String(y[1].ts)));
  if (!items.length) return `<h3>Asks</h3><div class="empty">Nothing Claude asked you is unanswered.</div>`;
  return `<h3>Asks · ${items.length}</h3>` + items.map(([t, a]) => `
    <div class="card ask">
      <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(a.id)}</span>${esc(t.title)} · ${ago(a.ts)}</div>
      <div class="ask-text clickable" title="Show where this came from" data-action="ctx" data-kind="ask" data-task="${esc(t.id)}" data-id="${esc(a.id)}">${esc(a.text)}</div>
      <div class="row">
        <input class="note" data-key="note:${esc(a.id)}" placeholder="note (optional)" value="${esc(draft("note:" + a.id))}">
        ${RESOLUTIONS.map(([r, label, tip]) =>
          `<button class="btn small res-${r}" title="${esc(tip)}" data-action="resolve" data-id="${esc(a.id)}" data-res="${r}">${label}</button>`).join("")}
      </div>
    </div>`).join("");
}

function renderMyTodos() {
  const items = [];
  for (const t of tasks().filter(isOpen))
    for (const x of t.todos) if (x.state === "open" && x.owner === "me") items.push([t, x]);
  // A card may still carry the old free-text "waiting on you" field (written before it was
  // folded into @me todos). Show it here as a todo rather than lose it; ticking clears it.
  const legacy = tasks().filter((t) => isOpen(t) && t.waiting_on_me);
  // Recently ticked items stay in view (struck through, with Undo) for an hour. After that,
  // reopen from the task itself — every change is also in the card's log.
  ui.recent = ui.recent.filter((r) => Date.now() - r.at < RECENT_MS);
  const recent = ui.recent.filter((r) => {
    const t = taskById(r.task);
    const x = t && t.todos.find((y) => y.i === r.i);
    return x && x.state !== "open";
  });
  if (!items.length && !recent.length && !legacy.length) return `<h3>Your todos</h3><div class="empty">Nothing waiting on you.</div>`;
  return `<h3>Your todos · ${items.length + legacy.length}</h3><div class="card">` + legacy.map((t) => `
    <div class="todo">
      <span class="box" title="Handled (you can undo)" data-action="clear-waiting" data-task="${esc(t.id)}"></span>
      <div style="flex:1"><span class="t clickable" title="Show context" data-action="ctx" data-kind="waiting" data-task="${esc(t.id)}">${esc(t.waiting_on_me)}</span>
        <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div></div>
    </div>`).join("") + items.map(([t, x]) => `
    <div class="todo">
      <span class="box" title="Mark done (you can undo)" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="done" data-from="open" data-text="${esc(x.text)}"></span>
      <div style="flex:1"><span class="t clickable" title="Show context" data-action="ctx" data-kind="todo" data-task="${esc(t.id)}" data-i="${x.i}">${esc(x.text)}</span>
        <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div></div>
      <button class="btn small ghost" title="Won't do (you can undo)" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop" data-from="open" data-text="${esc(x.text)}">✕</button>
    </div>`).join("") + recent.map((r) => `
    <div class="todo ${r.to === "drop" ? "dropped" : "done"}">
      <span class="box ${r.to === "drop" ? "dropped" : "done"}">${r.to === "drop" ? "–" : "✓"}</span>
      <div style="flex:1"><span class="t">${esc(r.text)}</span>
        <div class="meta">${r.to === "drop" ? "won't do" : "done"} ${ago(new Date(r.at).toISOString())} · undo available for an hour · <span class="chip link" data-action="goto" data-task="${esc(r.task)}">${esc(r.task)}</span></div></div>
      <button class="btn small" data-action="undo-todo" data-task="${esc(r.task)}" data-i="${r.i}">Undo</button>
    </div>`).join("") + `</div>`;
}

function renderWaitingUnused() {
  const items = tasks().filter((t) => isOpen(t) && t.waiting_on_me);
  if (!items.length) return "";
  return `<h3>Waiting on you · ${items.length}</h3>` + items.map((t) => `
    <div class="card">
      <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div>
      <div class="ask-text clickable" title="Show context" data-action="ctx" data-kind="waiting" data-task="${esc(t.id)}">${esc(t.waiting_on_me)}</div>
      <div class="row"><button class="btn small" data-action="clear-waiting" data-task="${esc(t.id)}">Handled</button></div>
    </div>`).join("");
}

// Within a status group: tasks with a live session first, then ones that had a session,
// then the rest; ties go to open asks, then the most recently updated.
// Latest activity of a live session in a project: bound to one of its tasks, or working in
// one of its directories.
function projectActivity(name) {
  if (!name) return 0;
  const pr = projects().find((p) => p.name === name);
  const paths = pr ? pr.paths.map((p) => p.replace(/\/+$/, "")) : [];
  let latest = 0;
  for (const s of ui.sessions) {
    const t = s.task && taskById(s.task);
    const cwd = s.cwd || "";
    if ((t && t.project === name) || paths.some((p) => cwd === p || cwd.startsWith(p + "/"))) {
      latest = Math.max(latest, Date.parse(s.updatedAt) || 0);
    }
  }
  return latest;
}

function taskRank(t) { return liveFor(t.id).length ? 2 : list(t.sessions).length ? 1 : 0; }
function compareTasks(a, b) {
  return taskRank(b) - taskRank(a) || openAsks(b).length - openAsks(a).length ||
    String(b.updated).localeCompare(String(a.updated)) || String(a.id).localeCompare(String(b.id));
}

function renderTasks() {
  const f = ui.filter.toLowerCase();
  const visible = tasks().filter((t) => (ui.showClosed || isOpen(t)) &&
    (!f || `${t.id} ${t.title} ${list(t.refs).join(" ")} ${t.category} ${t.project || ""}`.toLowerCase().includes(f)));
  if (!visible.length) return `<div class="empty">No tasks${f ? " match" : ""}.</div>`;
  let html = "";
  if (ui.groupBy === "project") {
    const names = projectNames();
    const extra = [...new Set(visible.map((t) => t.project || "").filter((n) => n && !names.includes(n)))];
    let order = [...names, ...extra];
    const activity = Object.fromEntries(order.map((n) => [n, projectActivity(n)]));
    // Active first: projects with a live session float up, newest activity first; the rest keep
    // the dragged order (Array.sort is stable).
    if (ui.activeFirst) order = order.slice().sort((a, b) => (activity[b] || 0) - (activity[a] || 0));
    for (const name of [...order, ""]) {
      const group = visible.filter((t) => (t.project || "") === name)
        .sort((a, b) => ORDER.indexOf(a.status) - ORDER.indexOf(b.status) || compareTasks(a, b));
      if (!group.length) continue;
      const key = name || "(none)";
      const shut = ui.collapsed.has(key);
      const asks = group.reduce((n, t) => n + openAsks(t).length, 0);
      const live = group.reduce((n, t) => n + liveFor(t.id).length, 0);
      const movable = Boolean(name) && names.includes(name);
      html += `<div class="group-title proj" data-action="collapse" data-key="${esc(key)}" title="Click to ${shut ? "expand" : "collapse"}${movable ? " · drag to reorder" : ""}"
          ${movable ? `draggable="true" data-drag-project="${esc(name)}"` : ""}>
        <span class="caret ${shut ? "" : "open"}"><svg viewBox="0 0 16 16"><path d="M6 3.5 10.5 8 6 12.5"/></svg></span>${esc(name || "No project")} <span class="meta">${group.length}</span>
        ${activity[name] ? `<span class="act" title="Latest session activity in this project">● ${ago(new Date(activity[name]).toISOString())}</span>` : ""}
        ${asks ? `<span class="badge" title="open asks">${asks}</span>` : ""}${live ? `<span class="badge live" title="live sessions">${live}</span>` : ""}
        ${name && !names.includes(name) ? `<span class="meta">not in list</span>` : ""}
        ${movable ? `<span class="grip" aria-hidden="true">⠿</span>` : ""}</div>`;
      if (!shut) html += group.map((t) => renderTask(t, "project")).join("");
    }
    return html;
  }
  for (const st of ORDER) {
    const group = visible.filter((t) => t.status === st).sort(compareTasks);
    if (!group.length) continue;
    html += `<div class="group-title">${LABEL[st]} <span class="meta">${group.length}</span></div>`;
    html += group.map((t) => renderTask(t, "status")).join("");
  }
  return html;
}

const STATUS_SHORT = { "waiting-on-me": "Waiting on you", blocked: "Blocked", active: "Active", done: "Done", abandoned: "Abandoned" };
function renderTask(t, mode) {
  const asks = openAsks(t).length;
  const live = liveFor(t.id).length;
  const open = ui.expanded.has(t.id);
  const mine = t.waiting_on_me || (t.todos.find((x) => x.state === "open" && x.owner === "me") || {}).text;
  const sub = mine && isOpen(t) ? `<div class="tsub waiting" title="Waiting on you">⮑ ${esc(mine)}</div>`
    : (t.next && isOpen(t) ? `<div class="tsub">⮑ ${esc(t.next)}</div>` : "");
  return `<div class="task" id="task-${esc(t.id)}">
    <div class="task-head" data-action="expand" data-task="${esc(t.id)}">
      <span class="tid">${esc(t.id)}</span>
      <div class="ttitle">${esc(t.title)}${sub}</div>
      ${asks ? `<span class="badge" title="open asks">${asks}</span>` : ""}
      ${live ? `<span class="badge live" title="live sessions working on it">${live}</span>` : ""}
      ${mode === "project" ? `<span class="stag ${esc(t.status)}">${STATUS_SHORT[t.status] || esc(t.status)}</span>`
        : t.project ? `<span class="chip">${esc(t.project)}</span>` : ""}
      <span class="meta">${esc(t.category || "")} · ${t.age_days ?? "?"}d</span>
    </div>
    ${open ? renderTaskBody(t) : ""}
  </div>`;
}

// ---- related resources: URLs as-is, shorthand (QA-123, repo#45) through hq.json "links" rules
// Titles are cut to a few words; the full title and the URL are in the tooltip.
const REF_LABEL_MAX = 36;
const shortLabel = (t) => (t.length > REF_LABEL_MAX ? t.slice(0, REF_LABEL_MAX).replace(/[\s\-–:,，]+\S*$/, "") + "…" : t);
const KIND_LABEL = { ticket: "Tickets", pr: "Pull requests", doc: "Docs", link: "Links", none: "Not linked" };
function kindOfUrl(u) {
  if (/github\.com\/[^/]+\/[^/]+\/(pull|merge_requests)\/|gitlab\.[^/]+\/.+\/merge_requests\//.test(u)) return "pr";
  if (/\/browse\/[A-Z][A-Z0-9]+-\d+|linear\.app\/|\/issues\/\d+|\/jira\//i.test(u)) return "ticket";
  if (/\/wiki\/|confluence|docs\.google|notion\.(so|site)|\.md(\b|$)|claude\.ai\/artifact/i.test(u)) return "doc";
  return "link";
}
function resolveRef(ref) {
  const url = (String(ref).match(/https?:\/\/[^\s<>"')]+/) || [])[0];
  if (url) {
    const label = String(ref).replace(url, "").replace(/[\s:：,，-]+$/, "").trim();
    return { ref, url, kind: kindOfUrl(url), label: label || url.replace(/^https?:\/\//, "").slice(0, 70) };
  }
  for (const rule of (ui.board && Array.isArray(ui.board.links) ? ui.board.links : [])) {
    let re;
    try { re = new RegExp(rule.match); } catch (e) { continue; }
    const m = String(ref).match(re);
    if (m) return { ref, url: String(rule.url).replace(/\$(\d)/g, (_, n) => m[Number(n)] || ""), kind: rule.kind || "link", label: ref };
  }
  return { ref, url: "", kind: "none", label: ref };
}
function logEntries(t) {
  return String(t.body || "").split("\n").map((l) => l.match(/^\s*-\s+(\d{4}-\d{2}-\d{2}):\s+(.*)$/))
    .filter(Boolean).map((m) => ({ date: m[1], text: m[2] }));
}
const PLUS = '<svg viewBox="0 0 16 16"><path d="M8 3v10M3 8h10"/></svg>';
const LINK = '<svg viewBox="0 0 16 16"><path d="M6.5 9.5l3-3M7 4.5l1-1a2.5 2.5 0 0 1 3.5 3.5l-1 1M9 11.5l-1 1A2.5 2.5 0 0 1 4.5 9l1-1"/></svg>';

function secHead(title, t, what, tip, count) {
  const on = ui.adding.has(`${t.id}:${what}`);
  return `<div class="sec-h"><h3>${title}${count != null ? ` <span class="meta">${count}</span>` : ""}</h3>
    <button class="icon ${on ? "on" : ""}" title="${esc(tip)}" data-action="toggle-add" data-what="${what}" data-task="${esc(t.id)}">${PLUS}</button></div>`;
}

function renderTaskBody(t) {
  const k = (f) => `${f}:${t.id}`;
  const adding = (what) => ui.adding.has(`${t.id}:${what}`);
  // next: edit, then Save or Cancel — nothing saves on Enter or on blur.
  const field = (name, label, placeholder) => {
    const v = t[name] || "";
    const d = ui.drafts[k(name)];
    const dirty = d !== undefined && d !== v;
    return `<div class="field"><label>${label}</label><div class="row nowrap">
      <input data-key="${k(name)}" data-field="${name}" data-task="${esc(t.id)}" value="${esc(d ?? v)}" placeholder="${esc(placeholder)}">
      ${dirty ? `<button class="btn small primary" data-action="save-field" data-field="${name}" data-task="${esc(t.id)}">Save</button>
        <button class="btn small ghost" data-action="cancel-field" data-field="${name}" data-task="${esc(t.id)}">Cancel</button>` : ""}
    </div></div>`;
  };
  // Open todos first, always shown. Finished ones follow; past FINISHED_SHOWN of them they fold
  // behind "Show N done" — except ones ticked in the last hour, which stay for an easy undo.
  const isRecent = (x) => ui.recent.some((r) => r.task === t.id && r.i === x.i && Date.now() - r.at < RECENT_MS);
  const openTodos = t.todos.filter((x) => x.state === "open");
  const finished = t.todos.filter((x) => x.state !== "open");
  const foldDone = finished.length > FINISHED_SHOWN && !ui.doneOpen.has(t.id);
  const shownTodos = openTodos.concat(foldDone ? finished.filter(isRecent) : finished);
  const hiddenDone = finished.length - (shownTodos.length - openTodos.length);
  const todoRow = (x) => {
    const mark = x.state === "done" ? "✓" : x.state === "dropped" ? "–" : "";
    const next = x.state === "open" ? "done" : "open";
    const owner = x.owner ? `<span class="owner ${x.owner === "me" ? "me" : ""}">@${esc(x.owner)}</span>` : "";
    return `<div class="todo ${x.state}">
      <span class="box ${x.state}" title="${x.state === "open" ? "Mark done" : "Reopen"}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="${next}" data-from="${x.state}" data-text="${esc(x.text)}">${mark}</span>
      <span class="t" style="flex:1">${owner}${esc(x.text)}</span>
      ${x.state === "open" ? `<button class="icon" title="Won't do" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop" data-from="open" data-text="${esc(x.text)}">✕</button>` : ""}</div>`;
  };
  const todos = !t.todos.length ? `<div class="empty">No todos.</div>`
    : (openTodos.length ? "" : `<div class="empty">All done.</div>`) + shownTodos.map(todoRow).join("") +
      (finished.length > FINISHED_SHOWN
        ? `<button class="btn small ghost" data-action="done-toggle" data-task="${esc(t.id)}">${ui.doneOpen.has(t.id) ? "Hide finished" : `Show ${hiddenDone} finished`}</button>` : "");
  const live = liveFor(t.id);
  const unbound = ui.sessions.filter((s) => s.task !== t.id);
  const logs = logEntries(t);
  const showLogs = ui.logAll.has(t.id) ? logs : logs.slice(-3);
  const refs = list(t.refs).map(resolveRef);
  const groups = ["ticket", "pr", "doc", "link", "none"].map((kd) => [kd, refs.filter((r) => r.kind === kd)]).filter(([, r]) => r.length);
  const resOpen = ui.resOpen.has(t.id);
  return `<div class="task-body">
    <div class="field"><label>status</label>
      <select data-action="set-status" data-task="${esc(t.id)}">
        ${ORDER.map((s) => `<option value="${s}" ${s === t.status ? "selected" : ""}>${LABEL[s]}</option>`).join("")}
      </select></div>
    <div class="field"><label>project</label>
      <select data-action="set-project" data-task="${esc(t.id)}">
        <option value="" ${t.project ? "" : "selected"}>(no project)</option>
        ${projectNames().map((c) => `<option value="${esc(c)}" ${c === t.project ? "selected" : ""}>${esc(c)}</option>`).join("")}
        ${t.project && !projectNames().includes(t.project) ? `<option value="${esc(t.project)}" selected>${esc(t.project)} (not in list)</option>` : ""}
      </select></div>
    <div class="field"><label>category</label>
      <select data-action="set-category" data-task="${esc(t.id)}">
        <option value="" ${t.category ? "" : "selected"}>(none)</option>
        ${categories().map((c) => `<option value="${esc(c)}" ${c === t.category ? "selected" : ""}>${esc(c)}</option>`).join("")}
        ${t.category && !categories().includes(t.category) ? `<option value="${esc(t.category)}" selected>${esc(t.category)} (not in list)</option>` : ""}
      </select></div>
    ${field("next", "next", "the next concrete step")}
    <div class="field"><label>workdirs</label><div class="meta">${list(t.workdirs).length
        ? list(t.workdirs).map(esc).join("<br>") : "— added automatically when a session is bound"}</div></div>

    ${secHead("Todos", t, "todo", "Add a todo")}
    ${adding("todo") ? `<div class="row nowrap addbox">
        <input class="note" data-key="${k("addtodo")}" data-task="${esc(t.id)}" data-enter="addtodo" placeholder="e.g. @me send the reply to …   (@me = you, @claude, or a name)" value="${esc(draft(k("addtodo")))}">
        <button class="btn small primary" data-action="add-todo" data-task="${esc(t.id)}">Add</button></div>` : ""}
    ${todos}

    ${secHead("Sessions", t, "bind", "Bind a live session")}
    ${adding("bind") ? `<div class="row nowrap addbox">${unbound.length
        ? `<select class="bind" data-key="${k("bindpick")}"><option value="">Choose a live session…</option>
            ${unbound.map((s) => `<option value="${esc(s.sessionId)}" ${draft(k("bindpick")) === s.sessionId ? "selected" : ""}>${esc(s.title || s.project)} (${esc(s.project)})${s.task ? " · now on " + esc(s.task) : ""}</option>`).join("")}</select>
           <button class="btn small primary" data-action="bind-pick" data-task="${esc(t.id)}">Bind</button>`
        : `<span class="empty">No other live sessions.</span>`}</div>` : ""}
    ${live.length ? live.map((s) => `<div class="bsess">
        <span class="dot ${esc(s.state || "")}"></span>
        <div style="flex:1;min-width:0"><div class="stitle">${esc(s.title || s.project)}</div>
          <div class="meta">${esc(s.project || "")} · ${esc(s.state || "?")} · ${ago(s.updatedAt)}</div></div>
        <div class="icons">
          <button class="icon" data-action="peek" data-session="${esc(s.sessionId)}" title="Peek — open the conversation">${ICON.peek}</button>
          <button class="icon" data-action="jump" data-session="${esc(s.sessionId)}" title="Jump to its terminal">${ICON.jump}</button>
          <button class="icon" data-action="unbind" data-session="${esc(s.sessionId)}" title="Unbind from this task">✕</button>
        </div></div>`).join("")
      : `<div class="empty">No live session is working on this.${list(t.sessions).length ? " Earlier sessions: click an item in Needs you, or use the context view." : ""}</div>`}

    ${secHead("Log", t, "log", "Add a note — the task's memory; bound sessions read it", logs.length || null)}
    ${adding("log") ? `<div class="addbox"><textarea class="note logbox" data-key="${k("log")}" placeholder="A decision, a finding, a note for whoever picks this up next">${esc(draft(k("log")))}</textarea>
        <div class="row" style="justify-content:flex-end"><button class="btn small primary" data-action="add-log" data-task="${esc(t.id)}">Save note</button></div></div>` : ""}
    ${showLogs.length ? `<div class="logs">${showLogs.map((l) => `<div class="logline"><span class="meta">${esc(l.date)}</span> ${inline(l.text)}</div>`).join("")}</div>` : `<div class="empty">Nothing logged yet.</div>`}
    ${logs.length > 3 ? `<button class="btn small ghost" data-action="log-all" data-task="${esc(t.id)}">${ui.logAll.has(t.id) ? "Show latest 3" : `Show all ${logs.length}`}</button>` : ""}

    <div class="row foot">
      <button class="btn small ${resOpen ? "on" : ""}" data-action="toggle-res" data-task="${esc(t.id)}">${LINK.replace("<svg", '<svg class="ic"')} Resources${refs.length ? ` · ${refs.length}` : ""}</button>
      <span style="flex:1"></span>
      <button class="btn small ghost" data-action="open" data-path="${esc(t.path)}">Open card</button>
    </div>
    ${resOpen ? `<div class="res">
      ${groups.map(([kd, rs]) => `<div class="res-g"><div class="meta">${KIND_LABEL[kd]}</div>${rs.map((r) => `<div class="res-i">
          ${r.url ? `<a href="#" data-action="link" data-url="${esc(r.url)}" title="${esc(r.label + "\n" + r.url)}">${esc(shortLabel(r.label))}</a>` : `<span title="${esc(r.label)}">${esc(shortLabel(r.label))}</span>`}
          <button class="icon" title="Remove" data-action="ref-remove" data-task="${esc(t.id)}" data-ref="${esc(r.ref)}">✕</button></div>`).join("")}</div>`).join("")
        || `<div class="empty">No related tickets, PRs or docs yet.</div>`}
      <div class="row nowrap"><input class="note" data-key="${k("addref")}" data-task="${esc(t.id)}" data-enter="addref" placeholder="Add a URL, or a ticket / PR like QA-123, repo#45" value="${esc(draft(k("addref")))}">
        <button class="btn small" data-action="add-ref" data-task="${esc(t.id)}">Add</button></div>
      ${!(ui.board && (ui.board.links || []).length) ? `<div class="meta">Tip: shorthand like QA-123 becomes a link once you add a rule under "links" in hq.json (see Guide).</div>` : ""}
    </div>` : ""}
  </div>`;
}

// Small line icons (currentColor), so the session cards need no button labels.
const ICON = {
  peek: '<svg viewBox="0 0 16 16"><path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8 12.1 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/></svg>',
  jump: '<svg viewBox="0 0 16 16"><path d="M9 2.5h4.5V7M13.5 2.5 7 9M11.5 9.5v3a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1h3"/></svg>',
  message: '<svg viewBox="0 0 16 16"><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/></svg>',
};

function renderSessions() {
  if (!ui.sessions.length) return `<div class="empty">No live Claude Code sessions (Claude Pet sees sessions started after it was installed).</div>`;
  const openTasks = tasks().filter(isOpen);
  const card = (s) => {
    const t = s.task && taskById(s.task);
    const sid = s.sessionId;
    const sorted = openTasks.slice().sort((a, b) =>
      (list(b.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0) -
      (list(a.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0));
    const taskCtl = t
      ? `<span class="chip link" data-action="goto" data-task="${esc(t.id)}" title="${esc(t.title)}">${esc(t.id)}</span>`
      : `<select class="bind mini" data-action="bind-session" data-session="${esc(sid)}" title="Bind this session to a task">
           <option value="">Bind…</option>
           ${sorted.map((x) => `<option value="${esc(x.id)}">${esc(x.id)} ${esc(x.title)}</option>`).join("")}
         </select>`;
    const busy = s.state === "busy";
    const kind = s.terminal && s.terminal.kind;
    const canSend = Boolean(SENDABLE[kind]);
    const why = canSend ? "" : `Messaging from the Task Board isn't supported for ${
      kind ? (TERMINAL_NAME[kind] || kind) + " terminals" : "this session's terminal"} yet — use Jump to open it.`;
    // The message box only takes room when asked for (or while it holds a draft).
    const open = canSend && (ui.msgOpen.has(sid) || Boolean(draft("msg:" + sid)));
    return `<div class="card session">
      <span class="dot ${esc(s.state || "")}" title="${esc(s.state || "")}"></span>
      <div class="body">
        <div class="shead">
          <div class="stitle" title="${esc(s.title || s.project || "")}">${esc(s.title || s.project || sid.slice(0, 8))}</div>
          ${taskCtl}
        </div>
        <div class="shead">
          <div class="meta smeta">${ui.sgroupBy !== "project" && sessionProject(s) ? `<span class="pchip">${esc(sessionProject(s))}</span> · ` : ""}${esc(s.project || "")} · ${esc(s.state || "?")} · ${ago(s.updatedAt)}${s.waitingOn ? " · waiting: " + esc(s.waitingOn) : ""}</div>
          <div class="icons">
            <button class="icon" data-action="peek" data-session="${esc(sid)}" title="Peek — open the recent conversation">${ICON.peek}</button>
            <button class="icon" data-action="jump" data-session="${esc(sid)}" title="Jump to its terminal">${ICON.jump}</button>
            <span title="${esc(canSend ? (open ? "Hide the message box" : "Message this session") : why)}"><button class="icon ${open ? "on" : ""}" data-action="toggle-msg" data-session="${esc(sid)}" ${canSend ? "" : "disabled"}>${ICON.message}</button></span>
          </div>
        </div>
        ${s.lastText ? `<div class="last">${esc(s.lastText)}</div>` : ""}
        ${open ? `<div class="send">
          <textarea data-key="msg:${esc(sid)}" data-session="${esc(sid)}"
            placeholder="${busy ? "Busy — your message will queue" : "Message — Enter to send"}">${esc(draft("msg:" + sid))}</textarea>
          <button class="btn small primary" data-action="send" data-session="${esc(sid)}">Send</button>
        </div>` : ""}
      </div>
    </div>`;
  };
  if (ui.sgroupBy !== "project") return ui.sessions.map(card).join("");
  // By project: same order as the Tasks column (active first if ticked), "No project" last.
  const names = projectNames();
  let order = [...names];
  const activity = Object.fromEntries(order.map((n) => [n, projectActivity(n)]));
  if (ui.activeFirst) order = order.slice().sort((x, y) => (activity[y] || 0) - (activity[x] || 0));
  const byProject = (n) => ui.sessions.filter((x) => sessionProject(x) === n);
  const extra = [...new Set(ui.sessions.map(sessionProject).filter((n) => n && !names.includes(n)))];
  let html = "";
  for (const name of [...order, ...extra, ""]) {
    const group = byProject(name);
    if (!group.length) continue;
    const key = name || "(none)";
    const shut = ui.scollapsed.has(key);
    html += `<div class="group-title proj" data-action="scollapse" data-key="${esc(key)}" title="Click to ${shut ? "expand" : "collapse"}">
      <span class="caret ${shut ? "" : "open"}"><svg viewBox="0 0 16 16"><path d="M6 3.5 10.5 8 6 12.5"/></svg></span>${esc(name || "No project")}
      <span class="meta">${group.length}</span></div>`;
    if (!shut) html += group.map(card).join("");
  }
  return html;
}

// A session's project: its task's project if bound, else the project owning its directory.
function sessionProject(s) {
  const t = s.task && taskById(s.task);
  if (t && t.project) return t.project;
  const cwd = (s.cwd || "").replace(/\/+$/, "");
  let best = "", depth = -1;
  for (const pr of projects()) {
    for (const raw of pr.paths) {
      const p = raw.replace(/\/+$/, "");
      if ((cwd === p || cwd.startsWith(p + "/")) && p.length > depth) { best = pr.name; depth = p.length; }
    }
  }
  return best;
}

function renderNewTask() {
  const dirs = [...new Set(ui.sessions.map((s) => s.cwd).concat(...tasks().map((t) => list(t.workdirs))).filter(Boolean))].sort();
  const cats = categories();
  const dflt = cats.includes("other") ? "other" : cats[0];
  return `<div class="card">
    <div class="field"><label>title</label><input id="nt-title" placeholder="What is this task?"></div>
    <div class="field"><label>project</label><select id="nt-proj"><option value="">(auto from the workdir)</option>${projectNames().map((c) =>
      `<option value="${esc(c)}">${esc(c)}</option>`).join("")}</select></div>
    <div class="field"><label>category</label><select id="nt-cat"><option value="">(none)</option>${cats.map((c) =>
      `<option value="${esc(c)}" ${c === dflt ? "selected" : ""}>${esc(c)}</option>`).join("")}</select></div>
    <div class="field"><label>workdir</label><input id="nt-dir" list="nt-dirs" placeholder="optional — type a path or pick one; binding a session adds its directory">
      <datalist id="nt-dirs">${dirs.map((d) => `<option value="${esc(d)}">`).join("")}</datalist></div>
    <div class="field"><label>bind session</label><select id="nt-session"><option value="">—</option>
      ${ui.sessions.filter((s) => !s.task).map((s) => `<option value="${esc(s.sessionId)}">${esc(s.title || s.project)}</option>`).join("")}</select></div>
    <div class="row" style="justify-content:flex-end"><button class="btn ghost" data-action="cancel-new">Cancel</button>
      <button class="btn primary" data-action="create">Create</button></div>
  </div>`;
}

function renderProjects() {
  const ps = projects();
  const dirs = [...new Set(ui.sessions.map((s) => s.cwd).concat(...tasks().map((t) => list(t.workdirs))).filter(Boolean))].sort();
  const unassigned = tasks().filter((t) => !t.project).length;
  const rows = ps.map((pr) => {
    const n = tasks().filter((t) => t.project === pr.name).length;
    if (ui.projRemove[pr.name]) {
      const key = "projto:" + pr.name;
      return `<div class="cat-row removing"><span>Move the ${n} task${n === 1 ? "" : "s"} in <b>${esc(pr.name)}</b> to</span>
        <select class="bind" data-key="${esc(key)}"><option value="">(no project)</option>
          ${ps.filter((x) => x.name !== pr.name).map((x) => `<option value="${esc(x.name)}" ${ui.drafts[key] === x.name ? "selected" : ""}>${esc(x.name)}</option>`).join("")}</select>
        <button class="btn small res-drop" data-action="proj-remove-confirm" data-p="${esc(pr.name)}">Move &amp; remove</button>
        <button class="btn small ghost" data-action="proj-remove-cancel" data-p="${esc(pr.name)}">Cancel</button></div>`;
    }
    const nk = "projname:" + pr.name;
    const dirty = ui.drafts[nk] !== undefined && ui.drafts[nk] !== pr.name;
    return `<div class="proj-row" draggable="true" data-drag-project="${esc(pr.name)}">
      <div class="row nowrap">
        <span class="grip" title="Drag to reorder">⠿</span>
        <input class="note" data-key="${esc(nk)}" value="${esc(ui.drafts[nk] ?? pr.name)}" title="Edit to rename (tasks are updated)">
        ${dirty ? `<button class="btn small primary" data-action="proj-rename" data-p="${esc(pr.name)}">Save</button>` : ""}
        <span class="meta">${n} task${n === 1 ? "" : "s"}</span>
        <button class="icon" title="Remove this project" data-action="proj-remove" data-p="${esc(pr.name)}">✕</button>
      </div>
      <div class="proj-paths">${pr.paths.map((x) => `<div class="res-i"><span class="meta">${esc(x)}</span>
          <button class="icon" title="Remove this directory" data-action="proj-path-remove" data-p="${esc(pr.name)}" data-path="${esc(x)}">✕</button></div>`).join("")
        || `<div class="meta">No directory — tasks are only assigned by hand.</div>`}
        ${ui.adding.has(pr.name + ":proj") ? `<div class="row nowrap"><input class="note" list="proj-dirs" data-key="${esc("projpath:" + pr.name)}" placeholder="a directory whose tasks belong here" value="${esc(draft("projpath:" + pr.name))}">
          <button class="btn small" data-action="proj-path-add" data-p="${esc(pr.name)}">Add</button></div>`
          : `<button class="btn small ghost" data-action="toggle-add" data-what="proj" data-task="${esc(pr.name)}" title="Add a directory">+ directory</button>`}</div>
    </div>`;
  }).join("");
  return `<div class="card">
    <div class="row"><b>Projects</b><span class="meta">a task's directory picks its project · drag ⠿ to reorder</span>
      <span style="flex:1"></span><button class="btn small" data-action="close-projects">Done</button></div>
    <datalist id="proj-dirs">${dirs.map((x) => `<option value="${esc(x)}">`).join("")}</datalist>
    ${rows || `<div class="empty">No projects yet.</div>`}
    <div class="proj-row"><div class="row nowrap">
      <input class="note" data-key="projnew" placeholder="new project name" value="${esc(draft("projnew"))}">
      <input class="note" list="proj-dirs" data-key="projnewpath" placeholder="its directory (optional)" value="${esc(draft("projnewpath"))}">
      <button class="btn small primary" data-action="proj-add">Add</button></div></div>
    ${unassigned ? `<div class="row" style="margin-top:6px"><span class="meta">${unassigned} task(s) have no project.</span>
      <button class="btn small" data-action="proj-auto">Assign by directory</button></div>` : ""}
  </div>`;
}

function categoryCount(name) { return tasks().filter((t) => (t.category || "") === name).length; }

function renderCategories() {
  const cats = categories();
  const used = [...new Set(tasks().map((t) => t.category).filter((c) => c && !cats.includes(c)))];
  const rows = cats.map((c) => {
    const n = categoryCount(c);
    if (ui.catRemove[c]) {
      const key = "catto:" + c;
      const others = cats.filter((x) => x !== c);
      return `<div class="cat-row removing">
        <span>Move the ${n} task${n === 1 ? "" : "s"} in <b>${esc(c)}</b> to</span>
        <select class="bind" data-key="${esc(key)}">
          <option value="" ${!ui.drafts[key] ? "selected" : ""}>(none)</option>
          ${others.map((x) => `<option value="${esc(x)}" ${ui.drafts[key] === x ? "selected" : ""}>${esc(x)}</option>`).join("")}
        </select>
        <button class="btn small res-drop" data-action="cat-remove-confirm" data-cat="${esc(c)}">Move &amp; remove</button>
        <button class="btn small ghost" data-action="cat-remove-cancel" data-cat="${esc(c)}">Cancel</button>
      </div>`;
    }
    return `<div class="cat-row">
      <input class="note" data-key="catname:${esc(c)}" data-enter="renamecat" data-cat="${esc(c)}" value="${esc(ui.drafts["catname:" + c] ?? c)}" title="Edit and press Enter to rename (tasks are updated)">
      <span class="meta">${n} task${n === 1 ? "" : "s"}</span>
      <button class="btn small ghost" data-action="cat-remove" data-cat="${esc(c)}" title="Remove this category">✕</button>
    </div>`;
  }).join("");
  const unlisted = used.map((c) => `<div class="cat-row"><span class="chip">${esc(c)}</span>
      <span class="meta">on ${categoryCount(c)} card(s) but not in the list</span>
      <button class="btn small" data-action="cat-adopt" data-cat="${esc(c)}">Add to list</button></div>`).join("");
  return `<div class="card">
    <div class="row"><b>Categories</b><span class="meta">this board's list, saved in hq.json</span>
      <span style="flex:1"></span><button class="btn small" data-action="close-cats">Done</button></div>
    <div class="meta" style="margin:4px 0 8px">Rename: edit a name and press Enter — every task using it is updated.
      Removing a category that tasks use asks where to move them.</div>
    ${rows || `<div class="empty">No categories yet.</div>`}
    ${unlisted}
    <div class="cat-row"><input class="note" data-key="catnew" data-enter="addcat" placeholder="new category — Enter to add" value="${esc(draft("catnew"))}"></div>
  </div>`;
}

// ------------------------------------------------------------------ peek window
// A session's recent conversation in a large overlay: select and copy freely,
// click links and file paths. Click outside or press Esc to close.
async function act2(op, args) {
  try {
    const r = await api(op, args);
    if (r && r.revealed) toast("Shown in Finder (not opened: it could run code)");
  } catch (e) { toast(String(e.message || e), true); }
}
async function copyText(text, msg) {
  try { await api("copy", { text }); toast(msg); } catch (e) { toast(String(e.message || e), true); }
}

async function openPeek(sid, back) {
  const s = ui.sessions.find((x) => x.sessionId === sid || x.sessionId.startsWith(sid));
  ui.modal = { type: "peek", sid: s ? s.sessionId : sid, title: (s && (s.title || s.project)) || sid.slice(0, 8),
               project: s ? s.project : "", cwd: s ? s.cwd : "", live: Boolean(s), msgs: null, sig: "", back: back || null };
  drawPeek(true);
  await refreshPeek(true);
}
function closePeek() {
  ui.modal = null;
  $("#modal").hidden = true;
  $("#modal").innerHTML = "";
}
async function refreshPeek(first) {
  const m = ui.modal;
  if (!m) return;
  let msgs;
  try { msgs = await apiJSON("peek", { session: m.sid }); } catch (e) { return toast(String(e.message || e), true); }
  if (ui.modal !== m) return;
  if (msgs && !Array.isArray(msgs)) {          // --meta form: also says who the session is
    if (!m.live) { m.title = msgs.title || m.title; m.cwd = msgs.cwd || m.cwd;
                   m.project = m.project || (msgs.cwd || "").split("/").pop(); }
    m.found = msgs.found;
    msgs = msgs.messages || [];
  }
  const sig = JSON.stringify(msgs);
  if (sig === m.sig) return;
  // Never rebuild under a selection the user is making or about to copy.
  const sel = window.getSelection();
  if (!first && sel && !sel.isCollapsed && $("#modal").contains(sel.anchorNode)) return;
  m.msgs = msgs;
  m.sig = sig;
  drawPeek(first);
}
function drawPeek(toBottom) {
  const m = ui.modal;
  const box = $("#modal");
  const body = box.querySelector(".peek-body");
  const atBottom = !body || body.scrollHeight - body.scrollTop - body.clientHeight < 12;
  const s = ui.sessions.find((x) => x.sessionId === m.sid) || {};
  const canSend = m.live && Boolean(SENDABLE[s.terminal && s.terminal.kind]);
  const noSend = !m.live ? "This session has ended — history only" : "Not supported in this terminal";
  const msgs = m.msgs;
  const list = msgs === null ? `<div class="empty">Loading…</div>`
    : !msgs.length ? `<div class="empty">${m.found === false ? "No transcript found for this session on this machine." : "No messages yet."}</div>`
    : msgs.map((x, i) => `<div class="pmsg ${x.role}">
        <div class="pwho">${x.role === "user" ? "You" : "Claude"} · ${ago(x.ts)}
          <button class="btn small ghost" data-action="copy-msg" data-i="${i}" title="Copy this message">Copy</button></div>
        <div class="md">${markdown(x.text)}</div>
      </div>`).join("");
  const keepDraft = box.querySelector("textarea") ? null : draft("msg:" + m.sid);
  box.innerHTML = `<div class="panel" role="dialog" aria-label="Conversation">
    <div class="phead">
      ${m.back ? `<button class="btn small ghost" data-action="modal-back" title="Back">←</button>` : ""}
      <div><div class="stitle">${esc(m.title)}${m.live ? "" : ` <span class="chip">ended</span>`}</div><div class="meta">${esc(m.project || "")} · last ${msgs ? msgs.length : "…"} messages · click outside or Esc to close</div></div>
      <span style="flex:1"></span>
      <button class="btn small" data-action="copy-all">Copy all</button>
      ${m.live ? `<button class="btn small" data-action="jump" data-session="${esc(m.sid)}">Jump</button>` : ""}
      <button class="btn small ghost" data-action="close-modal" title="Close (Esc)">✕</button>
    </div>
    <div class="peek-body">${list}</div>
    <div class="send pfoot ${canSend ? "" : "disabled"}" title="${canSend ? "" : !m.live ? "This session has ended." : "Messaging isn't supported for this session's terminal yet — use Jump."}">
      <textarea data-key="msg:${esc(m.sid)}" data-session="${esc(m.sid)}" ${canSend ? "" : "disabled"}
        placeholder="${canSend ? "Reply to this session — Enter to send" : noSend}">${esc(keepDraft ?? draft("msg:" + m.sid))}</textarea>
      <button class="btn small primary" data-action="send" data-session="${esc(m.sid)}" ${canSend ? "" : "disabled"}>Send</button>
    </div>
  </div>`;
  box.hidden = false;
  const nb = box.querySelector(".peek-body");
  if (toBottom || atBottom) nb.scrollTop = nb.scrollHeight;
}
document.addEventListener("mousedown", (ev) => {
  // Backdrop only: a drag that starts inside the panel (selecting text) must not close it.
  if (ui.modal && ev.target === $("#modal")) closePeek();
});

// ------------------------------------------------------------------ context window
// What an ask / todo / "waiting on you" item is about, and where to go next:
// the reply that raised it, the task card, and the sessions that worked on it.
function openContext(kind, ref) {
  ui.modal = { type: "context", kind, task: ref.task, id: ref.id, i: ref.i };
  drawContext();
}
function drawContext() {
  const m = ui.modal;
  const t = taskById(m.task);
  const box = $("#modal");
  if (!t) { closePeek(); return toast("That task is gone", true); }
  const ask = m.kind === "ask" ? (t.asks || []).find((a) => a.id === m.id) : null;
  const todo = m.kind === "todo" ? t.todos.find((x) => x.i === m.i) : null;
  const heading = m.kind === "ask" ? `Ask ${esc(m.id)}` : "Your todo";
  const text = ask ? ask.text : todo ? todo.text : t.waiting_on_me;
  const live = ui.sessions.filter((s) => s.task === t.id);
  const liveIds = new Set(live.map((s) => s.sessionId.slice(0, 8)));
  const past = list(t.sessions).filter((p) => !liveIds.has(String(p).slice(0, 8)));
  const askSession = ask && ask.session ? ui.sessions.find((s) => s.sessionId === ask.session) : null;
  const sessBtn = (sid, label, isLive) =>
    `<button class="btn small" data-action="ctx-peek" data-session="${esc(sid)}">${label}</button>` +
    (isLive ? ` <button class="btn small ghost" data-action="jump" data-session="${esc(sid)}">Jump</button>` : "");
  const origin = !ask ? "" : `<section class="ctx-sec">
      <h4>Where it came from</h4>
      <div class="meta">Raised ${ago(ask.ts)}${ask.session ? ` in ${askSession ? `<b>${esc(askSession.title || askSession.project)}</b> (live)` : `session ${esc(ask.session.slice(0, 8))} (ended)`}` : ""}</div>
      ${ask.session ? `<div class="row" style="margin:6px 0">${sessBtn(ask.session, "Open that conversation", Boolean(askSession))}</div>` : ""}
      ${ask.context ? `<div class="md quote">${markdown(ask.context)}</div>`
        : `<div class="empty">The reply that asked this wasn't recorded (asks from before this was added) — open the conversation above.</div>`}
    </section>`;
  box.innerHTML = `<div class="panel" role="dialog" aria-label="Context">
    <div class="phead">
      <div><div class="meta">${heading} · <span class="chip link" data-action="ctx-goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div>
        <div class="stitle ctx-title">${esc(text || "")}</div></div>
      <span style="flex:1"></span>
      <button class="btn small" data-action="ctx-goto" data-task="${esc(t.id)}">Show task</button>
      <button class="btn small" data-action="open" data-path="${esc(t.path)}">Open card</button>
      <button class="btn small ghost" data-action="close-modal" title="Close (Esc)">✕</button>
    </div>
    <div class="peek-body">
      ${origin}
      <section class="ctx-sec">
        <h4>Task</h4>
        <div class="meta">${esc(LABEL[t.status] || t.status)} · ${esc(t.category || "no category")} · updated ${t.age_days ?? "?"}d ago</div>
        ${t.next ? `<div style="margin-top:4px">Next: ${inline(t.next)}</div>` : ""}
        ${t.waiting_on_me ? `<div style="color:var(--amber)">Waiting on you: ${inline(t.waiting_on_me)}</div>` : ""}
      </section>
      <section class="ctx-sec">
        <h4>Sessions on this task</h4>
        ${live.map((s) => `<div class="row ctx-s"><span class="dot ${esc(s.state || "")}"></span><span>${esc(s.title || s.project)}</span><span class="meta">${esc(s.state || "")}</span>${sessBtn(s.sessionId, "Conversation", true)}</div>`).join("")}
        ${past.map((p) => `<div class="row ctx-s"><span class="dot"></span><span class="meta">session ${esc(String(p).slice(0, 8))} · ended</span>${sessBtn(String(p), "History", false)}</div>`).join("")}
        ${!live.length && !past.length ? `<div class="empty">No session has been bound to this task yet.</div>` : ""}
      </section>
      <section class="ctx-sec">
        <h4>Task card</h4>
        <div class="md">${markdown(t.body || "")}</div>
      </section>
    </div>
  </div>`;
  box.hidden = false;
}

// ------------------------------------------------------------------ markdown
// Small and safe: everything is escaped first; only these constructs become markup.
const FILE_EXT = "md|markdown|html?|txt|log|jsonl|json|ya?ml|toml|csv|tsv|xml|pdf|png|jpe?g|gif|svg|webp|" +
  "py|sh|swift|js|mjs|ts|tsx|jsx|css|go|java|kt|c|h|cc|cpp|hpp|rs|rb|sql|ipynb|conf|ini|env|patch|diff";
// A file with a known extension (optionally :line[:col]), or an absolute / ~ path of 2+ parts.
const PATH_BODY =
  "(?:~|\\.{1,2})?\\/?(?:[\\w.@+-]+\\/)*[\\w@+-][\\w.@+-]*\\.(?:" + FILE_EXT + ")(?![\\w])(?::\\d+(?::\\d+)?)?" +
  "|(?:~|\\/)(?:[\\w.@+-]+\\/)+[\\w.@+-]*";
const PATH_RE = new RegExp("(^|[\\s(（\\[\"'“‘:：,，])(" + PATH_BODY + ")", "g");
const PATH_WHOLE = new RegExp("^(?:" + PATH_BODY + ")$");
const URL_RE = /\bhttps?:\/\/[^\s<>"'）)\]]+/g;
const looksLikePath = (s) => PATH_WHOLE.test(s.trim());

function inline(text) {
  const keep = [];
  const hold = (html) => `\u0000${keep.push(html) - 1}\u0000`;
  let s = String(text);
  // inline code first; a path inside backticks is still clickable
  s = s.replace(/`([^`\n]+)`/g, (_, c) => hold(looksLikePath(c)
    ? `<code><a href="#" data-action="link" data-path="${esc(c.trim())}">${esc(c)}</a></code>`
    : `<code>${esc(c)}</code>`));
  s = s.replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/g, (_, t, u) =>
    hold(`<a href="#" data-action="link" data-url="${esc(u)}">${esc(t)}</a>`));
  s = s.replace(URL_RE, (u) => {
    const trail = (u.match(/[.,;:!?]+$/) || [""])[0];
    const url = trail ? u.slice(0, -trail.length) : u;
    return hold(`<a href="#" data-action="link" data-url="${esc(url)}">${esc(url)}</a>`) + trail;
  });
  s = s.replace(PATH_RE, (all, pre, p) => {
    const trail = (p.match(/[.,;:!?]+$/) || [""])[0];
    const path = trail ? p.slice(0, -trail.length) : p;
    if (!path || path === "/" || /^\.+$/.test(path)) return all;
    return pre + hold(`<a href="#" class="path" data-action="link" data-path="${esc(path)}">${esc(path)}</a>`) + trail;
  });
  s = esc(s).replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => keep[Number(i)]);
}

function markdown(text) {
  const out = [];
  const parts = String(text).split(/^```/m);
  parts.forEach((part, idx) => {
    if (idx % 2 === 1) {                       // fenced code: drop the language tag line
      const nl = part.indexOf("\n");
      const code = nl >= 0 && !/\s/.test(part.slice(0, nl).trim()) ? part.slice(nl + 1) : part;
      out.push(`<pre><code>${esc(code.replace(/\n$/, ""))}</code></pre>`);
      return;
    }
    let list = null, para = [];
    const flushPara = () => { if (para.length) { out.push(`<p>${para.map(inline).join("<br>")}</p>`); para = []; } };
    const flushList = () => { if (list) { out.push(`<${list.tag}>${list.items.join("")}</${list.tag}>`); list = null; } };
    for (const raw of part.split("\n")) {
      const line = raw.replace(/\s+$/, "");
      let m;
      if (!line.trim()) { flushPara(); flushList(); continue; }
      if ((m = line.match(/^(#{1,6})\s+(.*)$/))) { flushPara(); flushList(); out.push(`<h4>${inline(m[2])}</h4>`); continue; }
      if (/^\s*\|.*\|\s*$/.test(line)) {
        flushPara(); flushList();
        if (/^\s*\|[\s:|-]+\|\s*$/.test(line)) continue;  // separator row
        const cells = line.trim().slice(1, -1).split("|").map((c) => `<td>${inline(c.trim())}</td>`).join("");
        const last = out[out.length - 1];
        if (last && last.startsWith("<table>")) out[out.length - 1] = last.replace("</table>", `<tr>${cells}</tr></table>`);
        else out.push(`<table><tr>${cells}</tr></table>`);
        continue;
      }
      if ((m = line.match(/^(\s*)([-*]|\d+[.)])\s+(.*)$/))) {
        flushPara();
        const tag = /\d/.test(m[2]) ? "ol" : "ul";
        if (!list || list.tag !== tag) { flushList(); list = { tag, items: [] }; }
        const box = m[3].match(/^\[([ xX-])\]\s+(.*)$/);   // task-list items
        const body = box ? `<span class="tick">${{ " ": "☐", x: "☑", X: "☑", "-": "⊟" }[box[1]]}</span> ${inline(box[2])}` : inline(m[3]);
        list.items.push(`<li${m[1].length >= 2 ? ' class="sub"' : ""}${box ? ' class="task-li"' : ""}>${body}</li>`);
        continue;
      }
      if ((m = line.match(/^>\s?(.*)$/))) { flushPara(); flushList(); out.push(`<blockquote>${inline(m[1])}</blockquote>`); continue; }
      flushList();
      para.push(line);
    }
    flushPara(); flushList();
  });
  return out.join("");
}

// Bring a task into view in the middle column, whatever hides it: closed status, a search
// filter that does not match, or a folded project group.
function revealTask(id) {
  const t = taskById(id);
  if (!t) return toast(`${id} not found`, true);
  if (!isOpen(t)) ui.showClosed = $("#show-closed").checked = true;
  const f = ui.filter.toLowerCase();
  if (f && !`${t.id} ${t.title} ${list(t.refs).join(" ")} ${t.category} ${t.project || ""}`.toLowerCase().includes(f)) {
    ui.filter = $("#search").value = "";
  }
  if (ui.groupBy === "project") {
    ui.collapsed.delete(t.project || "(none)");
    savePref("hq-collapsed", JSON.stringify([...ui.collapsed]));
  }
  ui.expanded.add(id);
  render();
  const node = document.getElementById("task-" + id);
  if (node) {
    node.scrollIntoView({ behavior: "smooth", block: "start" });
    node.classList.add("flash");
    setTimeout(() => node.classList.remove("flash"), 1200);
  }
}

// ------------------------------------------------------------------ actions
async function send(sid) {
  const key = "msg:" + sid;
  const text = (ui.drafts[key] || "").trim();
  if (!text) return;
  try {
    await api("send", { session: sid, text });
    delete ui.drafts[key];
    toast("Sent");
  } catch (e) {
    toast(String(e.message || e), true);
  }
  setTimeout(refresh, 1200);
  render();
}

async function saveField(el) {
  const k = el.dataset.key;
  if (!(k in ui.drafts)) return;
  const t = taskById(el.dataset.task);
  if (t && (t[el.dataset.field] || "") === ui.drafts[k]) { delete ui.drafts[k]; return; }
  const v = ui.drafts[k];
  delete ui.drafts[k];
  await act("set", { task: el.dataset.task, fields: [`${el.dataset.field}=${v}`] }, "Saved");
}

document.addEventListener("click", async (ev) => {
  const el = ev.target.closest("[data-action]");
  if (!el || el.tagName === "SELECT") return;
  const d = el.dataset;
  switch (d.action) {
    case "resolve": {
      const note = ui.drafts["note:" + d.id] || "";
      delete ui.drafts["note:" + d.id];
      try {
        await api("resolve", { id: d.id, resolution: d.res, note });
        toast(`${d.id} → ${d.res}`, false, async () => {
          ui.drafts["note:" + d.id] = note;
          await act("reopen", { id: d.id }, `${d.id} reopened`);
        });
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "todo": return changeTodo(d.task, Number(d.i), d.state, d.from, d.text || "");
    case "undo-todo": return undoTodo(d.task, Number(d.i));
    case "undo-toast": {
      const fn = ui.undoFn;
      ui.undoFn = null;
      $("#toast").hidden = true;
      return fn && fn();
    }
    case "clear-waiting": {
      const prev = (taskById(d.task) || {}).waiting_on_me || "";
      try {
        await api("set", { task: d.task, fields: ["waiting_on_me="] });
        toast("Marked handled", false, () => act("set", { task: d.task, fields: [`waiting_on_me=${prev}`] }, "Undone"));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "expand":
      ui.expanded.has(d.task) ? ui.expanded.delete(d.task) : ui.expanded.add(d.task);
      return render();
    case "goto": return revealTask(d.task);
    case "jump": return act("jump", { session: d.session });
    case "unbind": return act("unbind", { session: d.session }, "Unbound");
    case "open": return act("open", { path: d.path });
    case "send": return send(d.session);
    case "peek": return openPeek(d.session);
    case "toggle-msg": {
      if (ui.msgOpen.has(d.session)) { ui.msgOpen.delete(d.session); delete ui.drafts["msg:" + d.session]; return render(); }
      ui.msgOpen.add(d.session);
      render();
      const ta = document.querySelector(`textarea[data-key="msg:${CSS.escape(d.session)}"]`);
      if (ta) ta.focus();
      return;
    }
    case "ctx": return openContext(d.kind, { task: d.task, id: d.id, i: Number(d.i) });
    case "ctx-peek": return openPeek(d.session, ui.modal);
    case "modal-back": {
      const back = ui.modal && ui.modal.back;
      if (!back) return closePeek();
      ui.modal = back;
      return back.type === "context" ? drawContext() : drawPeek(true);
    }
    case "ctx-goto": closePeek(); return revealTask(d.task);
    case "close-modal": return closePeek();
    case "copy-msg": {
      const m = ui.modal && ui.modal.msgs[Number(d.i)];
      if (m) await copyText(m.text, "Message copied");
      return;
    }
    case "copy-all":
      if (ui.modal) await copyText(ui.modal.msgs.map((m) => `${m.role === "user" ? "You" : "Claude"}:\n${m.text}`).join("\n\n"), "Conversation copied");
      return;
    case "link":
      ev.preventDefault();
      if (d.url) return act2("openURL", { url: d.url });
      if (d.path) return act2("openPath", { path: d.path, cwd: (ui.modal && ui.modal.cwd) || "" });
      return;
    case "toggle-add": {
      const key = `${d.task}:${d.what}`;
      ui.adding.has(key) ? ui.adding.delete(key) : ui.adding.add(key);
      render();
      const focus = { todo: "addtodo", log: "log" }[d.what];
      const el = focus && document.querySelector(`[data-key="${CSS.escape(focus + ":" + d.task)}"]`);
      if (el) el.focus();
      return;
    }
    case "save-field": {
      const key = `${d.field}:${d.task}`;
      const v = ui.drafts[key] ?? "";
      delete ui.drafts[key];
      return act("set", { task: d.task, fields: [`${d.field}=${v}`] }, "Saved");
    }
    case "cancel-field": delete ui.drafts[`${d.field}:${d.task}`]; return render();
    case "add-todo": {
      const key = "addtodo:" + d.task;
      const text = (ui.drafts[key] || "").trim();
      if (!text) return;
      delete ui.drafts[key];
      return act("addtodo", { task: d.task, text }, "Todo added");
    }
    case "bind-pick": {
      const sid = ui.drafts["bindpick:" + d.task];
      if (!sid) return toast("Choose a session first", true);
      delete ui.drafts["bindpick:" + d.task];
      ui.adding.delete(`${d.task}:bind`);
      return act("bind", { task: d.task, session: sid }, "Bound — the session learns the task on its next message");
    }
    case "add-log": {
      const key = "log:" + d.task;
      const text = (ui.drafts[key] || "").trim().replace(/\s*\n+\s*/g, " ");
      if (!text) return;
      delete ui.drafts[key];
      ui.adding.delete(`${d.task}:log`);
      return act("log", { task: d.task, message: text }, "Note saved");
    }
    case "done-toggle": ui.doneOpen.has(d.task) ? ui.doneOpen.delete(d.task) : ui.doneOpen.add(d.task); return render();
    case "log-all": ui.logAll.has(d.task) ? ui.logAll.delete(d.task) : ui.logAll.add(d.task); return render();
    case "toggle-res": ui.resOpen.has(d.task) ? ui.resOpen.delete(d.task) : ui.resOpen.add(d.task); return render();
    case "add-ref": {
      const key = "addref:" + d.task;
      const text = (ui.drafts[key] || "").trim();
      if (!text) return;
      delete ui.drafts[key];
      return act("ref", { action: "add", task: d.task, ref: text }, "Added");
    }
    case "ref-remove": {
      const ref = d.ref;
      try {
        await api("ref", { action: "remove", task: d.task, ref });
        toast("Removed", false, () => act("ref", { action: "add", task: d.task, ref }, "Restored"));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "sgroup-by": ui.sgroupBy = d.g; savePref("hq-sgroupby", d.g); return render();
    case "scollapse":
      ui.scollapsed.has(d.key) ? ui.scollapsed.delete(d.key) : ui.scollapsed.add(d.key);
      savePref("hq-scollapsed", JSON.stringify([...ui.scollapsed]));
      return render();
    case "fold-all": {
      if (ui.groupBy === "project") {
        const keys = [...new Set(tasks().map((t) => t.project || "(none)"))];
        const anyOpen = keys.some((k) => !ui.collapsed.has(k));
        ui.collapsed = new Set(anyOpen ? keys : []);
        if (anyOpen) ui.expanded.clear();
        savePref("hq-collapsed", JSON.stringify([...ui.collapsed]));
      } else {
        ui.expanded.clear();
      }
      return render();
    }
    case "group-by": ui.groupBy = d.g; savePref("hq-groupby", d.g); return render();
    case "collapse":
      ui.collapsed.has(d.key) ? ui.collapsed.delete(d.key) : ui.collapsed.add(d.key);
      savePref("hq-collapsed", JSON.stringify([...ui.collapsed]));
      return render();
    case "open-projects": ui.projOpen = !ui.projOpen; return render();
    case "close-projects": ui.projOpen = false; ui.projRemove = {}; return render();
    case "proj-rename": {
      const v = (ui.drafts["projname:" + d.p] || "").trim();
      delete ui.drafts["projname:" + d.p];
      if (!v || v === d.p) return render();
      return act("project", { action: "rename", names: [d.p, v] }, `Renamed ${d.p} → ${v}`);
    }
    case "proj-path-remove": {
      const pr = projects().find((x) => x.name === d.p);
      return act("project", { action: "paths", names: [d.p, ...pr.paths.filter((x) => x !== d.path)] }, "Directory removed");
    }
    case "proj-path-add": {
      const v = (ui.drafts["projpath:" + d.p] || "").trim();
      if (!v) return;
      delete ui.drafts["projpath:" + d.p];
      const pr = projects().find((x) => x.name === d.p);
      return act("project", { action: "paths", names: [d.p, ...pr.paths, v] }, "Directory added");
    }
    case "proj-remove": {
      const n = tasks().filter((t) => t.project === d.p).length;
      if (!n) return act("project", { action: "remove", names: [d.p] }, `Removed ${d.p}`);
      ui.projRemove[d.p] = true;
      return render();
    }
    case "proj-remove-cancel": delete ui.projRemove[d.p]; return render();
    case "proj-remove-confirm": {
      const to = ui.drafts["projto:" + d.p] ?? "";
      delete ui.projRemove[d.p];
      return act("project", { action: "remove", names: [d.p], to }, `Removed ${d.p}; tasks moved to ${to || "(no project)"}`);
    }
    case "proj-add": {
      const name = (ui.drafts["projnew"] || "").trim();
      const path = (ui.drafts["projnewpath"] || "").trim();
      if (!name) return toast("Give the project a name", true);
      delete ui.drafts["projnew"]; delete ui.drafts["projnewpath"];
      return act("project", { action: "add", names: [name], paths: path ? [path] : [] }, `Added ${name}`);
    }
    case "proj-auto": return act("project", { action: "auto" }, "Tasks assigned by directory");
    case "open-cats": ui.catsOpen = !ui.catsOpen; return render();
    case "close-cats": ui.catsOpen = false; ui.catRemove = {}; return render();
    case "cat-remove": {
      const n = categoryCount(d.cat);
      if (!n) return act("category", { action: "remove", names: [d.cat] }, `Removed ${d.cat}`);
      ui.catRemove[d.cat] = true;
      return render();
    }
    case "cat-remove-cancel": delete ui.catRemove[d.cat]; return render();
    case "cat-remove-confirm": {
      const to = ui.drafts["catto:" + d.cat] ?? "";
      delete ui.catRemove[d.cat];
      delete ui.drafts["catto:" + d.cat];
      return act("category", { action: "remove", names: [d.cat], to }, `Removed ${d.cat}; tasks moved to ${to || "(none)"}`);
    }
    case "cat-adopt": return act("category", { action: "add", names: [d.cat] }, `Added ${d.cat}`);
    case "cancel-new":
      ui.newTask = false; delete $("#newtask-form").dataset.drawn; return render();
    case "create": {
      const title = $("#nt-title").value.trim();
      if (!title) return toast("Give the task a title", true);
      try {
        const out = await api("new", { title, category: $("#nt-cat").value, workdir: $("#nt-dir").value, project: $("#nt-proj").value });
        const id = String(out).split("\n")[0].trim();
        const sid = $("#nt-session").value;
        if (sid) await api("bind", { task: id, session: sid });
        ui.newTask = false; delete $("#newtask-form").dataset.drawn;
        ui.expanded.add(id);
        toast(`Created ${id}`);
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
  }
});

document.addEventListener("change", (ev) => {
  const el = ev.target;
  const d = el.dataset;
  if (el.tagName === "SELECT" && d.action) el.blur();  // render() holds off while a select has focus
  if (d.action === "set-project") return act("set", { task: d.task, fields: [`project=${el.value}`] }, "Project saved");
  if (d.action === "set-category") return act("set", { task: d.task, fields: [`category=${el.value}`] }, "Category saved");
  if (el.tagName === "SELECT" && d.key) { ui.drafts[d.key] = el.value; el.blur(); return render(); }
  if (d.action === "set-status") return act("set", { task: d.task, fields: [`status=${el.value}`] }, "Status saved");
  if (d.action === "bind" && el.value) return act("bind", { task: d.task, session: el.value }, "Bound — the session learns the task on its next message");
  if (d.action === "bind-session" && el.value) return act("bind", { task: el.value, session: d.session }, "Bound — the session learns the task on its next message");
  if (el.id === "show-closed") { ui.showClosed = el.checked; render(); }
  if (el.id === "activefirst-cb") { ui.activeFirst = el.checked; savePref("hq-activefirst", el.checked ? "1" : "0"); render(); }
});

document.addEventListener("input", (ev) => {
  const el = ev.target;
  if (el.id === "search") { ui.filter = el.value; return render(); }
  if (el.dataset.key) ui.drafts[el.dataset.key] = el.value;
  if (el.dataset.field) render();
  if (el.tagName === "TEXTAREA") { el.style.height = "30px"; el.style.height = Math.min(el.scrollHeight, 120) + "px"; }
});

document.addEventListener("keydown", async (ev) => {
  const el = ev.target;
  if (ev.key === "Escape" && ui.modal) { ev.preventDefault(); return closePeek(); }
  if (ev.key === "Escape" && el.tagName === "TEXTAREA" && el.dataset.session && !(ui.drafts[el.dataset.key] || "").trim()) {
    ui.msgOpen.delete(el.dataset.session); el.blur(); return render();
  }
  if (ev.key !== "Enter" || ev.isComposing) return;  // isComposing: IME (e.g. Pinyin) candidate selection
  if (el.tagName === "TEXTAREA" && el.dataset.session && !ev.shiftKey) { ev.preventDefault(); return send(el.dataset.session); }
  if (el.dataset.field) { ev.preventDefault(); return; }   // fields save with their Save button
  if (el.dataset.enter) {
    ev.preventDefault();
    const text = (ui.drafts[el.dataset.key] || "").trim();
    if (!text) return;
    delete ui.drafts[el.dataset.key];
    if (el.dataset.enter === "log") return act("log", { task: el.dataset.task, message: text }, "Logged");
    if (el.dataset.enter === "addcat") return act("category", { action: "add", names: [text] }, `Added ${text}`);
    if (el.dataset.enter === "renamecat") {
      if (text === el.dataset.cat) return render();
      return act("category", { action: "rename", names: [el.dataset.cat, text] }, `Renamed ${el.dataset.cat} → ${text}`);
    }
    if (el.dataset.enter === "addtodo") return act("addtodo", { task: el.dataset.task, text }, "Todo added");
    if (el.dataset.enter === "addref") return act("ref", { action: "add", task: el.dataset.task, ref: text }, "Added");
  }
});


// ---- reorder projects by dragging a group header (Tasks) or a row (Projects panel).
// Forgiving on purpose: anywhere in the column counts — the nearest header decides the spot —
// and while dragging in the Tasks column every group folds to its header, so the targets sit
// next to each other instead of being pages apart.
function dropZone(ev) { return ev.target.closest && ev.target.closest("#tasks, #projects-panel"); }
function clearDropMarks() { document.querySelectorAll(".drop-before,.drop-after").forEach((n) => n.classList.remove("drop-before", "drop-after")); }
function nearestTarget(zone, y) {
  let best = null, dist = Infinity;
  for (const el of zone.querySelectorAll("[data-drag-project]")) {
    const r = el.getBoundingClientRect();
    if (!r.height) continue;
    const mid = r.top + r.height / 2;
    const d = Math.abs(y - mid);
    if (d < dist) { dist = d; best = { el, before: y < mid }; }
  }
  return best;
}
document.addEventListener("dragstart", (ev) => {
  const el = ev.target.closest && ev.target.closest("[data-drag-project]");
  if (!el || (ev.target.closest && ev.target.closest("input, textarea, select"))) return;
  ui.dragging = el.dataset.dragProject;
  ui.dropAt = null;
  ev.dataTransfer.effectAllowed = "move";
  ev.dataTransfer.setData("text/plain", ui.dragging);
  el.classList.add("dragging");
  // Folding has to wait a tick: changing the source element during dragstart cancels the drag.
  if (el.closest("#tasks")) setTimeout(() => { if (ui.dragging) $("#tasks").classList.add("reordering"); }, 0);
});
document.addEventListener("dragover", (ev) => {
  if (!ui.dragging) return;
  const zone = dropZone(ev);
  if (!zone) return;
  ev.preventDefault();
  ev.dataTransfer.dropEffect = "move";
  const t = nearestTarget(zone, ev.clientY);
  clearDropMarks();
  if (!t || t.el.dataset.dragProject === ui.dragging) { ui.dropAt = null; return; }
  t.el.classList.add(t.before ? "drop-before" : "drop-after");
  ui.dropAt = { name: t.el.dataset.dragProject, before: t.before };
});
document.addEventListener("drop", (ev) => {
  const moving = ui.dragging, at = ui.dropAt;
  if (!moving || !dropZone(ev)) return;
  ev.preventDefault();
  finishDrag();
  if (!at) return;
  const order = projectNames().filter((n) => n !== moving);
  const i = order.indexOf(at.name);
  if (i < 0) return;
  order.splice(at.before ? i : i + 1, 0, moving);
  act("project", { action: "order", names: order },
    ui.activeFirst ? "Order saved — projects with live sessions still come first (Active first)" : "Order saved");
});
function finishDrag() {
  ui.dragging = null;
  ui.dropAt = null;
  clearDropMarks();
  $("#tasks").classList.remove("reordering");
  document.querySelectorAll(".dragging").forEach((n) => n.classList.remove("dragging"));
}
document.addEventListener("dragend", () => { finishDrag(); render(); });

$("#refresh").addEventListener("click", refresh);
$("#new-task").addEventListener("click", () => { ui.newTask = true; render(); const t = $("#nt-title"); if (t) t.focus(); });

refresh();
setInterval(() => { if (document.visibilityState === "visible" && !document.hidden) refresh(); }, 4000);
