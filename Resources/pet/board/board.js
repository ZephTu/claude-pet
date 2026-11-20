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
const CATEGORIES = ["rca", "test-followup", "benchmark", "process", "dev", "side"];

const ui = {
  board: null, sessions: [], expanded: new Set(), peekOpen: new Set(), peeks: {},
  drafts: {}, showClosed: false, filter: "", newTask: false, busy: false,
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
function toast(msg, bad) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = bad ? "bad" : "";
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), bad ? 6000 : 2200);
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
}
window.hqRefresh = refresh;

// ------------------------------------------------------------------ render
function render() {
  // Never yank an open dropdown out from under the pointer.
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
  $("#waiting").innerHTML = renderWaiting();
  $("#newtask-form").hidden = !ui.newTask;
  if (ui.newTask && !$("#newtask-form").dataset.drawn) {
    $("#newtask-form").innerHTML = renderNewTask();
    $("#newtask-form").dataset.drawn = "1";
  }
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
  const waiting = all.filter((t) => t.status === "waiting-on-me").length;
  const activeN = all.filter(isOpen).length;
  $("#counts").innerHTML =
    `<span><b>${asks}</b> asks</span><span><b>${mine}</b> your todos</span>` +
    `<span><b>${waiting}</b> waiting on you</span><span><b>${activeN}</b> open tasks</span>` +
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
      <div class="ask-text">${esc(a.text)}</div>
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
  if (!items.length) return `<h3>Your todos</h3><div class="empty">No open @me todos.</div>`;
  return `<h3>Your todos · ${items.length}</h3><div class="card">` + items.map(([t, x]) => `
    <div class="todo">
      <span class="box" title="Done" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="done"></span>
      <div style="flex:1"><span class="t">${esc(x.text)}</span>
        <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div></div>
      <button class="btn small ghost" title="Won't do" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop">✕</button>
    </div>`).join("") + `</div>`;
}

function renderWaiting() {
  const items = tasks().filter((t) => isOpen(t) && t.waiting_on_me);
  if (!items.length) return "";
  return `<h3>Waiting on you · ${items.length}</h3>` + items.map((t) => `
    <div class="card">
      <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div>
      <div class="ask-text">${esc(t.waiting_on_me)}</div>
      <div class="row"><button class="btn small" data-action="clear-waiting" data-task="${esc(t.id)}">Handled</button></div>
    </div>`).join("");
}

function renderTasks() {
  const f = ui.filter.toLowerCase();
  const visible = tasks().filter((t) => (ui.showClosed || isOpen(t)) &&
    (!f || `${t.id} ${t.title} ${list(t.refs).join(" ")} ${t.category}`.toLowerCase().includes(f)));
  if (!visible.length) return `<div class="empty">No tasks${f ? " match" : ""}.</div>`;
  let html = "";
  for (const st of ORDER) {
    const group = visible.filter((t) => t.status === st)
      .sort((a, b) => String(b.updated).localeCompare(String(a.updated)));
    if (!group.length) continue;
    html += `<div class="group-title">${LABEL[st]} <span class="meta">${group.length}</span></div>`;
    html += group.map(renderTask).join("");
  }
  return html;
}

function renderTask(t) {
  const asks = openAsks(t).length;
  const live = liveFor(t.id).length;
  const open = ui.expanded.has(t.id);
  const sub = t.waiting_on_me ? `<div class="tsub waiting">⮑ ${esc(t.waiting_on_me)}</div>`
    : (t.next && isOpen(t) ? `<div class="tsub">⮑ ${esc(t.next)}</div>` : "");
  return `<div class="task" id="task-${esc(t.id)}">
    <div class="task-head" data-action="expand" data-task="${esc(t.id)}">
      <span class="tid">${esc(t.id)}</span>
      <div class="ttitle">${esc(t.title)}${sub}</div>
      ${asks ? `<span class="badge" title="open asks">${asks}</span>` : ""}
      ${live ? `<span class="badge live" title="live sessions">${live}</span>` : ""}
      <span class="meta">${esc(t.category || "")} · ${t.age_days ?? "?"}d</span>
    </div>
    ${open ? renderTaskBody(t) : ""}
  </div>`;
}

