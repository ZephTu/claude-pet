// HQ board. Everything is read from and written through the `hq` CLI via the
// native bridge (BoardWindow.swift); this page holds no state worth keeping.
"use strict";

const ORDER = ["waiting-on-me", "blocked", "active", "done", "abandoned"];
const LABEL = {
  "waiting-on-me": "Waiting on you", blocked: "Blocked", active: "Active",
  done: "Done", abandoned: "Abandoned",
};
// How an ask can be answered. Most asks are "should I?" or "A or B — I suggest A", so Yes ("go
// ahead / as you suggest", or with a note: "my answer is the note") comes first. "Later" keeps the
// ask open and out of sight until tomorrow. "No context" is rare and sits behind ⋯.
const RESOLUTIONS = [
  ["do", "Yes", "Yes — go ahead, or as you suggested. With a note, the note is your answer (\"A+C\", \"run it once\")"],
  ["drop", "No", "No — don't do it. A note can say why, or what instead"],
  ["todo", "To todo", "Something I'll do myself — make it an @me todo on this task and close the ask"],
  ["snooze", "Later", "Not now — keep the question, but hide it until tomorrow: it leaves Needs you and the cat's badge, and the session is told you'll answer later"],
];
const MORE_RESOLUTIONS = [["archive", "No context", "I can't answer this — park it"]];
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
  drafts: {}, showClosed: false, filter: "", newTask: false, busy: false, catsOpen: false, catRemove: {}, modal: null, recent: [], undoFn: null, msgOpen: new Set(), atts: {}, sending: new Set(), resolving: new Set(), picks: {}, autoPicked: new Set(), moreRes: new Set(), showLater: new Set(), handed: {}, handing: new Set(), history: {}, historyLoading: new Set(), histAll: new Set(), adding: new Set(), logAll: new Set(), resOpen: new Set(), projOpen: false, projRemove: {}, doneOpen: new Set(), scan: null, scanPick: new Set(),
  mode: pref("hq-mode", "today"),
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
// For ops whose reply is an object already (launch) — or JSON text, either way.
async function apiObj(op, args) { const r = await api(op, args); return typeof r === "string" ? JSON.parse(r || "{}") : (r || {}); }

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
const FINISHED_SHOWN = 3;
const STALE_DAYS = 3;       // a todo older than this shows its age in amber   // finished todos shown on a task before they fold
const TODO_STATE = { open: "open", done: "done", dropped: "drop", drop: "drop" };
async function changeTodo(task, i, to, from, text) {
  const label = { done: "Done", drop: "Won't do", open: "Reopened" }[to] || to;
  try {
    await api("todo", { task, index: i, state: to, text });
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
  await act("todo", { task, index: i, state: r ? r.from : "open", text: r ? r.text : "" }, "Undone");
}
const tasks = () => (ui.board ? ui.board.tasks : []);
const taskById = (id) => tasks().find((t) => t.id === id);
const isOpen = (t) => ["waiting-on-me", "blocked", "active"].includes(t.status);
// ---- drafts survive the pet quitting: what you typed, the images you added and the answers you
// picked are kept in localStorage (per machine), and put back when the board loads.
const DRAFTS_KEY = "hq-drafts-v1";
(function restoreDrafts() {
  try {
    const d = JSON.parse(localStorage.getItem(DRAFTS_KEY) || "{}");
    Object.assign(ui.drafts, d.drafts || {});
    Object.assign(ui.atts, d.atts || {});
    Object.assign(ui.picks, d.picks || {});
  } catch (e) { /* nothing kept, or storage off */ }
})();
function saveDrafts() {
  clearTimeout(saveDrafts.t);
  saveDrafts.t = setTimeout(() => {
    const drafts = Object.fromEntries(Object.entries(ui.drafts).filter(([, v]) => v !== "" && v != null));
    const atts = Object.fromEntries(Object.entries(ui.atts).filter(([, v]) => v && v.length));
    try { localStorage.setItem(DRAFTS_KEY, JSON.stringify({ drafts, atts, picks: ui.picks })); } catch (e) { /* full or off */ }
  }, 300);
}
// Drop what belonged to asks that are no longer open (answered elsewhere, or reopened then closed).
function pruneDrafts() {
  if (!ui.board) return;
  const open = new Set(tasks().flatMap((t) => pendingAsks(t).map((a) => a.id)));
  const gone = (id) => !open.has(id);
  for (const k of Object.keys(ui.drafts)) { const m = /^(?:note|push):(.+)$/.exec(k); if (m && gone(m[1])) delete ui.drafts[k]; }
  for (const k of Object.keys(ui.atts)) { const m = /^ask:(.+)$/.exec(k); if (m && gone(m[1])) delete ui.atts[k]; }
  for (const id of Object.keys(ui.picks)) if (gone(id)) delete ui.picks[id];
}
window.addEventListener("pagehide", () => { clearTimeout(saveDrafts.t); saveDrafts.t = null; try {
  localStorage.setItem(DRAFTS_KEY, JSON.stringify({ drafts: ui.drafts, atts: ui.atts, picks: ui.picks })); } catch (e) { /* */ } });

// Open asks you are to answer now; ones put off with "Later" stay open but out of sight until
// they come back (snoozed_until, local time), and pendingAsks counts both.
const isLater = (a) => Boolean(a.snoozed_until) && new Date(a.snoozed_until) > new Date();
const pendingAsks = (t) => (t.asks || []).filter((a) => a.state === "open");
const openAsks = (t) => pendingAsks(t).filter((a) => !isLater(a));
const laterAsks = (t) => pendingAsks(t).filter(isLater);
// "2 for later · back tomorrow", and the asks themselves when opened.
function laterLine(t) {
  const later = laterAsks(t);
  if (!later.length) return "";
  const open = ui.showLater.has(t.id);
  return `<button class="btn small ghost later-toggle" data-action="show-later" data-task="${esc(t.id)}"
      title="Questions you put off with Later. They come back by themselves tomorrow; open them to answer now">${open ? "Hide" : `${later.length} for later · back tomorrow`}</button>` +
    (open ? later.map((a) => askCard(t, a)).join("") : "");
}
const liveFor = (id) => ui.sessions.filter((s) => s.task === id);
// The pet's red dot, on the board: this session finished and you haven't looked yet. Peek, Jump or
// a reply (from here or its terminal) clears it, same as in the pet's list.
const newTag = (sid) => (ui.unread && ui.unread[sid]
  ? `<span class="newtag" title="Finished — not looked at yet. Peek, Jump or reply to clear it.">new</span>` : "");
// A session's dot, drawn exactly as in the pet's list (pet.js dotClass — keep the two in step):
// colour says whether it wants you, shape and motion what it is doing. Sessions the pet doesn't
// list (a `claude --bg` one, say) fall back to their plain state.
function dotClass(s) {
  const p = (ui.dots || {})[s.sessionId];
  if (!p) return s.state === "busy" || s.state === "waiting" ? s.state : "idle";
  if (p.quiet) return "quiet";
  if (p.state === "waiting") return p.asks === "permission" ? "waiting approve" : "waiting reply";
  if (p.state === "busy") return p.agent ? "busy agent" : p.struggle ? "busy struggling" : "busy";
  return p.background ? "idle bg" : "idle";
}
const DOT_TIP = { quiet: "Gone quiet — nothing heard for a while", "waiting approve": "Waiting for your approval",
  "waiting reply": "Waiting for your answer", "busy agent": "Waiting on an agent it sent off",
  "busy struggling": "Working — the last several calls failed", busy: "Working", "idle bg": "Turn over — something it started is still running in the background", idle: "Idle" };
// A session's status word, as the pet's list says it (pet.js row status — keep in step): what it
// is running, "1 in background", "Answered"… Sessions the pet doesn't list fall back to the state.
function statusWord(s) {
  const p = (ui.dots || {})[s.sessionId];
  if (!p) return s.state || "?";
  if (p.state === "waiting") return p.asks === "permission" ? "Needs approval" : "Awaiting reply";
  if (p.activity) return p.activity;
  if (p.quiet) return "No recent activity";
  if (p.state === "busy") return "Working";
  if (p.background) return `${p.background} in background`;
  return p.replied ? "Answered" : "Idle";
}
// How much context a session carries, as the pet's list shows it: tokens, and their share of the
// auto-compact window (ContextBudget) — 100% is "about to compact". Amber from two thirds, red from 80%.
function ctxTag(s) {
  const d = (ui.dots || {})[s.sessionId] || {};
  const p = d.context;
  if (p == null) return "";
  const k = (n) => n >= 999500 ? `${Math.round(n / 1e5) / 10}M` : `${Math.round(n / 1000)}k`;
  const tokens = d.contextTokens ? `${k(d.contextTokens)} · ` : "";
  const title = d.contextTokens ? `Context: ${k(d.contextTokens)} of the ${k(d.contextBudget)} auto-compact window — every turn re-sends it` : "Context used";
  return ` · <span class="ctx ${p >= 80 ? "hi" : p >= 67 ? "mid" : ""}" title="${title}">${tokens}${p}% ctx</span>`;
}
// Allow / Deny for a session stuck on a permission prompt — the same answer the pet's alert card
// gives (pet-emit holds the hook open; first answer wins, terminal or here). Shown only while the
// pet can still answer it: the dots carry an askId only while a pet-emit is holding that prompt.
// The text and the askId come from the same snapshot (the pet's dots), and the text is the whole
// command / path / URL / arguments, not the bubble's 48-character phrase.
// Allow takes two clicks, and the second must land on the same prompt: the board rebuilds every few
// seconds and rows can move, so a first click only arms THIS askId ("Allow?"); a click on another
// row's Allow arms that one instead of approving it.
function approveBar(s) {
  const p = (ui.dots || {})[s.sessionId];
  if (!p || p.state !== "waiting" || p.asks !== "permission" || !p.askId) return "";
  const armed = ui.allowArmed && ui.allowArmed.ask === p.askId;
  const data = `data-session="${esc(s.sessionId)}" data-ask="${esc(p.askId)}"`;
  return `<div class="approve"><div class="ap-head"><span class="ap-k">Approve</span>
      <button class="btn small ${armed ? "armed" : ""}" data-action="decide" data-behavior="allow" ${data}
        title="${armed ? "Click again to allow it" : "Allow — click twice"}">${armed ? "Allow?" : "Allow"}</button>
      <button class="btn small ghost" data-action="decide" data-behavior="deny" ${data}>Deny</button></div>
    <code class="ap-what">${esc(p.approveText || s.waitingOn || "this tool call")}</code></div>`;
}
const dot = (s) => { const c = dotClass(s); return `<span class="dot ${c}" title="${esc(DOT_TIP[c] || c)}"></span>`; };
const draft = (key) => ui.drafts[key] ?? "";
const list = (v) => (Array.isArray(v) ? v : []);

// ------------------------------------------------------------------ data
// The page is rebuilt from data. A rebuild between a button's mousedown and mouseup swaps the
// element under the pointer, and the browser then fires no click at all — which is what "the
// first click sometimes does nothing" was. So: skip rebuilds when nothing changed, and hold a
// timed rebuild while a mouse button is down.
async function refresh(force) {
  let sig = null;
  try {
    const [boardText, sessionsText, agentsText, unreadText, jobsSig] = await Promise.all([api("board"), api("sessions"), api("agents"),
      api("pet").catch(() => "{}"), ui.mode === "jobs" && typeof loadJobs === "function" ? loadJobs() : ""]);
    sig = boardText + "\u0001" + sessionsText + "\u0001" + agentsText + "\u0001" + unreadText + "\u0001" + jobsSig;
    ui.board = JSON.parse(boardText);
    const pet = JSON.parse(unreadText || "{}");
    ui.unread = pet.unread || {};
    ui.dots = pet.dots || {};
    ui.usage = pet.usage || null;
    pruneDrafts();
    ui.sessions = mergeBackground(JSON.parse(sessionsText), JSON.parse(agentsText || "[]"));
    $("#error").hidden = true;
  } catch (e) {
    $("#error").textContent = String(e.message || e);
    $("#error").hidden = false;
  }
  if (force !== "timer" || sig === null || sig !== ui.lastSig) {
    ui.lastSig = sig;
    // Only a timed rebuild waits for the mouse button; one you caused shows at once. (A native
    // dropdown's menu swallows the mouseup, so waiting for it could hold the board stale.)
    // Nor while the pointer rests on an Approve box: the row under it must not change while aimed at.
    if ((ui.pointerDown || ui.overApprove) && force === "timer") ui.pendingRender = true;
    else render();
  }
  if (ui.modal && ui.modal.type === "peek") refreshPeek();
}
window.hqRefresh = refresh;
window.hqReveal = (id) => refresh().then(() => { if (id) revealTask(id); });

// ------------------------------------------------------------------ render
// Background sessions (claude --bg) have no terminal; `claude agents --json` names them. Mark the
// ones the pet already tracks, and add any it doesn't.
function mergeBackground(sessions, agents) {
  const bg = (Array.isArray(agents) ? agents : []).filter((a) => a.kind === "background");
  const byId = new Map(sessions.map((s) => [s.sessionId, s]));
  for (const a of bg) {
    const s = byId.get(a.sessionId);
    // `claude attach` / `stop` take the short id that `claude agents` prints, not the session id.
    if (s) { s.background = true; s.bgId = a.id; s.title = s.title || a.name; continue; }
    sessions.push({ sessionId: a.sessionId, title: a.name, cwd: a.cwd, project: (a.cwd || "").split("/").pop(),
                    state: a.status, updatedAt: a.startedAt ? new Date(a.startedAt).toISOString() : null,
                    terminal: null, background: true, bgId: a.id, lastText: "" });
  }
  return sessions;
}

// Where "New session" opens: the user's choice, else the terminal most sessions run in.
const PLACES = { orca: "Orca", iterm2: "iTerm2", terminal: "Terminal", bg: "Background" };
// Sessions the board starts or resumes skip Claude Code's permission prompts — the user's choice,
// remembered; off unless ticked.
const skipPerms = () => pref("hq-skip-perms", "0") === "1";
// Stay on the board: a session the board starts or resumes opens its terminal tab in the
// background, and its conversation window opens here instead — carry on from the board.
const stayOnBoard = () => pref("hq-stay", "0") === "1";
function launchOptions() {
  return `<label class="skipperm" title="Start and resume sessions with --dangerously-skip-permissions: Claude won't stop to ask before running commands or editing files">
    <input type="checkbox" data-action="skip-perms" ${skipPerms() ? "checked" : ""}> skip permissions</label>
    <label class="skipperm" title="Open the session's terminal tab in the background and keep working here, in its conversation window">
    <input type="checkbox" data-action="stay-board" ${stayOnBoard() ? "checked" : ""}> stay on board</label>`;
}
// After starting or resuming a session with "stay on board": its conversation window, which
// fills in as the session comes up.
function stayWith(sid, title) {
  if (!stayOnBoard() || !sid) return;
  openPeek(sid, null, { starting: true, title });
}
// ---- earlier sessions of a task, to resume one (hq history). Fetched when shown, kept a minute.
const HISTORY_MS = 60 * 1000;
function ensureHistory(taskId) {
  const h = ui.history[taskId];
  if ((h && Date.now() - h.at < HISTORY_MS) || ui.historyLoading.has(taskId)) return;
  ui.historyLoading.add(taskId);
  apiJSON("history", { task: taskId })
    .then((rows) => { ui.history[taskId] = { at: Date.now(), rows: Array.isArray(rows) ? rows : [] }; })
    .catch(() => { ui.history[taskId] = { at: Date.now(), rows: [] }; })
    .finally(() => { ui.historyLoading.delete(taskId); render(); });
}
// Ended sessions of a task, newest first (a live one is listed with the live sessions instead).
function earlierSessions(t) {
  ensureHistory(t.id);
  const live = new Set(ui.sessions.map((s) => s.sessionId));
  return ((ui.history[t.id] || {}).rows || []).filter((r) => !r.live && !live.has(r.sessionId));
}
const resumeTip = (r) => `Resume it: claude --resume in ${r.cwd || "its directory"}${skipPerms() ? " (skipping permissions)" : ""}, in ${PLACES[launchPlace() === "bg" ? "terminal" : launchPlace()]}`;
function earlierList(t) {
  const rows = earlierSessions(t);
  if (!rows.length) return "";
  const shown = ui.histAll.has(t.id) ? rows : rows.slice(0, 3);
  return `<div class="meta past-h">Earlier sessions</div>` + shown.map((r) => `<div class="bsess past">
      <span class="dot idle"></span>
      <div style="flex:1;min-width:0"><div class="stitle">${esc(r.title || r.sessionId.slice(0, 8))}</div>
        <div class="meta">ended · ${ago(r.lastAt)}${r.lastText ? " · " + esc(r.lastText.slice(0, 90)) : ""}</div></div>
      <div class="icons">
        <button class="icon" data-action="peek" data-session="${esc(r.sessionId)}" title="Read its conversation">${ICON.peek}</button>
        <button class="btn small" data-action="resume" data-task="${esc(t.id)}" data-session="${esc(r.sessionId)}" data-dir="${esc(r.cwd || "")}" data-name="${esc(r.title || "")}" title="${esc(resumeTip(r))}">↻ Resume</button>
        <button class="icon" data-confirm="Remove?" data-action="forget-session" data-task="${esc(t.id)}" data-session="${esc(r.sessionId)}" title="Remove it from this task's sessions (the conversation itself is kept)">✕</button>
      </div></div>`).join("") +
    (rows.length > 3 ? `<button class="btn small ghost" data-action="hist-all" data-task="${esc(t.id)}">${ui.histAll.has(t.id) ? "Show fewer" : `Show all ${rows.length}`}</button>` : "");
}
function launchPlace() {
  const saved = pref("hq-launch", "");
  if (PLACES[saved]) return saved;
  const counts = {};
  for (const s of ui.sessions) { const k = s.terminal && s.terminal.kind; if (k === "orca" || k === "iterm2") counts[k] = (counts[k] || 0) + 1; }
  return Object.keys(counts).sort((a, b) => counts[b] - counts[a])[0] || "terminal";
}
function launchDir(t) {
  const w = list(t.workdirs)[0];
  if (w) return w;
  const pr = projects().find((p) => p.name === t.project);
  return pr && pr.paths[0] ? pr.paths[0] : "";
}
// ---- "▶ Do it" on an @claude todo: hand it to the task's live session, or start one for it.
const DO_PROMPT = (t, text) => `This session works on HQ task ${t.id}: ${t.title}. Read the task card, then do this todo from it: "${text}". Tick it on the card when it's done, or say what is blocking it.`;
const HANDED_MS = 30 * 60 * 1000;   // how long a handed-over todo says so
function doItButton(t, x) {
  if (x.state !== "open" || x.owner !== "claude") return "";
  const key = `${t.id}|${x.text}`;
  const h = ui.handed[key];
  if (ui.handing.has(key)) return `<button class="btn small ghost doit" disabled>Handing…</button>`;
  if (h && Date.now() - h.at < HANDED_MS) {
    return `<button class="btn small ghost doit" title="Handed to ${esc(h.to)} ${ago(new Date(h.at).toISOString())} — click to hand it over again" data-action="do-todo" data-task="${esc(t.id)}" data-text="${esc(x.text)}">✓ ${esc(h.to.length > 18 ? h.to.slice(0, 18) + "…" : h.to)}</button>`;
  }
  const s = doTarget(t);
  const tip = s ? `Send it to ${s.title || s.project} as a message${s.state === "busy" ? " (busy — it will queue)" : ""}`
    : "No session on this task can take a message — start one that does this todo";
  return `<button class="btn small doit" title="${esc(tip)}" data-action="do-todo" data-task="${esc(t.id)}" data-text="${esc(x.text)}">▶ Do it</button>`;
}
// The live session to hand a task's todo to: one the board can type into, most recently active first.
function doTarget(t) {
  return liveFor(t.id).filter((s) => SENDABLE[s.terminal && s.terminal.kind])
    .sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")))[0] || null;
}
async function doTodo(taskId, text) {
  const t = taskById(taskId);
  const key = `${taskId}|${text}`;
  if (!t || ui.handing.has(key)) return;
  ui.handing.add(key);
  render();
  try {
    const s = doTarget(t);
    if (s) {
      const busy = s.state === "busy";
      await api("send", { session: s.sessionId, text: `[HQ board] Please do this todo on ${t.id}'s card now: "${text}". Tick it on the card when it's done, or say what is blocking it.`, queue: busy });
      ui.handed[key] = { to: s.title || s.project, at: Date.now() };
      toast(`${busy ? "Queued for" : "Sent to"} ${s.title || s.project}`);
    } else {
      const dir = launchDir(t);
      if (!dir) throw new Error("This task has no directory yet — bind a session or give the project a directory first");
      const place = launchPlace();
      const r = await apiObj("launch", { task: t.id, title: t.title, dir, where: place, prompt: DO_PROMPT(t, text), skip: skipPerms(), focus: !stayOnBoard() });
      stayWith(r && r.session, `${t.id} ${t.title}`);
      ui.handed[key] = { to: "a new session", at: Date.now() };
      toast(`Started a session on ${t.id} (${PLACES[place]}) to do it`);
      setTimeout(() => refresh(), 2500);
    }
  } catch (e) { toast(String(e.message || e), true); }
  finally { ui.handing.delete(key); render(); }
}

// A card with nothing on it yet (no next step, todos or log) gets a different opening: the
// title alone is not a brief, and a session left to guess raised several asks about what it
// imagined the task to be. It asks one thing — what to work on — and waits.
const emptyCard = (t) => !t.next && !t.todos.length && !logEntries(t).length && !pendingAsks(t).length;
const LAUNCH_PROMPT = (t) => emptyCard(t)
  ? `This session works on HQ task ${t.id}: ${t.title}. The task card is new and empty. Don't guess what the task is from its title and don't plan anything yet. Reply in one short line, ending with an hq-asks block holding exactly one ask — what should we work on first in ${t.id}? (in the language the task card is written in) — and wait for my answer.`
  : `This session works on HQ task ${t.id}: ${t.title}. Read the task card, then reply in three short lines — where it stands, the next step, and anything waiting on me — and wait for my instructions before doing the work.`;

function render() {
  saveDrafts();
  // Never yank an open dropdown out from under the pointer.
  if (ui.dragging) return;
  // Nor rebuild a box an input method (Pinyin…) is composing in: the new box would get the raw
  // letters and the candidate window would close. Catch up when the composition ends.
  if (ui.composing) { ui.renderPending = true; return; }
  const active = document.activeElement;
  if (active && active.tagName === "SELECT") return;
  const key = active && active.dataset ? active.dataset.key : null;
  const sel = key && "selectionStart" in active ? [active.selectionStart, active.selectionEnd] : null;
  const activeRegion = active && active.closest ? active.closest("#modal") : null;
  // Peek panes are rebuilt every refresh; keep where the reader was (bottom = newest by default).
  const scrolls = {};
  document.querySelectorAll(".peek[data-sid]").forEach((p) => {
    scrolls[p.dataset.sid] = p.scrollHeight - p.scrollTop - p.clientHeight < 8 ? "bottom" : p.scrollTop;
  });

  renderCounts();
  // Four pages, each two columns: Focus (the tasks you keep in view), All, Needs you (every
  // unanswered ask and your todos) with its count on the tab, and Scheduled (jobs.js).
  if (!["today", "all", "needs", "jobs"].includes(ui.mode)) ui.mode = "today";
  const need = needCount();
  // Each tab carries its count; only Needs you's is lit, because only it asks something of you.
  // (Scheduled has none: its jobs are only read while that page is showing.)
  const tabN = { today: focusIds().length, all: tasks().filter(isOpen).length, needs: need };
  $("#mode").innerHTML = [["today", "Focus"], ["all", "All"], ["needs", "Needs you"], ["jobs", typeof jt === "function" ? jt("tab") : "Scheduled"]].map(([m, label]) =>
    `<button class="tab ${ui.mode === m ? "on" : ""}" data-action="mode" data-m="${m}"${ui.mode === m ? ` aria-current="page"` : ""}${m === "needs" ? ` title="Unanswered asks and your todos"` : ""}>${label}${tabN[m] ? `<span class="n ${m === "needs" ? "hot" : ""}">${tabN[m]}</span>` : ""}</button>`).join("");
  $("#today").hidden = ui.mode !== "today";
  $("#all").hidden = ui.mode !== "all";
  $("#needs").hidden = ui.mode !== "needs";
  $("#jobs").hidden = ui.mode !== "jobs";
  if (ui.mode === "jobs" && typeof renderJobsView === "function") renderJobsView();   // see jobs.js
  if (ui.mode === "today") {
    $("#today-focus").innerHTML = renderToday();
    $("#today-sessions").innerHTML = renderTodaySessions();
    $("#newtask-form").innerHTML = ""; delete $("#newtask-form").dataset.drawn;
  }
  $("#asks").innerHTML = renderAsks();
  $("#mytodos").innerHTML = renderMyTodos();
  $("#newtask-form").hidden = !ui.newTask || ui.mode === "today";
  if (ui.newTask && ui.mode !== "today" && !$("#newtask-form").dataset.drawn) {
    $("#newtask-form").innerHTML = renderNewTask();
    $("#newtask-form").dataset.drawn = "1";
  }
  $("#groupby").innerHTML = ["project", "status"].map((g) =>
    `<button class="${ui.groupBy === g ? "on" : ""}" data-action="group-by" data-g="${g}">${g === "project" ? "Project" : "Status"}</button>`).join("");
  $("#activefirst").hidden = ui.groupBy !== "project";
  $("#sgroupby").innerHTML = ["list", "project"].map((g) =>
    `<button class="${ui.sgroupBy === g ? "on" : ""}" data-action="sgroup-by" data-g="${g}">${g === "list" ? "List" : "Project"}</button>`).join("");
  // One button: by project it folds / unfolds every group; by status it closes open task cards.
  const anyOpen = ui.groupBy === "project" ? projectGroupKeys().some((k) => !ui.collapsed.has(k)) : ui.expanded.size > 0;
  $("#foldall").textContent = anyOpen ? "Collapse all" : "Expand all";
  $("#foldall").title = ui.groupBy === "project" ? "Fold or unfold every project group" : "Close every open task";
  $("#foldall").hidden = ui.groupBy === "status" && !anyOpen;
  $("#activefirst input").checked = ui.activeFirst;
  renderSettings();
  $("#tasks").innerHTML = renderTasks();
  $("#sessions").innerHTML = renderSessions();

  document.querySelectorAll(".peek[data-sid]").forEach((p) => {
    const v = scrolls[p.dataset.sid];
    p.scrollTop = v === undefined || v === "bottom" ? p.scrollHeight : v;
  });
  paintTaskIds();
  paintArmed();
  fitAllGrow();
  // Put the cursor back only if the box you were typing in was rebuilt — one that wasn't (the
  // conversation window's reply box, say) keeps it. And look for its stand-in in the same place:
  // a session's message box in the Sessions column shares its key with the conversation window's
  // reply box, and grabbing the first match moved the cursor to the one hidden behind the window.
  if (key && !active.isConnected) {
    const inModal = Boolean(activeRegion && activeRegion.id === "modal");
    // …and a visible one: Today's cards stay in the DOM, hidden, while All is showing.
    const el = [...document.querySelectorAll(`[data-key="${CSS.escape(key)}"]`)]
      .find((x) => Boolean(x.closest("#modal")) === inModal && x.getClientRects().length);
    if (el) {
      el.focus();
      if (sel && el.setSelectionRange) el.setSelectionRange(sel[0], sel[1]);
    }
  }
}

// Every task id on the page — chips, row ids — takes its task's status colour.
function paintTaskIds() {
  const st = Object.fromEntries(tasks().map((t) => [t.id, t.status]));
  document.querySelectorAll(".chip[data-task], .tid[data-task]").forEach((el) => {
    const s = st[el.dataset.task];
    if (!s) return;
    el.dataset.st = s;
    if (!el.title) el.title = STATUS_SHORT[s] || s;
  });
}

// What Needs you holds: unanswered asks (not the ones put off till later) and your open todos.
function needCount() {
  const open = tasks().filter(isOpen);
  return tasks().reduce((n, t) => n + openAsks(t).length, 0) +
    open.reduce((n, t) => n + t.todos.filter((x) => x.state === "open" && x.owner === "me").length + (t.waiting_on_me ? 1 : 0), 0);
}
// The status bar at the bottom: where things stand, at a glance — sessions by state, tasks by
// status, what is waiting on you (click → Needs you), and the quota on the right.
function renderCounts() {
  const all = tasks().filter(isOpen);
  const by = (st) => ui.sessions.filter((x) => x.state === st).length;
  const asks = tasks().reduce((n, t) => n + openAsks(t).length, 0);
  const later = tasks().reduce((n, t) => n + laterAsks(t).length, 0);
  const mine = all.reduce((n, t) => n + t.todos.filter((x) => x.state === "open" && x.owner === "me").length + (t.waiting_on_me ? 1 : 0), 0);
  const part = (n, label, cls = "") => n ? `<span class="sp ${cls}"><b>${n}</b> ${label}</span>` : "";
  // Task counts are on the tabs; the status bar says what the sessions are doing, what waits on
  // you (click → Needs you), and the quota on the right.
  $("#counts").innerHTML =
    `<span class="sgroup" title="Live Claude Code sessions"><b>${ui.sessions.length}</b> session${ui.sessions.length === 1 ? "" : "s"}` +
      `${part(by("busy"), "working")}${part(by("waiting"), "waiting on you", "warn")}</span>` +
    (asks || mine || later ? `<span class="sgroup jump" data-action="mode" data-m="needs" title="Open Needs you">` +
      `${asks ? `<b>${asks}</b> ask${asks === 1 ? "" : "s"}` : ""}${asks && mine ? " · " : ""}${mine ? `<b>${mine}</b> todo${mine === 1 ? "" : "s"}` : ""}` +
      `${later ? `<span class="sp">${later} for later</span>` : ""}</span>` : "");
  $("#quota").innerHTML = usageChips();
}
// The subscription's 5-hour and weekly limits — percent used and when each resets — as the
// statusline last saw them (see BoardBridge.usageSnapshot). Nothing when there is no fresh copy.
function untilText(iso) {
  const m = Math.max(0, Math.round((new Date(iso).getTime() - Date.now()) / 60000));
  if (isNaN(m)) return "";
  if (m < 60) return `${m}m`;
  if (m < 24 * 60) return `${Math.floor(m / 60)}h ${m % 60}m`;
  return `${Math.floor(m / 1440)}d ${Math.floor((m % 1440) / 60)}h`;
}
function usageChips() {
  const u = ui.usage;
  if (!u) return "";
  const one = (label, long, w) => {
    if (!w || w.used == null) return "";
    const p = Math.round(w.used);
    const r = w.resets_at ? untilText(w.resets_at) : "";
    return `<span class="quota ${p >= 90 ? "hi" : p >= 70 ? "mid" : ""}" title="${long}: ${p}% used${r ? ` · resets in ${r}` : ""}">${label}
      <span class="qbar"><i style="width:${Math.min(100, p)}%"></i></span><b>${p}%</b>${r ? `<span class="qr">resets ${r}</span>` : ""}</span>`;
  };
  return one("5h", "5-hour limit", u.five_hour) + one("week", "Weekly limit", u.seven_day);
}

function renderAsks() {
  const items = [];
  for (const t of tasks()) for (const a of openAsks(t)) items.push([t, a]);
  items.sort((x, y) => String(x[1].ts).localeCompare(String(y[1].ts)));
  const later = tasks().filter((t) => laterAsks(t).length);
  const laterHtml = later.map((t) => `<div class="later-of"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${laterLine(t)}</div>`).join("");
  const head = `<div class="vhead"><h1>Needs you</h1></div>`;
  if (!items.length) return head + `<div class="calm"><svg viewBox="0 0 16 16"><path d="M3 8.5l3 3 7-7"/></svg>Claude has nothing waiting on an answer from you.</div>` + laterHtml;
  const byTask = new Map();
  for (const [t, a] of items) byTask.set(t, (byTask.get(t) || []).concat([a]));
  return head + `<div class="group-title">Claude is asking <span class="meta">${items.length}</span></div>` + [...byTask].map(([t, asks]) => renderAskGroup(t, asks)).join("") + laterHtml;
}

// A task with several open asks answers them together: each answer button only picks, and one
// Send at the bottom records them all and types a single message into the session.
function renderAskGroup(t, asks) {
  if (asks.length < 2) return asks.map((a) => askCard(t, a)).join("");
  const target = groupTarget(asks);
  const picked = asks.filter((a) => ui.picks[a.id]).length;
  const sending = asks.some((a) => ui.resolving.has(a.id));
  const allPush = target && asks.every((a) => wantPush(a));
  return `<div class="askgroup">${asks.map((a) => askCard(t, a, { group: true, sharedTarget: Boolean(target) })).join("")}
    <div class="askbar">
      <span class="meta">${picked} of ${asks.length} answered</span>
      ${target ? `<label class="push" title="Type all the answers into that session as one message, so it carries on now">
        <input type="checkbox" data-action="push-group" data-ids="${esc(asks.map((a) => a.id).join(" "))}" ${allPush ? "checked" : ""}>
        send to <b>${esc(target.title || target.project)}</b> now${target.state === "busy" ? " (busy — it will queue)" : ""}</label>` : `<span style="flex:1"></span>`}
      <button class="btn small primary" data-action="resolve-all" data-task="${esc(t.id)}" ${picked && !sending ? "" : "disabled"}
        title="Record every answer you picked${target ? " and send them in one message" : ""}">${sending ? "Sending…" : picked ? `Send ${picked} answer${picked === 1 ? "" : "s"}` : "Send answers"}</button>
    </div></div>`;
}
// The one live session every ask in a group came from, if the board can type into it.
function groupTarget(asks) {
  const ts = asks.map(pushTarget);
  return ts[0] && ts.every((x) => x && x.sessionId === ts[0].sessionId) ? ts[0] : null;
}

function askCard(t, a, opt = {}) {
  const pick = ui.picks[a.id];
  const attKey = "ask:" + a.id;
  return `
    <div class="card ask ${pick ? "picked" : ""}">
      <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(a.id)}</span>${esc(t.title)} · ${ago(a.ts)}</div>
      <div class="ask-text clickable" title="Show where this came from" data-action="ctx" data-kind="ask" data-task="${esc(t.id)}" data-id="${esc(a.id)}">${esc(a.text)}</div>
      <div class="row askrow">
        <textarea class="note grow" rows="1" data-key="note:${esc(a.id)}" data-att="${esc(attKey)}" placeholder="note · paste images" title="Optional note — your answer in words, or why; paste or drop screenshots too">${esc(draft("note:" + a.id))}</textarea>
        ${RESOLUTIONS.concat(ui.moreRes.has(a.id) || pick === "archive" ? MORE_RESOLUTIONS : []).map(([r, label, tip]) => opt.group
          ? `<button class="btn small res-${r} ${pick === r ? "on" : ""}" title="${esc(tip)} — pick, then Send below" data-action="pick" data-id="${esc(a.id)}" data-res="${r}">${label}</button>`
          : `<button class="btn small res-${r}" title="${esc(tip)}" data-action="resolve" data-id="${esc(a.id)}" data-res="${r}">${label}</button>`).join("")}
        ${ui.moreRes.has(a.id) || pick === "archive" ? "" : `<button class="btn small ghost res-more" title="More answers: No context — I can't answer this, park it" data-action="more-res" data-id="${esc(a.id)}">⋯</button>`}
      </div>
      ${attachStrip(attKey)}
      ${pushTarget(a) && !opt.sharedTarget ? `<label class="push" title="Type your answer into that session so it carries on now, instead of waiting for your next message there">
        <input type="checkbox" data-key="push:${esc(a.id)}" ${wantPush(a) ? "checked" : ""}>
        send to <b>${esc(pushTarget(a).title || pushTarget(a).project)}</b> now${pushTarget(a).state === "busy" ? " (busy — it will queue)" : ""}</label>` : ""}
    </div>`;
}

// The live session that raised an ask, if the board can type into its terminal.
function pushTarget(a) {
  const s = a.session && ui.sessions.find((x) => x.sessionId === a.session);
  return s && SENDABLE[s.terminal && s.terminal.kind] ? s : null;
}
// Ticked by default while that session sits idle; a busy one would only queue it.
function wantPush(a) {
  const v = ui.drafts["push:" + a.id];
  if (v !== undefined) return v;
  const s = pushTarget(a);
  return Boolean(s) && s.state !== "busy";
}
const RES_TEXT = { do: "Yes", drop: "No", later: "Ask later — needs someone else first", archive: "No context — parked",
  todo: "Made it an @me todo — the user will do it themselves; don't ask again",
  snooze: "Later — the user will answer this later; carry on with what doesn't depend on it" };
// An answer as the session reads it: Yes with a note is the user's own answer, not "Yes — …".
function resText(res, note) {
  if (res === "do") return note ? `Answer: ${note}` : "Yes — go ahead as you suggested";
  if (res === "drop") return "No" + (note ? ` — ${note}` : "");
  return (RES_TEXT[res] || res) + (note && res !== "snooze" ? ` — ${note}` : "");
}
// "To todo" is the board's own answer: the ask becomes an @me todo on its task, and is closed as
// "do" with a note saying so. Returns what an Undo needs.
async function answerAsk(a, res, note) {
  if (res === "snooze") { await api("snooze", { id: a.id }); return { snoozed: true }; }
  if (res !== "todo") { await api("resolve", { id: a.id, resolution: res, note }); return null; }
  const task = a.id.replace(/\.\d+$/, "");
  const text = `@me ${a.text}${note ? ` — ${note}` : ""}`.replace(/\s+/g, " ").trim();
  await api("addtodo", { task, text });
  try {
    await api("resolve", { id: a.id, resolution: "do", note: `made an @me todo — the user will do it${note ? `: ${note}` : ""}` });
  } catch (e) {
    try { await dropMadeTodo({ task, text }); } catch (e2) { /* best effort */ }
    throw e;
  }
  return { task, text };
}
// Undo of "To todo": the todo it added goes too (marked dropped, so the card keeps the trace).
async function dropMadeTodo(made) {
  if (!made) return;
  await refresh();
  const t = taskById(made.task);
  const x = t && t.todos.find((y) => y.state === "open" && (y.owner ? `@${y.owner} ${y.text}` : y.text) === made.text);
  if (x) await api("todo", { task: made.task, index: x.i, state: "drop", text: x.text });
}
// An answer names its ask by id plus the question's opening words — enough for the session to
// match it to what it asked (it never saw the id: hq assigns it after the turn), without
// repeating the whole question back into the prompt.
function gist(text) {
  const t = String(text || "").replace(/\s+/g, " ").trim();
  return t.length > 30 ? t.slice(0, 30) + "…" : t;
}
function pushMessage(a, res, note) {
  return `[HQ board] ${a.id} "${gist(a.text)}": ${resText(res, note)}`;
}
function pushMessageAll(answers) {
  return "[HQ board] Answers:\n" +
    answers.map(({ a, res, note }) => `- ${a.id} "${gist(a.text)}": ${resText(res, note)}`).join("\n");
}
// An ask's note with any pasted images: Claude Code reads an image from a path in the prompt.
// Writing a note on one of several asks means you're answering it: Do is picked for you. Only
// a pick made this way is taken back when the note is emptied again; one you clicked stays.
function autoPick(id, hasNote) {
  const t = taskById(id.replace(/\.\d+$/, ""));
  if (!t || openAsks(t).length < 2) return;        // a lone ask's buttons answer at once
  if (!openAsks(t).some((a) => a.id === id)) return;   // a put-off ask (for later) isn't in the group
  if (hasNote && !ui.picks[id]) { ui.picks[id] = "do"; ui.autoPicked.add(id); render(); }
  else if (!hasNote && ui.autoPicked.has(id) && !(ui.atts["ask:" + id] || []).length) {
    delete ui.picks[id]; ui.autoPicked.delete(id); render();
  }
}
function answerNote(id) {
  const text = (ui.drafts["note:" + id] || "").trim();
  const imgs = (ui.atts["ask:" + id] || []).map((x) => x.path);
  return [text, ...imgs].filter(Boolean).join(" ");
}

function renderMyTodos() {
  const items = [];
  for (const t of tasks().filter(isOpen))
    for (const x of t.todos) if (x.state === "open" && x.owner === "me") items.push([t, x]);
  // A card may still carry the old free-text "waiting on you" field (written before it was
  // folded into @me todos). Show it here as a todo rather than lose it; ticking clears it.
  const legacy = tasks().filter((t) => isOpen(t) && t.waiting_on_me);
  // Newest first; each shows how long it has been waiting (amber after STALE_DAYS).
  const since = (iso) => Date.parse(iso || "") || 0;
  items.sort((a, b) => since(b[1].created) - since(a[1].created));
  legacy.sort((a, b) => since(b.waiting_since) - since(a.waiting_since));
  const age = (iso) => {
    const ms = since(iso);
    if (!ms) return "";
    const days = (Date.now() - ms) / 86400000;
    const label = ago(iso).replace(" ago", "");
    return `<span class="age ${days >= STALE_DAYS ? "stale" : ""}" title="Waiting since ${esc(new Date(ms).toLocaleString())}">${label}</span>`;
  };
  // Recently ticked items stay in view (struck through, with Undo) for an hour. After that,
  // reopen from the task itself — every change is also in the card's log.
  ui.recent = ui.recent.filter((r) => Date.now() - r.at < RECENT_MS);
  const recent = ui.recent.filter((r) => {
    const t = taskById(r.task);
    const x = t && t.todos.find((y) => y.i === r.i);
    return x && x.state !== "open";
  });
  const src = (t) => `<div class="meta src"><span class="tid link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span> ${esc(t.title)}${t.status === "blocked" ? " · blocked" : ""}</div>`;
  if (!items.length && !recent.length && !legacy.length) return `<div class="group-title">Your todos</div><div class="empty">Nothing waiting on you.</div>`;
  return `<div class="group-title">Your todos <span class="meta">${items.length + legacy.length}</span></div><div class="inbox-list">` + legacy.map((t) => `
    <div class="todo it">
      <span class="box" title="Handled (you can undo)" data-action="clear-waiting" data-task="${esc(t.id)}"></span>
      <div class="it-t"><span class="t clickable" title="Show context" data-action="ctx" data-kind="waiting" data-task="${esc(t.id)}">${esc(t.waiting_on_me)}</span>${src(t)}</div>
      ${age(t.waiting_since)}
    </div>`).join("") + items.map(([t, x]) => `
    <div class="todo it">
      <span class="box" title="Mark done (you can undo)" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="done" data-from="open" data-text="${esc(x.text)}"></span>
      <div class="it-t"><span class="t clickable" title="Show context" data-action="ctx" data-kind="todo" data-task="${esc(t.id)}" data-i="${x.i}">${esc(x.text)}</span>${src(t)}</div>
      ${age(x.created)}
      <button class="icon x" title="Won't do (you can undo)" data-confirm="Won't do?" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop" data-from="open" data-text="${esc(x.text)}">✕</button>
    </div>`).join("") + recent.map((r) => `
    <div class="todo it ${r.to === "drop" ? "dropped" : "done"}">
      <span class="box ${r.to === "drop" ? "dropped" : "done"}">${r.to === "drop" ? "–" : "✓"}</span>
      <div class="it-t"><span class="t">${esc(r.text)}</span>
        <div class="meta src">${r.to === "drop" ? "won't do" : "done"} ${ago(new Date(r.at).toISOString())} · undo available for an hour · <span class="tid link" data-action="goto" data-task="${esc(r.task)}">${esc(r.task)}</span></div></div>
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
// Every group the Tasks column can show by project — listed projects (even empty ones), any
// project named only on a card, and "No project".
function projectGroupKeys() {
  return [...new Set([...projectNames(), ...tasks().map((t) => t.project || "(none)")])];
}

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
  if (!tasks().length) return renderOnboarding();
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
      // Every listed project shows, even with nothing open — unless a search is narrowing things.
      if (!group.length && (!name || !names.includes(name) || f)) continue;
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
      if (!shut) {
        const closed = tasks().filter((t) => (t.project || "") === name && !isOpen(t)).length;
        html += group.length ? group.map((t) => renderTask(t, "project")).join("")
          : `<div class="empty proj-empty">No open tasks${closed && !ui.showClosed ? ` (${closed} closed)` : ""}.
              <button class="btn small ghost" data-action="new-in-project" data-p="${esc(name)}">+ New task</button></div>`;
      }
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
  // Row 1: id · title (one line) · badges. Row 2: the subtitle across the full width, two lines max.
  const subText = mine && isOpen(t) ? mine : (t.next && isOpen(t) ? t.next : "");
  // Status is the rail on the row's left edge (and the id's colour); the group heading already
  // names the project or the status, so the row repeats neither.
  const sub = subText ? `<div class="tsub ${mine && isOpen(t) ? "waiting" : ""}" title="${esc((mine && isOpen(t) ? "Waiting on you: " : "Next: ") + subText)}">${esc(subText)}</div>` : "";
  const busy = liveFor(t.id).some((x) => x.state === "busy");
  return `<div class="task ${open ? "open" : ""}" id="task-${esc(t.id)}" data-st="${esc(t.status)}">
    <div class="task-head" data-action="expand" data-task="${esc(t.id)}" title="${esc(STATUS_SHORT[t.status] || t.status)} — click to ${open ? "fold" : "open"}">
      <span class="tid" data-task="${esc(t.id)}">${esc(t.id)}</span>
      <div class="ttitle" title="${esc(t.title)}">${esc(t.title)}</div>
      <div class="tright">
        ${isOpen(t) ? `<button class="star ${focusIds().includes(t.id) ? "on" : ""}" data-action="focus-toggle" data-task="${esc(t.id)}"
            title="${focusIds().includes(t.id) ? "In Focus — click to take it off" : "Add to Focus"}">${focusIds().includes(t.id) ? "★" : "☆"}</button>` : ""}
        ${asks ? `<span class="badge" title="open asks">${asks}</span>` : ""}
        ${live ? `<span class="live ${busy ? "" : "idle"}" title="live sessions on it">${busy ? "working" : live === 1 ? "1 session" : `${live} sessions`}</span>` : ""}
        ${mode === "project" ? (t.status !== "active" ? `<span class="stag ${esc(t.status)}">${STATUS_SHORT[t.status] || esc(t.status)}</span>` : "")
          : t.project ? `<span class="tproj">${esc(t.project)}</span>` : ""}
        <span class="age-d" title="Last updated ${esc(t.updated || "")}">${t.age_days ?? "?"}d</span>
      </div>
      ${open ? "" : sub}
    </div>
    ${open ? renderTaskBody(t) : ""}
  </div>`;
}

// ------------------------------------------------------------------ Today
// A working view: only the tasks picked for today, each with what it needs from you and its
// sessions; everything else stays in All.
const focusState = () => (ui.board && ui.board.focus) || { ids: [], carry: [] };
const focusIds = () => focusState().ids || [];

// The latest activity of a task's live sessions (ISO), or "" when none is live.
const lastActive = (t) => liveFor(t.id).map((s) => s.updatedAt || "").sort().pop() || "";
function renderToday() {
  const f = focusState();
  // Active first: tasks with a live session lead, most recently active first; the rest keep your
  // order. Off: your order throughout, and the cards can be dragged into it.
  const mine = focusIds().map(taskById).filter(Boolean);
  const picked = ui.activeFirst
    ? mine.slice().sort((a, b) => lastActive(b).localeCompare(lastActive(a)) || mine.indexOf(a) - mine.indexOf(b))
    : mine;
  const pickable = tasks().filter((t) => isOpen(t) && !focusIds().includes(t.id));
  const draftNew = ui.newTask ? `<div class="card">${renderNewTask()}</div>` : "";
  return `<div class="today-h vhead"><h1>Focus</h1><span class="meta">${picked.length} task${picked.length === 1 ? "" : "s"}</span>
      <label class="toggle af" title="Tasks with a live session come first, most recently active first. Off: your own order — drag a card by ⠿ to change it. The same setting as in All."><input type="checkbox" data-action="active-first" ${ui.activeFirst ? "checked" : ""}> active first</label>
      <span style="flex:1"></span>
      <input class="note pick" list="today-pick" data-key="todaypick" placeholder="Add a task to Focus…" value="${esc(draft("todaypick"))}">
      <datalist id="today-pick">${pickable.map((t) => `<option value="${esc(t.id + " · " + t.title)}">`).join("")}</datalist>
      <button class="btn small" data-action="today-add">Add</button></div>
    ${draftNew}
    ${picked.length ? picked.map(focusCard).join("") : `<div class="card empty-today">
      <b>Nothing in Focus yet.</b>
      <div class="meta" style="margin-top:4px">Add the tasks you want in view with the box above, or star ☆ them in All. New tasks join automatically; they stay until you take them off.</div></div>`}`;
}

function focusCard(t) {
  const asks = openAsks(t);
  const open = t.todos.filter((x) => x.state === "open");
  const mine = open.filter((x) => x.owner === "me");
  const others = open.length - mine.length;
  const live = liveFor(t.id);
  const busy = live.some((s) => s.state === "busy");
  const detail = ui.expanded.has(t.id);
  const box = (x) => `<div class="todo">
      <span class="box" title="Mark done (you can undo)" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="done" data-from="open" data-text="${esc(x.text)}"></span>
      <span class="who me">You</span><span class="t">${esc(x.text)}</span>
      <button class="icon x" title="Won't do" data-confirm="Won't do?" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop" data-from="open" data-text="${esc(x.text)}">✕</button></div>`;
  // No live session: offer to resume the latest one, beside New session.
  const resume = live.length ? "" : (() => { const r = earlierSessions(t)[0]; return r
    ? `<button class="btn small" data-action="resume" data-task="${esc(t.id)}" data-session="${esc(r.sessionId)}" data-dir="${esc(r.cwd || "")}" data-name="${esc(r.title || "")}" title="${esc(resumeTip(r) + " — " + (r.title || r.sessionId.slice(0, 8)) + ", " + ago(r.lastAt))}">Resume</button>` : ""; })();
  // Clicking the card opens or closes its details, like a row in All; the details themselves
  // swallow clicks (data-action="none") so selecting or typing there never folds the card.
  // Closed, a card is its next step, what it asks you, and your own todos; Claude's todos, the
  // log and the sessions are one click away (the sessions are also in the right column).
  return `<div class="fcard ${detail ? "open" : ""}" id="ftask-${esc(t.id)}" data-st="${esc(t.status)}" data-today-card="${esc(t.id)}" data-action="expand" data-task="${esc(t.id)}" title="${detail ? "Click to fold" : "Click for details"}">
    <div class="fhead">
      ${ui.activeFirst ? "" : `<span class="tgrip" draggable="true" data-drag-task="${esc(t.id)}" title="Drag to reorder your Focus">⠿</span>`}
      <span class="tid" data-task="${esc(t.id)}">${esc(t.id)}</span>
      <div class="ftitle" title="${esc(t.title)}">${esc(t.title)}</div>
      ${live.length ? `<span class="live ${busy ? "" : "idle"}">${busy ? "working" : "idle"}</span>` : ""}
      ${t.status !== "active" ? `<span class="stag ${esc(t.status)}">${STATUS_SHORT[t.status] || esc(t.status)}</span>` : ""}
      ${t.project ? `<span class="tproj">${esc(t.project)}</span>` : ""}
      <button class="icon x" title="Take it off Focus (the task stays)" data-confirm="Unfocus?" data-action="today-remove" data-task="${esc(t.id)}">✕</button>
    </div>
    ${detail ? `<div data-action="none" title="">${renderTaskBody(t)}</div>` : `
    <div class="fbody">
      <div class="now">
        <div class="now-t"><div class="k">Next</div><div class="v">${t.next ? inline(t.next) : `<span class="faint">No next step yet</span>`}</div></div>
        <div class="tools" data-action="none" title="">${resume}${launchSplit(t)}</div>
      </div>
      ${asks.length || laterAsks(t).length ? `<div class="fsec" data-action="none" title="">${asks.length ? renderAskGroup(t, asks) : ""}${laterLine(t)}</div>` : ""}
      ${mine.length ? `<div class="fsec todos" data-action="none" title="">${mine.map(box).join("")}</div>` : ""}
      ${others || !(mine.length || asks.length || t.waiting_on_me) ? `<div class="fmore">${mine.length || asks.length || t.waiting_on_me ? "" : "Nothing waiting on you here"}${!(mine.length || asks.length || t.waiting_on_me) && others ? " · " : ""}${others ? `${others} more todo${others === 1 ? "" : "s"} for Claude or others — open for all` : ""}</div>` : ""}
    </div>`}
  </div>`;
}

function renderTodaySessions() {
  const ids = focusIds();
  const onToday = ui.sessions.filter((s) => s.task && ids.includes(s.task));
  const loose = ui.sessions.filter((s) => !s.task);
  return `<div class="vhead"><h2 class="side-h">Sessions on these tasks</h2></div>
    ${onToday.length ? renderSessions(onToday, "state") : `<div class="empty">None yet — start one from a task, or bind one below.</div>`}
    ${loose.length ? `<div class="vhead" style="margin-top:22px"><h2 class="side-h">Not on a task</h2></div>${renderSessions(loose, true)}` : ""}`;
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
  const url = (String(ref).match(/https?:\/\/[\x21\x23-\x26\x28-\x3b\x3d\x3f-\x7e]+/) || [])[0];
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
  // `- 2026-11-20 20:05:18: text` (hq log writes the time since 11/20); older lines carry the day only.
  return String(t.body || "").split("\n")
    .map((l) => l.match(/^\s*-\s+(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?):\s+(.*)$/))
    .filter(Boolean).map((m) => ({ date: m[1].replace("T", " "), text: m[2] }));
}
const PLUS = '<svg viewBox="0 0 16 16"><path d="M8 3v10M3 8h10"/></svg>';
const LINK = '<svg viewBox="0 0 16 16"><path d="M6.5 9.5l3-3M7 4.5l1-1a2.5 2.5 0 0 1 3.5 3.5l-1 1M9 11.5l-1 1A2.5 2.5 0 0 1 4.5 9l1-1"/></svg>';

function secHead(title, t, what, tip, count, extra = "") {
  const on = ui.adding.has(`${t.id}:${what}`);
  return `<div class="sec-h"><h3>${title}${count != null ? ` <span class="meta">${count}</span>` : ""}</h3>
    <button class="icon ${on ? "on" : ""}" title="${esc(tip)}" data-action="toggle-add" data-what="${what}" data-task="${esc(t.id)}">${PLUS}</button>${extra}</div>`;
}
// A directory as it reads best: the home directory as ~.
const tildePath = (p) => String(p).replace(/^\/Users\/[^/]+(?=\/|$)/, "~");

// "New session" with its options behind ▾: where it opens, skip permissions, stay on board.
function launchSplit(t) {
  const open = ui.launchMenu === t.id;
  // The same task can be drawn twice (Focus, and All behind it): each menu gets its own radio group.
  const group = `place-${t.id}-${(launchSplit.n = (launchSplit.n || 0) + 1)}`;
  return `<span class="launch">
    <button class="btn small primary" data-action="launch" data-task="${esc(t.id)}" title="Start a Claude Code session on this task in ${esc(launchDir(t) || "(no directory yet)")} (${esc(PLACES[launchPlace()])}) — it starts bound, reads the card and reports">New session</button><button class="btn small primary caret-btn ${open ? "on" : ""}" data-action="launch-menu" data-task="${esc(t.id)}" title="Where new sessions open, and how" aria-expanded="${open}">▾</button>
    ${open ? `<div class="menu">
      <div class="mh">Open new sessions in</div>
      ${Object.entries(PLACES).map(([k, v]) => `<label><input type="radio" name="${esc(group)}" data-action="launch-place" value="${k}" ${launchPlace() === k ? "checked" : ""}> ${v}</label>`).join("")}
      <hr>${launchOptions()}
    </div>` : ""}
  </span>`;
}
// A log entry's day, as a heading: Today, Yesterday, or the date.
function logDay(date) {
  const day = String(date).slice(0, 10);
  const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const now = new Date();
  if (day === iso(now)) return "Today";
  if (day === iso(new Date(now.getTime() - 86400000))) return "Yesterday";
  const d = new Date(day + "T00:00:00");
  return isNaN(d) ? day : d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: d.getFullYear() === now.getFullYear() ? undefined : "numeric" });
}
const OWNER_LABEL = (o) => (o === "me" ? "You" : o === "claude" ? "Claude" : o || "");

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
  // Open todos first — yours, then Claude's, then anyone else's. Finished ones follow; past
  // FINISHED_SHOWN of them they fold behind "Show N finished" — except ones ticked in the last
  // hour, which stay for an easy undo.
  const isRecent = (x) => ui.recent.some((r) => r.task === t.id && r.i === x.i && Date.now() - r.at < RECENT_MS);
  const ownerRank = (x) => (x.owner === "me" ? 0 : x.owner === "claude" ? 1 : x.owner ? 2 : 3);
  const openTodos = t.todos.filter((x) => x.state === "open").sort((a, b) => ownerRank(a) - ownerRank(b));
  const finished = t.todos.filter((x) => x.state !== "open");
  const foldDone = finished.length > FINISHED_SHOWN && !ui.doneOpen.has(t.id);
  const shownTodos = openTodos.concat(foldDone ? finished.filter(isRecent) : finished);
  const hiddenDone = finished.length - (shownTodos.length - openTodos.length);
  const todoRow = (x) => {
    const mark = x.state === "done" ? "✓" : x.state === "dropped" ? "–" : "";
    const next = x.state === "open" ? "done" : "open";
    const who = x.owner ? `<span class="who ${x.owner === "me" ? "me" : x.owner === "claude" ? "cl" : ""}">${esc(OWNER_LABEL(x.owner))}</span>` : `<span class="who"></span>`;
    return `<div class="todo ${x.state}">
      <span class="box ${x.state}" title="${x.state === "open" ? "Mark done" : "Reopen"}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="${next}" data-from="${x.state}" data-text="${esc(x.text)}">${mark}</span>
      ${who}<span class="t">${esc(x.text)}</span>
      ${doItButton(t, x)}
      ${x.state === "open" ? `<button class="icon x" title="Won't do" data-confirm="Won't do?" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop" data-from="open" data-text="${esc(x.text)}">✕</button>` : ""}</div>`;
  };
  const todoState = (!t.todos.length ? "" : `<span class="meta">${openTodos.length ? `${openTodos.length} open` : "all done"}${finished.length ? ` · ${finished.length} finished` : ""}</span>`) +
    (finished.length > FINISHED_SHOWN
      ? `<button class="btn small ghost" data-action="done-toggle" data-task="${esc(t.id)}">${ui.doneOpen.has(t.id) ? "Hide finished" : `Show ${hiddenDone} finished`}</button>` : "");
  const live = liveFor(t.id);
  const unbound = ui.sessions.filter((s) => s.task !== t.id);
  // The log reads newest first, grouped by day, with the time of day beside each entry.
  const logs = logEntries(t);
  const showLogs = (ui.logAll.has(t.id) ? logs : logs.slice(-3)).slice().reverse();
  let lastDay = "";
  const logHtml = showLogs.map((l) => {
    const day = logDay(l.date);
    const head = day !== lastDay ? `<li class="day">${esc(day)}</li>` : "";
    lastDay = day;
    return `${head}<li class="e"><time title="${esc(l.date)}">${esc(l.date.slice(11, 16))}</time><div>${inline(l.text)}</div></li>`;
  }).join("");
  const refs = list(t.refs).map(resolveRef);
  const resEdit = ui.resOpen.has(t.id);
  const dirs = list(t.workdirs);
  // Settled things — status, project, category, directories, links — sit in the right rail as
  // plain text; "Edit" turns the first three into menus and opens `next` for editing.
  const editNext = adding("next") || (ui.drafts[k("next")] !== undefined && ui.drafts[k("next")] !== (t.next || ""));
  const tools = `<div class="tools">
      <button class="btn small ${editNext ? "on" : ""}" data-action="toggle-add" data-what="next" data-task="${esc(t.id)}"
        title="${editNext ? "Done editing" : "Edit status, project, category and next"}">${editNext ? "Done" : "Edit"}</button>
      <button class="btn small" data-action="open" data-path="${esc(t.path)}" title="Open the card file">Open card</button>
      ${launchSplit(t)}
    </div>`;
  const head = editNext ? `<div class="now editing">
      <div class="metarow">
        <label>status <select data-action="set-status" data-task="${esc(t.id)}">
          ${ORDER.map((s) => `<option value="${s}" ${s === t.status ? "selected" : ""}>${LABEL[s]}</option>`).join("")}
        </select></label>
        <label>project <select data-action="set-project" data-task="${esc(t.id)}">
          <option value="" ${t.project ? "" : "selected"}>(no project)</option>
          ${projectNames().map((c) => `<option value="${esc(c)}" ${c === t.project ? "selected" : ""}>${esc(c)}</option>`).join("")}
          ${t.project && !projectNames().includes(t.project) ? `<option value="${esc(t.project)}" selected>${esc(t.project)} (not in list)</option>` : ""}
        </select></label>
        <label>category <select data-action="set-category" data-task="${esc(t.id)}">
          <option value="" ${t.category ? "" : "selected"}>(none)</option>
          ${categories().map((c) => `<option value="${esc(c)}" ${c === t.category ? "selected" : ""}>${esc(c)}</option>`).join("")}
          ${t.category && !categories().includes(t.category) ? `<option value="${esc(t.category)}" selected>${esc(t.category)} (not in list)</option>` : ""}
        </select></label>
        <span class="spacer"></span>${tools}
      </div>
      ${field("next", "Next", "the next concrete step")}
    </div>`
    : `<div class="now">
      <div class="now-t"><div class="k">Next</div><div class="v">${t.next ? inline(t.next) : `<span class="faint">No next step yet — Edit to set one</span>`}</div></div>
      ${tools}
    </div>`;
  const sessRow = (s) => `<div class="bsess">
        ${dot(s)}
        <div class="bs-t"><div class="stitle" title="${esc(s.title || s.project)}">${newTag(s.sessionId)}${esc(String(s.title || s.project).replace(new RegExp("^" + t.id + "\\s+"), "") || s.title || s.project)}</div>
          <div class="meta">${s.background ? `<span class="bgtag">background</span> ` : ""}${esc(statusWord(s))}${ctxTag(s)} · ${ago(s.updatedAt)}</div>${approveBar(s)}</div>
        <div class="icons">
          <button class="icon" data-action="peek" data-session="${esc(s.sessionId)}" title="Peek — open the conversation">${ICON.peek}</button>
          ${s.background
            ? `<button class="icon" data-action="attach" data-session="${esc(s.bgId || s.sessionId)}" title="Attach — open it in ${esc(PLACES[launchPlace() === "bg" ? "terminal" : launchPlace()])}">${ICON.attach}</button>
               <button class="icon ${ui.stopArmed === (s.bgId || s.sessionId) ? "armed" : ""}" data-action="stop" data-session="${esc(s.bgId || s.sessionId)}" title="Stop this background session (its conversation is kept)">${ui.stopArmed === (s.bgId || s.sessionId) ? "Stop?" : ICON.stop}</button>`
            : `<button class="icon" data-action="jump" data-session="${esc(s.sessionId)}" title="Jump to its terminal">${ICON.jump}</button>`}
          <button class="icon" data-confirm="Unbind?" data-action="unbind" data-session="${esc(s.sessionId)}" title="Unbind from this task">✕</button>
        </div></div>`;
  return `<div class="task-body">
    ${head}
    <div class="tcols">
      <div class="tmain">
        ${secHead("Todos", t, "todo", "Add a todo", null, todoState)}
        ${adding("todo") ? `<div class="row nowrap addbox">
            <input class="note" data-key="${k("addtodo")}" data-task="${esc(t.id)}" data-enter="addtodo" placeholder="e.g. @me send the reply to …   (@me = you, @claude, or a name)" value="${esc(draft(k("addtodo")))}">
            <button class="btn small primary" data-action="add-todo" data-task="${esc(t.id)}">Add</button></div>` : ""}
        ${shownTodos.length ? `<div class="todos">${shownTodos.map(todoRow).join("")}</div>` : `<div class="empty">No todos.</div>`}

        ${secHead("Log", t, "log", "Add a note — the task's memory; bound sessions read it", logs.length || null)}
        ${adding("log") ? `<div class="addbox"><textarea class="note logbox" data-key="${k("log")}" placeholder="A decision, a finding, a note for whoever picks this up next">${esc(draft(k("log")))}</textarea>
            <div class="row" style="justify-content:flex-end"><button class="btn small primary" data-action="add-log" data-task="${esc(t.id)}">Save note</button></div></div>` : ""}
        ${showLogs.length ? `<ol class="logs">${logHtml}</ol>` : `<div class="empty">Nothing logged yet.</div>`}
        ${logs.length > 3 ? `<button class="btn small ghost more" data-action="log-all" data-task="${esc(t.id)}">${ui.logAll.has(t.id) ? "Show latest 3" : `Show all ${logs.length}`}</button>` : ""}
      </div>
      <aside class="trail">
        <dl class="props">
          <dt>Status</dt><dd><span class="pill" data-st="${esc(t.status)}">${esc(LABEL[t.status] || t.status || "—")}</span></dd>
          <dt>Project</dt><dd>${esc(t.project || "—")}</dd>
          <dt>Category</dt><dd>${esc(t.category || "—")}</dd>
          <dt>Folders</dt><dd>${dirs.length ? dirs.map((x) => `<span class="path" title="${esc(x)}">${esc(tildePath(x).split("/").pop() || tildePath(x))}</span>`).join("")
            : `<span class="faint" title="Added automatically when a session is bound">none yet</span>`}</dd>
          <dt>Links</dt><dd>
            ${refs.map((r) => `<div class="ref-i">${r.url ? `<a href="#" class="ref" data-action="link" data-url="${esc(r.url)}" title="${esc(r.label + "\n" + r.url)}">${esc(shortLabel(r.label))}</a>` : `<span class="ref none" title="${esc(r.label)}">${esc(shortLabel(r.label))}</span>`}
              ${resEdit ? `<button class="icon x" title="Remove" data-confirm="Remove?" data-action="ref-remove" data-task="${esc(t.id)}" data-ref="${esc(r.ref)}">✕</button>` : ""}</div>`).join("")}
            <button class="lnk ${resEdit ? "on" : ""}" data-action="toggle-res" data-task="${esc(t.id)}">${resEdit ? "Done" : refs.length ? "Edit" : "+ Add"}</button>
          </dd>
        </dl>
        ${resEdit ? `<div class="res">
          <div class="row nowrap"><input class="note" data-key="${k("addref")}" data-task="${esc(t.id)}" data-enter="addref" placeholder="URL, or QA-123, repo#45" value="${esc(draft(k("addref")))}">
            <button class="btn small" data-action="add-ref" data-task="${esc(t.id)}">Add</button></div>
          ${!(ui.board && (ui.board.links || []).length) ? `<div class="meta">Shorthand like QA-123 becomes a link once you add a rule under "links" in hq.json (see Guide).</div>` : ""}
        </div>` : ""}
        <div class="rail-sec">
          <div class="sec-h"><h3>Sessions <span class="meta">${live.length || ""}</span></h3>
            <button class="icon ${adding("bind") ? "on" : ""}" title="Bind a live session" data-action="toggle-add" data-what="bind" data-task="${esc(t.id)}">${PLUS}</button></div>
          ${adding("bind") ? `<div class="row nowrap addbox">${unbound.length
              ? `<select class="bind" data-key="${k("bindpick")}"><option value="">Choose a live session…</option>
                  ${unbound.map((s) => `<option value="${esc(s.sessionId)}" ${draft(k("bindpick")) === s.sessionId ? "selected" : ""}>${esc(s.title || s.project)} (${esc(s.project)})${s.task ? " · now on " + esc(s.task) : ""}</option>`).join("")}</select>
                 <button class="btn small primary" data-action="bind-pick" data-task="${esc(t.id)}">Bind</button>`
              : `<span class="empty">No other live sessions.</span>`}</div>` : ""}
          ${live.length ? live.map(sessRow).join("") : `<div class="empty">None live.</div>`}
          ${earlierList(t)}
        </div>
      </aside>
    </div>
  </div>`;
}