function renderTaskBody(t) {
  const k = (f) => `${f}:${t.id}`;
  const val = (f, v) => (ui.drafts[k(f)] ?? v ?? "");
  const todos = t.todos.length ? t.todos.map((x) => {
    const mark = x.state === "done" ? "✓" : x.state === "dropped" ? "–" : "";
    const next = x.state === "open" ? "done" : x.state === "done" ? "drop" : "open";
    const owner = x.owner ? `<span class="owner ${x.owner === "me" ? "me" : ""}">@${esc(x.owner)}</span>` : "";
    return `<div class="todo ${x.state}">
      <span class="box ${x.state}" title="click: ${next}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="${next}">${mark}</span>
      <span class="t">${owner}${esc(x.text)}</span></div>`;
  }).join("") : `<div class="empty">No todos.</div>`;
  const live = liveFor(t.id);
  const unbound = ui.sessions.filter((s) => s.task !== t.id);
  return `<div class="task-body">
    <div class="field"><label>status</label>
      <select data-action="set-status" data-task="${esc(t.id)}">
        ${ORDER.map((s) => `<option value="${s}" ${s === t.status ? "selected" : ""}>${LABEL[s]}</option>`).join("")}
      </select></div>
    <div class="field"><label>next</label>
      <input data-key="${k("next")}" data-field="next" data-task="${esc(t.id)}" value="${esc(val("next", t.next))}" placeholder="next concrete step — Enter to save"></div>
    <div class="field"><label>waiting on you</label>
      <input data-key="${k("waiting_on_me")}" data-field="waiting_on_me" data-task="${esc(t.id)}" value="${esc(val("waiting_on_me", t.waiting_on_me))}" placeholder="empty = nothing — Enter to save"></div>
    <h3>Todos</h3>${todos}
    <div class="row" style="margin-top:6px">
      <input class="note" data-key="${k("addtodo")}" data-task="${esc(t.id)}" data-enter="addtodo" placeholder="add todo, e.g. @me send reply to …" value="${esc(draft(k("addtodo")))}">
    </div>
    <h3>Sessions</h3>
    ${live.length ? live.map((s) => `<div class="row"><span class="dot ${esc(s.state)}"></span>${esc(s.title || s.project)}
        <button class="btn small ghost" data-action="jump" data-session="${esc(s.sessionId)}">Jump</button>
        <button class="btn small ghost" data-action="unbind" data-session="${esc(s.sessionId)}">Unbind</button></div>`).join("")
      : `<div class="empty">No live session is working on this.</div>`}
    ${unbound.length ? `<div class="row" style="margin-top:4px"><select class="bind" data-action="bind" data-task="${esc(t.id)}">
        <option value="">Bind a live session…</option>
        ${unbound.map((s) => `<option value="${esc(s.sessionId)}">${esc(s.title || s.project)} (${esc(s.project)})</option>`).join("")}
      </select></div>` : ""}
    <h3>Log</h3>
    <div class="row"><input class="note" data-key="${k("log")}" data-task="${esc(t.id)}" data-enter="log" placeholder="add a note to the log — Enter" value="${esc(draft(k("log")))}">
      <button class="btn small" data-action="open" data-path="${esc(t.path)}">Open card</button></div>
    ${list(t.refs).length ? `<div class="meta" style="margin-top:8px">${list(t.refs).map(esc).join(" · ")}</div>` : ""}
  </div>`;
}