// Small line icons (currentColor), so the session cards need no button labels.
const ICON = {
  peek: '<svg viewBox="0 0 16 16"><path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8 12.1 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/></svg>',
  jump: '<svg viewBox="0 0 16 16"><path d="M9 2.5h4.5V7M13.5 2.5 7 9M11.5 9.5v3a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1h3"/></svg>',
  message: '<svg viewBox="0 0 16 16"><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/></svg>',
  attach: '<svg viewBox="0 0 16 16"><path d="M2.5 4.5h11v8h-11zM5 7.5l2 1.5-2 1.5M8.5 10.5h2.5"/></svg>',
  stop: '<svg viewBox="0 0 16 16"><rect x="4" y="4" width="8" height="8" rx="1.5"/></svg>',
};

// plain: one flat list; "state": grouped by what they are doing, whatever All's Sessions toggle says.
function renderSessions(items = ui.sessions, plain = false) {
  if (!items.length) return `<div class="empty">No live Claude Code sessions (Claude Pet sees sessions started after it was installed).</div>`;
  const openTasks = tasks().filter(isOpen);
  const card = (s) => {
    const t = s.task && taskById(s.task);
    const sid = s.sessionId;
    const sorted = openTasks.slice().sort((a, b) =>
      (list(b.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0) -
      (list(a.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0));
    const taskCtl = t
      ? `<span class="tid link" data-task="${esc(t.id)}" data-action="goto" title="${esc(t.title)}">${esc(t.id)}</span>`
      : `<select class="bind mini" data-action="bind-session" data-session="${esc(sid)}" title="Bind this session to a task">
           <option value="">Bind…</option>
           ${sorted.map((x) => `<option value="${esc(x.id)}">${esc(x.id)} ${esc(x.title)}</option>`).join("")}
         </select>`;
    const busy = s.state === "busy";
    const kind = s.terminal && s.terminal.kind;
    const canSend = Boolean(SENDABLE[kind]);
    const why = canSend ? "" : s.background ? "A background session has no terminal to type into — Attach to talk to it."
      : `Messaging from the Task Board isn't supported for ${kind ? (TERMINAL_NAME[kind] || kind) + " terminals" : "this session's terminal"} yet — use Jump to open it.`;
    // The message box only takes room when asked for (or while it holds a draft).
    const open = canSend && (ui.msgOpen.has(sid) || Boolean(draft("msg:" + sid)) || Boolean((ui.atts[sid] || []).length));
    // Title and time on the first line; the task, the project and what it is doing on the second;
    // its last words (markdown and hq blocks stripped) below, two lines at most. The buttons
    // appear on hover, over the time.
    const title = s.title || s.project || sid.slice(0, 8);
    return `<div class="session">
      ${dot(s)}
      <div class="body">
        <div class="shead">
          <div class="stitle" title="${esc(title)}">${newTag(sid)}${esc(t ? title.replace(new RegExp("^" + t.id.replace(/[-]/g, "\\-") + "\\s*"), "") || title : title)}</div>
          <span class="stime">${ago(s.updatedAt).replace(" ago", "")}</span>
        </div>
        <div class="shead">
          <div class="meta smeta">${taskCtl}${s.background ? ` <span class="bgtag">background</span>` : ""} · ${ui.sgroupBy !== "project" && sessionProject(s) && sessionProject(s) !== s.project ? `<span class="pchip">${esc(sessionProject(s))}</span> · ` : ""}${esc(s.project || "")} · ${esc(statusWord(s))}${ctxTag(s)}${s.waitingOn ? " · waiting: " + esc(s.waitingOn) : ""}</div>
          <div class="icons">
            <button class="icon" data-action="peek" data-session="${esc(sid)}" title="Peek — open the recent conversation">${ICON.peek}</button>
            ${s.background
              ? `<button class="icon" data-action="attach" data-session="${esc(s.bgId || sid)}" title="Attach — open it in a terminal">${ICON.attach}</button>
                 <button class="icon ${ui.stopArmed === (s.bgId || sid) ? "armed" : ""}" data-action="stop" data-session="${esc(s.bgId || sid)}" title="Stop this background session (its conversation is kept)">${ui.stopArmed === (s.bgId || s.sessionId) ? "Stop?" : ICON.stop}</button>`
              : `<button class="icon" data-action="jump" data-session="${esc(sid)}" title="Jump to its terminal">${ICON.jump}</button>`}
            <span title="${esc(canSend ? (open ? "Hide the message box" : "Message this session") : why)}"><button class="icon ${open ? "on" : ""}" data-action="toggle-msg" data-session="${esc(sid)}" ${canSend ? "" : "disabled"}>${ICON.message}</button></span>
          </div>
        </div>
        ${approveBar(s)}
        ${plainText(s.lastText) ? `<div class="last">${esc(plainText(s.lastText))}</div>` : ""}
        ${open ? `<div class="send">
          <textarea class="grow" rows="1" data-key="msg:${esc(sid)}" data-session="${esc(sid)}"
            placeholder="${busy ? "Busy — it will queue · paste or drop images" : "Message · paste or drop images"}">${esc(draft("msg:" + sid))}</textarea>
          ${sendButton(sid, true)}
        </div>${attachStrip(sid)}` : ""}
      </div>
    </div>`;
  };
  if (plain === true) return items.map(card).join("");
  // As a list: what waits on you first, then what is working, then the rest — newest first in each.
  if (plain === "state" || ui.sgroupBy !== "project") {
    const newest = (a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""));
    return [["waiting", "Waiting on you"], ["busy", "Working"], ["", "Idle"]].map(([st, label]) => {
      const group = items.filter((x) => (st ? x.state === st : x.state !== "waiting" && x.state !== "busy")).sort(newest);
      return group.length ? `<div class="group-title">${label} <span class="meta">${group.length}</span></div>${group.map(card).join("")}` : "";
    }).join("");
  }
  // By project: same order as the Tasks column (active first if ticked), "No project" last.
  const names = projectNames();
  let order = [...names];
  const activity = Object.fromEntries(order.map((n) => [n, projectActivity(n)]));
  if (ui.activeFirst) order = order.slice().sort((x, y) => (activity[y] || 0) - (activity[x] || 0));
  const byProject = (n) => items.filter((x) => sessionProject(x) === n);
  const extra = [...new Set(items.map(sessionProject).filter((n) => n && !names.includes(n)))];
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

// A session's last words as plain text: no hq-asks / hq-resolved blocks, code fences, or markdown marks.
function plainText(text) {
  return String(text || "")
    .replace(/```hq-[a-z]+[\s\S]*?(```|$)/g, " ")
    .replace(/```[a-z]*\n?/g, " ")
    .replace(/\[([^\]]+)\]\((?:[^()\s]|\([^()\s]*\))*\)/g, "$1")
    .replace(/\*\*(.+?)\*\*/g, "$1")
    .replace(/`/g, "")
    .replace(/^\s*(#{1,6}\s+|>\s?)/gm, "")
    .replace(/\s+/g, " ").trim();
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
  // Every field keeps its draft (nt:*): the form is rebuilt with the board, every few seconds
  // while sessions are busy, and a field without a draft came back empty.
  const v = (k, d = "") => ui.drafts["nt:" + k] ?? d;
  const cat = v("cat", dflt), proj = v("proj"), sess = v("session");
  return `<div class="card">
    <div class="field"><label>title</label><input id="nt-title" data-key="nt:title" placeholder="What is this task?" value="${esc(v("title"))}"></div>
    <div class="field"><label>project</label><select id="nt-proj" data-key="nt:proj"><option value="">(auto from the workdir)</option>${projectNames().map((c) =>
      `<option value="${esc(c)}" ${c === proj ? "selected" : ""}>${esc(c)}</option>`).join("")}</select></div>
    <div class="field"><label>category</label><select id="nt-cat" data-key="nt:cat"><option value="" ${cat ? "" : "selected"}>(none)</option>${cats.map((c) =>
      `<option value="${esc(c)}" ${c === cat ? "selected" : ""}>${esc(c)}</option>`).join("")}</select></div>
    <div class="field"><label>workdir</label><input id="nt-dir" data-key="nt:dir" list="nt-dirs" value="${esc(v("dir"))}" placeholder="optional — type a path or pick one; binding a session adds its directory">
      <datalist id="nt-dirs">${dirs.map((d) => `<option value="${esc(d)}">`).join("")}</datalist></div>
    <div class="field"><label>bind session</label><select id="nt-session" data-key="nt:session"><option value="">—</option>
      ${ui.sessions.filter((s) => !s.task).map((s) => `<option value="${esc(s.sessionId)}" ${s.sessionId === sess ? "selected" : ""}>${esc(s.title || s.project)}</option>`).join("")}</select></div>
    <div class="row" style="justify-content:flex-end"><button class="btn ghost" data-action="cancel-new">Cancel</button>
      <button class="btn primary" data-action="create">Create</button></div>
  </div>`;
}

function clearNewTaskDrafts() { for (const k of Object.keys(ui.drafts)) if (k.startsWith("nt:")) delete ui.drafts[k]; saveDrafts(); }

// ---- Settings: one window for what used to crowd the top bar — projects, categories, and how
// the board starts sessions. Open on any page (⚙); Esc, Done or a click outside closes it.
const SETTINGS_TABS = [["projects", "Projects"], ["categories", "Categories"], ["sessions", "Sessions"]];
function renderSettings() {
  const box = $("#settings");
  if (!ui.settings) { box.hidden = true; box.innerHTML = ""; return; }
  const tab = ui.settings;
  const prev = box.querySelector(".settings-body");
  const scroll = prev && prev.dataset.tab === tab ? prev.scrollTop : 0;
  const body = tab === "projects" ? renderProjects() : tab === "categories" ? renderCategories() : renderSessionSettings();
  // Keep the cursor if a box in here is being typed in (the window is rebuilt with the board).
  box.innerHTML = `<div class="panel" role="dialog" aria-label="Settings">
    <div class="phead"><div class="stitle">Settings</div>
      <span class="seg">${SETTINGS_TABS.map(([k, label]) => `<button class="${tab === k ? "on" : ""}" data-action="settings-tab" data-tab="${k}">${label}</button>`).join("")}</span>
      <span style="flex:1"></span><button class="btn small" data-action="close-settings">Done</button></div>
    <div class="settings-body" data-tab="${tab}">${body}</div></div>`;
  box.hidden = false;
  box.querySelector(".settings-body").scrollTop = scroll;   // rebuilt with the board, every few seconds
}
function closeSettings() { ui.settings = null; ui.projRemove = {}; ui.catRemove = {}; render(); }
function renderSessionSettings() {
  const row = (title, tip, ctl) => `<div class="set-row"><div><b>${title}</b><div class="meta">${tip}</div></div>${ctl}</div>`;
  return `<div class="set-list">
    ${row("New sessions open in", "Where ▶ New session, ↻ Resume and ▶ Do it open a session",
      `<select class="bind" data-action="launch-place">${Object.entries(PLACES).map(([k, v]) => `<option value="${k}" ${launchPlace() === k ? "selected" : ""}>${v}</option>`).join("")}</select>`)}
    ${row("Skip permissions", "Start and resume sessions with --dangerously-skip-permissions: Claude won't stop to ask before running commands or editing files",
      `<input type="checkbox" data-action="skip-perms" ${skipPerms() ? "checked" : ""}>`)}
    ${row("Stay on board", "Open the session's terminal tab in the background and carry on here, in its conversation window",
      `<input type="checkbox" data-action="stay-board" ${stayOnBoard() ? "checked" : ""}>`)}
    ${row("Active first", "Tasks (and project groups) with a live session come first, most recently active first. Off: your own order",
      `<input type="checkbox" data-action="active-first" ${ui.activeFirst ? "checked" : ""}>`)}
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
        <button class="icon" title="Remove this project" ${tasks().some((x) => x.project === pr.name) ? "" : `data-confirm="Remove?"`} data-action="proj-remove" data-p="${esc(pr.name)}">✕</button>
      </div>
      <div class="proj-paths">${pr.paths.map((x) => `<div class="res-i"><span class="meta">${esc(x)}</span>
          <button class="icon" title="Remove this directory" data-confirm="Remove?" data-action="proj-path-remove" data-p="${esc(pr.name)}" data-path="${esc(x)}">✕</button></div>`).join("")
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
    <div class="row" style="margin-top:8px"><button class="btn small" data-action="scan">Suggest from sessions</button>
      <span class="meta">finds repositories and directories your Claude Code sessions worked in</span></div>
    ${renderScan()}
  </div>`;
}

// ---- onboarding: suggest projects from the sessions already on this machine (hq scan)
function renderScan() {
  if (!ui.scan) return "";
  if (ui.scan === "loading") return `<div class="empty">Scanning your Claude Code sessions…</div>`;
  const fresh = ui.scan.projects.filter((p) => !p.existing);
  if (!fresh.length) return `<div class="empty">Every directory your sessions worked in already belongs to a project.</div>`;
  return `<div class="res" style="margin-top:6px">
    <div class="meta" style="margin-bottom:4px">${ui.scan.sessions.length} sessions in the last ${ui.scan.days} days. Pick the projects to create (skip personal or throwaway folders):</div>
    ${fresh.map((p) => `<label class="scan-i"><input type="checkbox" data-action="scan-pick" data-name="${esc(p.name)}" ${ui.scanPick.has(p.name) ? "checked" : ""}>
      <b>${esc(p.name)}</b> <span class="meta">${p.count} session${p.count === 1 ? "" : "s"} · ${ago(p.last)} · ${esc(p.path)}</span></label>`).join("")}
    <div class="row" style="margin-top:6px"><button class="btn small primary" data-action="scan-apply" ${ui.scanPick.size ? "" : "disabled"}>Create ${ui.scanPick.size || ""} project${ui.scanPick.size === 1 ? "" : "s"}</button>
      <button class="btn small ghost" data-action="scan-close">Close</button></div>
  </div>`;
}
function renderOnboarding() {
  return `<div class="card onboard">
    <h4>Start from the sessions you already have</h4>
    <ol>
      <li><b>Projects.</b> Find the repositories and folders your Claude Code sessions worked in, and pick which become projects.
        <div class="row" style="margin-top:4px"><button class="btn small primary" data-action="scan-open">Suggest projects</button></div></li>
      <li><b>Tasks.</b> In any Claude Code session, run <code>/hq-onboard</code>. Claude reads your recent sessions, drafts task cards (status, next step, your todos, links), shows you the list and creates nothing until you confirm. Live sessions get bound to their tasks.
        <div class="row" style="margin-top:4px"><button class="btn small" data-action="copy-onboard">Copy /hq-onboard</button></div></li>
      <li>Adjust anything here afterwards — or start fresh with <b>+ New task</b>.</li>
    </ol>
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
      <button class="btn small ghost" ${categoryCount(c) ? "" : `data-confirm="Remove?"`} data-action="cat-remove" data-cat="${esc(c)}" title="Remove this category">✕</button>
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

async function openPeek(sid, back, opt = {}) {
  const s = ui.sessions.find((x) => x.sessionId === sid || x.sessionId.startsWith(sid));
  ui.modal = { type: "peek", sid: s ? s.sessionId : sid, title: (s && (s.title || s.project)) || opt.title || sid.slice(0, 8),
               project: s ? s.project : "", cwd: s ? s.cwd : "", live: Boolean(s), msgs: null, sig: "", back: back || null,
               // Just started from the board: not live yet, but not ended either — it is coming up.
               starting: Boolean(opt.starting) && !s, startedAt: Date.now() };
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
  // A session that has come up (or ended) since the window opened: send box on or off.
  const s = ui.sessions.find((x) => x.sessionId === m.sid);
  let changed = false;
  if (Boolean(s) !== m.live) {
    m.live = Boolean(s); changed = true;
    if (s) { m.title = s.title || s.project || m.title; m.project = s.project; m.cwd = s.cwd; m.starting = false; }
  }
  if (m.starting && Date.now() - m.startedAt > 120000) { m.starting = false; changed = true; }
  if (msgs && !Array.isArray(msgs)) {          // --meta form: also says who the session is
    if (!m.live) { m.title = msgs.title || m.title; m.cwd = msgs.cwd || m.cwd;
                   m.project = m.project || (msgs.cwd || "").split("/").pop(); }
    m.found = msgs.found;
    msgs = msgs.messages || [];
  }
  const sig = JSON.stringify(msgs);
  if (sig === m.sig && !changed) return;
  // Never rebuild under a selection the user is making or about to copy.
  const sel = window.getSelection();
  if (!first && sel && !sel.isCollapsed && $("#modal").contains(sel.anchorNode)) return;
  m.msgs = msgs;
  m.sig = sig;
  drawPeek(first);
}
function drawPeek(toBottom) {
  if (ui.composing) { ui.peekPending = ui.peekPending || { toBottom: false }; ui.peekPending.toBottom ||= Boolean(toBottom); return; }
  const m = ui.modal;
  const box = $("#modal");
  // The reply box is rebuilt with the rest; keep the cursor in it.
  const active = document.activeElement;
  const typing = active && box.contains(active) && active.tagName === "TEXTAREA" ? [active.selectionStart, active.selectionEnd] : null;
  const body = box.querySelector(".peek-body");
  const atBottom = !body || body.scrollHeight - body.scrollTop - body.clientHeight < 12;
  const s = ui.sessions.find((x) => x.sessionId === m.sid) || {};
  const canSend = m.live && Boolean(SENDABLE[s.terminal && s.terminal.kind]);
  const noSend = m.starting ? "Starting the session — you can type here as soon as it is up" : !m.live ? "This session has ended — history only" : "Not supported in this terminal";
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
      <div><div class="stitle">${esc(m.title)}${m.live ? "" : m.starting ? ` <span class="chip">starting…</span>` : ` <span class="chip">ended</span>`}</div><div class="meta">${esc(m.project || "")} · last ${msgs ? msgs.length : "…"} messages · click outside or Esc to close</div></div>
      <span style="flex:1"></span>
      <button class="btn small" data-action="copy-all">Copy all</button>
      ${m.live ? `<button class="btn small" data-action="jump" data-session="${esc(m.sid)}">Jump</button>` : ""}
      <button class="btn small ghost" data-action="close-modal" title="Close (Esc)">✕</button>
    </div>
    <div class="peek-body">${list}</div>
    <div class="send pfoot ${canSend ? "" : "disabled"}" title="${canSend ? "" : m.starting ? "Starting the session…" : !m.live ? "This session has ended." : "Messaging isn't supported for this session's terminal yet — use Jump."}">
      <textarea class="grow" rows="1" data-key="msg:${esc(m.sid)}" data-session="${esc(m.sid)}" ${canSend ? "" : "disabled"}
        placeholder="${canSend ? "Reply to this session — paste or drop images too" : noSend}">${esc(keepDraft ?? draft("msg:" + m.sid))}</textarea>
      ${sendButton(m.sid, canSend)}
    </div>${canSend ? attachStrip(m.sid) : ""}
  </div>`;
  box.hidden = false;
  fitAllGrow(box);
  if (typing) { const ta = box.querySelector("textarea"); if (ta) { ta.focus(); ta.setSelectionRange(typing[0], typing[1]); } }
  const nb = box.querySelector(".peek-body");
  if (toBottom || atBottom) nb.scrollTop = nb.scrollHeight;
}
document.addEventListener("mousedown", (ev) => {
  // Backdrop only: a drag that starts inside the panel (selecting text) must not close it.
  if (ui.modal && ev.target === $("#modal")) closePeek();
  if (ui.settings && ev.target === $("#settings")) closeSettings();
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
        ${live.map((s) => `<div class="row ctx-s">${dot(s)}<span>${esc(s.title || s.project)}</span><span class="meta">${esc(statusWord(s))}${ctxTag(s)}</span>${sessBtn(s.sessionId, "Conversation", true)}</div>`).join("")}
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
// A URL is ASCII: it ends at the first space, quote, bracket or non-ASCII character (a Chinese
// comma or full-width bracket right after a link must not become part of it).
// printable ASCII except quotes and angle brackets
const URL_CHARS = /\bhttps?:\/\/[\x21\x23-\x26\x28-\x3b\x3d\x3f-\x7e]+/g;
const URL_RE = URL_CHARS;
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
    // quotes, brackets and sentence punctuation right after a link belong to the sentence
    const trail = (u.match(/[.,;:!?'"<>)\]]+$/) || [""])[0];
    const url = trail ? u.slice(0, -trail.length) : u;
    return hold(`<a href="#" data-action="link" data-url="${esc(url)}">${esc(url)}</a>`) + esc(trail);
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

// Code stays code, but a URL inside it can still be clicked. Matched on the raw text, then
// escaped piece by piece, so an escaped quote can't leak into the link.
function linkifyCode(code) {
  let out = "", last = 0;
  for (const m of code.matchAll(URL_CHARS)) {
    const trail = (m[0].match(/[.,;:!?)\]]+$/) || [""])[0];
    const url = trail ? m[0].slice(0, -trail.length) : m[0];
    out += esc(code.slice(last, m.index)) + `<a href="#" data-action="link" data-url="${esc(url)}">${esc(url)}</a>`;
    last = m.index + url.length;
  }
  return out + esc(code.slice(last));
}

function markdown(text) {
  const out = [];
  const parts = String(text).split(/^```/m);
  parts.forEach((part, idx) => {
    if (idx % 2 === 1) {                       // fenced code: drop the language tag line
      const nl = part.indexOf("\n");
      const lang = nl >= 0 ? part.slice(0, nl).trim() : "";
      const code = nl >= 0 && !/\s/.test(lang) ? part.slice(nl + 1) : part;
      // HQ's own blocks are for people too: a titled list with live links, not a code box.
      if (lang === "hq-asks" || lang === "hq-resolved" || lang === "hq-update") {
        const items = code.split("\n").map((l) => l.replace(/^\s*(?:[-*]|\d+[.)])\s*/, "").trim()).filter(Boolean);
        out.push(`<div class="hqblock ${lang}"><div class="hqb-t">${{ "hq-asks": "Asked you", "hq-resolved": "Answers recorded", "hq-update": "Card updated" }[lang]}</div>
          <ul>${items.map((i) => `<li>${inline(i)}</li>`).join("")}</ul></div>`);
        return;
      }
      out.push(`<pre><code>${linkifyCode(code.replace(/\n$/, ""))}</code></pre>`);
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
  // In Today, a task on today's list is its card there: bring that card's top edge to the top
  // of the column, without opening its details. Anything else is shown in All.
  if (ui.mode !== "all") {
    if (ui.mode === "today" && focusIds().includes(id)) return scrollToCard("ftask-" + id);
    ui.mode = "all";
    savePref("hq-mode", "all");
  }
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
  scrollToCard("task-" + id);
}

// Puts a card's top edge at the top of its scrolling column (with a little air) and flashes it.
function scrollToCard(elementId) {
  const node = document.getElementById(elementId);
  if (!node) return;
  const col = node.closest(".col");
  if (col) {
    const top = node.getBoundingClientRect().top - col.getBoundingClientRect().top + col.scrollTop - 8;
    col.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
  } else {
    node.scrollIntoView({ behavior: "smooth", block: "start" });
  }
  node.classList.add("flash");
  setTimeout(() => node.classList.remove("flash"), 1400);
}

// Text boxes that may hold several lines grow with what is in them — up to five lines, then
// they scroll (the cap is max-height in CSS). Run after every rebuild too: a box redrawn with a
// three-line draft would otherwise come back one line tall.
function fitGrow(el) {
  // Empty: one line, whatever the placeholder would wrap to in a narrow column.
  if (!el.value) { el.style.height = ""; return; }
  el.style.height = "auto";
  el.style.height = el.scrollHeight + 2 + "px";
}
function fitAllGrow(root = document) { root.querySelectorAll("textarea.grow").forEach(fitGrow); }

// The button a two-click confirm is waiting on, and how it is drawn after every rebuild.
function confirmKey(d) { return Object.keys(d).filter((k) => k !== "confirm").sort().map((k) => `${k}=${d[k]}`).join("&"); }
function paintArmed() {
  if (!ui.armed) return;
  for (const b of document.querySelectorAll("[data-confirm]")) {
    if (confirmKey(b.dataset) === ui.armed) { b.classList.add("armed"); b.textContent = b.dataset.confirm; }
  }
}

// ------------------------------------------------------------------ actions
// ---- images in a message or an ask's note: pasted or dropped, saved to a file, sent as their
// paths (Claude Code reads an image from a path in the prompt). Keyed by session id, or
// "ask:<id>" for an ask's note.
function attachStrip(sid) {
  const list = ui.atts[sid] || [];
  if (!list.length) return "";
  return `<div class="atts">${list.map((a, i) => `<span class="att" title="${esc(a.path)}"><img src="${a.url}" alt="">
      <button class="icon" title="Remove" data-action="att-remove" data-session="${esc(sid)}" data-i="${i}">✕</button></span>`).join("")}</div>`;
}
// A 128×96 JPEG preview of an image, small enough to keep with the drafts.
function thumbnail(dataURL) {
  return new Promise((ok) => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement("canvas"); c.width = 128; c.height = 96;
      const k = Math.max(128 / img.width, 96 / img.height), w = img.width * k, h = img.height * k;
      c.getContext("2d").drawImage(img, (128 - w) / 2, (96 - h) / 2, w, h);
      try { ok(c.toDataURL("image/jpeg", 0.75)); } catch (e) { ok(dataURL); }
    };
    img.onerror = () => ok(dataURL);
    img.src = dataURL;
  });
}
function readAsDataURL(file) {
  return new Promise((ok, fail) => { const r = new FileReader(); r.onload = () => ok(r.result); r.onerror = fail; r.readAsDataURL(file); });
}
async function addImages(sid, files) {
  let added = 0;
  for (const f of files) {
    if (!f || !/^image\/(png|jpeg|gif|webp)$/.test(f.type)) { toast("Only PNG, JPEG, GIF or WebP images", true); continue; }
    if (f.size > 20 * 1024 * 1024) { toast("That image is larger than 20 MB", true); continue; }
    try {
      const url = await readAsDataURL(f);
      const saved = await api("saveImage", { data: url });
      // Only a small preview is kept (it is saved with the draft); the full image is the file.
      (ui.atts[sid] = ui.atts[sid] || []).push({ path: saved.path, url: await thumbnail(url) });
      added++;
    } catch (e) { toast(String(e.message || e), true); }
  }
  if (added && sid.startsWith("ask:")) autoPick(sid.slice(4), true);   // an image is an answer too
  if (added) { if (!sid.startsWith("ask:")) ui.msgOpen.add(sid); render(); if (ui.modal && ui.modal.type === "peek" && ui.modal.sid === sid) drawPeek(false); }
}
document.addEventListener("paste", (ev) => {
  const box = ev.target.closest && ev.target.closest("textarea[data-session], [data-att]");
  if (!box || !ev.clipboardData) return;
  const files = [...ev.clipboardData.items].filter((i) => i.kind === "file" && i.type.startsWith("image/")).map((i) => i.getAsFile());
  if (!files.length) return;     // plain text pastes as usual
  ev.preventDefault();
  addImages(box.dataset.session || box.dataset.att, files);
});
document.addEventListener("dragover", (ev) => {
  const zone = !ui.dragging && ev.target.closest && ev.target.closest(".send, .card.ask");
  if (!zone || !ev.dataTransfer || ![...ev.dataTransfer.types].includes("Files")) return;
  ev.preventDefault();
  zone.classList.add("dropping");
});
document.addEventListener("dragleave", (ev) => {
  const zone = ev.target.closest && ev.target.closest(".send, .card.ask");
  if (zone) zone.classList.remove("dropping");
});
document.addEventListener("drop", (ev) => {
  const zone = !ui.dragging && ev.target.closest && ev.target.closest(".send, .card.ask");
  if (!zone || !ev.dataTransfer || !ev.dataTransfer.files.length) return;
  ev.preventDefault();
  zone.classList.remove("dropping");
  const box = zone.querySelector("textarea[data-session], [data-att]");
  if (box) addImages(box.dataset.session || box.dataset.att, [...ev.dataTransfer.files]);
});

// A busy session queues what it is sent; there is no new turn to wait for.
const isBusy = (sid) => (ui.sessions.find((x) => x.sessionId === sid) || {}).state === "busy";

// While a message is on its way (Orca waits up to 5 s to see it submitted) the button is locked,
// so a second click can't type the same message into the session again.
function sendButton(sid, enabled) {
  const inFlight = ui.sending.has(sid);
  return `<button class="btn small primary" data-action="send" data-session="${esc(sid)}" ${enabled && !inFlight ? "" : "disabled"}>${inFlight ? "Sending…" : "Send"}</button>`;
}

async function send(sid) {
  if (ui.sending.has(sid)) return;
  const key = "msg:" + sid;
  const text = (ui.drafts[key] || "").trim();
  const images = ui.atts[sid] || [];
  if (!text && !images.length) return;
  const message = [text, ...images.map((a) => a.path)].filter(Boolean).join("\n");
  const queued = isBusy(sid);
  ui.sending.add(sid);
  render();
  if (ui.modal && ui.modal.type === "peek" && ui.modal.sid === sid) drawPeek(false);
  try {
    await api("send", { session: sid, text: message, queue: queued });
    delete ui.drafts[key];
    delete ui.atts[sid];
    const withImgs = images.length ? ` with ${images.length} image${images.length === 1 ? "" : "s"}` : "";
    toast(queued ? `Delivered${withImgs} — queued until the session finishes its turn` : `Sent${withImgs}`);
  } catch (e) {
    toast(String(e.message || e), true);
  } finally {
    ui.sending.delete(sid);
  }
  setTimeout(refresh, 1200);
  render();
  if (ui.modal && ui.modal.type === "peek" && ui.modal.sid === sid) drawPeek(false);
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

const NO_EXPAND = "input, textarea, select, label, a, .card, .askgroup, .bsess, .atts, .tgrip";

// Record every answer picked on a task's asks, then type them into their session as one message.
async function resolveAll(taskId) {
  const t = taskById(taskId);
  const asks = t ? openAsks(t).filter((a) => ui.picks[a.id] && !ui.resolving.has(a.id)) : [];
  if (!asks.length) return;
  const answers = asks.map((a) => ({ a, res: ui.picks[a.id], note: answerNote(a.id),
    draft: ui.drafts["note:" + a.id], imgs: ui.atts["ask:" + a.id],
    // Taken now: a refresh during the awaits below can drop the session from ui.sessions.
    target: pushTarget(a), push: Boolean(pushTarget(a)) && wantPush(a) }));
  for (const x of answers) ui.resolving.add(x.a.id);
  render();
  const done = [];
  try {
    for (const x of answers) {
      try {
        x.made = await answerAsk(x.a, x.res, x.note);
        done.push(x);
        delete ui.picks[x.a.id]; delete ui.drafts["push:" + x.a.id];
        if (x.res !== "snooze") { delete ui.drafts["note:" + x.a.id]; delete ui.atts["ask:" + x.a.id]; }
      } catch (e) { toast(`${x.a.id}: ${e.message || e}`, true); }
    }
    if (!done.length) return;
    let msg = `${done.length} answer${done.length === 1 ? "" : "s"} recorded`;
    // One message per session (normally the one that asked them all).
    const bySession = new Map();
    for (const x of done.filter((x) => x.push)) {
      const sid = x.target.sessionId;
      bySession.set(sid, (bySession.get(sid) || []).concat([x]));
    }
    const sent = [];
    for (const [sid, xs] of bySession) {
      const s = xs[0].target;
      try {
        for (const x of xs) if (x.res !== "snooze") await api("delivered", { id: x.a.id, session: sid });
        await api("send", { session: sid, text: pushMessageAll(xs), queue: Boolean(s && s.state === "busy") });
        sent.push(...xs);
        msg += ` · ${s && s.state === "busy" ? "queued for" : "sent to"} ${s ? s.title || s.project : sid}`;
      } catch (e) {
        for (const x of xs) { try { await api("delivered", { id: x.a.id, session: sid, undo: true }); } catch (e2) { /* best effort */ } }
        msg += ` · couldn't reach the session (${e.message || e}); it gets the answers with your next message there`;
      }
    }
    toast(msg, false, async () => {
      // Reopen everything first, then put the notes back — a refresh in between would prune
      // drafts of asks that are still closed.
      for (const x of done) {
        try {
          if (x.made && x.made.snoozed) await api("snooze", { id: x.a.id, until: "" });
          else { await api("reopen", { id: x.a.id }); await dropMadeTodo(x.made); }
        } catch (e) { toast(String(e.message || e), true); }
      }
      for (const x of done) {
        ui.drafts["note:" + x.a.id] = x.draft || "";
        if (x.imgs) ui.atts["ask:" + x.a.id] = x.imgs;
        ui.picks[x.a.id] = x.res;
      }
      toast(sent.length ? "Reopened — the message already sent stays in the session" : "Reopened");
      refresh();
    });
  } finally {
    try { await refresh(); } finally { for (const x of answers) ui.resolving.delete(x.a.id); render(); }
  }
}

document.addEventListener("click", async (ev) => {
  // The "New session ▾" menu closes on any click outside it.
  if (ui.launchMenu && !ev.target.closest(".launch")) { ui.launchMenu = null; render(); }
  const el = ev.target.closest("[data-action]");
  if (!el || el.tagName === "SELECT") return;
  const d = el.dataset;
  // Removing or unbinding asks twice: the first click turns the button into a red "Unbind?" for
  // 4 s, the second does it. (WKWebView has no confirm() dialog.)
  if (d.confirm) {
    const key = confirmKey(d);
    if (ui.armed !== key) {
      ui.armed = key;
      clearTimeout(ui.armTimer);
      ui.armTimer = setTimeout(() => { if (ui.armed === key) { ui.armed = null; render(); } }, 4000);
      return render();
    }
    ui.armed = null;
    clearTimeout(ui.armTimer);
  }
  switch (d.action) {
    case "resolve": {
      // one answer per ask, even if the button is clicked again while it's being sent
      if (ui.resolving.has(d.id)) return;
      ui.resolving.add(d.id);
      const note = answerNote(d.id);
      const draftNote = ui.drafts["note:" + d.id], imgs = ui.atts["ask:" + d.id];
      // Later leaves the ask open, so a half-written note and its images stay for tomorrow.
      if (d.res !== "snooze") { delete ui.drafts["note:" + d.id]; delete ui.atts["ask:" + d.id]; }
      const a = tasks().flatMap((t) => t.asks || []).find((x) => x.id === d.id);
      const target = a && pushTarget(a);
      const push = Boolean(target) && wantPush(a);
      delete ui.drafts["push:" + d.id];
      try {
        const made = await answerAsk(a, d.res, note);
        let msg = `${d.id} → ${d.res === "todo" ? "@me todo" : d.res}`;
        if (push) {
          // Mark first: the message starts a turn at once, and that turn's hook must not inject
          // the same answer again. Unmark if the message never got there.
          try {
            // (Later is not an answer: nothing to keep the hook from repeating.)
            if (d.res !== "snooze") await api("delivered", { id: d.id, session: target.sessionId });
            await api("send", { session: target.sessionId, text: pushMessage(a, d.res, note), queue: target.state === "busy" });
            msg += ` · ${target.state === "busy" ? "queued for" : "sent to"} ${target.title || target.project}`;
          } catch (e) {
            try { await api("delivered", { id: d.id, session: target.sessionId, undo: true }); } catch (e2) { /* best effort */ }
            msg += ` · couldn't reach the session (${e.message || e}); it gets the answer with your next message there`;
          }
        }
        // Undo reopens the ask; an answer already typed into a session cannot be taken back.
        // Reopen first: a refresh while the ask is still closed would prune the restored note.
        toast(msg, false, async () => {
          try {
            if (made && made.snoozed) await api("snooze", { id: d.id, until: "" });
            else { await api("reopen", { id: d.id }); await dropMadeTodo(made); }
            ui.drafts["note:" + d.id] = draftNote || "";
            if (imgs) ui.atts["ask:" + d.id] = imgs;
            toast(push ? `${d.id} reopened — the message already sent stays in the session` : `${d.id} reopened`);
          } catch (e) { toast(String(e.message || e), true); }
          await refresh();
        });
      } catch (e) {
        // Not answered: the note and images go back where they were.
        if (draftNote) ui.drafts["note:" + d.id] = draftNote;
        if (imgs) ui.atts["ask:" + d.id] = imgs;
        toast(String(e.message || e), true);
      }
      try { await refresh(); } finally { ui.resolving.delete(d.id); }
      return;
    }
    case "pick":
      ui.autoPicked.delete(d.id);    // the user chose; typing no longer changes it
      if (ui.picks[d.id] === d.res) delete ui.picks[d.id]; else ui.picks[d.id] = d.res;
      return render();
    case "resolve-all": return resolveAll(d.task);
    case "do-todo": return doTodo(d.task, d.text);
    case "more-res": ui.moreRes.add(d.id); return render();
    case "show-later": ui.showLater.has(d.task) ? ui.showLater.delete(d.task) : ui.showLater.add(d.task); return render();
    case "forget-session": {
      const t = taskById(d.task);
      if (!t) return;
      const before = list(t.sessions);
      const after = before.filter((x) => !d.session.startsWith(String(x)));
      const set = (v) => api("set", { task: d.task, fields: [`sessions=${JSON.stringify(v)}`] });
      try {
        await set(after);
        toast("Removed from this task's sessions", false, async () => { await set(before); delete ui.history[d.task]; await refresh(); });
      } catch (e) { toast(String(e.message || e), true); }
      delete ui.history[d.task];
      return refresh();
    }
    case "hist-all": ui.histAll.has(d.task) ? ui.histAll.delete(d.task) : ui.histAll.add(d.task); return render();
    case "resume": {
      const t = taskById(d.task);
      const place = launchPlace() === "bg" ? "terminal" : launchPlace();
      try {
        await api("resume", { task: d.task, session: d.session, dir: d.dir || (t && launchDir(t)) || "", where: place, skip: skipPerms(), name: d.name || "", focus: !stayOnBoard() });
        toast(stayOnBoard() ? `Resumed — bound to ${d.task}; carry on here` : `Resuming it in ${PLACES[place]} — bound to ${d.task}`);
        stayWith(d.session, d.name);
      } catch (e) { toast(String(e.message || e), true); }
      delete ui.history[d.task];
      setTimeout(() => refresh(), 2500);
      return;
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
      // Only a click on the card itself folds it — not one in a box, on a label or ask, or one
      // that ends a text selection.
      if (ev.target !== el && ev.target.closest(NO_EXPAND)) return;
      if (String(window.getSelection() || "").trim()) return;
      ui.expanded.has(d.task) ? ui.expanded.delete(d.task) : ui.expanded.add(d.task);
      return render();
    case "launch-menu": ui.launchMenu = ui.launchMenu === d.task ? null : d.task; return render();
    case "goto": return revealTask(d.task);
    case "jump": return act("jump", { session: d.session });
    case "decide": {
      if (d.behavior === "allow" && !(ui.allowArmed && ui.allowArmed.ask === d.ask)) {
        clearTimeout(ui.allowArmed && ui.allowArmed.timer);
        ui.allowArmed = { ask: d.ask, timer: setTimeout(() => { ui.allowArmed = null; render(); }, 6000) };
        return render();
      }
      clearTimeout(ui.allowArmed && ui.allowArmed.timer);
      ui.allowArmed = null;
      return act("decide", { session: d.session, ask: d.ask, behavior: d.behavior },
                 d.behavior === "allow" ? "Allowed" : "Denied");
    }
    case "unbind": return act("unbind", { session: d.session }, "Unbound");
    case "open": return act("open", { path: d.path });
    case "send": return send(d.session);
    case "peek": return openPeek(d.session);
    case "att-remove":
      (ui.atts[d.session] || []).splice(Number(d.i), 1);
      render();
      if (ui.modal && ui.modal.type === "peek" && ui.modal.sid === d.session) drawPeek(false);
      return;
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
      ui.adding.delete(`${d.task}:${d.field}`);
      return act("set", { task: d.task, fields: [`${d.field}=${v}`] }, "Saved");
    }
    case "cancel-field": delete ui.drafts[`${d.field}:${d.task}`]; ui.adding.delete(`${d.task}:${d.field}`); return render();
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
        const keys = projectGroupKeys();
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
    case "open-settings": ui.settings = ui.settings || "projects"; return render();
    case "settings-tab": ui.settings = d.tab; return render();
    case "close-settings": closeSettings(); return;
    case "open-projects": ui.settings = "projects"; return render();
    case "close-projects": closeSettings(); return;
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
    case "scan-open": ui.settings = "projects"; // fall through to scan
    case "scan":
      ui.scan = "loading"; ui.scanPick = new Set(); render();
      try {
        ui.scan = await apiJSON("scan");
      } catch (e) { ui.scan = null; toast(String(e.message || e), true); }
      return render();
    case "scan-close": ui.scan = null; return render();
    case "scan-apply": {
      const names = [...ui.scanPick];
      ui.scan = null;
      return act("scan-apply", { names }, `Created ${names.length} project(s) and sorted tasks into them`);
    }
    case "copy-onboard": return copyText("/hq-onboard", "Copied — paste it into any Claude Code session");
    case "new-in-project": return openNewTask(d.p);
    case "mode": ui.mode = d.m; savePref("hq-mode", d.m); ui.newTask = false; return d.m === "jobs" ? refresh(true) : render();
    case "focus-toggle": {
      const on = focusIds().includes(d.task);
      return act("focus", { action: on ? "remove" : "add", tasks: [d.task] }, on ? `${d.task} off Focus` : `${d.task} added to Focus`);
    }
    case "today-add": {
      const v = (ui.drafts["todaypick"] || "").trim();
      const id = (v.match(/T-\d+/i) || [])[0];
      if (!id || !taskById(id.toUpperCase())) return toast("Pick a task from the list (type its id or title)", true);
      delete ui.drafts["todaypick"];
      return act("focus", { action: "add", tasks: [id.toUpperCase()] }, `${id.toUpperCase()} added to Focus`);
    }
    case "today-remove": {
      const id = d.task;
      try {
        await api("focus", { action: "remove", tasks: [id] });
        toast(`${id} off Focus`, false, () => act("focus", { action: "add", tasks: [id] }, `${id} back in Focus`));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "launch": {
      ui.launchMenu = null;
      const t = taskById(d.task);
      const dir = t && launchDir(t);
      if (!dir) return toast("This task has no directory yet — bind a session or give the project a directory first", true);
      const place = launchPlace();
      try {
        const r = await apiObj("launch", { task: t.id, title: t.title, dir, where: place, prompt: LAUNCH_PROMPT(t), skip: skipPerms(), focus: !stayOnBoard() });
        toast(place === "bg" ? `Started in the background on ${t.id} — Peek or Attach from its card`
          : stayOnBoard() ? `Started on ${t.id} — it reads the card and reports here` : `Started in ${PLACES[place]} on ${t.id} — it reads the card and reports`);
        stayWith(r && r.session, `${t.id} ${t.title}`);
      } catch (e) { toast(String(e.message || e), true); }
      setTimeout(() => refresh(), 2500);
      return;
    }
    case "attach": {
      const place = launchPlace() === "bg" ? "terminal" : launchPlace();
      try { await api("attach", { session: d.session, where: place }); toast(`Opening it in ${PLACES[place]}…`); }
      catch (e) { toast(String(e.message || e), true); }
      return;
    }
    case "stop":
      // WKWebView shows no confirm() dialog, so confirm with a second click instead.
      if (ui.stopArmed !== d.session) {
        ui.stopArmed = d.session;
        render();
        toast("Click stop again to stop it — its conversation is kept, Attach resumes it");
        setTimeout(() => { if (ui.stopArmed === d.session) { ui.stopArmed = null; render(); } }, 4000);
        return;
      }
      ui.stopArmed = null;
      return act("stop", { session: d.session }, "Stopped");
    case "proj-auto": return act("project", { action: "auto" }, "Tasks assigned by directory");
    case "open-cats": ui.settings = "categories"; return render();
    case "close-cats": closeSettings(); return;
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
      ui.newTask = false; delete $("#newtask-form").dataset.drawn; clearNewTaskDrafts(); return render();
    case "create": {
      const title = $("#nt-title").value.trim();
      if (!title) return toast("Give the task a title", true);
      try {
        const out = await api("new", { title, category: $("#nt-cat").value, workdir: $("#nt-dir").value, project: $("#nt-proj").value });
        const id = String(out).split("\n")[0].trim();
        const sid = $("#nt-session").value;
        if (sid) await api("bind", { task: id, session: sid });
        ui.newTask = false; delete $("#newtask-form").dataset.drawn;
        clearNewTaskDrafts();
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
  if (d.action === "push-group") { for (const id of d.ids.split(" ")) ui.drafts["push:" + id] = el.checked; saveDrafts(); return; }
  if (el.type === "checkbox" && d.key) { ui.drafts[d.key] = el.checked; saveDrafts(); return; }
  if (d.action === "scan-pick") { el.checked ? ui.scanPick.add(d.name) : ui.scanPick.delete(d.name); return render(); }
  if (d.action === "launch-place") { savePref("hq-launch", el.value); return render(); }
  if (d.action === "skip-perms") { savePref("hq-skip-perms", el.checked ? "1" : "0"); return render(); }
  if (d.action === "stay-board") { savePref("hq-stay", el.checked ? "1" : "0"); return render(); }
  // A picked status / project / category shows at once; the refresh after saving confirms it.
  if (["set-status", "set-project", "set-category"].includes(d.action)) {
    ui.pointerDown = false;
    const t = taskById(d.task);
    if (t) { t[d.action.slice(4)] = el.value; render(); }
  }
  if (d.action === "set-project") return act("set", { task: d.task, fields: [`project=${el.value}`] }, "Project saved");
  if (d.action === "set-category") return act("set", { task: d.task, fields: [`category=${el.value}`] }, "Category saved");
  if (el.tagName === "SELECT" && d.key) { ui.drafts[d.key] = el.value; el.blur(); return render(); }
  if (d.action === "set-status") return act("set", { task: d.task, fields: [`status=${el.value}`] }, "Status saved");
  if (d.action === "bind" && el.value) return act("bind", { task: d.task, session: el.value }, "Bound — the session learns the task on its next message");
  if (d.action === "bind-session" && el.value) return act("bind", { task: el.value, session: d.session }, "Bound — the session learns the task on its next message");
  if (el.id === "show-closed") { ui.showClosed = el.checked; render(); }
  if (el.id === "activefirst-cb" || d.action === "active-first") { ui.activeFirst = el.checked; savePref("hq-activefirst", el.checked ? "1" : "0"); render(); }
});

document.addEventListener("input", (ev) => {
  const el = ev.target;
  if (el.id === "search") { ui.filter = el.value; return render(); }
  if (el.dataset.key) { ui.drafts[el.dataset.key] = el.value; saveDrafts(); }
  const note = /^note:(.+)$/.exec(el.dataset.key || "");
  if (note) autoPick(note[1], el.value.trim() !== "");
  if (el.dataset.field) render();
  if (el.tagName === "TEXTAREA" && el.classList.contains("grow")) fitGrow(el);
});

// Input methods (Pinyin, Japanese…): hold every redraw while a word is being composed.
document.addEventListener("compositionstart", () => { ui.composing = true; }, true);
function compositionDone(ev) {
  if (!ui.composing) return;
  ui.composing = false;
  // The committed text arrives with an input event around compositionend; let it land first.
  setTimeout(() => {
    const el = ev.target;
    if (el && el.dataset && el.dataset.key && "value" in el) ui.drafts[el.dataset.key] = el.value;
    if (ui.renderPending) { ui.renderPending = false; render(); }
    if (ui.peekPending && ui.modal && ui.modal.type === "peek") drawPeek(ui.peekPending.toBottom);
    ui.peekPending = null;
  }, 0);
}
document.addEventListener("compositionend", compositionDone, true);
document.addEventListener("focusout", compositionDone, true);   // in case a composition is cut off

document.addEventListener("keydown", async (ev) => {
  const el = ev.target;
  if (ev.key === "Escape" && ui.launchMenu) { ev.preventDefault(); ui.launchMenu = null; return render(); }
  if (ev.key === "Escape" && ui.modal) { ev.preventDefault(); return closePeek(); }
  if (ev.key === "Escape" && ui.settings) { ev.preventDefault(); return closeSettings(); }
  if (ev.key === "Escape" && el.tagName === "TEXTAREA" && el.dataset.session && !(ui.drafts[el.dataset.key] || "").trim()) {
    ui.msgOpen.delete(el.dataset.session); el.blur(); return render();
  }
  if (ev.key !== "Enter" || ev.isComposing) return;  // isComposing: IME (e.g. Pinyin) candidate selection
  if (el.tagName === "TEXTAREA" && el.dataset.session) return;   // Enter is a new line; only Send sends
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
function dropZone(ev) { return ev.target.closest && ev.target.closest("#tasks, #settings .settings-body"); }
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
document.addEventListener("dragend", () => {
  // A drag ends without a mouseup, so the pointer would read as held and keep timed refreshes
  // waiting until the next click.
  ui.pointerDown = false;
  ui.pendingRender = false;
  finishDrag();
  render();
});

// ---- reorder Today's task cards by their ⠿ grip (only with Active first off). The order is
// today's list in focus.json, saved with `hq focus order`.
document.addEventListener("dragstart", (ev) => {
  const grip = ev.target.closest && ev.target.closest("[data-drag-task]");
  if (!grip) return;
  ui.dragging = "task:" + grip.dataset.dragTask;      // holds rebuilds until the drop
  ui.dropAt = null;
  ev.dataTransfer.effectAllowed = "move";
  // Not text/plain: dropped on a message box, that would type the task id into it.
  ev.dataTransfer.setData("application/x-hq-task", grip.dataset.dragTask);
  const card = grip.closest(".fcard");
  if (card) card.classList.add("dragging");
});
document.addEventListener("dragover", (ev) => {
  if (!String(ui.dragging || "").startsWith("task:")) return;
  const zone = ev.target.closest && ev.target.closest("#today-focus");
  if (!zone) { clearDropMarks(); ui.dropAt = null; return; }
  ev.preventDefault();
  ev.dataTransfer.dropEffect = "move";
  let best = null, dist = Infinity;
  for (const el of zone.querySelectorAll("[data-today-card]")) {
    const r = el.getBoundingClientRect(), mid = r.top + r.height / 2, d = Math.abs(ev.clientY - mid);
    if (d < dist) { dist = d; best = { el, before: ev.clientY < mid }; }
  }
  clearDropMarks();
  if (!best || "task:" + best.el.dataset.todayCard === ui.dragging) { ui.dropAt = null; return; }
  best.el.classList.add(best.before ? "drop-before" : "drop-after");
  ui.dropAt = { id: best.el.dataset.todayCard, before: best.before };
});
document.addEventListener("drop", async (ev) => {
  const moving = String(ui.dragging || "");
  if (!moving.startsWith("task:") || !(ev.target.closest && ev.target.closest("#today-focus"))) return;
  ev.preventDefault();
  const at = ui.dropAt, id = moving.slice(5);
  finishDrag();
  if (!at) return render();
  const order = focusIds().filter((x) => x !== id);
  const i = order.indexOf(at.id);
  if (i < 0) return render();
  order.splice(at.before ? i : i + 1, 0, id);
  const before = focusIds();
  ui.board.focus.ids = order;                    // shows at once; the save follows
  render();
  try { await api("focus", { action: "order", tasks: order }); }
  catch (e) {
    toast(String(e.message || e), true);
    ui.board.focus.ids = before;                 // not saved: back to the order hq has
    ui.lastSig = null;
    refresh();
  }
});

function openNewTask(project) {
  ui.newTask = true;
  delete $("#newtask-form").dataset.drawn;
  if (project) ui.drafts["nt:proj"] = project;
  render();
  const t = $("#nt-title");
  if (t) { t.scrollIntoView({ block: "center" }); t.focus(); }
}
$("#new-task").addEventListener("click", () => {
  // The form lives on Focus and All; from Needs you or Scheduled, go to All for it.
  if (ui.mode === "needs" || ui.mode === "jobs") { ui.mode = "all"; savePref("hq-mode", "all"); }
  ui.newTask = true; render(); const t = $("#nt-title"); if (t) t.focus();
});

refresh();
setInterval(() => { if (document.visibilityState === "visible" && !document.hidden) refresh("timer"); }, 4000);
// Not on a dropdown: its menu takes the mouseup, so the button would never read as released.
document.addEventListener("mousedown", (ev) => { if (ev.target.tagName !== "SELECT") ui.pointerDown = true; }, true);
document.addEventListener("mouseover", (ev) => {
  const over = Boolean(ev.target.closest && ev.target.closest(".approve"));
  if (over === Boolean(ui.overApprove)) return;
  ui.overApprove = over;
  if (!over && !ui.pointerDown && ui.pendingRender) { ui.pendingRender = false; setTimeout(render, 0); }
}, true);
document.addEventListener("mouseup", () => {
  ui.pointerDown = false;
  if (ui.pendingRender) { ui.pendingRender = false; setTimeout(render, 0); }
}, true);