function renderSessions() {
  if (!ui.sessions.length) return `<div class="empty">No live Claude Code sessions (Claude Pet sees sessions started after it was installed).</div>`;
  const openTasks = tasks().filter(isOpen);
  return ui.sessions.map((s) => {
    const t = s.task && taskById(s.task);
    const sid = s.sessionId;
    const sorted = openTasks.slice().sort((a, b) =>
      (list(b.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0) -
      (list(a.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0));
    const taskCtl = t
      ? `<span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span><span class="meta">${esc(t.title)}</span>`
      : `<select class="bind" data-action="bind-session" data-session="${esc(sid)}">
           <option value="">Bind to task…</option>
           ${sorted.map((x) => `<option value="${esc(x.id)}">${esc(x.id)} ${esc(x.title)}</option>`).join("")}
         </select>`;
    const busy = s.state === "busy";
    const peek = ui.peekOpen.has(sid)
      ? `<div class="peek" data-sid="${esc(sid)}">${(ui.peeks[sid] || []).map((m) =>
          `<div class="msg ${m.role}"><span class="who">${m.role === "user" ? "you" : "claude"} · ${ago(m.ts)}</span>${esc(m.text)}</div>`).join("") || `<div class="empty">Loading…</div>`}</div>`
      : "";
    return `<div class="card session">
      <span class="dot ${esc(s.state || "")}" title="${esc(s.state || "")}"></span>
      <div class="body">
        <div class="stitle">${esc(s.title || s.project || sid.slice(0, 8))}</div>
        <div class="meta">${esc(s.project || "")} · ${esc(s.state || "?")} · ${ago(s.updatedAt)}${s.waitingOn ? " · waiting: " + esc(s.waitingOn) : ""}</div>
        <div class="row" style="margin-top:4px">${taskCtl}</div>
        ${s.lastText ? `<div class="last">${esc(s.lastText)}</div>` : ""}
        <div class="row">
          <button class="btn small ghost" data-action="peek" data-session="${esc(sid)}">${ui.peekOpen.has(sid) ? "Hide" : "Peek"}</button>
          <button class="btn small ghost" data-action="jump" data-session="${esc(sid)}">Jump</button>
        </div>
        <div class="send">
          <textarea data-key="msg:${esc(sid)}" data-session="${esc(sid)}" placeholder="${busy ? "Busy — your message will queue" : "Message this session — Enter to send"}">${esc(draft("msg:" + sid))}</textarea>
          <button class="btn small primary" data-action="send" data-session="${esc(sid)}">Send</button>
        </div>
        ${peek}
      </div>
    </div>`;
  }).join("");
}

function renderNewTask() {
  const dirs = [...new Set(ui.sessions.map((s) => s.cwd).filter(Boolean))];
  return `<div class="card">
    <div class="field"><label>title</label><input id="nt-title" placeholder="What is this task?"></div>
    <div class="field"><label>category</label><select id="nt-cat">${CATEGORIES.map((c) => `<option>${c}</option>`).join("")}</select></div>
    <div class="field"><label>workdir</label><select id="nt-dir"><option value="">—</option>${dirs.map((d) => `<option>${esc(d)}</option>`).join("")}</select></div>
    <div class="field"><label>bind session</label><select id="nt-session"><option value="">—</option>
      ${ui.sessions.filter((s) => !s.task).map((s) => `<option value="${esc(s.sessionId)}">${esc(s.title || s.project)}</option>`).join("")}</select></div>
    <div class="row" style="justify-content:flex-end"><button class="btn ghost" data-action="cancel-new">Cancel</button>
      <button class="btn primary" data-action="create">Create</button></div>
  </div>`;
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
      return act("resolve", { id: d.id, resolution: d.res, note }, `${d.id} → ${d.res}`);
    }
    case "todo": return act("todo", { task: d.task, index: Number(d.i), state: d.state });
    case "clear-waiting": return act("set", { task: d.task, fields: ["waiting_on_me="] }, "Cleared");
    case "expand":
      ui.expanded.has(d.task) ? ui.expanded.delete(d.task) : ui.expanded.add(d.task);
      return render();
    case "goto": {
      const t = taskById(d.task);
      if (t && !isOpen(t)) ui.showClosed = $("#show-closed").checked = true;
      ui.expanded.add(d.task);
      render();
      const node = document.getElementById("task-" + d.task);
      if (node) node.scrollIntoView({ behavior: "smooth", block: "start" });
      return;
    }
    case "jump": return act("jump", { session: d.session });
    case "unbind": return act("unbind", { session: d.session }, "Unbound");
    case "open": return act("open", { path: d.path });
    case "send": return send(d.session);
    case "peek":
      if (ui.peekOpen.has(d.session)) { ui.peekOpen.delete(d.session); return render(); }
      ui.peekOpen.add(d.session);
      render();
      try { ui.peeks[d.session] = await apiJSON("peek", { session: d.session }); } catch (e) { toast(String(e.message || e), true); }
      return render();
    case "cancel-new":
      ui.newTask = false; delete $("#newtask-form").dataset.drawn; return render();
    case "create": {
      const title = $("#nt-title").value.trim();
      if (!title) return toast("Give the task a title", true);
      try {
        const out = await api("new", { title, category: $("#nt-cat").value, workdir: $("#nt-dir").value });
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
  if (d.action === "set-status") return act("set", { task: d.task, fields: [`status=${el.value}`] }, "Status saved");
  if (d.action === "bind" && el.value) return act("bind", { task: d.task, session: el.value }, "Bound — the session learns the task on its next message");
  if (d.action === "bind-session" && el.value) return act("bind", { task: el.value, session: d.session }, "Bound — the session learns the task on its next message");
  if (el.id === "show-closed") { ui.showClosed = el.checked; render(); }
});

document.addEventListener("input", (ev) => {
  const el = ev.target;
  if (el.id === "search") { ui.filter = el.value; return render(); }
  if (el.dataset.key) ui.drafts[el.dataset.key] = el.value;
  if (el.tagName === "TEXTAREA") { el.style.height = "30px"; el.style.height = Math.min(el.scrollHeight, 120) + "px"; }
});

document.addEventListener("keydown", async (ev) => {
  const el = ev.target;
  if (ev.key !== "Enter" || ev.isComposing) return;  // isComposing: IME (e.g. Pinyin) candidate selection
  if (el.tagName === "TEXTAREA" && el.dataset.session && !ev.shiftKey) { ev.preventDefault(); return send(el.dataset.session); }
  if (el.dataset.field) { ev.preventDefault(); el.blur(); return; }
  if (el.dataset.enter) {
    ev.preventDefault();
    const text = (ui.drafts[el.dataset.key] || "").trim();
    if (!text) return;
    delete ui.drafts[el.dataset.key];
    if (el.dataset.enter === "log") return act("log", { task: el.dataset.task, message: text }, "Logged");
    if (el.dataset.enter === "addtodo") return act("addtodo", { task: el.dataset.task, text }, "Todo added");
  }
});
document.addEventListener("focusout", (ev) => { if (ev.target.dataset && ev.target.dataset.field) saveField(ev.target); });

$("#refresh").addEventListener("click", refresh);
$("#new-task").addEventListener("click", () => { ui.newTask = true; render(); const t = $("#nt-title"); if (t) t.focus(); });

refresh();
setInterval(() => { if (document.visibilityState === "visible" && !document.hidden) refresh(); }, 4000);
