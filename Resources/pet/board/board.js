// HQ board. Everything is read from and written through the `hq` CLI via the
// native bridge (BoardWindow.swift); this page holds no state worth keeping.
"use strict";

// The app's language (Settings → Language in the pet's menu), set before this script runs; the
// page reloads when it changes. T("English", "中文") picks one — every word the board shows goes
// through it. Technical terms (session, todo, ask, Resume…) may stay English in the Chinese.
const LANG = window.PET_LANG === "zh" ? "zh" : "en";
const T = (en, zh) => (LANG === "zh" ? zh : en);
document.documentElement.lang = LANG;

const ORDER = ["waiting-on-me", "blocked", "active", "done", "abandoned"];
const LABEL = {
  "waiting-on-me": T("Waiting on you", "等你处理"), blocked: T("Blocked", "阻塞中"), active: T("Active", "进行中"),
  done: T("Done", "已完成"), abandoned: T("Abandoned", "已放弃"),
};
// How an ask can be answered. Most asks are "should I?" or "A or B — I suggest A", so Yes ("go
// ahead / as you suggest", or with a note: "my answer is the note") comes first. "Later" keeps the
// ask open and out of sight until tomorrow. "No context" is rare and sits behind ⋯.
const RESOLUTIONS = [
  ["do", T("Yes", "可以"), T("Yes — go ahead, or as you suggested. With a note, the note is your answer (\"A+C\", \"run it once\")", "可以——去做，或按你的建议来。写了说明，说明就是你的回答（如“A+C”“跑一次”）")],
  ["always", T("Yes, always", "以后都可以"), T("Yes — and from now on, sessions on this task do this kind of thing without asking. You word the standing grant before it's sent; revoke it any time under the task's Grants", "可以——而且以后这个任务的 session 遇到这类事情直接做，不再问。发出前你来定授权的措辞；随时可以在任务的「授权」里撤销")],
  ["drop", T("No", "不要"), T("No — don't do it. A note can say why, or what instead", "不要——别做。说明里可以写原因，或者换成什么")],
  ["todo", T("To todo", "转待办"), T("Something I'll do myself — make it an @me todo on this task and close the ask", "这是我自己要去做的事——在这个任务里加一条 @me 待办，并关掉这个问题")],
  ["snooze", T("Later", "稍后"), T("Not now — keep the question, but hide it until tomorrow: it leaves Needs you and the cat's badge, and the session is told you'll answer later", "先不答——问题留着，但藏到明天：它会离开 Needs you 和小猫的角标，session 会被告知你稍后再答")],
];
const MORE_RESOLUTIONS = [["archive", T("No context", "不了解背景"), T("I can't answer this — park it", "我答不了——先归档")]];
// Standing grants the user says yes to most (from the asks answered Yes on this board, 2026-11).
const GRANT_PRESETS = [
  T("Fix the review findings as suggested and push them to the same PR", "review 出的问题按建议全修，推到同一个 PR"),
  T("Rerun a verification with the same parameters as last time", "用和上次相同的参数重跑验证"),
  T("Once the plan is agreed, start: worktree and branch off origin/main, open a PR when done", "方案确认后直接开工：从 origin/main 开 worktree 和分支，做完开 PR"),
  T("Push the branch, open a PR, push commits to the open PR", "推送分支、开 PR、把提交推到已有的 PR"),
  T("Delete a test env once its failure is triaged and written down", "失败原因已查清并记下的测试环境直接删"),
  T("After a PR merges, install from main on this machine (scripts/install.sh)", "PR 合并后从 main 本机安装（scripts/install.sh）"),
  T("Draft a Jira, reply or message — without sending it", "起草 Jira、回复或消息（不发送）"),
  T("Record verification results in the tracker or artifact", "把验证结果记到 tracker 或 artifact 里"),
];
const grantKey = (s) => String(s || "").split(/\s+/).filter(Boolean).join(" ").toLowerCase();
// The wording a "Yes, always" will grant: what you typed, else the session's suggestion, else the question.
const grantWording = (a) => ui.drafts["grant:" + a.id] ?? (a.grant || a.text);
function grantPresets(action, attrs) {
  return `<div class="presets">${GRANT_PRESETS.map((p) => `<button class="chip link" data-action="${action}" ${attrs} data-text="${esc(p)}">${esc(p)}</button>`).join("")}</div>`;
}
const projects = () => (ui.board && Array.isArray(ui.board.projects) ? ui.board.projects : []);
const projectNames = () => projects().map((p) => p.name);
// Terminals the board can type into; anything else gets Jump only.
const SENDABLE = { orca: "Orca", iterm2: "iTerm2", terminal: "Terminal" };
const TERMINAL_NAME = { vscode: "VS Code", ghostty: "Ghostty", orca: "Orca", iterm2: "iTerm2", terminal: "Terminal" };
// Can the board deliver a message to this session? A terminal it can type into, or a background
// session between turns — that one is continued with the message (BoardBridge.sendBackground).
function canMessage(s) {
  if (!s) return false;
  if (SENDABLE[s.terminal && s.terminal.kind]) return true;
  // "waiting" is still mid-turn (a permission prompt or question is open): continuing it now
  // would stop that turn and throw the pending step away.
  return Boolean(s.background && s.bgId && s.state !== "busy" && s.state !== "waiting");
}
// The session's state as the pet shows it (its dots correct a wait that was answered or closed
// since the state file was written); the file's state for sessions the pet doesn't list.
function liveState(s) {
  const p = s && (ui.dots || {})[s.sessionId];
  return p && p.state ? p.state : s ? s.state : "";
}
// A terminal session stopped on a permission prompt or a question menu takes typed keys as its
// answer: the Return that submits a message would pick the highlighted option ("Yes") for
// something the user never saw. Nothing is typed into it until it has been answered there.
const onPrompt = (s) => Boolean(s && SENDABLE[s.terminal && s.terminal.kind] && liveState(s) === "waiting");
const ON_PROMPT = () => T("It is waiting on a prompt in its terminal — answer it there first (↗ Jump), then message it.",
  "它在终端里等你确认或回答——先跳到终端（↗）在那里处理，再给它发消息。");
// Can the board type into this session right now?
const canSendNow = (s) => canMessage(s) && !onPrompt(s);
// Esc for a session mid-turn: pressed in its terminal, it interrupts the turn as it would there.
// Only terminals that can take a lone key (Orca, iTerm2); Terminal.app always adds a Return.
const INTERRUPTIBLE = { orca: true, iterm2: true };
// No Stop hook follows an Esc: the pet's record stays busy and only turns quiet (about 10 s later,
// Claude Code's own status says idle), so the button stays away that long and for good once quiet:
// a second Esc on a stopped session opens Claude Code's rewind menu.
const ESC_HOLD_MS = 12_000;
const escHeld = (sid) => Date.now() - ((ui.interrupted || {})[sid] || 0) < ESC_HOLD_MS;
const canInterrupt = (s) => Boolean(s && !s.background && INTERRUPTIBLE[s.terminal && s.terminal.kind]
  && liveState(s) === "busy" && !((ui.dots || {})[s.sessionId] || {}).quiet && !escHeld(s.sessionId));
const escButton = (s) => canInterrupt(s)
  ? `<button class="icon esc" data-action="interrupt" data-session="${esc(s.sessionId)}" title="${T("Interrupt — press Esc in its terminal to stop this turn; the session stays open for your next message", "中断——在它的终端里按 Esc，停下这一轮；session 还开着，可以接着发消息")}">Esc</button>`
  : "";
// What a send needs beyond the text: a background session goes by its short id, and is continued
// with the board's skip-permissions choice, as a session started from here would be.
const sendExtra = (s) => (s && s.background && !SENDABLE[s.terminal && s.terminal.kind] ? { bg: s.bgId, skip: skipPerms() } : {});

function pref(key, dflt) { try { return localStorage.getItem(key) ?? dflt; } catch (e) { return dflt; } }
function savePref(key, value) { try { localStorage.setItem(key, value); } catch (e) { /* private mode */ } }
// All, the page of every task, is gone: whoever had it open lands on the Projects & duties list.
function startMode() {
  const m = pref("hq-mode", "today");
  if (m !== "all") return m;
  savePref("hq-mode", "projects");
  savePref("hq-proj", "");
  return "projects";
}
const ui = {
  board: null, sessions: [], peekOpen: new Set(), peeks: {}, hlSession: null, hlTimer: 0,
  drafts: {}, hqOpen: new Set(), filter: "", busy: false, modal: null, recent: [], undoFn: null, msgOpen: new Set(), atts: {}, sending: new Set(), resuming: new Set(), resolving: new Set(), picks: {}, autoPicked: new Set(), moreRes: new Set(), granting: new Set(), showLater: new Set(), handed: {}, handing: new Set(), noteOpen: new Set(), history: {}, historyLoading: new Set(), histAll: new Set(), adding: new Set(), logAll: new Set(), resOpen: new Set(), projOpen: false, doneOpen: new Set(), refMore: new Set(), scan: null, scanPick: new Set(),
  mode: startMode(),
  // The task open in the side drawer ("@sessions": the list of live sessions), and whether the
  // boards show a column of recently finished tasks.
  drawer: null, showDone: pref("hq-show-done", "0") === "1",
  sgroupBy: pref("hq-sgroupby", "list"),
  scollapsed: new Set(JSON.parse(pref("hq-scollapsed", "[]"))), activeFirst: pref("hq-activefirst", "1") === "1", shown: {}, hover: new Set(), heldBack: false,
  // Tasks whose open @claude todos are unfolded (folded by default).
  claudeOpen: new Set(JSON.parse(pref("hq-claude-todos-open", "[]"))),
  // `hq status --focus` flags by task id ({kind, text, text_zh}), and when they were last read.
  flags: {}, flagsAt: 0, flagsKey: "", flagsIds: "", flagsLoading: false,
};

// ------------------------------------------------------------------ bridge
async function api(op, args = {}) {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hq;
  if (!h) throw new Error(T("Open this page from Claude Pet (Task Board…)", "请从 Claude Pet 打开此页（Task Board…）"));
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
// The static labels in board.html are English; in Chinese they are set here once (the page
// reloads when the language changes).
if (LANG === "zh") {
  $("#search").placeholder = "筛选任务";
  $("#capture").placeholder = "记一笔…（回车）";
  $(".capture").title = "记一句话、一个链接或粘贴一张截图；回车后自动分拣（新任务、某个任务的待办或记录、你的待办），去向在 Needs you 里看";
  $("#search").title = "每个页面都筛选：任务按编号、标题、关联、项目；问题和待办也按自己的文字。在项目与职责页，匹配的任务（包括已结束的）列在最上面";
  $("#new-task").textContent = "＋ 新建";
  $("#secretary-btn").title = "秘书：问它各个任务怎么样了、什么在等你；它的建议出现在 Needs you";
  $('[data-action="open-settings"]').title = "设置：session 怎么开";
  $("#guide").title = "使用说明：HQ 怎么用";
  $("#needs .vhead h1").textContent = "等你处理";
}
function ago(iso) {
  if (!iso) return "";
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (isNaN(s)) return "";
  if (s < 90) return T("just now", "刚刚");
  if (s < 3600) return T(`${Math.round(s / 60)}m ago`, `${Math.round(s / 60)} 分钟前`);
  if (s < 86400 * 2) return T(`${Math.round(s / 3600)}h ago`, `${Math.round(s / 3600)} 小时前`);
  return T(`${Math.round(s / 86400)}d ago`, `${Math.round(s / 86400)} 天前`);
}
function toast(msg, bad, undo) {
  const t = $("#toast");
  ui.undoFn = undo || null;
  t.innerHTML = `<span>${esc(msg)}</span>` +
    (undo ? ` <button class="btn small" data-action="undo-toast">${T("Undo", "撤销")}</button>` : "");
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
  const label = { done: T("Done", "已完成"), drop: T("Won't do", "不做"), open: T("Reopened", "已恢复") }[to] || to;
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
  await act("todo", { task, index: i, state: r ? r.from : "open", text: r ? r.text : "" }, T("Undone", "已撤销"));
}
const tasks = () => (ui.board ? ui.board.tasks : []);
// The secretary's own card (hq.json's `secretary`) is its notebook, not a piece of your work: the
// task lists and their counts leave it out. Its asks (its proposals) still show in Needs you, and
// in its window.
const secId = () => (ui.board && ui.board.secretary) || "";
const listed = () => tasks().filter((t) => t.id !== secId());
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
  for (const k of Object.keys(ui.drafts)) { const m = /^(?:note|push|grant):(.+)$/.exec(k); if (m && gone(m[1])) delete ui.drafts[k]; }
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
      title="${T("Questions you put off with Later. They come back by themselves tomorrow; open them to answer now", "你选了“稍后”的问题。明天会自己回来；点开可以现在就回答")}">${open ? T("Hide", "收起") : T(`${later.length} for later · back tomorrow`, `${later.length} 条稍后再答 · 明天回来`)}</button>` +
    (open ? later.map((a) => askCard(t, a)).join("") : "");
}
const liveFor = (id) => ui.sessions.filter((s) => s.task === id);
// Its turn is over but commands it started (a build, a test run…) are still running under it.
// Not idle: it will have something to say when they finish. (A `claude --bg` session is another
// thing — s.background — and says so with its own tag.)
const bgRunning = (s) => s.state !== "busy" && s.state !== "waiting" && dotClass(s) === "idle bg";
// One word for where a task's live sessions stand, for its row and its Focus card: working beats
// running in the background beats idle.
const liveTag = (live) => {
  if (!live.length) return "";
  const [cls, word] = live.some((x) => x.state === "busy") ? ["", T("working", "在干活")]
    : live.some(bgRunning) ? ["bg", T("in background", "后台在跑")]
    : ["idle", live.length === 1 ? T("idle", "空闲") : T(`${live.length} idle`, `${live.length} 个空闲`)];
  return `<span class="live ${cls}" title="${T("Its live sessions", "它在跑的 session")}">${word}</span>`;
};
// The pet's red dot, on the board: this session finished and you haven't looked yet. Peek, Jump or
// a reply (from here or its terminal) clears it, same as in the pet's list.
const newTag = (sid) => (ui.unread && ui.unread[sid]
  ? `<span class="newtag" title="${T("Finished — not looked at yet. Peek, Jump or reply to clear it.", "干完了一轮，你还没看。Peek、Jump 或回复它就会消失。")}">${T("new", "新")}</span>` : "");
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
const DOT_TIP = { quiet: T("Gone quiet — nothing heard for a while", "没动静了——有一阵子没有消息"), "waiting approve": T("Waiting for your approval", "等你授权"),
  "waiting reply": T("Waiting for your answer", "等你回答"), "busy agent": T("Waiting on an agent it sent off", "在等它派出去的 agent"),
  "busy struggling": T("Working — the last several calls failed", "在干活——最近几次调用都失败了"), busy: T("Working", "在干活"), "idle bg": T("Turn over — something it started is still running in the background", "这一轮结束了——它启动的东西还在后台跑"), idle: T("Idle", "空闲") };
// A session's status word, as the pet's list says it (pet.js row status — keep in step): what it
// is running, "1 in background", "Answered"… Sessions the pet doesn't list fall back to the state.
function statusWord(s) {
  const p = (ui.dots || {})[s.sessionId];
  if (!p) return LANG === "zh" ? ({ busy: "在干活", waiting: "等你", idle: "空闲" }[s.state] || s.state || "?") : s.state || "?";
  if (p.state === "waiting") return p.asks === "permission" ? T("Needs approval", "等你授权")
    : p.askKind === "plan" ? T("Plan to approve", "等你批准计划") : T("Awaiting reply", "等你回答");
  if (p.activity) return p.activity;
  if (p.quiet) return T("No recent activity", "最近没有动静");
  if (p.state === "busy") return T("Working", "在干活");
  if (p.background) return T(`${p.background} in background`, `${p.background} 个在后台跑`);
  return p.replied ? T("Answered", "已回复") : T("Idle", "空闲");
}
// How much context a session carries, as the pet's list shows it: tokens, and their share of the
// auto-compact window (ContextBudget) — 100% is "about to compact". Amber from two thirds, red from 80%.
function ctxTag(s) {
  const d = (ui.dots || {})[s.sessionId] || {};
  const p = d.context;
  if (p == null) return "";
  const k = (n) => n >= 999500 ? `${Math.round(n / 1e5) / 10}M` : `${Math.round(n / 1000)}k`;
  const tokens = d.contextTokens ? `${k(d.contextTokens)} · ` : "";
  const title = d.contextTokens ? T(`Context: ${k(d.contextTokens)} of the ${k(d.contextBudget)} auto-compact window — every turn re-sends it`, `上下文：${k(d.contextTokens)}，自动 compact 门槛是 ${k(d.contextBudget)}——每一轮都要重新发送一次`) : T("Context used", "已用上下文");
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
  if (p && p.state === "waiting" && p.promptAsk) return ui.approvedPlans && ui.approvedPlans.has(p.promptAsk) ? "" : promptBar(s, p);
  if (!p || p.state !== "waiting" || p.asks !== "permission" || !p.askId) return "";
  const armed = ui.allowArmed && ui.allowArmed.ask === p.askId;
  const data = `data-session="${esc(s.sessionId)}" data-ask="${esc(p.askId)}"`;
  return `<div class="approve"><div class="ap-head"><span class="ap-k">${T("Approve", "批准")}</span>
      <button class="btn small ${armed ? "armed" : ""}" data-action="decide" data-behavior="allow" ${data}
        title="${armed ? T("Click again to allow it", "再点一下就允许") : T("Allow — click twice", "允许——要点两下")}">${armed ? T("Allow?", "允许？") : T("Allow", "允许")}</button>
      <button class="btn small ghost" data-action="decide" data-behavior="deny" ${data}>${T("Deny", "拒绝")}</button></div>
    <code class="ap-what">${esc(p.approveText || s.waitingOn || T("this tool call", "这次工具调用"))}</code></div>`;
}
// A question menu (AskUserQuestion) or a plan (ExitPlanMode) the session has up in its terminal,
// answered here in a dialog (openPrompt): the pet-emit holding the prompt hands the picks, or the
// feedback, back to Claude Code; a plan is approved by pressing Enter in the terminal (a hook's
// "allow" is ignored for it). Shown only while the pet is holding the prompt (`promptAsk`).
function promptBar(s, p) {
  const plan = p.askKind === "plan";
  return `<div class="approve prompt"><div class="ap-head"><span class="ap-k">${plan ? T("Plan", "计划") : T("Question", "提问")}</span>
      <button class="btn small primary" data-action="open-prompt" data-session="${esc(s.sessionId)}">${plan ? T("Review plan…", "看计划…") : T("Answer…", "回答…")}</button></div>
    <div class="ap-what">${esc(s.waitingOn || (plan ? T("A plan is ready for your approval", "计划写好了，等你批准") : T("It asked you a question", "它问了你一个问题")))}</div></div>`;
}

async function openPrompt(sid) {
  let d;
  try { d = await apiJSON("prompt", { session: sid }); }
  catch (e) { return toast(String(e.message || e), true); }
  const s = ui.sessions.find((x) => x.sessionId === sid);
  ui.modal = { type: "prompt", sid, title: (s && (s.title || s.project)) || sid.slice(0, 8), kind: d.kind, ask: d.ask,
    plan: d.plan || "", questions: Array.isArray(d.questions) ? d.questions : [], picks: {}, busy: false };
  drawPrompt();
}
const promptOtherKey = (m, i) => `qother:${m.ask}:${i}`;
const planFeedbackKey = (m) => `planfb:${m.ask}`;
// question text → what goes back: the picked labels (several joined with ", "), and your own
// words after them when you wrote any. Null while a question has neither.
function promptAnswers(m) {
  const out = {};
  for (const [i, q] of m.questions.entries()) {
    const picked = [...(m.picks[i] || [])];
    const own = (draft(promptOtherKey(m, i)) || "").trim();
    const parts = q.multiSelect ? [...picked, ...(own ? [own] : [])] : own ? [own] : picked.slice(0, 1);
    if (!parts.length) return null;
    out[String(q.question || "")] = parts.join(", ");
  }
  return Object.keys(out).length ? out : null;
}
function drawPrompt() {
  const m = ui.modal;
  const box = $("#modal");
  const head = `<div class="phead">
      <div><div class="meta">${m.kind === "plan" ? T("Plan to approve", "等你批准的计划") : T("Question to answer", "等你回答的问题")}</div>
        <div class="stitle ctx-title">${esc(m.title)}</div></div>
      <span style="flex:1"></span>
      <button class="btn small ghost" data-action="jump" data-session="${esc(m.sid)}" title="${T("Answer it in its terminal instead", "改去它的终端里回答")}">↗ Jump</button>
      <button class="btn small ghost" data-action="close-modal" title="${T("Close (Esc)", "关闭 (Esc)")}">✕</button>
    </div>`;
  let body, foot;
  if (m.kind === "plan") {
    body = `<div class="md plan-md">${m.plan ? markdown(m.plan) : `<div class="empty">${T("(no plan text)", "（没有计划内容）")}</div>`}</div>`;
    const fb = draft(planFeedbackKey(m));
    foot = `<div class="prompt-foot">
      <textarea class="grow" rows="2" data-key="${esc(planFeedbackKey(m))}" placeholder="${T("What to change — sent back, and it keeps planning", "要改什么——发回给它，它继续规划")}">${esc(fb)}</textarea>
      <div class="row-btns">
        <button class="btn small" data-action="plan-feedback" ${m.busy || !fb.trim() ? "disabled" : ""}>${T("Keep planning", "继续规划")}</button>
        <button class="btn small primary" data-action="plan-approve" ${m.busy ? "disabled" : ""} title="${T("Presses Enter in its terminal: the dialog's first option, “Yes”, and it starts", "在它的终端里按回车：选对话框的第一项「Yes」，开始执行")}">${T("Approve", "批准")}</button>
      </div></div>`;
  } else {
    body = m.questions.map((q, i) => {
      const picked = m.picks[i] || new Set();
      const opts = (Array.isArray(q.options) ? q.options : []).map((o) => {
        const on = picked.has(o.label);
        return `<button class="qopt ${on ? "on" : ""}" data-action="prompt-pick" data-q="${i}" data-label="${esc(o.label)}">
          <span class="qo-l">${q.multiSelect ? (on ? "☑" : "☐") : on ? "◉" : "○"} ${esc(o.label)}</span>
          ${o.description ? `<span class="qo-d">${esc(o.description)}</span>` : ""}</button>`;
      }).join("");
      return `<section class="ctx-sec qblock">
        ${q.header ? `<h4>${esc(q.header)}${q.multiSelect ? T(" · pick any", " · 可多选") : ""}</h4>` : ""}
        <div class="q-text">${esc(q.question || "")}</div>
        <div class="qopts">${opts}</div>
        <input class="q-other" data-key="${esc(promptOtherKey(m, i))}" value="${esc(draft(promptOtherKey(m, i)))}" placeholder="${T("Or in your own words…", "或者自己写…")}">
      </section>`;
    }).join("");
    foot = `<div class="prompt-foot"><div class="row-btns">
      <button class="btn small primary" data-action="prompt-send" ${m.busy || !promptAnswers(m) ? "disabled" : ""}>${T("Send answers", "发送回答")}</button></div></div>`;
  }
  box.innerHTML = `<div class="panel ppanel prompt-panel" role="dialog" aria-label="${T("Prompt", "提问")}">${head}
    <div class="peek-body">${body}</div>${foot}</div>`;
  box.hidden = false;
}
// The prompt went away (answered in the terminal, or replaced): the dialog has nothing to answer.
function checkPrompt() {
  const m = ui.modal;
  const p = (ui.dots || {})[m.sid];
  if (m.busy || (p && p.promptAsk === m.ask)) return;
  closePeek();
  toast(T("That prompt was answered or closed in its terminal", "这个提问已经在终端里回答或关掉了"));
}
// Typing doesn't redraw the dialog (the cursor would jump); it only turns its buttons on or off.
// Your own words for a single-choice question replace its pick.
function syncPromptButtons(el) {
  const m = ui.modal;
  const other = /^qother:[^:]*:(\d+)$/.exec(el.dataset.key || "");
  if (other && el.value.trim()) {
    const i = Number(other[1]);
    const q = m.questions[i] || {};
    if (!q.multiSelect && m.picks[i] && m.picks[i].size) {
      m.picks[i] = new Set();
      document.querySelectorAll(`#modal .qopt[data-q="${i}"]`).forEach((b) => { b.classList.remove("on"); b.querySelector(".qo-l").textContent = "○ " + b.dataset.label; });
    }
  }
  const send = $("#modal [data-action=prompt-send]");
  if (send) send.disabled = m.busy || !promptAnswers(m);
  const fb = $("#modal [data-action=plan-feedback]");
  if (fb) fb.disabled = m.busy || !(draft(planFeedbackKey(m)) || "").trim();
}
async function promptSubmit(op, args, ok) {
  const m = ui.modal;
  m.busy = true;
  drawPrompt();
  try {
    await api(op, { session: m.sid, ask: m.ask, ...args });
    // An approved plan's box stays away until the next hook clears it: one Enter per plan.
    if (op === "plan-approve") (ui.approvedPlans ||= new Set()).add(m.ask);
    for (const k of Object.keys(ui.drafts)) if (k.includes(m.ask)) delete ui.drafts[k];
    saveDrafts();
    closePeek();
    toast(ok);
  } catch (e) {
    m.busy = false;
    drawPrompt();
    toast(String(e.message || e), true);
  }
  refresh();
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
      api("pet").catch(() => "{}"), (ui.mode === "jobs" || ui.mode === "projects") && typeof loadJobs === "function" ? loadJobs() : ""]);
    sig = boardText + "\u0001" + sessionsText + "\u0001" + agentsText + "\u0001" + unreadText + "\u0001" + jobsSig;
    ui.board = JSON.parse(boardText);
    const pet = JSON.parse(unreadText || "{}");
    ui.unread = pet.unread || {};
    ui.dots = pet.dots || {};
    ui.usage = pet.usage || null;
    ui.clickTarget = pet.clickTarget || "";   // empty: no pet behind this board (--render-board)
    ui.skin = pet.skin || ui.skin || "cat";    // the secretary wears the pet's face
    ui.secGlance = pet.secretary || null;
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
  else if (ui.modal && ui.modal.type === "prompt") checkPrompt();
  loadFlags();
  sessionFinishes();
}
window.hqRefresh = refresh;

// The Focus cards' ⚠ lines: `hq status --focus` reads each task's sessions, so it runs once a
// minute (and when the Focus list changes), not on every few-second refresh; it never holds one up.
const FLAGS_EVERY_MS = 60000;
function showFlags(flags) {
  const key = JSON.stringify(flags);
  if (key === ui.flagsKey) return;
  ui.flags = flags; ui.flagsKey = key;
  // A timed redraw, so it waits for the mouse button and the Approve box as refresh() does.
  if (ui.pointerDown || ui.overApprove) ui.pendingRender = true;
  else render();
}
async function loadFlags() {
  const ids = list(focusState().ids).join(",");
  if (ui.flagsLoading || (Date.now() - ui.flagsAt < FLAGS_EVERY_MS && ids === ui.flagsIds)) return;
  ui.flagsLoading = true;
  try {
    const r = JSON.parse(await api("status"));
    const flags = {};
    for (const t of list(r.tasks)) if (list(t.flags).length) flags[t.id] = t.flags;
    ui.flagsAt = Date.now(); ui.flagsIds = ids;
    showFlags(flags);
  } catch (e) {
    // An old hq without `status`, or hq failing: no ⚠ rather than stale ones; try again in a minute.
    console.warn("hq status:", e);
    ui.flagsAt = Date.now();
    showFlags({});
  } finally {
    ui.flagsLoading = false;
  }
}
// From the pet: a click on a session opens its task here (Settings → "Clicking a session on the
// pet opens"), with that session picked out and its conversation open.
window.hqReveal = (id, sid) => refresh().then(() => {
  clearTimeout(ui.hlTimer);   // a second click soon after the last Peek closed: keep the new pick
  ui.hlSession = sid && id && id !== secId() && taskById(id) ? sid : null;
  // Draw the pick first: revealTask only scrolls to a card already in Focus, without a redraw.
  render();
  if (id) revealTask(id);
  if (ui.hlSession) openPeek(sid);
});

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
const PLACES = { orca: "Orca", iterm2: "iTerm2", terminal: "Terminal", bg: T("Background", "后台") };
// Sessions the board starts or resumes skip Claude Code's permission prompts — the user's choice,
// remembered; off unless ticked.
const skipPerms = () => pref("hq-skip-perms", "0") === "1";
// Stay on the board: a session the board starts or resumes opens its terminal tab in the
// background, and its conversation window opens here instead — carry on from the board.
const stayOnBoard = () => pref("hq-stay", "0") === "1";
function launchOptions() {
  return `<label class="skipperm" title="${T("Start and resume sessions with --dangerously-skip-permissions: Claude won't stop to ask before running commands or editing files", "新开和续上的 session 带 --dangerously-skip-permissions：Claude 跑命令、改文件前不再停下来问")}">
    <input type="checkbox" data-action="skip-perms" ${skipPerms() ? "checked" : ""}> ${T("skip permissions", "跳过权限确认")}</label>
    <label class="skipperm" title="${T("Open the session's terminal tab in the background and keep working here, in its conversation window", "终端标签页在后台打开，留在这里、在它的对话窗口里接着干")}">
    <input type="checkbox" data-action="stay-board" ${stayOnBoard() ? "checked" : ""}> ${T("stay on board", "留在看板上")}</label>`;
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
const resumeTip = (r) => T(`Resume it: claude --resume in ${r.cwd || "its directory"}${skipPerms() ? " (skipping permissions)" : ""}, in ${PLACES[launchPlace() === "bg" ? "terminal" : launchPlace()]}`,
  `续上它：在 ${r.cwd || "它原来的目录"} 里 claude --resume${skipPerms() ? "（跳过权限确认）" : ""}，开在 ${PLACES[launchPlace() === "bg" ? "terminal" : launchPlace()]}`);
function earlierList(t) {
  const rows = earlierSessions(t);
  if (!rows.length) return "";
  const shown = ui.histAll.has(t.id) ? rows : rows.slice(0, 3);
  return `<div class="meta past-h">${T("Earlier sessions", "以前的 session")}</div>` + shown.map((r) => `<div class="bsess past">
      <span class="dot idle"></span>
      <div style="flex:1;min-width:0"><div class="stitle">${esc(r.title || r.sessionId.slice(0, 8))}</div>
        <div class="meta">${T("ended", "已结束")} · ${ago(r.lastAt)}${r.lastText ? " · " + esc(r.lastText.slice(0, 90)) : ""}</div></div>
      <div class="icons">
        <button class="icon" data-action="peek" data-session="${esc(r.sessionId)}" title="${T("Read its conversation", "看它的对话")}">${ICON.peek}</button>
        <button class="btn small" data-action="resume" data-task="${esc(t.id)}" data-session="${esc(r.sessionId)}" data-dir="${esc(r.cwd || "")}" data-name="${esc(r.title || "")}" title="${esc(resumeTip(r))}" ${ui.resuming.has(r.sessionId) ? "disabled" : ""}>↻ Resume</button>
        <button class="icon" data-confirm="${T("Remove?", "移除？")}" data-action="forget-session" data-task="${esc(t.id)}" data-session="${esc(r.sessionId)}" title="${T("Remove it from this task's sessions (the conversation itself is kept)", "从这个任务的 session 列表里去掉（对话本身保留）")}">✕</button>
      </div></div>`).join("") +
    (rows.length > 3 ? `<button class="btn small ghost" data-action="hist-all" data-task="${esc(t.id)}">${ui.histAll.has(t.id) ? T("Show fewer", "收起") : T(`Show all ${rows.length}`, `显示全部 ${rows.length} 个`)}</button>` : "");
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
// A task with no folder yet (made on the board or from a quick note, no session bound): ask for
// one, keep it on the card, and start there. "" when the picker is cancelled.
async function ensureLaunchDir(t) {
  const have = launchDir(t);
  if (have) return have;
  const r = await apiObj("pick-folder", { path: "", message: T(`${t.id} has no folder yet — pick the one its sessions should start in`, `${t.id} 还没有目录——选一个 session 要开在里面的目录`) });
  if (!r.path) return "";
  // Start there even if it can't be kept (an older hq without `workdir`): launch expands the ~.
  try { await api("workdir", { action: "add", task: t.id, path: r.path }); } catch (e) { toast(String(e.message || e), true); return r.path; }
  await refresh();
  return launchDir(taskById(t.id) || t) || r.path;
}
// ---- "▶ Do it" on an @claude todo: hand it to the task's live session, or start one for it.
const DO_PROMPT = (t, text) => `This session works on HQ task ${t.id}: ${t.title}. Read the task card, then do this todo from it: "${text}". Tick it on the card when it's done, or say what is blocking it.`;
const HANDED_MS = 30 * 60 * 1000;   // how long a handed-over todo says so
function doItButton(t, x) {
  if (x.state !== "open" || x.owner !== "claude") return "";
  const key = `${t.id}|${x.text}`;
  const h = ui.handed[key];
  if (ui.handing.has(key)) return `<button class="btn small ghost doit" disabled>${T("Handing…", "交接中…")}</button>`;
  if (h && Date.now() - h.at < HANDED_MS) {
    return `<button class="btn small ghost doit" title="${esc(T(`Handed to ${h.to} ${ago(new Date(h.at).toISOString())} — click to hand it over again`, `${ago(new Date(h.at).toISOString())}交给了 ${h.to}——再点一下会再交一次`))}" data-action="do-todo" data-task="${esc(t.id)}" data-text="${esc(x.text)}">✓ ${esc(h.to.length > 18 ? h.to.slice(0, 18) + "…" : h.to)}</button>`;
  }
  const s = doTarget(t);
  const held = !s && doBlocked(t);
  const tip = s ? T(`Send it to ${s.title || s.project} as a message${s.state === "busy" ? " (busy — it will queue)" : ""}`, `作为一条消息发给 ${s.title || s.project}${s.state === "busy" ? "（正忙——会排队）" : ""}`)
    : held ? `${held.title || held.project}: ${ON_PROMPT()}`
    : T("No session on this task can take a message — start one that does this todo", "这个任务没有能收消息的 session——新开一个来做这条待办");
  return `<button class="btn small doit" title="${esc(tip)}" data-action="do-todo" data-task="${esc(t.id)}" data-text="${esc(x.text)}">▶ ${T("Do it", "去做")}</button>`;
}
// The live session to hand a task's todo to: one the board can type into, most recently active first.
function doTarget(t) {
  return liveFor(t.id).filter(canSendNow)
    .sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")))[0] || null;
}
// A session on the task that could take the todo but is stopped on a prompt: the todo waits for
// it rather than going to a second, new session.
const doBlocked = (t) => liveFor(t.id).filter(canMessage).find(onPrompt) || null;
// Hand a task something to do: as a message to its live session (queued when it is busy), or
// to a new session started the way "New session" would, when none can take one. Nothing goes to
// a session stopped on a prompt. `key` marks the button that asked, so it can say who got it.
async function handOff(t, key, message, prompt, started) {
  if (!t || ui.handing.has(key)) return;
  ui.handing.add(key);
  render();
  try {
    const s = doTarget(t);
    if (s) {
      const busy = s.state === "busy";
      await api("send", { session: s.sessionId, text: message, queue: busy, ...sendExtra(s) });
      ui.handed[key] = { to: s.title || s.project, at: Date.now() };
      toast(T(`${busy ? "Queued for" : "Sent to"} ${s.title || s.project}`, `${busy ? "已排队发给" : "已发给"} ${s.title || s.project}`));
    } else if (doBlocked(t)) {
      throw new Error(`${doBlocked(t).title || doBlocked(t).project}: ${ON_PROMPT()}`);
    } else {
      const dir = await ensureLaunchDir(t);
      if (!dir) return toast(T("No folder picked — the session needs one to start in", "没有选目录——session 得有个目录才能开"));
      const place = launchPlace();
      const r = await apiObj("launch", { task: t.id, title: t.title, dir, where: place, prompt, skip: skipPerms(), focus: !stayOnBoard() });
      stayWith(r && r.session, `${t.id} ${t.title}`);
      ui.handed[key] = { to: T("a new session", "新 session"), at: Date.now() };
      toast(started(PLACES[place]));
      setTimeout(() => refresh(), 2500);
    }
  } catch (e) { toast(String(e.message || e), true); }
  finally { ui.handing.delete(key); render(); }
}
function doTodo(taskId, text) {
  const t = taskById(taskId);
  return handOff(t, `${taskId}|${text}`,
    `[HQ board] Please do this todo on ${taskId}'s card now: "${text}". Tick it on the card when it's done, or say what is blocking it.`,
    t && DO_PROMPT(t, text),
    (place) => T(`Started a session on ${taskId} (${place}) to do it`, `已在 ${taskId} 上新开一个 session（${place}）去做`));
}

// ---- "Tidy todos": have the task's session check its open @claude todos against how things
// stand now, and tick or drop each in its hq-update. Same hand-off as Do it.
const TIDY_ASK = "check each against how things stand now (PR merged? cluster deleted? run finished?) and, in your hq-update, tick the finished ones with `done: <text>` and drop the obsolete ones with `drop: <text>`, the text copied exactly from the card. Leave the ones still to do open and don't start on them now.";
const TIDY_PROMPT = (t) => `This session works on HQ task ${t.id}: ${t.title}. Read the task card, then tidy its open @claude todos: ${TIDY_ASK}`;
const claudeOpenTodos = (t) => t.todos.filter((x) => x.state === "open" && x.owner === "claude");
// The list itself goes with the message: a running session only has the one it was given at start
// (maybe compacted away since), and a `done:` whose text doesn't match fails the whole hq-update.
// Same cap as hq's SessionStart list: the newest 20 that fit in 2000 characters.
function tidyList(t) {
  const items = claudeOpenTodos(t);
  const shown = [];
  let used = 0;
  for (const x of items.slice().reverse()) {
    if (shown.length >= 20 || (shown.length && used + x.text.length > 2000)) break;
    shown.unshift(x);
    used += x.text.length;
  }
  const more = items.length - shown.length;
  return `The open @claude todos (${items.length}), text exactly as on the card:\n` + shown.map((x) => `- ${x.text}`).join("\n")
    + (more ? `\n- … ${more} older ones not shown — read the card's todo section` : "");
}
function tidyButton(t) {
  const n = claudeOpenTodos(t).length;
  if (!n) return "";
  const key = `${t.id}|tidy`;
  const h = ui.handed[key];
  if (ui.handing.has(key)) return `<button class="btn small ghost tidy" disabled>${T("Handing…", "交接中…")}</button>`;
  if (h && Date.now() - h.at < HANDED_MS) {
    return `<button class="btn small ghost tidy" title="${esc(T(`Handed to ${h.to} ${ago(new Date(h.at).toISOString())} — click to hand it over again`, `${ago(new Date(h.at).toISOString())}交给了 ${h.to}——再点一下会再交一次`))}" data-action="tidy-todos" data-task="${esc(t.id)}">✓ ${esc(h.to.length > 18 ? h.to.slice(0, 18) + "…" : h.to)}</button>`;
  }
  const s = doTarget(t);
  const held = !s && doBlocked(t);
  const what = T(`check Claude's ${n} open todo${n === 1 ? "" : "s"} against how things stand now and tick or drop each`, `对照现状检查 Claude 的 ${n} 条未完成待办，逐条勾掉或不做`);
  const tip = s ? T(`Ask ${s.title || s.project} to ${what}${s.state === "busy" ? " (busy — it will queue)" : ""}`, `让 ${s.title || s.project} ${what}${s.state === "busy" ? "（正忙——会排队）" : ""}`)
    : held ? `${held.title || held.project}: ${ON_PROMPT()}`
    : T(`No session on this task can take a message — start one to ${what}`, `这个任务没有能收消息的 session——新开一个来${what}`);
  return `<button class="btn small ghost tidy" title="${esc(tip)}" data-action="tidy-todos" data-task="${esc(t.id)}">${T("Tidy todos", "整理待办")}</button>`;
}
function tidyTodos(taskId) {
  const t = taskById(taskId);
  return handOff(t, `${taskId}|tidy`,
    `[HQ board] Please tidy the open @claude todos on ${taskId}'s card: ${TIDY_ASK}` + (t ? "\n" + tidyList(t) : ""),
    t && TIDY_PROMPT(t),
    (place) => T(`Started a session on ${taskId} (${place}) to tidy its todos`, `已在 ${taskId} 上新开一个 session（${place}）整理待办`));
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
  // Which copy it was: the conversation window, the task drawer and the page can each show a box
  // with the same key (an ask's note box is in Needs you and in the drawer).
  const regionOf = (x) => (x.closest("#modal, #drawer") || {}).id || "";
  const activeRegion = active && active.closest ? regionOf(active) : "";
  const taScrolls = textScrolls(document);
  // Peek panes are rebuilt every refresh; keep where the reader was (bottom = newest by default).
  const scrolls = {};
  document.querySelectorAll(".peek[data-sid]").forEach((p) => {
    scrolls[p.dataset.sid] = p.scrollHeight - p.scrollTop - p.clientHeight < 8 ? "bottom" : p.scrollTop;
  });
  // So are Focus's lanes: each keeps its own scroll, or a refresh every few seconds would throw a
  // long lane back to its top.
  grabLaneScrolls();

  renderCounts();
  drawSecretaryButton();
  // Four pages: Focus (the tasks you keep in view), Projects & duties (projects.js: every project,
  // with what is running and waiting on you in each), Needs you (every unanswered ask and your
  // todos) with its count on the tab, and Scheduled (jobs.js).
  if (!["today", "projects", "needs", "jobs"].includes(ui.mode)) ui.mode = "today";
  const need = needCount();
  // Each tab carries its count; only Needs you's is lit, because only it asks something of you.
  // (Scheduled has none: its jobs are only read while that page is showing.)
  // Projects & duties counts the open tasks, as All did.
  const tabN = { today: focusIds().filter((id) => id !== secId()).length, projects: listed().filter(isOpen).length, needs: need };
  $("#mode").innerHTML = [["today", "Focus"], ["projects", T("Projects & duties", "项目与职责")], ["needs", "Needs you"], ["jobs", typeof jt === "function" ? jt("tab") : "Scheduled"]].map(([m, label]) =>
    `<button class="tab ${ui.mode === m ? "on" : ""}" data-action="mode" data-m="${m}"${ui.mode === m ? ` aria-current="page"` : ""}${m === "needs" ? ` title="${T("Unanswered asks, your todos and unsorted notes", "未回应的问题、你的待办和未分拣的记录")}"` : m === "projects" ? ` title="${T("Every project and duty, with what is running and waiting on you in each; the number counts open tasks", "所有项目和职责，每个里面在跑、在等你的任务；数字是进行中的任务数")}"` : ""}>${label}${tabN[m] ? `<span class="n ${m === "needs" ? "hot" : ""}">${tabN[m]}</span>` : ""}</button>`).join("");
  $("#today").hidden = ui.mode !== "today";
  $("#needs").hidden = ui.mode !== "needs";
  $("#jobs").hidden = ui.mode !== "jobs";
  $("#projects").hidden = ui.mode !== "projects";
  if (ui.mode === "jobs" && typeof renderJobsView === "function") renderJobsView();   // see jobs.js
  // Only the page on show holds cards: a hidden page's leftovers would double ids like kc-<id>,
  // and a lookup would find the invisible copy.
  $("#today-focus").innerHTML = ui.mode === "today" ? renderToday() : "";
  $("#proj-view").innerHTML = "";
  if (ui.mode === "projects" && typeof renderProjectsView === "function") renderProjectsView();   // see projects.js
  renderNeeds();
  renderCaptureAtts();
  renderSettings();
  renderDrawer();

  document.querySelectorAll(".peek[data-sid]").forEach((p) => {
    const v = scrolls[p.dataset.sid];
    p.scrollTop = v === undefined || v === "bottom" ? p.scrollHeight : v;
  });
  paintTaskIds();
  paintArmed();
  fitAllGrow();
  restoreLaneScrolls();   // after the text boxes have their height back
  // Put the cursor back only if the box you were typing in was rebuilt — one that wasn't (the
  // conversation window's reply box, say) keeps it. And look for its stand-in in the same place:
  // a session's message box in the Sessions column shares its key with the conversation window's
  // reply box, and grabbing the first match moved the cursor to the one hidden behind the window.
  if (key && !active.isConnected) {
    // …and a visible one: a hidden page's boxes can stay in the DOM.
    const el = [...document.querySelectorAll(`[data-key="${CSS.escape(key)}"]`)]
      .find((x) => regionOf(x) === activeRegion && x.getClientRects().length);
    if (el) {
      el.focus();
      if (sel && el.setSelectionRange) el.setSelectionRange(sel[0], sel[1]);
    }
  }
  restoreTextScrolls(document, taScrolls);
  slashPlace();
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
  return unsortedNotes().length + tasks().reduce((n, t) => n + openAsks(t).length, 0) +
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
  const loose = unsortedNotes().length;
  // Task counts are on the tabs; the status bar says what the sessions are doing, what waits on
  // you (click → Needs you), and the quota on the right.
  $("#counts").innerHTML =
    `<span class="sgroup jump" data-action="open-sessions" title="${T("Live Claude Code sessions — click for the list", "正在运行的 Claude Code session——点击看列表")}"><b>${ui.sessions.length}</b> ${T(`session${ui.sessions.length === 1 ? "" : "s"}`, "个 session")}` +
      `${part(by("busy"), T("working", "在干活"))}${part(by("waiting"), T("waiting on you", "等你"), "warn")}</span>` +
    (asks || mine || later || loose ? `<span class="sgroup jump" data-action="mode" data-m="needs" title="${T("Open Needs you", "打开 Needs you")}">` +
      [asks ? `<b>${asks}</b> ${T(`ask${asks === 1 ? "" : "s"}`, "个问题")}` : "", mine ? `<b>${mine}</b> ${T(`todo${mine === 1 ? "" : "s"}`, "条待办")}` : "",
       loose ? `<b>${loose}</b> ${T(`unsorted note${loose === 1 ? "" : "s"}`, "条未分拣")}` : ""].filter(Boolean).join(" · ") +
      `${later ? `<span class="sp">${T(`${later} for later`, `${later} 条稍后再答`)}</span>` : ""}</span>` : "");
  $("#quota").innerHTML = usageChips();
}
// The subscription's 5-hour and weekly limits — percent used and when each resets — as the
// statusline last saw them (see BoardBridge.usageSnapshot). Nothing when there is no fresh copy.
function untilText(iso) {
  const m = Math.max(0, Math.round((new Date(iso).getTime() - Date.now()) / 60000));
  if (isNaN(m)) return "";
  if (m < 60) return T(`${m}m`, `${m}分钟`);
  if (m < 24 * 60) return T(`${Math.floor(m / 60)}h ${m % 60}m`, `${Math.floor(m / 60)}小时${m % 60}分`);
  return T(`${Math.floor(m / 1440)}d ${Math.floor((m % 1440) / 60)}h`, `${Math.floor(m / 1440)}天${Math.floor((m % 1440) / 60)}小时`);
}
function usageChips() {
  const u = ui.usage;
  if (!u) return "";
  const one = (label, long, w) => {
    if (!w || w.used == null) return "";
    const p = Math.round(w.used);
    const r = w.resets_at ? untilText(w.resets_at) : "";
    return `<span class="quota ${p >= 90 ? "hi" : p >= 70 ? "mid" : ""}" title="${T(`${long}: ${p}% used${r ? ` · resets in ${r}` : ""}`, `${long}：已用 ${p}%${r ? ` · ${r}后重置` : ""}`)}">${label}
      <span class="qbar"><i style="width:${Math.min(100, p)}%"></i></span><b>${p}%</b>${r ? `<span class="qr">${T(`resets ${r}`, `${r}后重置`)}</span>` : ""}</span>`;
  };
  return one(T("5h", "5小时"), T("5-hour limit", "5 小时额度"), u.five_hour) + one(T("week", "每周"), T("Weekly limit", "每周额度"), u.seven_day);
}

function renderAsks() {
  const items = [];
  let total = 0;
  for (const t of tasks()) for (const a of openAsks(t)) { total++; if (taskMatches(t, a.text)) items.push([t, a]); }
  items.sort((x, y) => String(x[1].ts).localeCompare(String(y[1].ts)));
  const later = tasks().filter((t) => laterAsks(t).length && taskMatches(t, ...laterAsks(t).map((a) => a.text)));
  const laterHtml = later.map((t) => `<div class="later-of">${t.id === secId() ? secChip() : `<span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>`}${laterLine(t)}</div>`).join("");
  const head = "";
  if (!items.length && total) return head + `<div class="group-title">${T("Claude is asking", "Claude 在问")}</div>` + filterNote(0, total) + laterHtml;
  if (!items.length) return head + `<div class="calm"><svg viewBox="0 0 16 16"><path d="M3 8.5l3 3 7-7"/></svg>${T("Claude has nothing waiting on an answer from you.", "Claude 没有在等你回答的问题。")}</div>` + laterHtml;
  const byTask = new Map();
  for (const [t, a] of items) byTask.set(t, (byTask.get(t) || []).concat([a]));
  return head + `<div class="group-title">${T("Claude is asking", "Claude 在问")} <span class="meta">${items.length}</span></div>` + filterNote(items.length, total) + [...byTask].map(([t, asks]) => renderAskGroup(t, asks)).join("") + laterHtml;
}

// A task with several open asks answers them together: each answer button only picks, and one
// Send at the bottom records them all and types a single message into the session.
function renderAskGroup(t, asks, extra = {}) {
  if (asks.length < 2) return asks.map((a) => askCard(t, a, extra)).join("");
  const target = groupTarget(asks);
  const picked = asks.filter((a) => ui.picks[a.id]).length;
  const sending = asks.some((a) => ui.resolving.has(a.id));
  const allPush = target && asks.every((a) => wantPush(a));
  return `<div class="askgroup">${asks.map((a) => askCard(t, a, { ...extra, group: true, sharedTarget: Boolean(target) })).join("")}
    <div class="askbar">
      <span class="meta">${T(`${picked} of ${asks.length} answered`, `已选 ${picked} / ${asks.length}`)}</span>
      ${target ? `<label class="push" title="${T("Type all the answers into that session as one message, so it carries on now", "把所有回答合成一条消息发给那个 session，让它马上接着干")}">
        <input type="checkbox" data-action="push-group" data-ids="${esc(asks.map((a) => a.id).join(" "))}" ${allPush ? "checked" : ""}>
        ${T("send to", "现在发给")} <b>${esc(target.title || target.project)}</b>${T(" now", "")}${target.state === "busy" ? T(" (busy — it will queue)", "（正忙——会排队）") : ""}</label>` : `<span style="flex:1"></span>`}
      <button class="btn small primary" data-action="resolve-all" data-task="${esc(t.id)}" ${picked && !sending ? "" : "disabled"}
        title="${T(`Record every answer you picked${target ? " and send them in one message" : ""}`, `记下你选好的每个回答${target ? "，并合成一条消息发出" : ""}`)}">${sending ? T("Sending…", "发送中…") : picked ? T(`Send ${picked} answer${picked === 1 ? "" : "s"}`, `发送 ${picked} 个回答`) : T("Send answers", "发送回答")}</button>
    </div></div>`;
}
// The one live session every ask in a group came from, if the board can type into it.
function groupTarget(asks) {
  const ts = asks.map(pushTarget);
  return ts[0] && ts.every((x) => x && x.sessionId === ts[0].sessionId) ? ts[0] : null;
}

// The secretary's asks are labeled as its own and open its window, not its (hidden) card.
const secChip = () => `<span class="chip link sec" data-action="open-secretary" title="${T("Open the secretary", "打开秘书")}">${T("Secretary", "秘书")}</span>`;
// No "Yes, always" for the secretary: a standing grant is never for it. opt.peek: in its window,
// which doesn't redraw for ⋯ or pasted images either: those stay in Needs you.
function askCard(t, a, opt = {}) {
  const pick = ui.picks[a.id];
  const attKey = "ask:" + a.id;
  const sec = t.id === secId();
  const meta = opt.peek ? `<span class="chip">${esc(a.id)}</span>${ago(a.ts)}`
    : sec ? `${secChip()}<span class="chip link" data-action="open-secretary">${esc(a.id)}</span>${ago(a.ts)}`
    : opt.inTask ? `<span class="chip">${esc(a.id)}</span>${ago(a.ts)}`
    : `<span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(a.id)}</span>${esc(t.title)} · ${ago(a.ts)}`;
  const res = opt.peek || sec ? RESOLUTIONS.filter(([r]) => r !== "always")
    : RESOLUTIONS.concat(ui.moreRes.has(a.id) || pick === "archive" ? MORE_RESOLUTIONS : []);
  return `
    <div class="card ask ${pick ? "picked" : ""}">
      <div class="meta">${meta}</div>
      ${opt.peek ? `<div class="ask-text">${esc(a.text)}</div>`
        : `<div class="ask-text clickable" title="${T("Show where this came from", "看看它从哪来")}" data-action="ctx" data-kind="ask" data-task="${esc(t.id)}" data-id="${esc(a.id)}">${esc(a.text)}</div>`}
      <div class="row askrow">
        <textarea class="note grow" rows="1" data-key="note:${esc(a.id)}" ${opt.peek ? "" : `data-att="${esc(attKey)}"`} placeholder="${opt.peek ? T("note", "说明") : T("note · paste images", "说明 · 可粘贴图片")}" title="${T("Optional note — your answer in words, or why; paste or drop screenshots too", "可选的说明——用文字写你的回答或原因；也可以粘贴或拖入截图")}">${esc(draft("note:" + a.id))}</textarea>
        ${res.map(([r, label, tip]) => opt.group
          ? `<button class="btn small res-${r} ${pick === r ? "on" : ""}" title="${esc(tip)}${T(" — pick, then Send below", "——先选，再点下面的发送")}" data-action="pick" data-id="${esc(a.id)}" data-res="${r}">${label}</button>`
          : `<button class="btn small res-${r} ${r === "always" && ui.granting.has(a.id) ? "on" : ""}" title="${esc(tip)}" data-action="${r === "always" ? "grant-open" : "resolve"}" data-id="${esc(a.id)}" data-res="${r}">${label}</button>`).join("")}
        ${opt.peek || sec || ui.moreRes.has(a.id) || pick === "archive" ? "" : `<button class="btn small ghost res-more" title="${T("More answers: No context — I can't answer this, park it", "更多回答：不了解背景——我答不了，先归档")}" data-action="more-res" data-id="${esc(a.id)}">⋯</button>`}
      </div>
      ${opt.peek ? "" : attachStrip(attKey)}
      ${!opt.peek && (opt.group ? pick === "always" : ui.granting.has(a.id)) ? grantBox(t, a, opt) : ""}
      ${pushTarget(a) && !opt.sharedTarget ? `<label class="push" title="${T("Type your answer into that session so it carries on now, instead of waiting for your next message there", "把回答直接发给那个 session，让它马上接着干，不用等你在那边发下一条消息")}">
        <input type="checkbox" data-key="push:${esc(a.id)}" ${wantPush(a) ? "checked" : ""}>
        ${T("send to", "现在发给")} <b>${esc(pushTarget(a).title || pushTarget(a).project)}</b>${T(" now", "")}${pushTarget(a).state === "busy" ? T(" (busy — it will queue)", "（正忙——会排队）") : ""}</label>`
        : pushBlocked(a) && !opt.sharedTarget ? `<div class="onprompt">${T(`${esc(pushBlocked(a).title || pushBlocked(a).project)} is waiting on a prompt in its terminal — the answer reaches it at its next turn`, `${esc(pushBlocked(a).title || pushBlocked(a).project)} 在终端里等你确认或回答——回应会在它下一轮送达`)}</div>` : ""}
    </div>`;
}

// "Yes, always": word the standing grant before it goes on the card. The session may have
// suggested one with the ask ([grant: …]); presets are the kinds you said yes to most.
function grantBox(t, a, opt) {
  const have = (t.grants || []).some((g) => grantKey(g.text) === grantKey(grantWording(a)));
  return `<div class="grantbox">
    <div class="meta">${T("From now on, without asking — sessions on", "以后不用问，直接做——")} ${esc(t.id)}${T(":", " 的 session：")}</div>
    <textarea class="note grow" rows="1" data-key="grant:${esc(a.id)}" placeholder="${T("the kind of step, e.g. rerun a verification with the same parameters", "这一类事情，如：用和上次相同的参数重跑验证")}">${esc(grantWording(a))}</textarea>
    ${have ? `<div class="meta">${T("Already granted on this task — this just answers Yes.", "这个任务已经有这条授权——这次只是回答可以。")}</div>` : ""}
    ${grantPresets("grant-preset", `data-id="${esc(a.id)}"`)}
    ${opt.group ? "" : `<div class="row" style="justify-content:flex-end">
      <button class="btn small ghost" data-action="grant-cancel" data-id="${esc(a.id)}">${T("Cancel", "取消")}</button>
      <button class="btn small primary" data-action="resolve" data-id="${esc(a.id)}" data-res="always">${T("Yes, and grant it", "可以，并授权")}</button></div>`}
  </div>`;
}

// The live session that raised an ask, if the board can type into its terminal.
function pushTarget(a) {
  const s = a.session && ui.sessions.find((x) => x.sessionId === a.session);
  return canSendNow(s) ? s : null;
}
// The session that raised an ask, when it could take the answer but is stopped on a prompt.
function pushBlocked(a) {
  const s = a.session && ui.sessions.find((x) => x.sessionId === a.session);
  return canMessage(s) && onPrompt(s) ? s : null;
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
function resText(res, note, granted) {
  if (res === "always") return resText("do", note) + (granted ? ` — and from now on, without asking: ${granted} (a standing grant)` : "");
  if (res === "do") return note ? `Answer: ${note}` : "Yes — go ahead as you suggested";
  if (res === "drop") return "No" + (note ? ` — ${note}` : "");
  return (RES_TEXT[res] || res) + (note && res !== "snooze" ? ` — ${note}` : "");
}
// "To todo" is the board's own answer: the ask becomes an @me todo on its task, and is closed as
// "do" with a note saying so. Returns what an Undo needs.
async function answerAsk(a, res, note) {
  if (res === "snooze") { await api("snooze", { id: a.id }); return { snoozed: true }; }
  if (res === "always") {
    const task = a.id.replace(/\.\d+$/, "");
    const wording = String(grantWording(a)).replace(/\s+/g, " ").trim();
    if (!wording) throw new Error(T("Word the grant first", "先写好授权的措辞"));
    // hq says whether the grant was already on the card: then an Undo leaves it there.
    const r = await apiObj("resolve", { id: a.id, resolution: "do", note, grant: wording });
    delete ui.drafts["grant:" + a.id]; ui.granting.delete(a.id);
    return { task, granted: r.granted || wording, existed: Boolean(r.existed) };
  }
  if (res !== "todo") { await api("resolve", { id: a.id, resolution: res, note }); return null; }
  const task = a.id.replace(/\.\d+$/, "");
  const text = `@me ${a.text}${note ? ` — ${note}` : ""}`.replace(/\s+/g, " ").trim();
  await api("addtodo", { task, text });
  try {
    await api("resolve", { id: a.id, resolution: "do", toTodo: true, note: `made an @me todo — the user will do it${note ? `: ${note}` : ""}` });
  } catch (e) {
    try { await dropMadeTodo({ task, text }); } catch (e2) { /* best effort */ }
    throw e;
  }
  return { task, text };
}
// Undo of "To todo": the todo it added goes too (marked dropped, so the card keeps the trace).
// Undo of "Yes, always": the grant it added is revoked again.
async function dropMadeTodo(made) {
  if (!made) return;
  if (made.granted) {
    if (!made.existed) await api("grant", { action: "revoke", task: made.task, text: made.granted });
    return;
  }
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
function pushMessage(a, res, note, made) {
  return `[HQ board] ${a.id} "${gist(a.text)}": ${resText(res, note, made && made.granted)}`;
}
function pushMessageAll(answers) {
  return "[HQ board] Answers:\n" +
    answers.map(({ a, res, note, made }) => `- ${a.id} "${gist(a.text)}": ${resText(res, note, made && made.granted)}`).join("\n");
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
  let total = 0;
  for (const t of tasks().filter(isOpen))
    for (const x of t.todos) if (x.state === "open" && x.owner === "me") { total++; if (taskMatches(t, x.text)) items.push([t, x]); }
  // A card may still carry the old free-text "waiting on you" field (written before it was
  // folded into @me todos). Show it here as a todo rather than lose it; ticking clears it.
  const waiting = tasks().filter((t) => isOpen(t) && t.waiting_on_me);
  total += waiting.length;
  const legacy = waiting.filter((t) => taskMatches(t, t.waiting_on_me));
  // Newest first; each shows how long it has been waiting (amber after STALE_DAYS).
  const since = (iso) => Date.parse(iso || "") || 0;
  items.sort((a, b) => since(b[1].created) - since(a[1].created));
  legacy.sort((a, b) => since(b.waiting_since) - since(a.waiting_since));
  const age = (iso) => {
    const ms = since(iso);
    if (!ms) return "";
    const days = (Date.now() - ms) / 86400000;
    const label = ago(iso).replace(" ago", "").replace(/前$/, "");
    return `<span class="age ${days >= 7 ? "stale old" : days >= STALE_DAYS ? "stale" : ""}" title="${T("Waiting since", "开始等待于")} ${esc(new Date(ms).toLocaleString())}">${label}</span>`;
  };
  // Recently ticked items stay in view (struck through, with Undo) for an hour. After that,
  // reopen from the task itself — every change is also in the card's log.
  ui.recent = ui.recent.filter((r) => Date.now() - r.at < RECENT_MS);
  const recent = ui.recent.filter((r) => {
    const t = taskById(r.task);
    const x = t && t.todos.find((y) => y.i === r.i);
    return x && x.state !== "open" && taskMatches(t, r.text);
  });
  const src = (t) => `<div class="meta src"><span class="tid link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span> ${esc(t.title)}${t.status === "blocked" ? T(" · blocked", " · 阻塞中") : ""}</div>`;
  const note = filterNote(items.length + legacy.length, total);
  if (!items.length && !recent.length && !legacy.length) return `<div class="group-title">${T("Your todos", "你的待办")}</div>${note || `<div class="empty">${T("Nothing waiting on you.", "没有在等你的事。")}</div>`}`;
  return `<div class="group-title">${T("Your todos", "你的待办")} <span class="meta">${items.length + legacy.length}</span></div>${note}<div class="inbox-list">` + legacy.map((t) => `
    <div class="todo it">
      <span class="box" title="${T("Handled (you can undo)", "处理好了（可以撤销）")}" data-action="clear-waiting" data-task="${esc(t.id)}"></span>
      <div class="it-t"><span class="t clickable" title="${T("Show context", "查看上下文")}" data-action="ctx" data-kind="waiting" data-task="${esc(t.id)}">${esc(t.waiting_on_me)}</span>${src(t)}</div>
      ${age(t.waiting_since)}
    </div>`).join("") + items.map(([t, x]) => `
    <div class="todo it">
      <span class="box" title="${T("Mark done (you can undo)", "标为完成（可以撤销）")}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="done" data-from="open" data-text="${esc(x.text)}"></span>
      <div class="it-t"><span class="t clickable" title="${T("Show context", "查看上下文")}" data-action="ctx" data-kind="todo" data-task="${esc(t.id)}" data-i="${x.i}">${esc(x.text)}</span>${src(t)}</div>
      ${age(x.created)}
      <button class="icon x" title="${T("Won't do (you can undo)", "不做（可以撤销）")}" data-confirm="${T("Won't do?", "不做？")}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop" data-from="open" data-text="${esc(x.text)}">✕</button>
    </div>`).join("") + recent.map((r) => `
    <div class="todo it ${r.to === "drop" ? "dropped" : "done"}">
      <span class="box ${r.to === "drop" ? "dropped" : "done"}">${r.to === "drop" ? "–" : "✓"}</span>
      <div class="it-t"><span class="t">${esc(r.text)}</span>
        <div class="meta src">${r.to === "drop" ? T("won't do", "不做") : T("done", "已完成")} ${ago(new Date(r.at).toISOString())} · ${T("undo available for an hour", "1 小时内可以撤销")} · <span class="tid link" data-action="goto" data-task="${esc(r.task)}">${esc(r.task)}</span></div></div>
      <button class="btn small" data-action="undo-todo" data-task="${esc(r.task)}" data-i="${r.i}">${T("Undo", "撤销")}</button>
    </div>`).join("") + `</div>`;
}

// The scrolling boxes render() rebuilds (Needs you's columns are drawn once): in Focus a lane's card list and the lanes' grid where it scrolls as a
// whole (narrow windows); on a project's page its two columns too. Keyed by the page (and the
// project), the lane and the box's place among its kind, so a lane gets its own scroll back even
// when cards move between lanes. Kept across renders in ui.laneScroll, so coming back to a page
// from another tab finds them where they were.
const LANE_SCROLLERS = { "#today-focus": ".lane-body, .board", "#proj-view": ".lane-body, .board, .pd-info, .pd-main, .pscroll" };
function laneScrollKeys() {
  const seen = {};
  const sel = Object.entries(LANE_SCROLLERS).map(([box, xs]) => xs.split(", ").map((x) => `${box} ${x}`).join(", ")).join(", ");
  return [...document.querySelectorAll(sel)]
    .map((el) => {
      const page = el.closest("#today-focus") ? "focus" : "proj:" + (ui.proj || "");
      const base = [page, (el.closest("[data-lane]") || {}).dataset?.lane || "", el.className].join("|");
      seen[base] = (seen[base] || 0) + 1;
      return [el, base + "|" + seen[base]];
    });
}
function grabLaneScrolls() {
  ui.laneScroll = ui.laneScroll || {};
  for (const [el, k] of laneScrollKeys()) ui.laneScroll[k] = el.scrollTop;
}
function restoreLaneScrolls() {
  for (const [el, k] of laneScrollKeys()) if (ui.laneScroll[k]) el.scrollTop = ui.laneScroll[k];
}

// Needs you: three columns — what Claude asks, what you are to do, what you jotted down — under a
// line of totals.
function renderNeeds() {
  const asks = tasks().reduce((n, t) => n + openAsks(t).length, 0);
  const later = tasks().reduce((n, t) => n + laterAsks(t).length, 0);
  const open = tasks().filter(isOpen);
  const todos = open.flatMap((t) => myTodos(t).map((x) => x.created).concat(t.waiting_on_me ? [t.waiting_since] : []));
  const oldest = todos.map((iso) => Date.parse(iso || "") || 0).filter(Boolean).sort((a, b) => a - b)[0];
  const oldDays = oldest ? Math.floor((Date.now() - oldest) / 86400000) : 0;
  const unsorted = unsortedNotes().length;
  const recent = notes().filter((x) => x.state !== "unsorted" && x.state !== "dropped" && Date.now() - (Date.parse(x.at) || 0) < 2 * 86400000).length;
  const stat = (ln, n, label, sub) => `<div class="stat l-${ln}"><span class="n">${n}</span><span class="l">${label}</span><span class="s">${sub}</span></div>`;
  $("#needs-sum").innerHTML =
    stat("you", asks, T("to answer", "个问题要回答"), later ? T(`${later} for later`, `${later} 条稍后再答`) : "") +
    stat("ready", todos.length, T("to do", "件事要你去做"), oldDays >= 1 ? T(`oldest ${oldDays}d`, `最久的 ${oldDays} 天`) : "") +
    stat("run", unsorted, T("notes to sort", "条记下的没分拣"), recent ? T(`${recent} sorted lately`, `最近分好 ${recent} 条`) : "");
  const h = (ln, name, n, hint) => `<span class="ld"></span><span class="name">${name}</span><span class="cnt">${n}</span><span class="hint">${hint}</span>`;
  $("#asks-h").innerHTML = h("you", T("Answer", "回答"), asks, T("Claude is asking", "Claude 在问"));
  $("#mytodos-h").innerHTML = h("ready", T("Do", "去做"), todos.length, T("your todos, newest first", "你的待办，新的在前"));
  $("#notes-h").innerHTML = h("run", T("Jotted", "记下的"), unsorted, T("unsorted, and the last two days", "未分拣的，和最近两天的"));
  $("#asks").innerHTML = renderAsks();
  $("#mytodos").innerHTML = renderMyTodos();
  $("#notes").innerHTML = renderNotes();
}

// ---- quick notes (`hq inbox`): a line, link or screenshot jotted in the header box or with the
// pet's shortcut (⌃⌥⌘N). A cheap model files it — a new task, a todo or a log line on a task, or
// your own todo — and what it isn't sure of waits here. Every note can be moved with a click.
const notes = () => (ui.board && ui.board.inbox) || [];
const unsortedNotes = () => notes().filter((x) => x.state === "unsorted");
function destLabel(d) {
  if (!d || d.kind === "unsorted") return T("unsorted", "未分拣");
  if (d.kind === "task") return T(`new task “${d.title || ""}”`, `新任务「${d.title || ""}」`) + (d.project ? ` · ${d.project}` : "");
  if (d.kind === "todo") return `${d.task} ${T("todo", "待办")} @${d.owner || "me"}`;
  if (d.kind === "note") return `${d.task} ${T("log", "记录")}`;
  return T("your todo", "我的待办");
}
// Where a note could go: the model's pick and its alternatives, each once.
function noteGuesses(x) {
  const seen = new Set(), out = [];
  for (const d of [x.dest, ...(x.alts || [])]) {
    if (!d || !d.kind) continue;
    const k = [d.kind, d.task || "", d.kind === "task" ? d.title : ""].join("|");
    if (!seen.has(k)) { seen.add(k); out.push(d); }
  }
  return out;
}
function destChip(x, d, extra = "") {
  return `<button class="chip link dest ${extra}" data-action="note-move" data-id="${esc(x.id)}" data-dest="${esc(JSON.stringify(d))}" title="${esc(d.text || d.title || "")}">${esc(destLabel(d))}</button>`;
}
// A title for "New task" when the model didn't offer one: the note's first line.
function noteTitle(x) {
  const g = noteGuesses(x).find((d) => d.kind === "task");
  if (g) return g.title;
  const line = String(x.text || "").split("\n")[0].trim();
  return line.length > 60 ? line.slice(0, 59) + "…" : line || T("Quick note", "快速记录");
}
function renderNotes() {
  const all = notes();
  if (!all.length) return "";
  const f = filterText();
  const items = all.filter((x) => !f || [x.text, x.dest && (x.dest.text || x.dest.title), x.task].join(" ").toLowerCase().includes(f));
  const open = unsortedNotes().length;
  const picker = (x) => {
    const k = "note-pick:" + x.id;
    // Preselect the task it is filed on — not a card it created, which it can't be filed onto.
    const pick = ui.drafts[k] || (x.dest && x.dest.kind === "task" ? "" : x.task) || "";
    const choices = tasks().filter(isOpen).filter((t) => t.id !== secId());
    return `<div class="qnote-pick">
      <select data-key="${esc(k)}"><option value="">${T("Choose a task…", "选一个任务…")}</option>
        ${choices.map((t) => `<option value="${esc(t.id)}" ${t.id === pick ? "selected" : ""}>${esc(t.id)} · ${esc(t.title)}</option>`).join("")}</select>
      <button class="btn small" data-action="note-to-task" data-id="${esc(x.id)}" data-kind="todo" ${pick ? "" : "disabled"}>${T("As a todo", "作为待办")}</button>
      <button class="btn small" data-action="note-to-task" data-id="${esc(x.id)}" data-kind="note" ${pick ? "" : "disabled"}>${T("As a log line", "作为记录")}</button>
      <span class="spacer"></span>
      ${x.dest && x.dest.kind === "task" && x.state === "sorted" ? "" : destChip(x, { kind: "task", title: noteTitle(x) })}
      ${!secId() || (x.dest && x.dest.kind === "me" && x.state === "sorted") ? "" : destChip(x, { kind: "me" })}
      ${x.state === "sorted" ? destChip(x, { kind: "unsorted" }, "ghost") : ""}
    </div>`;
  };
  // A conversation or issue from `hq feed`: its first line is "Zulip · <title> · <url>" (or
  // "Jira · …"); the lines after it are clamped to a few until the note is opened.
  const feedText = (x, isOpen) => {
    const [head, ...body] = String(x.text || "").split("\n");
    const parts = head.split(" · ");
    const url = parts.length >= 3 ? parts.pop() : "";
    const [src, ...title] = parts;
    return `<span class="t"><span class="chip">${esc(src)}</span> ${url ? `<a href="#" data-action="link" data-url="${esc(url)}" title="${esc(url)}">${esc(title.join(" · "))}</a>` : esc(title.join(" · "))}</span>
      <div class="feed-msgs ${isOpen ? "open" : ""}">${esc(body.join("\n"))}</div>`;
  };
  const imgs = (x) => (x.images || []).map((p, i) => `<span class="chip link" data-action="open" data-path="${esc(p)}" title="${esc(p)}">${T("image", "图")} ${i + 1}</span>`).join(" ");
  const row = (x) => {
    const isOpen = ui.noteOpen.has(x.id);
    const d = x.dest;
    let meta = "", chips = "", side = "";
    if (x.state === "sorting") meta = `<span class="sorting">${T("Sorting…", "分拣中…")}</span>`;
    else if (x.state === "dropped") {
      meta = T("deleted", "已删掉");
      side = `<button class="btn small" data-action="note-restore" data-id="${esc(x.id)}">${T("Restore", "恢复")}</button>`;
    } else if (x.state === "unsorted") {
      meta = x.error ? `<span class="bad">${T("Couldn't sort", "没分拣成")}: ${esc(x.error)}</span>`
        : x.reason ? `${T("Not sure", "没把握")} · ${esc(x.reason)}` : (x.by === "user" ? T("moved back here", "改回了未分拣") : "");
      chips = noteGuesses(x).map((g) => destChip(x, g)).join("") +
        `<button class="chip link ghost" data-action="note-change" data-id="${esc(x.id)}">${isOpen ? T("Fewer", "收起") : T("Somewhere else…", "放别处…")}</button>`;
      side = `<button class="icon x" title="${T("Delete (you can restore it)", "删掉（可以恢复）")}" data-action="note-drop" data-id="${esc(x.id)}">✕</button>`;
    } else {
      const tid = x.task || (d && d.task);
      const where = d && d.kind === "task" ? T("new task", "新任务") : d && d.kind === "todo" ? `${T("todo", "待办")} @${esc(d.owner || "me")}`
        : d && d.kind === "note" ? T("log", "记录") : T("your todo", "我的待办");
      meta = `→ ${tid ? `<span class="tid link" data-action="goto" data-task="${esc(tid)}">${esc(tid)}</span> ` : ""}${where}: ${esc(d ? d.text || d.title || "" : "")}` +
        `<span class="by">${x.by === "user" ? T(" · moved by you", " · 你改的") : ""}</span>`;
      chips = isOpen ? noteGuesses(x).filter((g) => !(g.kind === d.kind && (g.task || "") === (d.task || ""))).map((g) => destChip(x, g)).join("") : "";
      side = `<button class="btn small ${isOpen ? "" : "ghost"}" data-action="note-change" data-id="${esc(x.id)}" title="${T("Put it somewhere else", "放到别处")}">${T("Move", "改")}</button>`;
    }
    return `<div class="qnote it ${x.state}">
      <div class="it-t">${["zulip", "jira"].includes(x.via) ? feedText(x, isOpen) : `<span class="t">${esc(x.text)}</span>`} ${imgs(x)}
        <div class="meta src">${meta}</div>
        ${chips ? `<div class="dests">${chips}</div>` : ""}
        ${isOpen && ["unsorted", "sorted"].includes(x.state) ? picker(x) : ""}
      </div>
      <span class="age" title="${esc(new Date(x.at).toLocaleString())}">${ago(x.at).replace(" ago", "").replace(/前$/, "")}</span>
      ${side}
    </div>`;
  };
  return `<div class="group-title">${T("Quick notes", "记下的")} ${open ? `<span class="n hot">${open}</span>` : ""}<span class="meta">${T("unsorted, and the last two days", "未分拣的，和最近两天的")}</span></div>${filterNote(items.length, all.length)}<div class="inbox-list notes">${items.map(row).join("")}</div>`;
}
// Moves a note; the toast's Undo puts it back where it was.
async function noteMove(id, dest, quiet) {
  const x = notes().find((n) => n.id === id);
  const back = x && x.state === "sorted" ? x.dest : { kind: "unsorted" };
  try {
    const r = await apiObj("note-move", Object.assign({ id }, dest));
    ui.noteOpen.delete(id);
    if (!quiet) toast(`${id} → ${destLabel(r.state === "sorted" ? r.dest : null)}${r.left ? ` (${r.left})` : ""}`, false, () => noteMove(id, back, true));
  } catch (e) { toast(String(e.message || e), true); }
  return refresh();
}
async function captureSubmit() {
  const box = $("#capture");
  const text = box.value.trim();
  const atts = ui.atts.capture || [];
  const images = atts.map((a) => a.path);
  if (!text && !images.length) return;
  box.value = "";
  delete ui.atts.capture;
  saveDrafts();
  renderCaptureAtts();
  let x;
  try { x = await apiObj("note-add", { text, images }); }
  catch (e) {
    // Put back what was typed and pasted, unless something new is already in the box.
    if (!box.value && !(ui.atts.capture || []).length) { box.value = text; ui.atts.capture = atts; renderCaptureAtts(); }
    return toast(String(e.message || e), true);
  }
  toast(T("Noted — sorting…", "记下了，正在分拣…"));
  refresh();
  try {
    const r = await apiObj("note-sort", { id: x.id });
    if (r.state === "sorted") toast(`${T("Filed", "已放到")}: ${destLabel(r.dest)}`, false, () => noteMove(r.id, { kind: "unsorted" }, true));
    else toast(T("Not sure where it goes — it's waiting in Needs you", "没把握放哪——在 Needs you 里等你挑"));
  } catch (e) { toast(String(e.message || e), true); }
  refresh();
}
function renderCaptureAtts() {
  const list = ui.atts.capture || [];
  $("#capture-atts").innerHTML = list.map((a, i) => `<span class="att mini" title="${esc(a.path)}"><img src="${a.url}" alt=""><button class="icon" title="${T("Remove", "移除")}" data-action="att-remove" data-session="capture" data-i="${i}">✕</button></span>`).join("");
}

function renderWaitingUnused() {
  const items = tasks().filter((t) => isOpen(t) && t.waiting_on_me);
  if (!items.length) return "";
  return `<h3>${T("Waiting on you", "等你处理")} · ${items.length}</h3>` + items.map((t) => `
    <div class="card">
      <div class="meta"><span class="chip link" data-action="goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div>
      <div class="ask-text clickable" title="${T("Show context", "查看上下文")}" data-action="ctx" data-kind="waiting" data-task="${esc(t.id)}">${esc(t.waiting_on_me)}</div>
      <div class="row"><button class="btn small" data-action="clear-waiting" data-task="${esc(t.id)}">${T("Handled", "处理好了")}</button></div>
    </div>`).join("");
}

const projectByName = (name) => projects().find((p) => p.name === name) || null;
// The phases a task's project goes through (a goal's, in order), for the drawer's picker.
const phasesOf = (t) => { const pr = projectByName(t.project || ""); return (pr && pr.kind === "goal" && pr.phases) || []; };
const projectClosed = (pr) => Boolean(pr && pr.defined && ["done", "abandoned"].includes(pr.status));
// Days from today to a YYYY-MM-DD date (negative: past), or null.
function daysUntil(day) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day || ""));
  if (!m) return null;
  const now = new Date();
  return Math.round((new Date(+m[1], m[2] - 1, +m[3]) - new Date(now.getFullYear(), now.getMonth(), now.getDate())) / 86400000);
}
function dueText(day) {
  const n = daysUntil(day);
  if (n === null) return "";
  const short = String(day).slice(5);
  const left = n > 0 ? T(`${n}d left`, `还剩 ${n} 天`) : n === 0 ? T("today", "今天") : T(`${-n}d late`, `过期 ${-n} 天`);
  return `<span class="pdue ${n < 0 ? "late" : n <= 7 ? "soon" : ""}" title="${T("Due", "截止")} ${esc(day)}">${T("due", "截止")} ${esc(short)} · ${left}</span>`;
}
const PKIND_LABEL = { goal: T("project", "项目"), duty: T("duty", "职责") };
const PSTATUS_LABEL = { active: T("active", "进行中"), paused: T("paused", "暂停"), done: T("done", "已完成"), abandoned: T("abandoned", "已放弃") };
// What a project heading says after its name: a goal's progress and deadline, a duty's load.
function projectSummary(pr) {
  if (!pr || !pr.defined) return "";
  const st = pr.stats || {};
  const bits = [];
  if (pr.kind) bits.push(`<span class="ptag ${esc(pr.kind)}">${PKIND_LABEL[pr.kind]}</span>`);
  if (pr.status && pr.status !== "active") bits.push(`<span class="ptag st">${PSTATUS_LABEL[pr.status] || esc(pr.status)}</span>`);
  if (pr.kind === "goal") {
    const total = (st.open || 0) + (st.done || 0);
    if (pr.due && !projectClosed(pr)) bits.push(dueText(pr.due));
    if (total) {
      const pct = Math.round(100 * (st.done || 0) / total);
      bits.push(`<span class="pprog" title="${T(`${st.done} of ${total} tasks done`, `${total} 个任务完成了 ${st.done} 个`)}"><span class="bar"><span style="width:${pct}%"></span></span>${st.done}/${total}</span>`);
    }
  } else if (pr.kind === "duty") {
    bits.push(`<span class="pload">${T(`${st.open || 0} open`, `${st.open || 0} 进行中`)}${st.done_7d ? T(` · ${st.done_7d} done this week`, ` · 本周完成 ${st.done_7d}`) : ""}</span>`);
  }
  return bits.join("");
}

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

// Within a lane: tasks with a live session first, then ones that had a session, then the rest;
// ties go to open asks, then the most recently updated.
function taskRank(t) { return liveFor(t.id).length ? 2 : list(t.sessions).length ? 1 : 0; }
function compareTasks(a, b) {
  return taskRank(b) - taskRank(a) || openAsks(b).length - openAsks(a).length ||
    String(b.updated).localeCompare(String(a.updated)) || String(a.id).localeCompare(String(b.id));
}
// When its live sessions last did something (0: none) — what Active first orders a lane by.
const taskActivity = (t) => Math.max(0, ...liveFor(t.id).map((s) => Date.parse(s.updatedAt) || 0));
// The cards in a lane: with Active first on, the task whose session moved last comes first (in
// Focus over the order you added them in); the rest as before.
// Two things keep that from shuffling all the time: whatever moved in the last two minutes counts
// as "now" — sessions busy side by side keep their places instead of overtaking each other on
// every few-second refresh — and a lane, card grid or column the pointer is over keeps the order it
// shows until the pointer leaves (see steady()).
const HOT_MS = 2 * 60 * 1000, HOT = 8.64e15;
const hotAct = (ms) => (ms && Date.now() - ms < HOT_MS ? HOT : ms || 0);
function laneOrder(a, b, was = () => 0) {
  if (!ui.activeFirst) return compareTasks(a, b);
  const x = hotAct(taskActivity(a)), y = hotAct(taskActivity(b));
  return y - x || (x === HOT ? was(a, b) : 0) || compareTasks(a, b);
}
// Sorts a lane (or the project cards) by cmp and remembers what it showed under key; ties cmp leaves
// to was() keep that order. While the pointer is over the element carrying data-okey=key, the
// list stays as last shown (new items after), and the redraw waits until the pointer leaves.
function steady(key, items, cmp, idOf = (x) => x.id) {
  const prev = ui.shown[key] || [];
  const at = new Map(prev.map((id, i) => [id, i]));
  const pos = (x) => (at.has(idOf(x)) ? at.get(idOf(x)) : prev.length);
  const was = (a, b) => pos(a) - pos(b);
  const fresh = items.slice().sort((a, b) => cmp(a, b, was));
  let out = fresh;
  if (prev.length && ui.hover.has(key)) {
    out = items.slice().sort((a, b) => was(a, b) || cmp(a, b, was));
    if (out.some((x, i) => x !== fresh[i])) ui.heldBack = true;
  }
  ui.shown[key] = out.map(idOf);
  return out;
}

// The search box filters every tab: a task matches on its id, title, refs or project;
// an ask or a todo also on its own text.
const filterText = () => ui.filter.trim().toLowerCase();
function taskMatches(t, ...own) {
  const f = filterText();
  return !f || [t.id, t.title, list(t.refs).join(" "), t.project || "", ...own].join(" ").toLowerCase().includes(f);
}
// Above a filtered list: how much of it the filter shows, and a way out.
function filterNote(shown, total) {
  if (!filterText() || shown === total) return "";
  const q = esc(ui.filter.trim());
  return `<div class="fnote">${T(`Filter “${q}”: ${shown} of ${total}`, `筛选"${q}"：显示 ${shown} / ${total}`)}<button class="btn small ghost" data-action="clear-filter">${T("Clear", "清除")}</button></div>`;
}

// ------------------------------------------------------------------ lanes
// Focus and a project's page are boards of four columns, worked out from what the card and its sessions say —
// never stored: a session stopped on you (a prompt to answer) puts a task in Needs you; else a
// session working or something it started still running in the background puts it in Running —
// its asks and todos still show on the card, and it is nothing you can pick up yet; else an open
// ask, your todo or status waiting-on-me puts it in Needs you; else Blocked is its status; the
// rest is Ready to push on.
// Dragging a card into another column sets the status that belongs there (Running is the
// sessions' to decide). Recently done is a fifth, optional column.
const LANES = ["you", "run", "ready", "blocked"];
const LANE_NAME = { you: T("Needs you", "等你"), run: T("Running", "在跑"), ready: T("Ready", "待推进"), blocked: T("Blocked", "卡住"), done: T("Recently done", "最近完成") };
const LANE_HINT = {
  you: T("A question or a todo of yours, or a session waiting on you", "有问题等你答、有你的待办，或 session 停下来等你"),
  run: T("A session is working on it, or something it started runs in the background", "有 session 在干活，或它起的东西还在后台跑"),
  ready: T("Nothing running — start or resume a session", "没在跑——开一个或接上 session"),
  blocked: T("Waiting on someone or something else", "在等别人或别的事"),
  done: T("Finished in the last 3 days", "3 天内完成的"),
};
const STATUS_OF = { you: "waiting-on-me", ready: "active", blocked: "blocked", done: "done" };
const DONE_DAYS = 3;
const myTodos = (t) => t.todos.filter((x) => x.state === "open" && x.owner === "me");
function lane(t) {
  if (!isOpen(t)) return "done";
  const live = liveFor(t.id);
  if (live.some((s) => liveState(s) === "waiting")) return "you";
  if (live.some((s) => liveState(s) === "busy" || bgRunning(s))) return "run";
  // Blocked (waiting on someone else) wins over its asks and @me todos: they still show on the
  // card and in Needs you. A new ask moves it back to waiting-on-me (hq does that).
  if (t.status === "blocked") return "blocked";
  if (openAsks(t).length || myTodos(t).length || t.waiting_on_me || t.status === "waiting-on-me") return "you";
  return "ready";
}
// By the day it was closed (hq stamps `closed`), not its last update: a note on a task finished
// weeks ago doesn't bring it back. Cards closed before hq stamped it fall back to `updated`.
const daysSince = (day) => { const d = Date.parse(String(day || "") + "T00:00:00"); return Number.isNaN(d) ? null : Math.floor((Date.now() - d) / 86400000); };
const recentDone = (t) => t.status === "done" && (daysSince(t.closed) ?? t.age_days ?? 99) <= DONE_DAYS;
const laneCols = () => LANES.concat(ui.showDone ? ["done"] : []);
const KIND_ICON = { goal: "◆", duty: "↻" };
const kindIcon = (pr) => (pr && pr.kind ? `<i class="ki ${esc(pr.kind)}">${KIND_ICON[pr.kind] || ""}</i>` : "");

// An ask on a card answers in one click — Yes or No, with no note, sent on to its session as
// in Needs you; anything longer (a note, Later, a grant) is the drawer's, which "…" opens at it.
function quickAnswer(t, a) {
  const busy = ui.resolving.has(a.id);
  const btn = (r, label) => `<button class="qa-b res-${r}" data-action="resolve" data-quick="1" data-id="${esc(a.id)}" data-res="${r}" ${busy ? "disabled" : ""}
    title="${esc((RESOLUTIONS.find((x) => x[0] === r) || [])[2] || "")}">${label}</button>`;
  return `<span class="qa">${btn("do", T("Yes", "可以"))}${btn("drop", T("No", "不要"))}<button class="qa-b" data-action="ask-answer" data-task="${esc(t.id)}" data-id="${esc(a.id)}"
    title="${T("Answer with a note, Later, a grant… — opens the task at this question", "写说明、稍后、授权……——打开任务，停在这个问题")}">…</button></span>`;
}

// A task's card on the boards. Clicking it opens the side drawer with everything; the card itself
// is what you need to decide where to look: what it waits on you for, its next step, and one line
// for its sessions. opt.compact (a project's page): one line of title and of next step.
function kcard(t, opt = {}) {
  const ln = lane(t);
  const pr = t.project ? projectByName(t.project) : null;
  const star = focusIds().includes(t.id);
  const asks = openAsks(t), mine = myTodos(t);
  const rows = [
    ...asks.map((a) => `<div class="row ask-q"><span class="q">?</span><span class="t" data-action="ask-answer" data-task="${esc(t.id)}" data-id="${esc(a.id)}" title="${T("Answer it here or with a note — opens the task", "在详情里回答，可以写说明")}">${esc(a.text)}</span>${quickAnswer(t, a)}</div>`),
    ...(t.waiting_on_me ? [`<div class="row"><span class="q">!</span><span class="t">${esc(t.waiting_on_me)}</span></div>`] : []),
    ...mine.map((x) => `<div class="row"><span class="box" title="${T("Mark done (you can undo)", "标为完成（可以撤销）")}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="done" data-from="open" data-text="${esc(x.text)}"></span><span class="t">${esc(x.text)}</span></div>`),
  ];
  const max = opt.compact ? 1 : 2;
  const you = rows.length ? `<div class="kc-you">${rows.slice(0, max).join("")}${rows.length > max ? `<span class="more" data-action="ask-answer" data-task="${esc(t.id)}">${T(`${rows.length - max} more →`, `还有 ${rows.length - max} 件 →`)}</span>` : ""}</div>` : "";
  const next = t.next && ln !== "done" ? `<div class="kc-next"><b>${ln === "blocked" ? T("Waiting on", "在等") : T("Next", "下一步")}</b>${esc(t.next)}</div>` : "";
  const flags = list(ui.flags[t.id]);
  return `<div class="kc l-${ln} ${opt.compact ? "compact" : ""} ${ln === "done" ? "done" : ""} ${ui.drawer === t.id ? "sel" : ""}" id="kc-${esc(t.id)}"
      data-action="open-task" data-task="${esc(t.id)}" ${isOpen(t) ? `draggable="true" data-drag-card="${esc(t.id)}"` : ""}
      title="${T("Click for details · drag to another column to change its status", "点击看详情 · 拖到别的列改状态")}">
    <div class="kc-top"><span class="id tid" data-task="${esc(t.id)}">${esc(t.id)}</span>${t.project && !opt.noProject ? `<span class="proj">${kindIcon(pr)}${esc(pr && pr.title && pr.title !== t.project ? pr.title : t.project)}</span>` : ""}
      ${t.status === "abandoned" ? `<span class="stag abandoned">${STATUS_SHORT.abandoned}</span>` : ""}
      ${flags.length ? `<span class="kflag" title="${esc(flags.map((x) => T(x.text, x.text_zh || x.text)).join("\n"))}">⚠</span>` : ""}
      ${isOpen(t) ? `<button class="star ${star ? "on" : ""}" data-action="focus-toggle" data-task="${esc(t.id)}" title="${star ? T("In Focus — click to take it off", "在 Focus 里——点击拿掉") : T("Add to Focus", "加进 Focus")}">${star ? "★" : "☆"}</button>` : ""}</div>
    <div class="kc-title">${esc(t.title)}</div>
    ${you}${next}
    ${ln === "done" ? "" : kcardSessions(t, opt)}
  </div>`;
}

// The card's last line: its live sessions (dots, the latest words of the one that matters, Peek),
// or, with none, Resume and New.
function kcardSessions(t, opt) {
  const live = liveFor(t.id);
  if (!live.length) {
    if (opt.compact) return "";
    const r = earlierSessions(t)[0];
    return `<div class="kc-sess"><span class="line idle">${T("No session", "没有 session")}</span>
      ${r ? `<button class="go" data-action="resume" data-task="${esc(t.id)}" data-session="${esc(r.sessionId)}" data-dir="${esc(r.cwd || "")}" data-name="${esc(r.title || "")}" title="${esc(resumeTip(r) + " — " + (r.title || r.sessionId.slice(0, 8)) + ", " + ago(r.lastAt))}" ${ui.resuming.has(r.sessionId) ? "disabled" : ""}>Resume</button>` : ""}
      <button class="go" data-action="launch" data-task="${esc(t.id)}" title="${T(`Start a session on this task (${PLACES[launchPlace()]})`, `为这个任务新开 session（${PLACES[launchPlace()]}）`)}">${T("New", "新开")}</button></div>`;
  }
  const order = { waiting: 0, busy: 1 };
  const rank = (s) => order[liveState(s)] ?? (bgRunning(s) ? 2 : 3);
  const sorted = live.slice().sort((a, b) => rank(a) - rank(b) || String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")));
  const s = sorted[0];
  const st = liveState(s);
  const last = plainText(s.lastText);
  const line = st === "busy" && last ? last : st === "waiting" ? statusWord(s) : `${statusWord(s)} · ${ago(s.updatedAt)}`;
  return `<div class="kc-sess${s.sessionId === ui.hlSession ? " hl" : ""}"><span class="stack">${sorted.slice(0, 3).map(dot).join("")}</span>
    ${live.length > 1 ? `<span class="cnt">${live.length}</span>` : ""}
    <span class="line ${st === "busy" ? "" : "idle"}" title="${esc(s.title || "")}${last ? "\n" + esc(last) : ""}">${newTag(s.sessionId)}${esc(line)}</span>
    <button class="go peekb" data-action="peek" data-session="${esc(s.sessionId)}" title="${T("Peek its conversation", "Peek 它的对话")}">${ICON.peek}</button></div>`;
}

function laneHead(ln, n) {
  return `<div class="lane-h l-${ln}" title="${esc(LANE_HINT[ln])}"><span class="ld"></span><span class="name">${LANE_NAME[ln]}</span><span class="cnt">${n}</span></div>`;
}
function laneCol(ln, items, opt = {}) {
  return `<section class="lane l-${ln}" data-lane="${ln}"${opt.okey ? ` data-okey="${esc(opt.okey)}"` : ""}>${laneHead(ln, items.length)}
    <div class="lane-hint">${esc(LANE_HINT[ln])}</div>
    <div class="lane-body">${items.length ? items.map((t) => kcard(t, opt)).join("") : `<div class="lane-empty">${ln === "you" ? T("Nothing waiting on you", "没有在等你的") : "—"}</div>`}</div></section>`;
}
const showDoneToggle = () => `<label class="toggle" title="${T("Show a column of tasks finished in the last 3 days", "多一列：3 天内完成的任务")}"><input type="checkbox" data-action="show-done" ${ui.showDone ? "checked" : ""}> ${T("recently done", "最近完成")}</label>`;

const STATUS_SHORT = { "waiting-on-me": T("Waiting on you", "等你处理"), blocked: T("Blocked", "阻塞中"), active: T("Active", "进行中"), done: T("Done", "已完成"), abandoned: T("Abandoned", "已放弃") };

// ------------------------------------------------------------------ the drawer
// A task's details slide in from the right over the board (ui.drawer: its id), with buttons to
// set its status; "@sessions" shows every live session instead (the status bar's count opens it).
const DRAWER_STATUS = [["active", T("Active", "进行中")], ["waiting-on-me", T("Waiting on me", "等我")], ["blocked", T("Blocked", "卡住")], ["done", T("Done", "完成")]];
function renderDrawer() {
  const el = $("#drawer");
  const body0 = el.querySelector(".dr-body");
  const keep = body0 && el.dataset.for === ui.drawer ? body0.scrollTop : 0;
  const t = ui.drawer && ui.drawer !== "@sessions" ? taskById(ui.drawer) : null;
  if (ui.drawer && ui.drawer !== "@sessions" && !t) ui.drawer = null;
  if (!ui.drawer) { el.hidden = true; el.innerHTML = ""; el.dataset.for = ""; return; }
  el.hidden = false;
  el.dataset.for = ui.drawer;
  const close = `<button class="icon x" data-action="drawer-close" title="${T("Close (Esc)", "关闭（Esc）")}">✕</button>`;
  if (!t) {
    el.className = "drawer";
    el.innerHTML = `<div class="dr-head"><div class="r1"><b class="dr-k">${T("Live sessions", "正在运行的 session")}</b><span class="meta">${ui.sessions.length}</span><span class="spacer"></span>
        <span class="seg">${["list", "project"].map((g) => `<button class="${ui.sgroupBy === g ? "on" : ""}" data-action="sgroup-by" data-g="${g}">${g === "list" ? T("List", "列表") : T("Project", "项目")}</button>`).join("")}</span>${close}</div></div>
      <div class="dr-body">${renderSessions()}</div>`;
  } else {
    const ln = lane(t);
    const pr = t.project ? projectByName(t.project) : null;
    const star = focusIds().includes(t.id);
    el.className = `drawer l-${ln}`;
    el.innerHTML = `<div class="dr-head"><div class="r1"><span class="tid" data-task="${esc(t.id)}">${esc(t.id)}</span>
        ${t.project ? `<span class="chip link" data-action="project-panel" data-p="${esc(t.project)}">${kindIcon(pr)}${esc(pr && pr.title && pr.title !== t.project ? pr.title : t.project)}</span>` : ""}<span class="spacer"></span>
        ${isOpen(t) ? `<button class="star ${star ? "on" : ""}" data-action="focus-toggle" data-task="${esc(t.id)}" title="${star ? T("In Focus — click to take it off", "在 Focus 里——点击拿掉") : T("Add to Focus", "加进 Focus")}">${star ? "★" : "☆"}</button>` : ""}${close}</div>
      <h2>${esc(t.title)}</h2>
      <div class="dr-status">${DRAWER_STATUS.map(([s, w]) => `<button class="${t.status === s ? "on" : ""}" data-action="drawer-status" data-task="${esc(t.id)}" data-s="${s}">${w}</button>`).join("")}
        ${t.status === "abandoned" ? `<span class="stag abandoned">${STATUS_SHORT.abandoned}</span>` : ""}
        ${ln !== "done" || recentDone(t) ? `<span class="meta lane-now">${T("Column:", "在：")} <b>${LANE_NAME[ln]}</b></span>` : ""}</div>
      ${focusFlags(t)}</div>
      <div class="dr-body">${renderTaskBody(t)}</div>`;
  }
  const body = el.querySelector(".dr-body");
  if (body && keep) body.scrollTop = keep;
}
function openDrawer(id) {
  ui.drawer = id;
  ui.launchMenu = null;
  render();
  const node = document.getElementById("kc-" + id);
  if (node) flashCard(node);
}

// ------------------------------------------------------------------ Focus
// The tasks you keep in view, as four columns; the rest are on their projects' pages.
const focusState = () => (ui.board && ui.board.focus) || { ids: [], carry: [] };
const focusIds = () => focusState().ids || [];

function renderToday() {
  const picked = focusIds().filter((id) => id !== secId()).map(taskById).filter(Boolean);
  const shown = picked.filter((t) => taskMatches(t));
  const pickable = listed().filter((t) => isOpen(t) && !focusIds().includes(t.id));
  const head = `<div class="vhead"><h1>Focus</h1><span class="meta">${T(`${picked.length} task${picked.length === 1 ? "" : "s"}`, `${picked.length} 个任务`)}</span>
      <span class="spacer"></span>${showDoneToggle()}
      <input class="note pick" list="today-pick" data-key="todaypick" placeholder="${T("Add a task to Focus…", "把任务加进 Focus…")}" value="${esc(draft("todaypick"))}">
      <datalist id="today-pick">${pickable.map((t) => `<option value="${esc(t.id + " · " + t.title)}">`).join("")}</datalist>
      <button class="btn small" data-action="today-add">${T("Add", "添加")}</button></div>`;
  if (!picked.length) return head + `<div class="card empty-today">
      <b>${T("Nothing in Focus yet.", "Focus 里还没有任务。")}</b>
      <div class="meta" style="margin-top:4px">${T("Add the tasks you want in view with the box above, or star ☆ them in a task's drawer. New tasks join automatically; they stay until you take them off.", "用上面的输入框把想盯着的任务加进来，或者在任务详情侧栏里点 ☆。新建的任务会自动加入；一直留着，直到你把它拿掉。")}</div></div>`;
  const by = Object.fromEntries(LANES.concat("done").map((l) => [l, []]));
  for (const t of shown) by[lane(t)].push(t);
  // Active first: over the order you added them in (the sort is stable: ties keep yours).
  for (const l of LANES) by[l] = steady("focus:" + l, by[l], (a, b, was) => {
    if (!ui.activeFirst) return 0;
    const x = hotAct(taskActivity(a)), y = hotAct(taskActivity(b));
    return y - x || (x === HOT ? was(a, b) : 0);
  });
  // Done: what was finished lately, Focus or not (a finished task leaves Focus by itself).
  by.done = listed().filter((t) => recentDone(t) && taskMatches(t) && !shown.includes(t)).concat(by.done)
    .sort((a, b) => String(b.updated).localeCompare(String(a.updated)));
  const cols = laneCols();
  return head + filterNote(shown.length, picked.length) +
    `<div class="board c${cols.length}">${cols.map((l) => laneCol(l, by[l], { okey: "focus:" + l })).join("")}</div>`;
}

// What `hq status` found off about the task — the card behind its session, idle while the card says
// it waits on a run, untouched for a week, done with a session still running, over budget.
function focusFlags(t) {
  const f = list(ui.flags[t.id]);
  if (!f.length) return "";
  return `<div class="fflags">${f.map((x) => {
    const text = T(x.text, x.text_zh || x.text);
    return `<div class="fflag" title="${esc(text)}">⚠ <span>${esc(text)}</span></div>`;
  }).join("")}</div>`;
}

// ---- related resources: URLs as-is, shorthand (QA-123, repo#45) through hq.json "links" rules
// Titles are cut to a few words; the full title and the URL are in the tooltip.
const REF_LABEL_MAX = 36;
const shortLabel = (t) => (t.length > REF_LABEL_MAX ? t.slice(0, REF_LABEL_MAX).replace(/[\s\-–:,，]+\S*$/, "") + "…" : t);
const KIND_LABEL = { ticket: T("Tickets", "工单"), pr: "Pull requests", doc: T("Docs", "文档"), link: T("Links", "链接"), none: T("Not linked", "未链接") };
function kindOfUrl(u) {
  if (/github\.com\/[^/]+\/[^/]+\/(pull|merge_requests)\/|gitlab\.[^/]+\/.+\/merge_requests\//.test(u)) return "pr";
  if (/\/browse\/[A-Z][A-Z0-9]+-\d+|linear\.app\/|\/issues\/\d+|\/jira\//i.test(u)) return "ticket";
  if (/\/wiki\/|confluence|docs\.google|notion\.(so|site)|\.md(\b|$)|claude\.ai\/artifact/i.test(u)) return "doc";
  return "link";
}
// ---- ref keys: begin (kept free of the page, so a script can run it next to hq's ref_key)
const REF_URL_RE = /https?:\/\/[\x21\x23-\x26\x28-\x3b\x3d\x3f-\x7e]+/g;
// Python's str.split() whitespace, so a collapsed key here is the one hq makes.
const PY_SPACE = /[\t-\r\x1c-\x20\x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+/;
// hq's canonical_url, pattern for pattern: a PR's /files tab is the PR, a Jira issue opened from a
// board the issue, a Jenkins console or test report the build; a link to one comment stays its
// own, and any other #fragment is kept.
const URL_TAIL_RE = /[\/).,;:]+$/;
const URL_SPLIT_RE = /^(https?:\/\/)([^/?#]*)([\s\S]*)$/i;
const CANON_GH_ITEM = /^(\/[^/?#]+\/[^/?#]+\/(?:pull|issues)\/[0-9]+)(?:[/?#][\s\S]*)?$/;
const CANON_GH_COMMENT = /#(?:issuecomment-|discussion_r|pullrequestreview-|r)[0-9]+$/;
const CANON_JIRA_BROWSE = /^([\s\S]*?\/browse\/[A-Z][A-Z0-9]+-[0-9]+)(?:[/?#][\s\S]*)?$/;
const CANON_JIRA_PATH = /^([\s\S]*?)\/jira\/[^?#]*\/([A-Z][A-Z0-9]+-[0-9]+)(?:[/?#][\s\S]*)?$/;
const CANON_JIRA_SELECTED = /^([\s\S]*?)\/jira\/[^?#]*\?(?:[^#]*&)?selectedIssue=([A-Z][A-Z0-9]+-[0-9]+)(?:[&#][\s\S]*)?$/;
const CANON_JIRA_COMMENT = /[?&]focusedCommentId=([0-9]+)|#comment-([0-9]+)$/;
const CANON_JENKINS_BUILD = /^((?:\/[^/?#]+)*?(?:\/job\/[^/?#]+)+\/[0-9]+)(?:\/([^?#]*))?(?:[?#][\s\S]*)?$/;
// What may follow a build number on a host not named "jenkins" (hq's JENKINS_VIEW_RE).
const CANON_JENKINS_VIEW = /^(?:|console\w*|testReport\b[\s\S]*|artifact\b[\s\S]*|changes|parameters|pipeline\S*|flowGraphTable|execution\b[\s\S]*|timestamps\b[\s\S]*|injectedEnvVars|display\b[\s\S]*|stages\b[\s\S]*|api\b[\s\S]*)\/?$/;
const isJenkins = (host, view) => host.includes("jenkins") || CANON_JENKINS_VIEW.test(view || "");
function canonicalUrl(url) {
  url = String(url).replace(URL_TAIL_RE, "");
  const m = url.match(URL_SPLIT_RE);
  if (!m) return url;
  const host = m[2].toLowerCase();
  const base = m[1].toLowerCase() + host;
  let rest = m[3];
  const g = host.includes("github") ? rest.match(CANON_GH_ITEM) : null;
  if (g) return base + (CANON_GH_COMMENT.test(rest) ? rest : g[1]);
  const jb = rest.match(CANON_JIRA_BROWSE);
  const j = jb || rest.match(CANON_JIRA_PATH) || rest.match(CANON_JIRA_SELECTED);
  if (j) {
    const c = rest.match(CANON_JIRA_COMMENT);
    return base + (jb ? j[1] : j[1] + "/browse/" + j[2]) + (c ? `?focusedCommentId=${c[1] || c[2]}` : "");
  }
  const b = rest.match(CANON_JENKINS_BUILD);
  if (b && isJenkins(host, b[2])) return base + b[1];
  if (rest.endsWith("#")) rest = rest.slice(0, -1);
  return base + (rest.includes("#") ? rest : rest.replace(/\/+$/, ""));
}
// Which refs are the same — exactly hq's ref_key: a ref with one literal URL is that URL's
// canonical form (trailing `/).,;:` never count); anything else (no URL, a ticket key, or two or
// more URLs) is its text with whitespace collapsed. Never the URL a links rule builds: hq doesn't
// know those.
// The key mark (`! ` before a ref, hq's KEY_MARK): a link the card keeps even when it is a build,
// a run or a comment — those otherwise go to HISTORY.md. It is not part of what the link is.
const keyMarked = (ref) => new RegExp(`^(?:${PY_SPACE.source})?!`).test(String(ref));
function unmarkedRef(ref) {
  const text = String(ref).replace(PY_TRIM, "");
  return text.startsWith("!") ? text.slice(1).replace(new RegExp(`^(?:${PY_SPACE.source})`), "") : text;
}
function refKey(ref) {
  const text = unmarkedRef(ref);
  const urls = text.match(REF_URL_RE) || [];
  if (urls.length === 1) return canonicalUrl(urls[0]);
  return text.split(PY_SPACE).filter(Boolean).join(" ");
}
const lowerHost = (u) => { const m = u.match(URL_SPLIT_RE); return m ? m[1].toLowerCase() + m[2].toLowerCase() + m[3] : u; };
function refUrlIsCanonical(ref) {
  const urls = String(ref).match(REF_URL_RE) || [];
  if (urls.length !== 1) return false;
  const u = urls[0].replace(URL_TAIL_RE, "");
  return lowerHost(u) === canonicalUrl(u);
}
function withCanonicalUrl(ref) {
  const text = String(ref);
  const found = [...text.matchAll(REF_URL_RE)];
  if (found.length !== 1 || refUrlIsCanonical(text)) return text;
  const u = found[0][0].replace(URL_TAIL_RE, "");
  return text.slice(0, found[0].index) + canonicalUrl(u) + text.slice(found[0].index + u.length);
}
// hq's merge_refs, so a card written before hq merged views of one thing shows them as one: the
// canonical URL, the title of an entry already on it (the newest such), else the newest title.
// One with no other of its key stays exactly as written.
const PY_TRIM = new RegExp(`^(?:${PY_SPACE.source})|(?:${PY_SPACE.source})$`, "g");   // str.strip()
function mergeRefs(refs) {
  const order = [], groups = new Map();
  for (let r of refs) {
    r = String(r).replace(PY_TRIM, "");
    if (!r) continue;
    const k = refKey(r);
    if (!groups.has(k)) { groups.set(k, []); order.push(k); }
    groups.get(k).push(r);
  }
  return order.map((k) => {
    const rs = groups.get(k);
    if (new Set(rs).size === 1) return rs[0];
    // The key mark stays with the link whichever entry's title wins.
    const mark = rs.some(keyMarked) ? "! " : "";
    const us = rs.map(unmarkedRef);
    const exact = us.filter(refUrlIsCanonical);
    return mark + withCanonicalUrl(exact.length ? exact[exact.length - 1] : us[us.length - 1]);
  });
}
// Where a link lives, for the Links groups in a task's right rail (kindOfUrl is about what it is).
function refSource(url) {
  const m = String(url || "").match(/^https?:\/\/([^/?#]*)([^?#]*)/i);
  if (!m) return "other";
  const host = m[1].toLowerCase(), path = m[2];
  if (host.includes("github")) return "github";
  if (/\/browse\/[A-Z][A-Z0-9]+-\d+/.test(path) || host.includes("jira") || (host.endsWith("atlassian.net") && /^\/jira(\/|$)/.test(path))) return "jira";
  if (host.includes("confluence") || (host.endsWith("atlassian.net") && /^\/wiki\//.test(path))) return "confluence";
  const b = path.match(CANON_JENKINS_BUILD);
  if (host.includes("jenkins") || (b && isJenkins(host, b[2]))) return "jenkins";
  return "other";
}
// ---- ref keys: end
function resolveRef(ref) {
  const text = unmarkedRef(ref);
  const url = (text.match(new RegExp(REF_URL_RE.source)) || [])[0];
  if (url) {
    const label = text.replace(url, "").replace(/[\s:：,，-]+$/, "").trim();
    return { ref, url, kind: kindOfUrl(url), label: label || url.replace(/^https?:\/\//, "").slice(0, 70) };
  }
  for (const rule of (ui.board && Array.isArray(ui.board.links) ? ui.board.links : [])) {
    let re;
    try { re = new RegExp(rule.match); } catch (e) { continue; }
    const m = text.match(re);
    if (m) return { ref, url: String(rule.url).replace(/\$(\d)/g, (_, n) => m[Number(n)] || ""), kind: rule.kind || "link", label: text };
  }
  return { ref, url: "", kind: "none", label: text };
}
// The Links of a task's right rail, grouped by where they live, newest first; past REF_GROUP_SHOWN
// a group folds behind "N more" (unfolded for this board's life, per task and group).
const REF_GROUPS = [["github", "GitHub"], ["jira", "Jira"], ["confluence", "Confluence"], ["jenkins", "Jenkins"], ["other", T("Other", "其他")]];
const REF_GROUP_SHOWN = 5;
function refGroups(t, refs, editing) {
  const by = {};
  for (const r of refs.slice().reverse()) (by[refSource(r.url)] = by[refSource(r.url)] || []).push(r);
  const item = (r) => `<div class="ref-i">${r.url ? `<a href="#" class="ref" data-action="link" data-url="${esc(r.url)}" title="${esc(r.label + "\n" + r.url)}">${esc(shortLabel(r.label))}</a>` : `<span class="ref none" title="${esc(r.label)}">${esc(shortLabel(r.label))}</span>`}
      ${editing ? `<button class="icon x" title="${T("Remove", "移除")}" data-confirm="${T("Remove?", "移除？")}" data-action="ref-remove" data-task="${esc(t.id)}" data-ref="${esc(r.ref)}">✕</button>` : ""}</div>`;
  return REF_GROUPS.filter(([g]) => by[g]).map(([g, name]) => {
    const rs = by[g], key = `${t.id}:${g}`, all = ui.refMore.has(key);
    const more = rs.length - REF_GROUP_SHOWN;
    return `<div class="ref-g"><div class="ref-gh">${esc(name)} <span class="meta">${rs.length}</span></div>
      ${(all ? rs : rs.slice(0, REF_GROUP_SHOWN)).map(item).join("")}
      ${more > 0 ? `<button class="lnk ref-more" data-action="ref-more" data-group="${esc(key)}">${all ? T("Show fewer", "收起") : T(`${more} more`, `还有 ${more} 条`)}</button>` : ""}</div>`;
  }).join("") + processGroup(t, editing);
}
// Process links — a build, a run, a comment — live in the task's HISTORY.md, not on the card (so
// sessions don't read them): one folded group, newest first. Edit offers to keep one on the card.
function processGroup(t, editing) {
  const rs = list(t.history && t.history.links).map(resolveRef).reverse();
  if (!rs.length) return "";
  const key = `${t.id}:process`, open = ui.refMore.has(key);
  const item = (r) => `<div class="ref-i">${r.url ? `<a href="#" class="ref" data-action="link" data-url="${esc(r.url)}" title="${esc(r.label + "\n" + r.url)}">${esc(shortLabel(r.label))}</a>` : `<span class="ref none" title="${esc(r.label)}">${esc(shortLabel(r.label))}</span>`}
      ${editing ? `<button class="icon" title="${T("Keep on the card — a key link sessions see", "留在卡上——作为 session 会看到的关键链接")}" data-action="ref-pin" data-task="${esc(t.id)}" data-ref="${esc(r.ref)}">↑</button>
        <button class="icon x" title="${T("Remove", "移除")}" data-confirm="${T("Remove?", "移除？")}" data-action="ref-remove" data-task="${esc(t.id)}" data-ref="${esc(r.ref)}">✕</button>` : ""}</div>`;
  return `<div class="ref-g proc"><button class="lnk ref-gh" data-action="ref-more" data-group="${esc(key)}"
      title="${T("Builds, runs and comments — kept in HISTORY.md, not read by sessions", "构建、运行和评论——放在 HISTORY.md 里，session 不读")}">${open ? "▾" : "▸"} ${T("Process", "过程")} <span class="meta">${rs.length}</span></button>
    ${open ? rs.map(item).join("") : ""}</div>`;
}
function logEntries(t) {
  // `- 2026-11-20 20:05:18: text` (hq log writes the time since 11/20); older lines carry the day only.
  const parse = (text) => String(text || "").split("\n")
    .map((l) => l.match(/^\s*-\s+(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?)?):\s+(.*)$/))
    .filter(Boolean).map((m) => ({ date: m[1].replace("T", " "), text: m[2] }));
  // What the card budget moved to HISTORY.md (todo ticks, older entries) reads in its place by time.
  const hist = parse(list(t.history && t.history.log).join("\n"));
  const card = parse(t.body);
  if (!hist.length) return card;
  return hist.concat(card).map((e, i) => [e, i])
    .sort((a, b) => (a[0].date < b[0].date ? -1 : a[0].date > b[0].date ? 1 : a[1] - b[1])).map((x) => x[0]);
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
  // The same task can be drawn twice (a board, and the drawer over it): each menu gets its own radio group.
  const group = `place-${t.id}-${(launchSplit.n = (launchSplit.n || 0) + 1)}`;
  return `<span class="launch">
    <button class="btn small primary" data-action="launch" data-task="${esc(t.id)}" title="${esc(T(`Start a Claude Code session on this task in ${launchDir(t) || "(no directory yet)"} (${PLACES[launchPlace()]}) — it starts bound, reads the card and reports`, `在 ${launchDir(t) || "（还没有目录）"} 里为这个任务新开一个 Claude Code session（${PLACES[launchPlace()]}）——一启动就绑定，读卡后汇报`))}">${T("New session", "新 session")}</button><button class="btn small primary caret-btn ${open ? "on" : ""}" data-action="launch-menu" data-task="${esc(t.id)}" title="${T("Where new sessions open, and how", "新 session 开在哪里、怎么开")}" aria-expanded="${open}">▾</button>
    ${open ? `<div class="menu">
      <div class="mh">${T("Open new sessions in", "新 session 开在")}</div>
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
  if (day === iso(now)) return T("Today", "今天");
  if (day === iso(new Date(now.getTime() - 86400000))) return T("Yesterday", "昨天");
  const d = new Date(day + "T00:00:00");
  return isNaN(d) ? day : d.toLocaleDateString(T("en-US", "zh-CN"), { month: "short", day: "numeric", year: d.getFullYear() === now.getFullYear() ? undefined : "numeric" });
}
const OWNER_LABEL = (o) => (o === "me" ? T("You", "你") : o === "claude" ? "Claude" : o || "");

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
      ${dirty ? `<button class="btn small primary" data-action="save-field" data-field="${name}" data-task="${esc(t.id)}">${T("Save", "保存")}</button>
        <button class="btn small ghost" data-action="cancel-field" data-field="${name}" data-task="${esc(t.id)}">${T("Cancel", "取消")}</button>` : ""}
    </div></div>`;
  };
  // Open todos first — yours, then Claude's, then anyone else's. Finished ones follow; past
  // FINISHED_SHOWN of them they fold behind "Show N finished" — except ones ticked in the last
  // hour, which stay for an easy undo.
  const isRecent = (x) => ui.recent.some((r) => r.task === t.id && r.i === x.i && Date.now() - r.at < RECENT_MS);
  const ownerRank = (x) => (x.owner === "me" ? 0 : x.owner === "claude" ? 1 : x.owner ? 2 : 3);
  const openTodos = t.todos.filter((x) => x.state === "open").sort((a, b) => ownerRank(a) - ownerRank(b));
  // Closed todos the card budget moved to HISTORY.md follow the card's own, read-only.
  const histDone = list(t.history && t.history.todos).map((x) => ({ ...x, hist: true }));
  const finished = t.todos.filter((x) => x.state !== "open").concat(histDone.slice().reverse());
  const anyTodos = t.todos.length + histDone.length;
  const foldDone = finished.length > FINISHED_SHOWN && !ui.doneOpen.has(t.id);
  const shownDone = foldDone ? finished.filter(isRecent) : finished;
  const hiddenDone = finished.length - shownDone.length;
  // Claude's open todos — its own working list, often long — fold behind one row, in their place
  // after yours; yours and other people's stay in view. The row unfolds them (remembered per task).
  const claudeN = openTodos.filter((x) => x.owner === "claude").length;
  const claudeShown = ui.claudeOpen.has(t.id);
  const todoRow = (x) => {
    const mark = x.state === "done" ? "✓" : x.state === "dropped" ? "–" : "";
    const next = x.state === "open" ? "done" : "open";
    const who = x.owner ? `<span class="who ${x.owner === "me" ? "me" : x.owner === "claude" ? "cl" : ""}">${esc(OWNER_LABEL(x.owner))}</span>` : `<span class="who"></span>`;
    if (x.hist) return `<div class="todo ${x.state} hist" title="${T("In HISTORY.md (card budget)", "在 HISTORY.md 里（卡片预算）")}">
      <span class="box ${x.state}">${mark}</span>${who}<span class="t">${esc(x.text)}</span></div>`;
    return `<div class="todo ${x.state}">
      <span class="box ${x.state}" title="${x.state === "open" ? T("Mark done", "标为完成") : T("Reopen", "恢复")}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="${next}" data-from="${x.state}" data-text="${esc(x.text)}">${mark}</span>
      ${who}<span class="t">${esc(x.text)}</span>
      ${doItButton(t, x)}
      ${x.state === "open" ? `<button class="icon x" title="${T("Won't do", "不做")}" data-confirm="${T("Won't do?", "不做？")}" data-action="todo" data-task="${esc(t.id)}" data-i="${x.i}" data-state="drop" data-from="open" data-text="${esc(x.text)}">✕</button>` : ""}</div>`;
  };
  const claudeFold = () => `<button class="todo cfold ${claudeShown ? "on" : ""}" data-action="claude-todos-toggle" data-task="${esc(t.id)}"
      title="${claudeShown ? T("Fold Claude's todos", "收起 Claude 的待办") : T("Show Claude's open todos", "展开 Claude 的未完成待办")}"><span class="box fold">${claudeShown ? "▾" : "▸"}</span><span class="who cl">Claude</span><span class="t">${T(`Claude's ${claudeN} todo${claudeN === 1 ? "" : "s"}`, `Claude 的 ${claudeN} 条`)}</span></button>`;
  const todoRows = () => {
    const out = [];
    let folded = false;
    for (const x of openTodos) {
      if (x.owner === "claude") {
        if (!folded) { out.push(claudeFold()); folded = true; }
        if (!claudeShown) continue;
      }
      out.push(todoRow(x));
    }
    return out.concat(shownDone.map(todoRow)).join("");
  };
  const todoState = (!anyTodos ? "" : `<span class="meta">${openTodos.length ? T(`${openTodos.length} open`, `${openTodos.length} 条未完成`) : T("all done", "全部完成")}${finished.length ? T(` · ${finished.length} finished`, ` · ${finished.length} 条已结束`) : ""}</span>`) +
    (finished.length > FINISHED_SHOWN
      ? `<button class="btn small ghost" data-action="done-toggle" data-task="${esc(t.id)}">${ui.doneOpen.has(t.id) ? T("Hide finished", "收起已结束的") : T(`Show ${hiddenDone} finished`, `显示 ${hiddenDone} 条已结束的`)}</button>` : "") +
    tidyButton(t);
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
  // One entry per link, merged as hq merges them (a card may predate that): a PR and a comment on
  // it, or a build and its console, are one link.
  const refs = mergeRefs(list(t.refs)).map(resolveRef);
  const resEdit = ui.resOpen.has(t.id);
  const dirs = list(t.workdirs);
  // Settled things — status, project, directories, links — sit in the right rail as
  // plain text; "Edit" turns the first three into menus and opens `next` for editing.
  const editNext = adding("next") || (ui.drafts[k("next")] !== undefined && ui.drafts[k("next")] !== (t.next || ""));
  const tools = `<div class="tools">
      <button class="btn small ${editNext ? "on" : ""}" data-action="toggle-add" data-what="next" data-task="${esc(t.id)}"
        title="${editNext ? T("Done editing", "改完了") : T("Edit status, project and next", "修改状态、项目和下一步")}">${editNext ? T("Done", "完成") : T("Edit", "编辑")}</button>
      <button class="btn small" data-action="open" data-path="${esc(t.path)}" title="${T("Open the card file", "用编辑器打开任务卡文件")}">${T("Open card", "打开任务卡")}</button>
      ${isOpen(t) && t.id !== secId() ? `<button class="btn small" data-action="continue" data-task="${esc(t.id)}" data-confirm="${T("Continue?", "续？")}"
        title="${T("Continue on a new card dated today: open todos, status, next step, key links and grants come along; this card is closed and its sessions move over", "续到一张今天的新卡：未完成待办、当前状态、下一步、关键链接和授权都带过去；这张卡关闭，绑定的 session 一起换过去")}">${T("Continue today", "续到今天")}</button>` : ""}
      ${launchSplit(t)}
    </div>`;
  const head = editNext ? `<div class="now editing">
      <div class="metarow">
        <label>${T("status", "状态")} <select data-action="set-status" data-task="${esc(t.id)}">
          ${ORDER.map((s) => `<option value="${s}" ${s === t.status ? "selected" : ""}>${LABEL[s]}</option>`).join("")}
        </select></label>
        <label>${T("project", "项目")} <select data-action="set-project" data-task="${esc(t.id)}">
          <option value="" ${t.project ? "" : "selected"}>${T("(no project)", "（无项目）")}</option>
          ${projectNames().map((c) => `<option value="${esc(c)}" ${c === t.project ? "selected" : ""}>${esc(c)}</option>`).join("")}
          ${t.project && !projectNames().includes(t.project) ? `<option value="${esc(t.project)}" selected>${esc(t.project)} ${T("(not in list)", "（不在列表里）")}</option>` : ""}
        </select></label>
        ${phasesOf(t).length || t.phase ? `<label>${T("phase", "阶段")} <select data-action="set-phase" data-task="${esc(t.id)}">
          <option value="" ${t.phase ? "" : "selected"}>${T("(none)", "（不分阶段）")}</option>
          ${phasesOf(t).concat(t.phase && !phasesOf(t).includes(t.phase) ? [t.phase] : []).map((x) => `<option value="${esc(x)}" ${x === t.phase ? "selected" : ""}>${esc(x)}</option>`).join("")}
        </select></label>` : ""}
        <span class="spacer"></span>${tools}
      </div>
      ${field("next", T("Next", "下一步"), T("the next concrete step", "下一个具体的步骤"))}
    </div>`
    : `<div class="now">
      <div class="now-t"><div class="k">${T("Next", "下一步")}</div><div class="v">${t.next ? inline(t.next) : `<span class="faint">${T("No next step yet — Edit to set one", "还没有下一步——点编辑来设置")}</span>`}</div></div>
      ${tools}
    </div>`;
  const sessRow = (s) => `<div class="bsess${s.sessionId === ui.hlSession ? " hl" : ""}">
        ${dot(s)}
        <div class="bs-t"><div class="stitle" title="${esc(s.title || s.project)}">${newTag(s.sessionId)}${esc(String(s.title || s.project).replace(new RegExp("^" + t.id + "\\s+"), "") || s.title || s.project)}</div>
          <div class="meta">${s.background ? `<span class="bgtag">${T("background", "后台")}</span> ` : ""}${esc(statusWord(s))}${ctxTag(s)} · ${ago(s.updatedAt)}</div>${approveBar(s)}
          ${plainText(s.lastText) ? `<div class="last" data-action="peek" data-session="${esc(s.sessionId)}" title="${T("Its last words — click to Peek", "它最后说的话——点击 Peek")}">${esc(plainText(s.lastText))}</div>` : ""}</div>
        <div class="icons">
          <button class="icon" data-action="peek" data-session="${esc(s.sessionId)}" title="${T("Peek — open the conversation", "Peek——打开对话")}">${ICON.peek}</button>
          ${s.background
            ? `<button class="icon" data-action="attach" data-session="${esc(s.bgId || s.sessionId)}" title="${T("Attach — open it in", "Attach——在这里打开：")} ${esc(PLACES[launchPlace() === "bg" ? "terminal" : launchPlace()])}">${ICON.attach}</button>
               <button class="icon ${ui.stopArmed === (s.bgId || s.sessionId) ? "armed" : ""}" data-action="stop" data-session="${esc(s.bgId || s.sessionId)}" title="${T("Stop this background session (its conversation is kept)", "停止这个后台 session（对话保留）")}">${ui.stopArmed === (s.bgId || s.sessionId) ? T("Stop?", "停止？") : ICON.stop}</button>`
            : `${escButton(s)}<button class="icon" data-action="jump" data-session="${esc(s.sessionId)}" title="${T("Jump to its terminal", "Jump——跳到它的终端")}">${ICON.jump}</button>
               <button class="icon ${ui.stopArmed === s.sessionId ? "armed" : ""}" data-action="stop-session" data-session="${esc(s.sessionId)}" title="${T("Stop this session — ends its Claude Code process; the conversation is kept and Resume picks it up", "停止这个 session——结束它的 Claude Code 进程；对话保留，之后可以 Resume 续上")}">${ui.stopArmed === s.sessionId ? T("Stop?", "停止？") : ICON.stop}</button>`}
          <button class="icon" data-confirm="${T("Unbind?", "解绑？")}" data-action="unbind" data-session="${esc(s.sessionId)}" title="${T("Unbind from this task", "从这个任务解绑")}">✕</button>
        </div></div>`;
  // Claude's open questions come first: they are what the task waits on you for.
  const asks = openAsks(t);
  const askSec = asks.length || laterAsks(t).length ? `<div class="dr-asks">
      ${asks.length ? `<div class="sec-h"><h3>${T("Claude is asking", "Claude 在问")} <span class="meta">${asks.length}</span></h3></div>${renderAskGroup(t, asks, { inTask: true })}` : ""}
      ${laterLine(t)}</div>` : "";
  return `<div class="task-body">
    ${askSec}
    ${head}
    ${stillRunning(t)}
    <div class="tcols">
      <div class="tmain">
        <div class="tsess">
          <div class="sec-h"><h3>Sessions <span class="meta">${live.length || ""}</span></h3>
            <button class="icon ${adding("bind") ? "on" : ""}" title="${T("Bind a live session", "绑定一个正在运行的 session")}" data-action="toggle-add" data-what="bind" data-task="${esc(t.id)}">${PLUS}</button></div>
          ${adding("bind") ? `<div class="row nowrap addbox">${unbound.length
              ? `<select class="bind" data-key="${k("bindpick")}"><option value="">${T("Choose a live session…", "选一个正在运行的 session…")}</option>
                  ${unbound.map((s) => `<option value="${esc(s.sessionId)}" ${draft(k("bindpick")) === s.sessionId ? "selected" : ""}>${esc(s.title || s.project)} (${esc(s.project)})${s.task ? T(" · now on ", " · 现在在 ") + esc(s.task) : ""}</option>`).join("")}</select>
                 <button class="btn small primary" data-action="bind-pick" data-task="${esc(t.id)}">${T("Bind", "绑定")}</button>`
              : `<span class="empty">${T("No other live sessions.", "没有别的正在运行的 session。")}</span>`}</div>` : ""}
          ${live.length ? live.map(sessRow).join("") : `<div class="empty">${T("None live.", "没有在跑的。")}</div>`}
          ${earlierList(t)}
        </div>
        ${secHead(T("Todos", "待办"), t, "todo", T("Add a todo", "加一条待办"), null, todoState)}
        ${adding("todo") ? `<div class="row nowrap addbox">
            <input class="note" data-key="${k("addtodo")}" data-task="${esc(t.id)}" data-enter="addtodo" placeholder="${T("e.g. @me send the reply to …   (@me = you, @claude, or a name)", "如 @me 把回复发给 …   （@me = 你，@claude，或人名）")}" value="${esc(draft(k("addtodo")))}">
            <button class="btn small primary" data-action="add-todo" data-task="${esc(t.id)}">${T("Add", "添加")}</button></div>` : ""}
        ${anyTodos ? `<div class="todos">${todoRows()}</div>` : `<div class="empty">${T("No todos.", "没有待办。")}</div>`}

        ${secHead(T("Grants", "授权"), t, "grant", T("Add a standing grant — a kind of step sessions on this task take without asking", "加一条常设授权——这个任务的 session 不用问就可以做的一类事"), (t.grants || []).length || null)}
        ${adding("grant") ? `<div class="addbox"><div class="row nowrap">
            <input class="note" data-key="${k("addgrant")}" data-task="${esc(t.id)}" data-enter="addgrant" placeholder="${T("e.g. rerun a verification with the same parameters", "如：用和上次相同的参数重跑验证")}" value="${esc(draft(k("addgrant")))}">
            <button class="btn small primary" data-action="add-grant" data-task="${esc(t.id)}">${T("Add", "添加")}</button></div>
            ${grantPresets("grant-preset-task", `data-for="${esc(t.id)}"`)}</div>` : ""}
        ${(t.grants || []).length ? `<div class="grants">${t.grants.map((g) => `<div class="grant">
            <span class="t">${esc(g.text)}</span>
            <span class="meta" title="${esc(g.at || "")}">${g.from ? esc(g.from) + " · " : ""}${g.at ? ago(g.at) : ""}</span>
            <button class="icon x" title="${T("Revoke — sessions ask again before this kind of step", "撤销——之后 session 遇到这类事情会重新问")}" data-confirm="${T("Revoke?", "撤销？")}" data-action="grant-revoke" data-task="${esc(t.id)}" data-i="${g.i}" data-text="${esc(g.text)}">✕</button></div>`).join("")}</div>`
          : `<div class="empty">${T("None — sessions ask before each such step. Answer an ask with \"Yes, always\" to add one.", "没有——session 每次都会先问。回答 ask 时点「以后都可以」就会加一条。")}</div>`}

        ${secHead(T("Log", "日志"), t, "log", T("Add a note — the task's memory; bound sessions read it", "加一条备注——任务的记忆；绑定的 session 会读它"), logs.length || null)}
        ${adding("log") ? `<div class="addbox"><textarea class="note logbox" data-key="${k("log")}" placeholder="${T("A decision, a finding, a note for whoever picks this up next", "一个决定、一个发现、给下一个接手者的备注")}">${esc(draft(k("log")))}</textarea>
            <div class="row" style="justify-content:flex-end"><button class="btn small primary" data-action="add-log" data-task="${esc(t.id)}">${T("Save note", "保存备注")}</button></div></div>` : ""}
        ${showLogs.length ? `<ol class="logs">${logHtml}</ol>` : `<div class="empty">${T("Nothing logged yet.", "还没有日志。")}</div>`}
        ${logs.length > 3 ? `<button class="btn small ghost more" data-action="log-all" data-task="${esc(t.id)}">${ui.logAll.has(t.id) ? T("Show latest 3", "只看最近 3 条") : T(`Show all ${logs.length}`, `显示全部 ${logs.length} 条`)}</button>` : ""}
      </div>
      <aside class="trail">
        <dl class="props">
          <dt>${T("Status", "状态")}</dt><dd><span class="pill" data-st="${esc(t.status)}">${esc(LABEL[t.status] || t.status || "—")}</span></dd>
          <dt>${T("Project", "项目")}</dt><dd>${esc(t.project || "—")}</dd>
          ${t.phase ? `<dt>${T("Phase", "阶段")}</dt><dd>${esc(t.phase)}</dd>` : ""}
          <dt>${T("Folders", "目录")}</dt><dd>${dirs.map((x) => `<span class="path" title="${esc(x)}"><span class="nm">${esc(tildePath(x).split("/").pop() || tildePath(x))}</span>${resEdit ? ` <button class="lnk x" data-action="workdir-remove" data-task="${esc(t.id)}" data-path="${esc(x)}" title="${T("Remove this folder from the task", "从任务里移除这个目录")}">✕</button>` : ""}</span>`).join("")}
            ${!dirs.length ? `<span class="faint" title="${T("Added by itself when a session is bound; New session uses the project's folder, or asks for one", "绑定 session 时会自动加上；点新 session 时用项目的目录，没有就让你选")}">${T("none yet", "还没有")}</span>` : ""}
            ${!dirs.length || resEdit ? `<button class="lnk" data-action="workdir-add" data-task="${esc(t.id)}">${T("+ Add", "+ 添加")}</button>` : ""}</dd>
          <dt>${T("Links", "链接")}</dt><dd>
            ${refGroups(t, refs, resEdit)}
            <button class="lnk ${resEdit ? "on" : ""}" data-action="toggle-res" data-task="${esc(t.id)}">${resEdit ? T("Done", "完成") : refs.length ? T("Edit", "编辑") : T("+ Add", "+ 添加")}</button>
          </dd>
        </dl>
        ${resEdit ? `<div class="res">
          <div class="row nowrap"><input class="note" data-key="${k("addref")}" data-task="${esc(t.id)}" data-enter="addref" placeholder="${T("URL, or QA-123, repo#45", "网址，或 QA-123、repo#45")}" value="${esc(draft(k("addref")))}">
            <button class="btn small" data-action="add-ref" data-task="${esc(t.id)}">${T("Add", "添加")}</button></div>
          ${!(ui.board && (ui.board.links || []).length) ? `<div class="meta">${T("Shorthand like QA-123 becomes a link once you add a rule under \"links\" in hq.json (see Guide).", "在 hq.json 的 \"links\" 里加上规则后，QA-123 这样的简写就会变成链接（见说明）。")}</div>` : ""}
        </div>` : ""}
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

// A finished task whose sessions are still running: say so, with one button to stop them all.
function stillRunning(t) {
  const live = isOpen(t) ? [] : liveFor(t.id);
  if (!live.length) return "";
  const key = "task:" + t.id;
  return `<div class="stillrun" data-action="none" title="">
    <span>${T(`${live.length === 1 ? "A session is" : `${live.length} sessions are`} still running on this ${esc(STATUS_SHORT[t.status] || t.status)} task`, `这个任务${esc(STATUS_SHORT[t.status] || t.status)}，还有 ${live.length} 个 session 在跑`)}</span>
    <button class="btn small ${ui.stopArmed === key ? "armed" : ""}" data-action="stop-task-sessions" data-task="${esc(t.id)}" title="${T("End their Claude Code processes — conversations are kept; Resume picks them up", "结束它们的 Claude Code 进程——对话保留，之后可以 Resume 续上")}">${ui.stopArmed === key ? T("Click again to stop", "再点一下停止") : live.length === 1 ? T("Stop it", "停止") : T("Stop all", "全部停止")}</button>
  </div>`;
}
// Sessions bound to finished tasks, across the board — the Sessions list offers to stop them.
const strays = () => ui.sessions.filter((s) => { const t = s.task && taskById(s.task); return t && !isOpen(t); });
function strayBar() {
  const xs = strays();
  if (!xs.length) return "";
  const key = "strays";
  return `<div class="stillrun">
    <span>${T(`${xs.length === 1 ? "1 session is" : `${xs.length} sessions are`} still running on finished tasks`, `有 ${xs.length} 个 session 还挂在已结束的任务上在跑`)} (${[...new Set(xs.map((s) => s.task))].map(esc).join(", ")})</span>
    <button class="btn small ${ui.stopArmed === key ? "armed" : ""}" data-action="stop-strays" title="${T("End their Claude Code processes — conversations are kept", "结束它们的 Claude Code 进程——对话保留")}">${ui.stopArmed === key ? T("Click again to stop", "再点一下停止") : T("Stop them", "全部停止")}</button>
  </div>`;
}
// Ends one live session: a background one with `claude stop`, a terminal one by ending its process.
async function stopOne(s) {
  if (s.background && !SENDABLE[s.terminal && s.terminal.kind]) await api("stop", { session: s.bgId || s.sessionId });
  else await api("stop-session", { session: s.sessionId });
}
async function stopMany(list, armKey, what) {
  if (ui.stopArmed !== armKey) {
    ui.stopArmed = armKey;
    render();
    toast(T(`Click again to stop ${what} — conversations are kept`, `再点一下停止${what}——对话保留`));
    setTimeout(() => { if (ui.stopArmed === armKey) { ui.stopArmed = null; render(); } }, 4000);
    return;
  }
  ui.stopArmed = null;
  return stopAll(list);
}
async function stopAll(list, lead = "") {
  let ok = 0;
  const errs = [];
  for (const s of list) {
    try { await stopOne(s); ok++; } catch (e) { errs.push(`${s.title || s.sessionId.slice(0, 8)}: ${e.message || e}`); }
  }
  toast(lead + (errs.length ? T(`Stopped ${ok}; ${errs.join("; ")}`, `已停止 ${ok} 个；${errs.join("；")}`) : T(`stopped ${ok} session${ok === 1 ? "" : "s"} — conversations are kept`, `已停止 ${ok} 个 session——对话保留`)), errs.length > 0);
  await refresh();
}
// Finishing a task here (done or abandoned) while it has live sessions asks whether to stop them
// too, unless an answer was remembered (Settings → Sessions changes it). Conversations are kept and
// Resume picks them up. A task its own session finished (that session's hq-update) is handled the
// same way, see sessionFinishes; one finished by `hq set` only gets the "still running" bar.
const finishStop = () => pref("hq-finish-stop", "ask");   // ask | stop | keep
async function setStatus(id, status) {
  const live = isOpen({ status }) ? [] : liveFor(id);
  try { await api("set", { task: id, fields: [`status=${status}`] }); }
  catch (e) { toast(String(e.message || e), true); await refresh(); return false; }
  if (live.length && finishStop() === "stop") { await stopAll(live, T("Status saved; ", "状态已保存；")); return true; }
  toast(T("Status saved", "状态已保存"));
  await refresh();
  if (live.length && finishStop() === "ask") { ui.finishAsk = { task: id, status }; drawFinishAsk(); }
  return true;
}
// The question, in its own small window over the board. Its list is the task's sessions at the
// moment of answering, not of asking.
function drawFinishAsk() {
  const box = $("#confirm");
  const a = ui.finishAsk;
  const live = a ? liveFor(a.task) : [];
  if (!a || !live.length) { ui.finishAsk = null; box.hidden = true; box.innerHTML = ""; return; }
  const word = esc(STATUS_SHORT[a.status] || a.status);
  const n = live.length;
  box.innerHTML = `<div class="panel" role="dialog" aria-label="${T("Stop its sessions?", "停掉它的 session？")}">
    <div class="stitle">${T(`${esc(a.task)} is ${esc(a.status)} — stop ${n === 1 ? "its session" : `its ${n} sessions`} too?`, `${esc(a.task)} ${word}，要把它的 ${n} 个 session 也停掉吗？`)}</div>
    <div class="meta">${T("Their Claude Code processes end; conversations are kept and Resume picks them up.", "结束它们的 Claude Code 进程；对话保留，之后可以 Resume 续上。")}</div>
    <ul class="cf-list">${live.map((s) => `<li><span class="dot ${dotClass(s)}"></span>${esc(s.title || s.project || s.sessionId.slice(0, 8))} <span class="meta">${esc(statusWord(s))}</span></li>`).join("")}</ul>
    <label class="cf-remember"><input type="checkbox" id="cf-remember"> ${T("Remember my answer and don't ask again (Settings → Sessions changes it)", "记住我的选择，以后不再问（可以在 设置 → Sessions 里改）")}</label>
    <div class="row cf-btns"><button class="btn ghost" data-action="finish-keep">${T("Leave them running", "不停")}</button>
      <button class="btn primary" data-action="finish-stop">${n === 1 ? T("Stop it", "停掉") : T("Stop all", "全部停掉")}</button></div>
  </div>`;
  box.hidden = false;
  // Opened by a refresh, not by your click: Return or Space meant for the box you were typing in
  // must not stop anything, so the safe button takes the focus.
  box.querySelector(a.auto ? "[data-action=finish-keep]" : "[data-action=finish-stop]").focus();
}
function answerFinishAsk(stop) {
  const a = ui.finishAsk;
  const remember = stop !== null && $("#cf-remember") && $("#cf-remember").checked;
  if (remember) savePref("hq-finish-stop", stop ? "stop" : "keep");
  ui.finishAsk = null;
  drawFinishAsk();
  const live = a && stop ? liveFor(a.task) : [];
  if (live.length) return stopAll(live, remember ? T("Remembered; ", "已记住；") : "");
  if (remember) { toast(T("Remembered — finishing a task leaves its sessions running", "已记住——以后结束任务时不停 session")); render(); }
}

// A session that finished its own task (status done / abandoned in its hq-update) is treated as if
// the task were finished here: the same setting stops its sessions, asks, or leaves them. Not while
// the finishing session is busy (its reply hasn't landed, or background work it started is still
// running); a prompt sent to it after finishing takes the mark away (hq drops it), so a session you
// are still talking to is never stopped; and only within 10 minutes — older ones, from while the
// board was closed, are left to the amber "still running" bar. Each mark is handled once
// ("hq-finish-seen": session|time → when it was handled); one that has to wait — the finisher
// busy, or another finish question already open — stays for a later refresh. Stopping without
// asking leaves the task's other sessions alone while they are working or waiting on you.
const FINISH_FRESH_MS = 10 * 60 * 1000;
function sessionFinishes() {
  const now = Date.now(), at = (s) => Date.parse(s.finished.at) || 0, key = (s) => `${s.sessionId}|${s.finished.at}`;
  let seen = {};
  try { seen = JSON.parse(pref("hq-finish-seen", "{}")) || {}; } catch (e) { seen = {}; }
  if (typeof seen !== "object" || Array.isArray(seen)) seen = {};
  for (const k of Object.keys(seen)) if (!(now - seen[k] < 2 * FINISH_FRESH_MS)) delete seen[k];
  const marks = ui.sessions.filter((s) => s.finished && s.finished.task === s.task && !seen[key(s)] && now - at(s) < FINISH_FRESH_MS);
  const byTask = new Map();
  for (const s of marks) {
    if (liveState(s) === "busy") continue;
    byTask.set(s.task, [...(byTask.get(s.task) || []), s]);
  }
  for (const [id, finishers] of byTask) {
    const t = taskById(id), live = liveFor(id), mode = finishStop();
    if (t && !isOpen(t) && live.length && mode === "ask") {
      if (ui.finishAsk) continue;   // one question at a time; this one waits for the next refresh
      ui.finishAsk = { task: id, status: t.status, auto: true };
      drawFinishAsk();
    } else if (t && !isOpen(t) && live.length && mode === "stop") {
      const mine = new Set(finishers.map((s) => s.sessionId));
      const targets = live.filter((s) => mine.has(s.sessionId) || !["busy", "waiting"].includes(liveState(s)));
      if (targets.length) stopAll(targets, T(`${id} was finished by its session; `, `${id} 已由它的 session 结束；`));
    }
    for (const s of finishers) seen[key(s)] = now;
  }
  savePref("hq-finish-seen", JSON.stringify(seen));
}

// plain: one flat list; "state": grouped by what they are doing, whatever the List | Project toggle says.
function renderSessions(items = ui.sessions, plain = false) {
  if (!items.length) return `<div class="empty">${T("No live Claude Code sessions (Claude Pet sees sessions started after it was installed).", "没有正在运行的 Claude Code session（Claude Pet 只看得到它安装之后启动的 session）。")}</div>`;
  return (items === ui.sessions ? strayBar() : "") + renderSessionList(items, plain);
}
function renderSessionList(items, plain) {
  const openTasks = listed().filter(isOpen);
  const card = (s) => {
    const t = s.task && taskById(s.task);
    const sid = s.sessionId;
    const sorted = openTasks.slice().sort((a, b) =>
      (list(b.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0) -
      (list(a.workdirs).some((w) => s.cwd && s.cwd.startsWith(w)) ? 1 : 0));
    const taskCtl = t
      ? `<span class="tid link" data-task="${esc(t.id)}" data-action="goto" title="${esc(t.title)}">${esc(t.id)}</span>`
      : `<select class="bind mini" data-action="bind-session" data-session="${esc(sid)}" title="${T("Bind this session to a task", "把这个 session 绑定到任务")}">
           <option value="">${T("Bind…", "绑定…")}</option>
           ${sorted.map((x) => `<option value="${esc(x.id)}">${esc(x.id)} ${esc(x.title)}</option>`).join("")}
         </select>`;
    const busy = s.state === "busy";
    const kind = s.terminal && s.terminal.kind;
    const canSend = canMessage(s);
    const prompt = onPrompt(s);
    const why = canSend ? "" : s.background ? T("It is busy in the background — you can message it when its turn ends, or Attach to watch it.", "它正在后台干活——等这一轮结束再发消息，或者 Attach 进去看。")
      : T(`Messaging from the Task Board isn't supported for ${kind ? (TERMINAL_NAME[kind] || kind) + " terminals" : "this session's terminal"} yet — use Jump to open it.`,
          `看板还不支持给${kind ? ` ${TERMINAL_NAME[kind] || kind} 终端` : "这个 session 的终端"}发消息——用 Jump 打开它。`);
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
          <span class="stime">${ago(s.updatedAt).replace(" ago", "").replace(/前$/, "")}</span>
        </div>
        <div class="shead">
          <div class="meta smeta">${taskCtl}${s.background ? ` <span class="bgtag">${T("background", "后台")}</span>` : ""} · ${ui.sgroupBy !== "project" && sessionProject(s) && sessionProject(s) !== s.project ? `<span class="pchip">${esc(sessionProject(s))}</span> · ` : ""}${esc(s.project || "")} · ${esc(statusWord(s))}${ctxTag(s)}${s.waitingOn ? T(" · waiting: ", " · 在等：") + esc(s.waitingOn) : ""}</div>
          <div class="icons">
            <button class="icon" data-action="peek" data-session="${esc(sid)}" title="${T("Peek — open the recent conversation", "Peek——打开最近的对话")}">${ICON.peek}</button>
            ${s.background
              ? `<button class="icon" data-action="attach" data-session="${esc(s.bgId || sid)}" title="${T("Attach — open it in a terminal", "Attach——在终端里打开")}">${ICON.attach}</button>
                 <button class="icon ${ui.stopArmed === (s.bgId || sid) ? "armed" : ""}" data-action="stop" data-session="${esc(s.bgId || sid)}" title="${T("Stop this background session (its conversation is kept)", "停止这个后台 session（对话保留）")}">${ui.stopArmed === (s.bgId || s.sessionId) ? T("Stop?", "停止？") : ICON.stop}</button>`
              : `${escButton(s)}<button class="icon" data-action="jump" data-session="${esc(sid)}" title="${T("Jump to its terminal", "Jump——跳到它的终端")}">${ICON.jump}</button>
                 <button class="icon ${ui.stopArmed === sid ? "armed" : ""}" data-action="stop-session" data-session="${esc(sid)}" title="${T("Stop this session — ends its Claude Code process; the conversation is kept and Resume picks it up", "停止这个 session——结束它的 Claude Code 进程；对话保留，之后可以 Resume 续上")}">${ui.stopArmed === sid ? T("Stop?", "停止？") : ICON.stop}</button>`}
            <span title="${esc(canSend ? (open ? T("Hide the message box", "收起消息框") : T("Message this session", "给这个 session 发消息")) : why)}"><button class="icon ${open ? "on" : ""}" data-action="toggle-msg" data-session="${esc(sid)}" ${canSend ? "" : "disabled"}>${ICON.message}</button></span>
          </div>
        </div>
        ${approveBar(s)}
        ${plainText(s.lastText) ? `<div class="last">${esc(plainText(s.lastText))}</div>` : ""}
        ${open ? `<div class="send" ${prompt ? `title="${esc(ON_PROMPT())}"` : ""}>
          <textarea class="grow" rows="1" data-key="msg:${esc(sid)}" data-session="${esc(sid)}"
            placeholder="${prompt ? ON_PROMPT() : busy ? T("Busy — it will queue · paste or drop images", "正忙——会排队 · 可粘贴或拖入图片") : T("Message · paste or drop images", "消息 · 可粘贴或拖入图片")}">${esc(draft("msg:" + sid))}</textarea>
          ${sendButton(sid, !prompt)}
        </div>${prompt ? `<div class="onprompt">${ON_PROMPT()}</div>` : ""}${attachStrip(sid)}` : ""}
      </div>
    </div>`;
  };
  if (plain === true) return items.map(card).join("");
  // As a list: what waits on you first, then what is working, then the rest — newest first in each.
  if (plain === "state" || ui.sgroupBy !== "project") {
    const newest = (a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""));
    // "In background": its turn is over but something it started is still running — it will be
    // back. Idle is only what has nothing running and nothing to wait for.
    const groupOf = (x) => (x.state === "waiting" || x.state === "busy" ? x.state : bgRunning(x) ? "bg" : "");
    return [["waiting", T("Waiting on you", "等你")], ["busy", T("Working", "在干活")],
      ["bg", T("In background", "后台在跑")], ["", T("Idle", "空闲")]].map(([st, label]) => {
      const group = items.filter((x) => groupOf(x) === st).sort(newest);
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
    html += `<div class="group-title proj" data-action="scollapse" data-key="${esc(key)}" title="${T(`Click to ${shut ? "expand" : "collapse"}`, `点击${shut ? "展开" : "收起"}`)}">
      <span class="caret ${shut ? "" : "open"}"><svg viewBox="0 0 16 16"><path d="M6 3.5 10.5 8 6 12.5"/></svg></span>${esc(name || T("No project", "无项目"))}
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

// ---- Settings: how the board starts sessions and what happens around them. Projects are managed
// on their own pages (Projects & duties). Open on any page (⚙); Esc, Done or a click outside closes it.
function renderSettings() {
  const box = $("#settings");
  if (!ui.settings) { box.hidden = true; box.innerHTML = ""; return; }
  const prev = box.querySelector(".settings-body");
  const scroll = prev ? prev.scrollTop : 0;
  box.innerHTML = `<div class="panel" role="dialog" aria-label="${T("Settings", "设置")}">
    <div class="phead"><div class="stitle">${T("Settings", "设置")}</div>
      <span style="flex:1"></span><button class="btn small" data-action="close-settings">${T("Done", "完成")}</button></div>
    <div class="settings-body">${renderSessionSettings()}</div></div>`;
  box.hidden = false;
  box.querySelector(".settings-body").scrollTop = scroll;   // rebuilt with the board, every few seconds
}
function closeSettings() { ui.settings = false; render(); }
function renderSessionSettings() {
  const row = (title, tip, ctl) => `<div class="set-row"><div><b>${title}</b><div class="meta">${tip}</div></div>${ctl}</div>`;
  return `<div class="set-list">
    ${row(T("New sessions open in", "新 session 开在"), T("Where ▶ New session, ↻ Resume and ▶ Do it open a session", "▶ 新 session、↻ Resume 和 ▶ 去做 在哪里开 session"),
      `<select class="bind" data-action="launch-place">${Object.entries(PLACES).map(([k, v]) => `<option value="${k}" ${launchPlace() === k ? "selected" : ""}>${v}</option>`).join("")}</select>`)}
    ${row(T("Skip permissions", "跳过权限确认 (skip permissions)"), T("Start and resume sessions with --dangerously-skip-permissions: Claude won't stop to ask before running commands or editing files", "新开和续上的 session 带 --dangerously-skip-permissions：Claude 跑命令、改文件前不再停下来问"),
      `<input type="checkbox" data-action="skip-perms" ${skipPerms() ? "checked" : ""}>`)}
    ${row(T("Stay on board", "留在看板上"), T("Open the session's terminal tab in the background and carry on here, in its conversation window", "终端标签页在后台打开，留在这里、在它的对话窗口里接着干"),
      `<input type="checkbox" data-action="stay-board" ${stayOnBoard() ? "checked" : ""}>`)}
    ${ui.clickTarget ? row(T("Clicking a session on the pet opens", "在宠物上点击 session 时打开"), T("A finish bubble, a row in the pet's list, or the jump-to-waiting shortcut. Its task's drawer opens here, with the session picked out and its conversation open; a session bound to no task still goes to its terminal. Also in the pet's right-click menu → Settings", "完成气泡、宠物列表里的一行，或“跳到等待中的 session”快捷键。打开看板上它的任务时，打开这个任务的详情侧栏，并把这个 session 高亮、打开它的对话；没绑定任务的 session 照旧跳终端。宠物右键菜单 → 设置 里也能改"),
      `<select class="bind" data-action="click-target">${[["terminal", T("Its terminal", "它的终端")], ["board", T("Its task on the board", "看板上它的任务")]].map(([k, v]) => `<option value="${k}" ${ui.clickTarget === k ? "selected" : ""}>${v}</option>`).join("")}</select>`) : ""}
    ${row(T("Finishing a task", "结束任务时"), T("When you set a task to done or abandoned here and it still has live sessions", "在看板上把任务改成 done 或 abandoned、它还有 session 在跑时"),
      `<select class="bind" data-action="finish-stop-pref">${[["ask", T("Ask each time", "每次问")], ["stop", T("Stop its sessions", "停掉它的 session")], ["keep", T("Leave them running", "不停")]].map(([k, v]) => `<option value="${k}" ${finishStop() === k ? "selected" : ""}>${v}</option>`).join("")}</select>`)}
    ${row(T("Active first", "活跃的在前"), T("On Projects & duties, projects with a live session come first, most recently active first; in every lane (Focus and a project's page), the task whose session moved last comes first. Off: your own order", "项目与职责里有 session 在跑的项目排最前，最近有动静的在前；每一列里（Focus 和项目页），session 最近有动静的任务排最上面。不勾：按你自己的顺序"),
      `<input type="checkbox" data-action="active-first" ${ui.activeFirst ? "checked" : ""}>`)}
  </div>`;
}

// ---- onboarding: suggest projects from the sessions already on this machine (hq scan)
function renderScan() {
  if (!ui.scan) return "";
  if (ui.scan === "loading") return `<div class="empty">${T("Scanning your Claude Code sessions…", "正在扫描你的 Claude Code session…")}</div>`;
  const fresh = ui.scan.projects.filter((p) => !p.existing);
  if (!fresh.length) return `<div class="empty">${T("Every directory your sessions worked in already belongs to a project.", "你的 session 干过活的每个目录都已经属于某个项目了。")}</div>`;
  return `<div class="res" style="margin-top:6px">
    <div class="meta" style="margin-bottom:4px">${T(`${ui.scan.sessions.length} sessions in the last ${ui.scan.days} days. Pick the projects to create (skip personal or throwaway folders):`, `最近 ${ui.scan.days} 天有 ${ui.scan.sessions.length} 个 session。勾选要创建的项目（个人或临时的目录可以跳过）：`)}</div>
    ${fresh.map((p) => `<label class="scan-i"><input type="checkbox" data-action="scan-pick" data-name="${esc(p.name)}" ${ui.scanPick.has(p.name) ? "checked" : ""}>
      <b>${esc(p.name)}</b> <span class="meta">${T(`${p.count} session${p.count === 1 ? "" : "s"}`, `${p.count} 个 session`)} · ${ago(p.last)} · ${esc(p.path)}</span></label>`).join("")}
    <div class="row" style="margin-top:6px"><button class="btn small primary" data-action="scan-apply" ${ui.scanPick.size ? "" : "disabled"}>${T(`Create ${ui.scanPick.size || ""} project${ui.scanPick.size === 1 ? "" : "s"}`, `创建 ${ui.scanPick.size || ""} 个项目`)}</button>
      <button class="btn small ghost" data-action="scan-close">${T("Close", "关闭")}</button></div>
  </div>`;
}
function renderOnboarding() {
  return `<div class="card onboard">
    <h4>${T("Start from the sessions you already have", "从已有的 session 开始")}</h4>
    <ol>
      <li>${T(`<b>Projects.</b> Find the repositories and folders your Claude Code sessions worked in, and pick which become projects.`, `<b>项目。</b>找出你的 Claude Code session 干过活的仓库和目录，挑出哪些成为项目。`)}
        <div class="row" style="margin-top:4px"><button class="btn small primary" data-action="scan-open">${T("Suggest projects", "推荐项目")}</button></div></li>
      <li>${T(`<b>Tasks.</b> In any Claude Code session, run <code>/hq-onboard</code>. Claude reads your recent sessions, drafts task cards (status, next step, your todos, links), shows you the list and creates nothing until you confirm. Live sessions get bound to their tasks.`, `<b>任务。</b>在任意 Claude Code session 里运行 <code>/hq-onboard</code>。Claude 会读你最近的 session，起草任务卡（状态、下一步、你的待办、链接），列给你看，你确认之前不会创建任何东西。正在运行的 session 会绑定到对应的任务。`)}
        <div class="row" style="margin-top:4px"><button class="btn small" data-action="copy-onboard">${T("Copy /hq-onboard", "复制 /hq-onboard")}</button></div></li>
      <li>${T(`Adjust anything here afterwards — or start fresh with <b>+ New task</b>.`, `之后在这里随便改——或者直接用 <b>+ 新建任务</b> 从头开始。`)}</li>
    </ol>
  </div>`;
}


// ------------------------------------------------------------------ peek window
// A session's recent conversation in a large overlay: select and copy freely,
// click links and file paths. Click outside or press Esc to close.
async function act2(op, args) {
  try {
    const r = await api(op, args);
    if (r && r.revealed) toast(T("Shown in Finder (not opened: it could run code)", "已在访达中显示（没有直接打开：它可能会运行代码）"));
  } catch (e) { toast(String(e.message || e), true); }
}
async function copyText(text, msg) {
  try { await api("copy", { text }); toast(msg); } catch (e) { toast(String(e.message || e), true); }
}

async function openPeek(sid, back, opt = {}) {
  if (opt.secretary) {
    ui.modal = { type: "peek", secretary: true, sec: opt.secretary, sid, title: T("Secretary", "秘书"), project: "", cwd: "",
                 live: false, msgs: null, sig: "", back: back || null, items: null, turn: null, todos: null, details: {},
                 openTools: new Set(), openGroups: new Set(), fullTools: new Set(), todoOpen: false, starting: false,
                 startedAt: Date.now() };
    drawPeek(true);
    return refreshPeek(true);
  }
  const s = sid && ui.sessions.find((x) => x.sessionId === sid || x.sessionId.startsWith(sid));
  ui.modal = { type: "peek", sid: s ? s.sessionId : sid, title: (s && (s.title || s.project)) || opt.title || sid.slice(0, 8),
               project: s ? s.project : "", cwd: s ? s.cwd : "", live: Boolean(s), msgs: null, sig: "", back: back || null,
               items: null, turn: null, todos: null, details: {}, openTools: new Set(), openGroups: new Set(),
               fullTools: new Set(), todoOpen: false,
               // Just started from the board: not live yet, but not ended either — it is coming up.
               starting: Boolean(opt.starting) && !s, startedAt: Date.now() };
  drawPeek(true);
  await refreshPeek(true);
}
function closePeek() {
  // A session the pet sent us to stays picked out a moment longer, where its card is.
  if (ui.hlSession && ui.modal && ui.modal.sid === ui.hlSession) {
    const sid = ui.hlSession;
    requestAnimationFrame(() => { const row = document.querySelector(".bsess.hl, .fs.hl"); if (row) row.scrollIntoView({ block: "nearest", behavior: "smooth" }); });
    clearTimeout(ui.hlTimer);
    ui.hlTimer = setTimeout(() => { if (ui.hlSession === sid) { ui.hlSession = null; render(); } }, 4000);
  }
  ui.modal = null;
  $("#modal").hidden = true;
  $("#modal").innerHTML = "";
}
async function refreshPeek(first) {
  const m = ui.modal;
  if (!m) return;
  let msgs, act = { items: null, turn: null, todos: null, queued: null };
  let secChanged = false;
  if (m.secretary) {
    // Its state first: the session's id is handed out with the first message, and whether it is
    // replying decides the send box.
    try { m.sec = ui.secretary = await apiObj("secretary"); } catch (e) { return toast(String(e.message || e), true); }
    if (ui.modal !== m) return;
    if (m.sec.sessionId && m.sec.sessionId !== m.sid) m.sid = m.sec.sessionId;
    // Its card's state and its open asks too: answering one here (or in Needs you) redraws it.
    const card = taskById(secId());
    const secSig = JSON.stringify([m.sid, m.sec.running, m.sec.waking, m.sec.last, m.sec.state, m.sec.reports, m.sec.schedule, m.sec.files,
      m.sec.runStart, ui.skin, ui.secGlance && ui.secGlance.lastAt, secIdleWord(ui.secGlance && ui.secGlance.lastAt), card ? (card.asks || []).map((a) => [a.id, a.state, isLater(a), a.note]) : null]);
    secChanged = secSig !== m.secSig;
    m.secSig = secSig;
  }
  try {
    msgs = m.secretary && !m.sid ? [] : await apiJSON("peek", { session: m.sid, opened: Boolean(first) });
  } catch (e) { return toast(String(e.message || e), true); }
  if (ui.modal !== m) return;
  // A session that has come up (or ended) since the window opened: send box on or off.
  const s = ui.sessions.find((x) => x.sessionId === m.sid);
  let changed = secChanged;
  if (!m.secretary && Boolean(s) !== m.live) {
    m.live = Boolean(s); changed = true;
    if (s) { m.title = s.title || s.project || m.title; m.project = s.project; m.cwd = s.cwd; m.starting = false; }
  }
  if (m.starting && Date.now() - m.startedAt > 120000) { m.starting = false; changed = true; }
  if (msgs && !Array.isArray(msgs)) {          // --meta form: also says who the session is
    if (!m.live) { if (!m.secretary) m.title = msgs.title || m.title; m.cwd = msgs.cwd || m.cwd;
                   m.project = m.project || (msgs.cwd || "").split("/").pop(); }
    m.found = msgs.found;
    act = { items: msgs.items || null, turn: msgs.turn || null, todos: msgs.todos || null, queued: msgs.queued || null };
    msgs = msgs.messages || [];
  }
  // The session's state counts too: stopping on a permission prompt changes no transcript line,
  // but the status line and the waiting row must say so.
  // Two parts: the conversation (messages, tool rows: what a rebuild redraws) and the live lines
  // above it (status, todos). While Claude works, its token count changes on every poll; that
  // alone only redraws those lines, so the list you are reading or scrolling is left alone.
  const bodySig = JSON.stringify([msgs, act.items, s ? liveState(s) : null]);
  // (The secretary's window shows neither tokens nor todos: only the turn ending counts there.)
  const sig = bodySig + "\u0001" + JSON.stringify(m.secretary ? [act.turn && act.turn.done] : [act.turn, act.todos, act.queued, s ? s.waitingOn || "" : null]);
  if (sig === m.sig && !changed) return;
  // Never rebuild under a selection the user is making or about to copy.
  const sel = window.getSelection();
  if (!first && sel && !sel.isCollapsed && $("#modal").contains(sel.anchorNode)) return;
  const next = { msgs, sig, bodySig, act };
  if (!first && !changed && bodySig === m.bodySig) {   // only the lines above the list
    applyPeek(m, next);
    if (drawPeekLive()) return;
  }
  // A rebuild sets the list's scroll position, which stops a trackpad's glide dead: one that
  // comes while you scroll waits until you have stopped for a moment. The new data waits with
  // it, so what is on screen (Copy buttons, the status line) still matches the old list.
  if (!first && !changed && peekScrolling()) { m.next = next; return holdPeek(m); }
  applyPeek(m, next);
  drawPeek(first);
}
function applyPeek(m, next) {
  m.next = null;
  m.msgs = next.msgs;
  m.sig = next.sig;
  m.bodySig = next.bodySig;
  Object.assign(m, next.act);
  // An opened row whose call has since finished (or failed) shows its new output.
  for (const id of m.openTools) {
    const t = (m.items || []).find((x) => x.id === id);
    if (t && m.details[id] && m.details[id]._st !== t.status) loadToolDetail(m, id);
  }
}
const PEEK_SCROLL_QUIET_MS = 1000;
const peekScrolling = () => Date.now() - (ui.peekScrollAt || 0) < PEEK_SCROLL_QUIET_MS
  || ui.peekScrollbar;   // its scrollbar is being dragged
// Not while you select text in it either: the rebuild would drop the selection before you copy.
const peekSelecting = () => { const sel = window.getSelection(); return sel && !sel.isCollapsed && $("#modal").contains(sel.anchorNode); };
function holdPeek(m) {
  if (m.held) return;
  m.held = setTimeout(function again() {
    if (ui.modal !== m) return;
    if (peekScrolling() || peekSelecting()) { m.held = setTimeout(again, 250); return; }
    m.held = null;
    if (m.next) applyPeek(m, m.next);
    drawPeek(false);
  }, 250);
}
// A redraw the board starts on its own (not one you clicked for): waits out a scroll.
function redrawPeek(m) {
  if (peekScrolling()) holdPeek(m); else drawPeek(false);
}
// Just the status line and Claude's todos, in place (the reply box is not touched, so this is safe
// mid-composition too). False when the window has not drawn them yet: then the caller rebuilds.
function drawPeekLive() {
  const m = ui.modal, live = $("#modal .plive");
  if (!live || m.secretary) return false;
  const s = ui.sessions.find((x) => x.sessionId === m.sid) || {};
  live.innerHTML = peekStatus(m, s, peekRun(m, s)) + peekTodos(m);
  // The queue box, only when it changed: rewriting it resets its own scroll. It sits under the
  // list, so the list's height changes with it — a reader at the bottom stays there.
  const q = $("#modal .pqueue-slot"), qh = peekQueue(m, s);
  if (q && q.dataset.h !== qh) {
    const body = $("#modal .peek-body");
    const atBottom = body && body.scrollHeight - body.scrollTop - body.clientHeight < 12;
    q.innerHTML = qh; q.dataset.h = qh;
    if (atBottom) body.scrollTop = body.scrollHeight;
  }
  $("#modal").querySelectorAll("[data-ago]").forEach((el) => { el.textContent = ago(el.dataset.ago); });
  return true;
}
document.addEventListener("wheel", (ev) => {
  if (ui.modal && ui.modal.type === "peek" && ev.target.closest && ev.target.closest(".peek-body")) ui.peekScrollAt = Date.now();
}, { capture: true, passive: true });
// Scrolling from the keyboard glides too (not while typing in the reply box).
const SCROLL_KEYS = new Set(["PageUp", "PageDown", "Home", "End", "ArrowUp", "ArrowDown", " "]);
document.addEventListener("keydown", (ev) => {
  if (!ui.modal || ui.modal.type !== "peek" || !SCROLL_KEYS.has(ev.key)) return;
  const t = ev.target;
  if (t && (t.tagName === "TEXTAREA" || t.tagName === "INPUT" || t.isContentEditable)) return;
  ui.peekScrollAt = Date.now();
}, true);
// The scrollbar: a left press on the list's own box at its right edge (macOS draws an overlay
// scrollbar over the content, so clientWidth alone does not find it). Only that, so a click or a
// right-click (whose menu can swallow the mouseup) in the conversation never holds Peek.
document.addEventListener("mousedown", (ev) => {
  const b = ev.target;
  ui.peekScrollbar = ev.button === 0 && b.classList && b.classList.contains("peek-body") && ev.offsetX >= b.clientWidth - 16;
}, true);
document.addEventListener("mouseup", () => { ui.peekScrollbar = false; }, true);
function drawPeek(toBottom) {
  if (ui.composing) { ui.peekPending = ui.peekPending || { toBottom: false }; ui.peekPending.toBottom ||= Boolean(toBottom); return; }
  const m = ui.modal;
  if (m.held) { clearTimeout(m.held); m.held = null; }   // this draw is the one it was holding
  if (m.next) applyPeek(m, m.next);                       // so it shows what it was holding too
  if (m.secretary) return drawSecretary(toBottom);       // its own window: a chat
  const box = $("#modal");
  // The reply box is rebuilt with the rest; keep the cursor in it.
  const active = document.activeElement;
  // (By its key: the secretary's window also has its asks' note boxes.)
  const typing = active && box.contains(active) && active.tagName === "TEXTAREA" ? [active.selectionStart, active.selectionEnd, active.dataset.key] : null;
  const taScrolls = textScrolls(box);
  const scroll = peekScrollGrab(box, m);
  const s = ui.sessions.find((x) => x.sessionId === m.sid) || {};
  const key = m.sid;
  const prompt = m.live && canMessage(s) && onPrompt(s);
  const canSend = m.live && canMessage(s);
  const noSend = m.starting ? T("Starting the session — you can type here as soon as it is up", "session 正在启动——起来后就可以在这里输入") : !m.live ? T("This session has ended — history only", "这个 session 已结束——只能看历史") : T("Not supported in this terminal", "这个终端不支持");
  const msgs = m.msgs;
  // Messages, with each run of tool calls between them as one block (see peekBlocks).
  const blocks = msgs === null ? null : peekBlocks(m.items || msgs.map((x) => ({ kind: "msg", ...x })));
  m.keys = blocks ? blocks.map((b) => (b.kind === "group" ? `g|${b.tools[0].id}` : `${b.role}|${b.ts}|${b.text}`)) : null;
  const run = peekRun(m, s);
  const queue = peekQueue(m, s);
  let mi = 0;
  const list = msgs === null ? `<div class="empty">${T("Loading…", "加载中…")}</div>`
    : !blocks.length ? `<div class="empty">${m.found === false ? T("No transcript found for this session on this machine.", "这台机器上找不到这个 session 的对话记录。") : T("No messages yet.", "还没有消息。")}</div>`
    : blocks.map((x) => x.kind === "group" ? `<div class="pmsg ptools">${toolGroup(x, m, run)}</div>` : `<div class="pmsg ${x.role}">
        <div class="pwho">${x.role === "user" ? T("You", "你") : "Claude"} · <span data-ago="${esc(x.ts)}">${ago(x.ts)}</span>
          <button class="btn small ghost" data-action="copy-msg" data-i="${mi++}" title="${T("Copy this message", "复制这条消息")}">${T("Copy", "复制")}</button></div>
        <div class="md">${markdown(x.text, `${x.role}|${x.ts}`)}</div>
      </div>`).join("");
  const keepDraft = box.querySelector(".pfoot textarea") ? null : draft("msg:" + key);
  const chip = m.live ? "" : m.starting ? ` <span class="chip">${T("starting…", "启动中…")}</span>` : ` <span class="chip">${T("ended", "已结束")}</span>`;
  const sub = `${esc(m.project || "")} · ${T(`last ${msgs ? msgs.length : "…"} messages · click outside or Esc to close`, `最近 ${msgs ? msgs.length : "…"} 条消息 · 点外面或按 Esc 关闭`)}`;
  box.innerHTML = `<div class="panel" role="dialog" aria-label="${T("Conversation", "对话")}">
    <div class="phead">
      ${m.back ? `<button class="btn small ghost" data-action="modal-back" title="${T("Back", "返回")}">←</button>` : ""}
      <div><div class="stitle">${esc(m.title)}${chip}</div><div class="meta">${sub}</div></div>
      <span style="flex:1"></span>
      <button class="btn small" data-action="copy-all">${T("Copy all", "全部复制")}</button>
      ${m.live ? `<button class="btn small" data-action="jump" data-session="${esc(m.sid)}">Jump</button>` : ""}
      <button class="btn small ghost" data-action="close-modal" title="${T("Close (Esc)", "关闭 (Esc)")}">✕</button>
    </div>
    <div class="plive">${peekStatus(m, s, run)}${peekTodos(m)}</div>
    <div class="peek-body">${list}</div>
    <div class="pqueue-slot" data-h="${esc(queue)}">${queue}</div>
    <div class="send pfoot ${canSend ? "" : "disabled"}" title="${canSend ? "" : m.starting ? T("Starting the session…", "session 正在启动…") : !m.live ? T("This session has ended.", "这个 session 已结束。") : T("Messaging isn't supported for this session's terminal yet — use Jump.", "还不支持给这个 session 的终端发消息——用 Jump。")}">
      <textarea class="grow" rows="1" data-key="msg:${esc(key)}" data-session="${esc(key)}" ${canSend ? "" : "disabled"}
        placeholder="${prompt ? ON_PROMPT() : canSend ? T("Reply to this session — paste or drop images too", "回复这个 session——也可以粘贴或拖入图片") : noSend}">${esc(keepDraft ?? draft("msg:" + key))}</textarea>
      ${sendButton(key, canSend && !prompt)}
    </div>${prompt ? `<div class="onprompt">${ON_PROMPT()}</div>` : ""}${canSend ? attachStrip(key) : ""}
  </div>`;
  box.hidden = false;
  fitAllGrow(box);
  if (typing) {
    const ta = [...box.querySelectorAll("textarea")].find((x) => x.dataset.key === typing[2]);
    if (ta) { ta.focus(); ta.setSelectionRange(typing[0], typing[1]); }
  }
  restoreTextScrolls(box, taScrolls);
  slashPlace();
  peekScrollPut(box, m, scroll, toBottom);
}
// Where the reader is in the conversation, to put the rebuilt one back there: at the bottom
// (newest) it follows new messages. Peek keeps the last 30 messages, so when one arrives the
// oldest drops off and everything moves up: remember the first message in view (by m.keys, one
// per .pmsg) and where it sat.
function peekScrollGrab(box, m) {
  const body = box.querySelector(".peek-body");
  const atBottom = !body || body.scrollHeight - body.scrollTop - body.clientHeight < 12;
  const prevTop = body ? body.scrollTop : 0;    // the rebuilt list starts at the top otherwise
  let anchor = null;
  if (body && !atBottom && m.keys) {
    const top = body.getBoundingClientRect().top;
    const els = [...body.querySelectorAll(".pmsg")];
    const i = els.findIndex((el) => el.getBoundingClientRect().bottom > top);
    if (i >= 0 && m.keys[i]) anchor = { key: m.keys[i], off: els[i].getBoundingClientRect().top - top };
  }
  return { atBottom, prevTop, anchor };
}
function peekScrollPut(box, m, sc, toBottom) {
  const nb = box.querySelector(".peek-body");
  if (!nb) return;
  if (toBottom || sc.atBottom) { nb.scrollTop = nb.scrollHeight; return; }
  nb.scrollTop = sc.prevTop;
  const j = sc.anchor && m.keys ? m.keys.indexOf(sc.anchor.key) : -1;
  if (j >= 0) {
    const el = nb.querySelectorAll(".pmsg")[j];
    nb.scrollTop += el.getBoundingClientRect().top - nb.getBoundingClientRect().top - sc.anchor.off;
  }
}

// ------------------------------------------------------------------ secretary
// A standing chat with the secretary (SecretaryController): an agent that knows the board, in a
// fixed background session in the HQ root — one run of its job per message. Its window reads like
// a chat with a person, not like Peek: its tool calls and in-between messages are hidden, each turn
// shows only its last reply, its proposals (asks on its own card) are answered right where it
// raised them, and it wears the pet's face. A yes wakes it to carry them out.
const SEC = "secretary";   // the reply box's key, and its send button's session
const peekKey = (m) => (m.secretary ? SEC : m.sid);

// Where the face sits in each state's picture (384 px square): centre x, centre y, diameter.
// A skin without an entry borrows the cat's boxes; a state without one, its idle box.
const FACE = {
  cat:        { idle: [192, 136, 240], reading: [188, 128, 236], working: [176, 132, 236], sleeping: [172, 148, 236] },
  cultivator: { idle: [192, 140, 224], reading: [172, 116, 216], working: [170, 136, 212], sleeping: [180, 136, 212] },
};
// The pet's face, cut from the current skin's picture for that state, `size` px across.
function face(state, size, cls = "") {
  const skin = ui.skin || "cat";
  const boxes = FACE[skin] || FACE.cat;
  const st = boxes[state] ? state : "idle";
  const [cx, cy, d] = boxes[st];
  const k = size / d;
  return `<span class="av ${cls}" aria-hidden="true" style="width:${size}px;height:${size}px;background-image:url('../skins/${encodeURIComponent(skin)}/assets/${st}.png');background-size:${(384 * k).toFixed(1)}px;background-position:${(size / 2 - cx * k).toFixed(1)}px ${(size / 2 - cy * k).toFixed(1)}px"></span>`;
}
// Quiet for an hour: it shows asleep (a message wakes it).
const secAsleep = (iso) => Boolean(iso) && secsSince(iso) > 3600;
// What the idle status line says about the time, so an open window redraws when that changes.
const secIdleWord = (iso) => (iso ? (secAsleep(iso) ? "asleep:" : "") + ago(iso) : "");

// The top bar's button: its face (asleep, or ringed while it replies) and how many of its
// proposals wait on you. Redrawn only when that changes, so the ring's breathing doesn't restart.
function drawSecretaryButton() {
  const b = $("#secretary-btn");
  if (!b) return;
  const g = ui.secGlance || {};
  const t = secId() && taskById(secId());
  const n = t ? openAsks(t).length : 0;
  const mood = g.busy ? "working" : secAsleep(g.lastAt) ? "sleeping" : "idle";
  const html = `<span class="secface${g.busy ? " ring" : ""}">${face(mood, 20, mood === "sleeping" ? "dim" : "")}</span>${T("Secretary", "秘书")}${n ? `<span class="badge" title="${T(`${n} proposal${n === 1 ? "" : "s"} waiting on you`, `${n} 条建议在等你回应`)}">${n}</span>` : ""}`;
  if (b.dataset.sig === html) return;
  b.dataset.sig = html;
  b.innerHTML = html;
}

async function openSecretary() {
  let st;
  try { st = ui.secretary = await apiObj("secretary"); } catch (e) { return toast(String(e.message || e), true); }
  if (!st.ready || !st.job) { ui.modal = { type: "secretary-setup" }; return drawSecretarySetup(); }
  return openPeek(st.sessionId || "", null, { secretary: st });
}
function drawSecretarySetup(busy) {
  const st = ui.secretary || {};
  const file = (p, ok) => `<li><code>${esc(p)}</code>${ok ? ` <span class="meta">${T("(there — kept)", "（已有——保留）")}</span>` : ""}</li>`;
  const files = st.files || {};
  const box = $("#modal");
  box.innerHTML = `<div class="panel sec-setup" role="dialog" aria-label="${T("Secretary", "秘书")}">
    <div class="phead">${face("idle", 36)}<div><div class="stitle">${T("Secretary", "秘书")}</div><div class="meta">${T("not set up on this board yet", "这个看板还没设置秘书")}</div></div>
      <span style="flex:1"></span><button class="btn small ghost" data-action="close-modal" title="${T("Close (Esc)", "关闭 (Esc)")}">✕</button></div>
    <div class="sec-body">
      <p>${T("The secretary is a Claude session that knows this board. Ask it where things stand and what is waiting on you; it answers from the cards and sessions, and proposes changes (a new task, a note, a todo, closing a task) as questions in <b>Needs you</b>. It changes nothing until you say yes, and it doesn't do the work itself.",
             "秘书是一个了解这个看板的 Claude session。问它各个任务怎么样了、什么在等你；它从任务卡和 session 里找答案，要改看板（建任务、记一笔、加待办、关任务）就作为问题放进 <b>Needs you</b>，你说同意它才动手。它自己不干活。")}</p>
      <p>${T("Setting it up creates:", "设置会创建：")}</p>
      <ul>
        ${file(st.agent || ".claude/agents/secretary.md", st.agentExists)}
        ${Object.keys(files).map((f) => file(`${st.memory || "secretary"}/${f}`, files[f])).join("")}
        <li>${st.task ? T(`its card, ${esc(st.task)} (there — kept)`, `它自己的任务卡 ${esc(st.task)}（已有——保留）`) : T("its own task card, “Secretary” (its notebook; its asks are its proposals)", "它自己的任务卡“秘书”（它的笔记本；它的提问就是它的建议）")}</li>
        <li>${T("a job “Secretary” in Scheduled, with no schedule: it runs when you message it", "“定时任务”页里的一个任务“秘书”，不定时：你发消息它才运行")}</li>
      </ul>
      <p class="meta">${T("The memory files (who you are, your colleagues, your recurring processes) are yours to edit; the secretary proposes changes to them as a diff.", "记忆文件（你是谁、同事、常做的流程）你可以直接改；秘书要改它们会先给你看 diff。")}</p>
      <div class="row"><span style="flex:1"></span><button class="btn primary" data-action="secretary-setup" ${busy ? "disabled" : ""}>${busy ? T("Setting up…", "设置中…") : T("Set up", "设置")}</button></div>
    </div>
  </div>`;
  box.hidden = false;
}
async function setupSecretary() {
  drawSecretarySetup(true);
  try { ui.secretary = await apiObj("secretary-setup", { lang: LANG }); }
  catch (e) { toast(String(e.message || e), true); return drawSecretarySetup(); }
  toast(T("Secretary set up", "秘书设置好了"));
  refresh();
  return openPeek(ui.secretary.sessionId || "", null, { secretary: ui.secretary });
}

// Messages the board or its schedule sent on your behalf: a line in the middle, not your bubble.
const SEC_NOTES = [
  [/^(Scheduled run:|定时运行：)/, "report", () => T("Scheduled: the report that is due", "定时：写今天该写的报告")],
  [/^(Write the report that is due now|现在写今天该写的报告)/, "report", () => T("You asked for the report now", "你让它现在写一份报告")],
  [/^(I answered your proposals on the board|我在看板上回应了你的建议)/, "wake", () => T("You answered its proposals", "你回应了它的建议")],
];
const secNote = (text) => { const n = SEC_NOTES.find(([re]) => re.test(String(text || "").trim())); return n ? { kind: n[1], text: n[2]() } : null; };
// What it is doing, from the call it is in: a word for the typing bubble and the face to wear.
function secDoing(t) {
  const r = (mood, en, zh) => ({ mood, text: T(en, zh) });
  if (!t) return r("working", "Writing…", "在写回复…");
  const name = t.title || "", label = t.label || "";
  const sub = name === "Bash" ? (label.match(/(?:^|[\s/])hq\s+(\S+)/) || [])[1] || "" : "";
  if (sub === "report") return /\bkeep\b/.test(label) ? r("working", "Filing the report…", "在存报告…") : r("reading", "Gathering what happened…", "在收集进展…");
  if (["status", "board", "asks", "project"].includes(sub)) return r("reading", "Looking over the board…", "在看看板…");
  if (["peek", "history"].includes(sub)) return r("reading", "Checking what the sessions said…", "在看 session 说了什么…");
  if (sub === "show") return r("reading", "Reading a task card…", "在翻任务卡…");
  if (sub) return r("working", "Updating the board…", "在改看板…");
  if (["Write", "Edit", "MultiEdit"].includes(name)) return /daily|weekly/.test(label) ? r("working", "Writing the report…", "在写报告…") : r("working", "Writing it down…", "在记下来…");
  if (name === "Read") return /TASK\.md/.test(label) ? r("reading", "Reading a task card…", "在翻任务卡…") : r("reading", "Reading up…", "在翻资料…");
  if (name === "Grep" || name === "Glob") return r("reading", "Looking something up…", "在查东西…");
  return r("working", "Working on it…", "在忙…");
}
// Its reply without HQ's bookkeeping blocks (card updates, recorded answers), and the proposals
// its hq-asks block raised, one line each.
function secSplit(text) {
  const asks = [];
  const keep = String(text || "").split(/^```/m).map((p, i) => {
    if (i % 2 === 0) return p;
    const nl = p.indexOf("\n");
    const lang = nl >= 0 ? p.slice(0, nl).trim() : "";
    if (!lang.startsWith("hq-")) return "```" + p + "```";
    if (lang === "hq-asks") asks.push(...p.slice(nl + 1).split("\n").map((l) => l.replace(/^\s*(?:[-*]|\d+[.)]|[a-z][.)])\s*/, "").trim()).filter(Boolean));
    return "";
  });
  return { text: keep.join("").replace(/\n{3,}/g, "\n\n").trim(), asks };
}
// The ask's text as hq records it: without a trailing [grant: …] / [授权：…] suggestion.
const askKey = (s) => String(s || "").replace(/\s*\[(?:grant|授权)[:：][^\[\]]*\]\s*$/i, "").replace(/\s+/g, " ").trim();
const RES_WORD = (s) => (RESOLUTIONS.concat(MORE_RESOLUTIONS).find((r) => r[0] === s) || [])[1] || { later: T("Ask later", "以后再问") }[s] || s;
// One of its proposals: open, a card to answer (the same answers as in Needs you, minus
// "Yes, always": a standing grant is never for the secretary); answered, one line.
function secPropose(a) {
  if (a.state === "open" && !isLater(a)) {
    return `<div class="propose"><div class="ph2">${T("Proposal", "建议")} · ${esc(a.id)}</div><div class="ptext">${esc(a.text)}</div>
      <textarea class="note grow" rows="1" data-key="note:${esc(a.id)}" placeholder="${T("note (optional) — it is your answer", "说明（可选）——写了就按说明办")}">${esc(draft("note:" + a.id))}</textarea>
      <div class="acts">${RESOLUTIONS.filter(([r]) => r !== "always").map(([r, label, tip]) =>
        `<button class="pb ${r === "do" ? "yes" : ""}" title="${esc(tip)}" data-action="resolve" data-id="${esc(a.id)}" data-res="${r}" ${ui.resolving.has(a.id) ? "disabled" : ""}>${label}</button>`).join("")}</div></div>`;
  }
  const said = a.state === "open" ? T("Later", "稍后再答") : RES_WORD(a.state);
  return `<div class="propose done"><div class="ptext">${esc(a.text)}</div>
    <div class="answered">${T("You:", "你：")} <b>${esc(said)}</b>${a.note ? ` · ${esc(a.note)}` : ""}</div></div>`;
}
// Clock time for the line between turns: today's as 14:05, older ones with their date.
function secWhen(iso) {
  const d = new Date(iso), now = new Date();
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  if (d.toDateString() === now.toDateString()) return hm;
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")} ${hm}`;
}
// The scan (`hq feed all`, a job of its own): Zulip mentions and DMs, and Jira issue updates, go to
// the quick notes and are sorted there. Its switch, "scan now" and how the last scan went, as rows of
// class `cls`: "pi" in the ⋯ menu, "ss-row" in the side column.
function secFeedItems(st, cls) {
  const f = st.feed || {};
  const hourly = f.kind === "cron" && f.cron === "0 9-19 * * 1-5";
  const when = hourly ? T("weekdays, hourly 9–19", "工作日 9–19 点每小时") : T("as set in Scheduled", "按定时任务的设置");
  const last = f.last;
  const tip = T("Zulip @-mentions and direct messages, and Jira issues you are assignee, reporter or watcher of: one quick note per conversation or issue. A log line for a task is filed, a todo or a new task waits for your click, the rest is put away.",
    "Zulip 里 @ 你的消息和私信，以及你是经办人、报告人或关注者的 Jira 单子：每个会话或单子记一条。属于某个任务的记进 Log，待办和新任务等你点一下，其余的收起。");
  return `<button class="${cls}" data-action="secretary-feed" data-on="${f.enabled ? "" : "1"}" title="${esc(tip)}"><span class="lbl">${T("Scan into quick notes", "扫进记一笔")}</span><span class="meta">${when}</span><span class="switch ${f.enabled ? "on" : ""}"><span></span></span></button>
    <button class="${cls}" data-action="secretary-feed-now" ${f.running ? "disabled" : ""}><span class="lbl">${f.running ? T("Scanning…", "扫描中…") : T("Scan now", "现在扫一次")}</span>${last ? `<span class="meta one ${last.failed ? "bad" : ""}" title="${esc(last.summary || "")}">${T("last", "上次")} ${ago(last.at)}${last.summary ? ` · ${esc(last.summary)}` : ""}</span>` : ""}</button>`;
}
// Closing finished todos (`hq autoclose`, a job of its own, every 5 minutes): a todo about merging a
// PR, closing a Jira issue or waiting for a Jenkins build is ticked once that is done. Rows as above.
function secCloseItems(st, cls) {
  const f = st.autoclose || {};
  const mins = f.job ? f.everyMinutes : 5;     // not made yet: it will run every 5 minutes
  const every = !f.job || f.kind === "every" ? T(`every ${mins} min`, `每 ${mins} 分钟`) : T("as set in Scheduled", "按定时任务的设置");
  const last = f.last;
  const tip = T("A todo about merging or reviewing a PR is ticked once the PR merged (dropped if it was closed unmerged); one about closing, fixing or following up a Jira issue once the issue is done; one about waiting for a Jenkins build once it passed. A todo with a step after that (\"merge #12, then reinstall\") is left alone, and so is one you reopen. Each tick is a line in the task's log.",
    "待办写的是合并或 review 某个 PR 的，PR 合并后勾掉（没合并就关了的标成不做）；写的是关闭、修复、跟进某个 Jira 单子的，单子完成后勾掉；写的是等某个 Jenkins 构建的，构建成功后勾掉。后面还跟着别的步骤的（“合并 #12，然后重装”）不动，你重新打开的也不动。每次勾选都在任务的 Log 里记一行。");
  return `<button class="${cls}" data-action="secretary-autoclose" data-on="${f.enabled ? "" : "1"}" title="${esc(tip)}"><span class="lbl">${T("Tick finished todos", "自动勾选完成的待办")}</span><span class="meta">${every}</span><span class="switch ${f.enabled ? "on" : ""}"><span></span></span></button>
    <button class="${cls}" data-action="secretary-autoclose-now" ${f.running ? "disabled" : ""}><span class="lbl">${f.running ? T("Checking…", "检查中…") : T("Check now", "现在查一次")}</span>${last ? `<span class="meta one ${last.failed ? "bad" : ""}" title="${esc(last.summary || "")}">${T("last", "上次")} ${ago(last.at)}${last.summary ? ` · ${esc(last.summary)}` : ""}</span>` : ""}</button>`;
}
const localDate = (iso) => { const d = new Date(iso); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
const kindWord = (k) => (k === "weekly" ? T("Weekly report", "周报") : T("Daily report", "日报"));

// The conversation as chat rows: {side: "me" | "it" | "note" | "when", key, html, copy}.
function secRows(m, busy, doing) {
  const st = m.sec || {};
  const items = m.items || (m.msgs || []).map((x) => ({ kind: "msg", ...x }));
  const turns = [];
  for (const it of items) {
    if (it.kind === "msg" && it.role === "user") { turns.push({ user: it, replies: [] }); continue; }
    if (!turns.length) turns.push({ user: null, replies: [] });
    if (it.kind === "msg") turns[turns.length - 1].replies.push(it);
  }
  const card = secId() && taskById(secId());
  const asks = card ? card.asks || [] : [];
  const shown = new Map();   // ask id → the row showing its card
  const rows = [];
  let lastTs = 0;
  const when = (ts) => {
    const t = new Date(ts).getTime();
    if (!isNaN(t) && t - lastTs > 30 * 60 * 1000) rows.push({ side: "when", key: `w|${ts}`, html: esc(secWhen(ts)) });
    if (!isNaN(t)) lastTs = t;
  };
  // The turn it is in: the last one, if its message came after the run began. The transcript lags
  // the run by a few seconds; until the new message is in, every turn shown is finished, and the
  // message just sent from here stands in for it.
  const liveStart = busy && st.runStart ? new Date(st.runStart).getTime() : 0;
  const lastTurn = turns[turns.length - 1];
  const liveIdx = !busy || !lastTurn ? -1
    : liveStart ? (lastTurn.user && new Date(lastTurn.user.ts).getTime() >= liveStart - 1000 ? turns.length - 1 : -1)
    : lastTurn.replies.length ? -1 : turns.length - 1;
  turns.forEach((turn, i) => {
    const live = i === liveIdx;
    let note = null;
    if (turn.user) {
      when(turn.user.ts);
      note = secNote(turn.user.text);
      if (note) rows.push({ side: "note", key: `n|${turn.user.ts}`, html: esc(note.text) });
      else rows.push({ side: "me", key: `u|${turn.user.ts}`, html: esc(turn.user.text).replace(/\n/g, "<br>"), copy: { who: "you", text: turn.user.text } });
    }
    if (live) return;   // its in-between messages stay hidden: the typing bubble stands for them
    // The turn's last reply that says something (one holding only a card update says nothing).
    let reply = null, parts = null;
    for (let j = turn.replies.length - 1; j >= 0 && !reply; j--) {
      const p = secSplit(turn.replies[j].text);
      if (p.text || p.asks.length) { reply = turn.replies[j]; parts = p; }
    }
    if (!reply) return;
    if (!turn.user) when(reply.ts);
    const scope = `${reply.role}|${reply.ts}`;
    if (parts.text) {
      const report = note && note.kind === "report" && (st.reports || []).find((r) => r.date === localDate(reply.ts));
      const html = note && note.kind === "report"
        ? `<div class="report"><div class="rh">📄 <b>${report ? `${kindWord(report.kind)} · ${esc(report.date.slice(5))}` : T("Report", "报告")}</b></div>
            <div class="rb md">${markdown(parts.text, scope)}</div>
            ${report ? `<div class="rf"><button class="lnk" data-action="open" data-path="${esc(report.path)}" title="${T("Open it to edit — it learns from your edits", "打开编辑——它会照你的修改调整写法")}">${T("Open the full report", "打开全文")}</button></div>` : ""}</div>`
        : `<div class="bub md">${markdown(parts.text, scope)}</div>`;
      rows.push({ side: "it", key: `a|${reply.ts}`, html, copy: { who: "it", text: parts.text } });
    }
    // Each line to the ask hq made of it: the same text, closest in time to this reply (an
    // earlier, answered ask can share the text). Asked again, hq keeps one open ask: the newest
    // message holds its card, the older one keeps just the line.
    const at = new Date(reply.ts).getTime();
    for (const line of parts.asks) {
      const plain = `<div class="propose done"><div class="ptext">${esc(askKey(line))}</div></div>`;
      let a = null;
      for (const x of asks) {
        if ((x.session && x.session !== m.sid) || askKey(x.text) !== askKey(line)) continue;
        if (!a || Math.abs(new Date(x.ts).getTime() - at) < Math.abs(new Date(a.ts).getTime() - at)) a = x;
      }
      if (a && shown.has(a.id)) rows[shown.get(a.id)].html = rows[shown.get(a.id)].plain;
      if (a) shown.set(a.id, rows.length);
      rows.push({ side: "it", key: `q|${reply.ts}|${line}`, html: a ? secPropose(a) : plain, plain });
    }
  });
  // Proposals still waiting whose message has scrolled out of what Peek keeps (or that came
  // before this window was set up): at the end, so none is out of reach.
  const left = asks.filter((a) => a.state === "open" && !isLater(a) && !shown.has(a.id));
  if (left.length) {
    rows.push({ side: "note", key: "n|left", html: T("Still waiting on you", "这些还在等你回应") });
    for (const a of left) rows.push({ side: "it", key: `q|left|${a.id}`, html: secPropose(a) });
  }
  const sent = m.sentMsg;
  if (busy && liveIdx < 0 && sent && (!liveStart || sent.at >= liveStart - 2000)) {
    const n = secNote(sent.text);
    rows.push(n ? { side: "note", key: "n|sent", html: esc(n.text) }
                : { side: "me", key: "u|sent", html: esc(sent.text).replace(/\n/g, "<br>"), copy: { who: "you", text: sent.text } });
  }
  if (busy || st.waking) {
    rows.push({ side: "it", key: "typing", typing: true, html: `<div class="bub typing" aria-label="${T("typing", "正在输入")}"><i></i><i></i><i></i></div>`,
                doing: st.waking && !busy ? T("Carrying out what you said yes to…", "去办你同意的事…") : doing.text });
  } else if (st.last && (st.last.failed || st.last.status === "skipped")) {
    rows.push({ side: "note", key: `x|${st.last.at}`, warn: true,
                html: `<span class="warn">${st.last.status === "skipped" ? T("Your last message was skipped:", "上一条被跳过：") : T("Its last reply didn't finish:", "上一次没回完：")}</span> ${esc(st.last.summary || st.last.status)}` });
  }
  return rows;
}

// The window. Same data as Peek (the session's transcript, its card, its job), drawn as a chat.
function drawSecretary(toBottom) {
  const m = ui.modal, st = m.sec || {};
  const box = $("#modal");
  const active = document.activeElement;
  const typing = active && box.contains(active) && active.tagName === "TEXTAREA" ? [active.selectionStart, active.selectionEnd, active.dataset.key] : null;
  const taScrolls = textScrolls(box);
  const scroll = peekScrollGrab(box, m);
  const run = peekRun(m, {});
  const busy = run.state === "busy";
  const doing = secDoing(run.current);
  const lastAt = (ui.secGlance && ui.secGlance.lastAt) || (st.last && st.last.at);
  const mood = busy || st.waking ? doing.mood : secAsleep(lastAt) ? "sleeping" : "idle";
  const failed = !busy && st.last && (st.last.failed || st.last.status === "skipped");
  const status = busy ? doing.text : st.waking ? T("Carrying out what you said yes to in a moment…", "马上去办你同意的事…")
    : failed ? T("Its last reply didn't finish", "上一次没回完")
    : mood === "sleeping" ? T(`Resting · last replied ${ago(lastAt)} — a message wakes it`, `在休息 · ${ago(lastAt)}回过话，发消息就会叫醒它`)
    : lastAt ? T(`Here · last replied ${ago(lastAt)}`, `在 · ${ago(lastAt)}回过话`) : T("Here", "在");

  let rows = m.msgs === null ? null : secRows(m, busy, doing);
  if (rows && !rows.some((r) => r.side !== "when")) {
    rows = [{ side: "it", key: "intro", html: `<div class="bub">${T("Hi — I keep an eye on the board for you. Ask me how a task is doing, what is waiting on you, or what looks stuck. If something on the board should change, I'll ask you first.",
      "你好，我替你盯着看板。可以问我哪个任务怎么样了、什么在等你、哪些看着卡住了。看板上要改什么，我会先问你。")}</div>` }];
  }
  // Its face goes on the last of its rows in a run, like a chat app.
  m.chat = [];
  const body = rows === null ? `<div class="empty">${T("Loading…", "加载中…")}</div>` : rows.map((r, i) => {
    if (r.side === "when") return `<div class="pmsg when">${r.html}</div>`;
    if (r.side === "note") return `<div class="pmsg snote ${r.warn ? "warn" : ""}">${r.html}</div>`;
    const ci = r.copy ? m.chat.push(r.copy) - 1 : -1;
    const copy = ci >= 0 ? `<button class="copy" data-action="sec-copy" data-i="${ci}" title="${T("Copy this message", "复制这条消息")}">${T("Copy", "复制")}</button>` : "";
    const inner = copy && /^<div class="(bub|report)/.test(r.html) ? r.html.replace(/<\/div>$/, `${copy}</div>`) : r.html;
    if (r.side === "me") return `<div class="pmsg row me"><div class="bub">${r.html}${copy}</div></div>`;
    const lastOfRun = !rows[i + 1] || rows[i + 1].side !== "it";
    return `<div class="pmsg row it ${lastOfRun ? "" : "cont"}">${lastOfRun ? face(r.typing ? mood : "idle", 28) : `<span class="av-gap"></span>`}<div class="it-col">${inner}${r.doing ? `<div class="doing">${esc(r.doing)}</div>` : ""}</div></div>`;
  }).join("");
  m.keys = rows ? rows.map((r) => r.key) : null;

  const sch = st.schedule || {}, reports = st.reports || [];
  const hm = `${String(sch.hour ?? 18).padStart(2, "0")}:${String(sch.minute ?? 30).padStart(2, "0")}`;
  const when = sch.kind === "weekdays" ? T(`weekdays ${hm}`, `工作日 ${hm}`) : sch.kind === "daily" ? T(`daily ${hm}`, `每天 ${hm}`) : T("as set in Scheduled", "按定时任务的设置");
  const dayWord = (date) => { const n = Math.round((new Date(localDate(new Date().toISOString())) - new Date(date)) / 86400000);
    return n === 0 ? T("today", "今天") : n === 1 ? T("yesterday", "昨天") : T(`${n} days ago`, `${n} 天前`); };
  const repPop = `<div class="pop" role="menu"><div class="ph">${T("Reports", "报告")}</div>
    ${reports.length ? reports.map((r) => `<button class="pi" data-action="open" data-path="${esc(r.path)}" title="${T("Open it to edit — it learns from your edits", "打开编辑——它会照你的修改调整写法")}">${esc(r.date.slice(5))} ${kindWord(r.kind)}<span class="meta">${dayWord(r.date)}</span></button>`).join("")
      : `<div class="pi off">${T("None yet", "还没有")}</div>`}
    <hr><button class="pi" data-action="secretary-report-now" ${busy || ui.sending.has(SEC) ? "disabled" : ""}>${T("Write one now", "让它现在写一份")}</button></div>`;
  const MEM = { "profile.md": T("About you", "关于你"), "people.md": T("Colleagues", "同事"), "playbooks.md": T("Recurring processes", "常做的流程"), "reports.md": T("How reports are written", "报告怎么写") };
  // Always in this order (hq's JSON doesn't keep one); anything new after them, by name.
  const memRank = (f) => { const i = Object.keys(MEM).indexOf(f); return i < 0 ? 99 : i; };
  const mem = Object.keys(st.files || {}).filter((f) => st.files[f]).sort((a, b) => memRank(a) - memRank(b) || a.localeCompare(b));
  const evening = sch.reports === false
    // Its scheduled runs ask what you wrote in Scheduled; turning reports on replaces that.
    ? `<button class="pi" data-action="secretary-reports" data-on="1" title="${T("Turning reports on replaces the prompt you gave it in Scheduled", "开启定时报告会替换你在“定时任务”里给它的 prompt")}">${sch.enabled ? T("Scheduled runs use your own prompt — write reports instead", "定时运行用的是你自己的 prompt——改成写报告") : T("Evening report", "傍晚写报告")}<span class="switch"><span></span></span></button>`
    : `<button class="pi" data-action="secretary-reports" data-on="${sch.enabled ? "" : "1"}" title="${sch.next ? T(`Next: ${esc(sch.next)}`, `下一次：${esc(sch.next)}`) : ""}"><span class="lbl">${T("Evening report", "傍晚写报告")}</span><span class="meta">${when}${T(", weekly on Fridays", "，周五写周报")}</span><span class="switch ${sch.enabled ? "on" : ""}"><span></span></span></button>`;
  const morePop = `<div class="pop" role="menu">${evening}<hr><div class="ph">Zulip · Jira</div>${secFeedItems(st, "pi")}<hr><div class="ph">${T("Finished todos", "完成的待办")}</div>${secCloseItems(st, "pi")}
    ${mem.length ? `<hr><div class="ph">${T("What it remembers", "它记着的")}</div>${mem.map((f) => `<button class="pi" data-action="open" data-path="${esc(st.memory + "/" + f)}" title="${T("Open it to edit", "打开编辑")}">${esc(MEM[f] || f)}<span class="meta">${esc(f.replace(/\.md$/, ""))}</span></button>`).join("")}` : ""}
    <hr><button class="pi" data-action="copy-all">${T("Copy the conversation", "复制整段对话")}</button></div>`;
  const ibtn = (pop, label, svg) => `<div class="popwrap"><button class="ibtn" data-action="sec-pop" data-pop="${pop}" aria-expanded="${m.pop === pop}" aria-label="${label}" title="${label}">${svg}</button>${m.pop === pop ? (pop === "rep" ? repPop : morePop) : ""}</div>`;

  const watch = st.state || [];
  const watchHtml = watch.length ? `<div class="watch ${m.watchOpen ? "open" : ""}">
      <div class="watch-h" data-action="sec-watch"><span class="eye">◉</span><span>${T(`Keeping an eye on ${watch.length} thing${watch.length === 1 ? "" : "s"}`, `替你盯着 ${watch.length} 件事`)}${m.watchOpen ? "" : ` · ${esc(watch[0])}`}</span><span class="car">${m.watchOpen ? "▴" : "▾"}</span></div>
      ${m.watchOpen ? `<ul>${watch.map((l) => `<li>${esc(l)}</li>`).join("")}</ul>` : ""}</div>` : "";

  // The side column (wide windows only): what it watches, proposals still open, its reports,
  // the Zulip · Jira scan and the files it remembers — the same things the menus above hold, in view.
  const card = secId() && taskById(secId());
  const secAsks = (card ? card.asks || [] : []).filter((a) => a.state === "open" && !isLater(a));
  const sideRes = RESOLUTIONS.filter(([r]) => r === "do" || r === "drop");
  const sideSec = (title, n, inner) => `<section class="ss"><div class="ss-h">${title}${n ? `<span class="meta">${n}</span>` : ""}</div>${inner}</section>`;
  const sideHtml = `<aside class="sec-side">
    ${sideSec(T("Keeping an eye on", "替你盯着"), watch.length, watch.length ? `<ul class="ss-watch">${watch.map((l) => `<li>${esc(l)}</li>`).join("")}</ul>` : `<div class="ss-empty">${T("Nothing right now.", "现在没有。")}</div>`)}
    ${sideSec(T("Waiting on your answer", "待回应建议"), secAsks.length, secAsks.length ? secAsks.map((a) => `<div class="ss-prop"><div class="t">${esc(askKey(a.text))}</div>
        <div class="acts">${sideRes.map(([r, label, tip]) => `<button class="pb ${r === "do" ? "yes" : ""}" title="${esc(tip)}" data-action="resolve" data-id="${esc(a.id)}" data-res="${r}" ${ui.resolving.has(a.id) ? "disabled" : ""}>${label}</button>`).join("")}</div></div>`).join("")
      : `<div class="ss-empty">${T("No proposal waiting.", "没有等你回应的建议。")}</div>`)}
    ${sideSec(T("Reports", "报告"), reports.length, `${reports.slice(0, 6).map((r) => `<button class="ss-row" data-action="open" data-path="${esc(r.path)}" title="${T("Open it to edit — it learns from your edits", "打开编辑——它会照你的修改调整写法")}">${esc(r.date.slice(5))} ${kindWord(r.kind)}<span class="meta">${dayWord(r.date)}</span></button>`).join("")}
      ${evening.replace('class="pi"', 'class="ss-row"')}
      <button class="ss-row ss-act" data-action="secretary-report-now" ${busy || ui.sending.has(SEC) ? "disabled" : ""}>${T("Write one now", "让它现在写一份")}</button>`)}
    ${sideSec("Zulip · Jira", 0, secFeedItems(st, "ss-row"))}
    ${sideSec(T("Finished todos", "完成的待办"), 0, secCloseItems(st, "ss-row"))}
    ${mem.length ? sideSec(T("What it remembers", "它记得的"), 0, mem.map((f) => `<button class="ss-row" data-action="open" data-path="${esc(st.memory + "/" + f)}" title="${T("Open it to edit", "打开编辑")}">${esc(MEM[f] || f)}<span class="meta">${esc(f.replace(/\.md$/, ""))}</span></button>`).join("")) : ""}
  </aside>`;

  const key = "msg:" + SEC;
  const keepDraft = box.querySelector(".c-foot textarea") ? null : draft(key);
  const QUICK = [[T("What is waiting on me?", "有什么在等我？")], [T("What looks stuck?", "哪些看着卡住了？")], [T("What happened today?", "今天做了什么？")],
                 [T("Draft a message", "帮我起草消息"), T("Draft a message to ", "帮我起草一条消息，发给 ")]];
  const quick = busy || st.waking ? "" : `<div class="quick">${QUICK.map(([label, fill]) => `<button class="chipq" data-action="sec-quick" ${fill ? `data-fill="${esc(fill)}"` : `data-text="${esc(label)}"`}>${esc(label)}</button>`).join("")}</div>`;
  const sendBtn = busy
    ? `<button class="sendc stop" data-action="secretary-stop" title="${T("Stop its reply", "让它停下")}" aria-label="${T("Stop", "停止")}"><svg viewBox="0 0 24 24"><rect x="7" y="7" width="10" height="10" rx="2" fill="currentColor"/></svg></button>`
    : `<button class="sendc" data-action="send" data-session="${SEC}" ${ui.sending.has(SEC) || st.waking ? "disabled" : ""} title="${T("Send (Enter)", "发送（回车）")}" aria-label="${T("Send", "发送")}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg></button>`;

  box.innerHTML = `<div class="panel sec-chat" role="dialog" aria-label="${T("Secretary", "秘书")}">
    <div class="c-head">
      ${m.back ? `<button class="btn small ghost" data-action="modal-back" title="${T("Back", "返回")}">←</button>` : ""}
      <span class="secface${busy ? " ring" : ""}">${face(mood, 44, mood === "sleeping" ? "dim" : "")}</span>
      <div class="c-who"><div class="c-name">${T("Secretary", "秘书")}</div>
        <div class="c-status"><span class="sdot ${busy || st.waking ? "busy" : failed ? "bad" : mood === "sleeping" ? "off" : ""}"></span><span>${esc(status)}</span></div></div>
      ${ibtn("rep", T("Reports", "报告"), `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5M10 13h6M10 17h6"/></svg>`)}
      ${ibtn("more", T("More", "更多"), `<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></svg>`)}
      <button class="ibtn" data-action="close-modal" aria-label="${T("Close", "关闭")}" title="${T("Close (Esc)", "关闭 (Esc)")}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
    </div>
    <div class="sec-wrap"><div class="sec-main">
    ${watchHtml}
    <div class="peek-body c-body">${body}</div>
    <div class="c-foot">${quick}
      <div class="inrow"><textarea class="grow" rows="1" data-key="${key}" data-session="${SEC}" placeholder="${T("Message your secretary — paste or drop images too", "跟秘书说点什么——也可以粘贴或拖入图片")}">${esc(keepDraft ?? draft(key))}</textarea>${sendBtn}</div>
      ${attachStrip(SEC)}
    </div></div>${sideHtml}</div>
  </div>`;
  box.hidden = false;
  fitAllGrow(box);
  if (typing) {
    const ta = [...box.querySelectorAll("textarea")].find((x) => x.dataset.key === typing[2]);
    if (ta) { ta.focus(); ta.setSelectionRange(typing[0], typing[1]); }
  }
  restoreTextScrolls(box, taScrolls);
  peekScrollPut(box, m, scroll, toBottom);
}
// preset: a message of the window's own ("Write one now", a quick question); the draft in the
// box stays as it is.
async function sendSecretary(preset) {
  if (ui.sending.has(SEC)) return;
  if (ui.modal && ui.modal.secretary && ui.modal.sec && ui.modal.sec.running) {
    return toast(T("It is still replying — wait for it, or stop it", "它还在回复——等它说完，或者先让它停下"), true);
  }
  const key = "msg:" + SEC;
  const text = preset || (ui.drafts[key] || "").trim();
  const images = preset ? [] : ui.atts[SEC] || [];
  if (!text && !images.length) return;
  const message = [text, ...images.map((a) => a.path)].filter(Boolean).join("\n");
  ui.sending.add(SEC);
  if (ui.modal && ui.modal.secretary) drawPeek(true);
  try {
    await api("secretary-send", { text: message });
    if (!preset) { delete ui.drafts[key]; delete ui.atts[SEC]; }
    if (ui.modal && ui.modal.secretary && ui.modal.sec) { ui.modal.sec.running = true; ui.modal.sentMsg = { text: message, at: Date.now() }; }
  } catch (e) {
    toast(String(e.message || e), true);
  } finally {
    ui.sending.delete(SEC);
  }
  if (ui.modal && ui.modal.secretary) { drawPeek(true); refreshPeek(); }
}

// ------------------------------------------------------------------ peek activity
// Between the messages, Claude's tool calls: one line each, a run of them folded to its newest
// line, a click on a line opens its input and output (fetched then: the list the board polls
// stays summaries). Above the conversation, one line on what the turn is doing now and, when
// Claude keeps one, its todo list.
function fmtDur(sec) {
  sec = Math.max(0, Math.round(sec));
  if (sec < 60) return `${sec}s`;
  if (sec < 3600) return `${Math.floor(sec / 60)}m ${String(sec % 60).padStart(2, "0")}s`;
  return `${Math.floor(sec / 3600)}h ${String(Math.floor((sec % 3600) / 60)).padStart(2, "0")}m`;
}
const fmtTok = (n) => (n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : String(n || 0));
const secsSince = (iso) => (Date.now() - new Date(iso).getTime()) / 1000;
const secsBetween = (a, b) => (new Date(b).getTime() - new Date(a).getTime()) / 1000;
function peekBlocks(items) {
  const out = [];
  for (const it of items) {
    const last = out[out.length - 1];
    if (it.kind !== "tool") out.push(it);
    else if (last && last.kind === "group") last.tools.push(it);
    else out.push({ kind: "group", tools: [it] });
  }
  return out;
}
// What the session is doing now, as far as Peek can tell: its state, and the call it is in.
function peekRun(m, s) {
  const state = m.secretary ? (m.sec && m.sec.running ? "busy" : "") : m.live ? liveState(s) : "";
  const turnOpen = state === "busy" || state === "waiting";
  const pending = turnOpen ? (m.items || []).filter((t) => t.kind === "tool" && t.status === "pending") : [];
  return { state, turnOpen, pending: new Set(pending.map((t) => t.id)), current: pending[pending.length - 1] || null };
}
// A call that is still going: in this turn, or a background agent / command not yet finished.
const toolActive = (t, run) => run.pending.has(t.id) || (t.status === "background" && run.state !== "");
function toolRow(t, m, run) {
  const open = m.openTools.has(t.id);
  let ico, cls, time = "", tip = "";
  if (run.pending.has(t.id) && run.state === "waiting" && t === run.current) {
    ico = "?"; cls = "wait"; tip = T("Waiting for you in the terminal", "在终端里等你");
    time = `<span data-since="${esc(t.ts)}">${fmtDur(secsSince(t.ts))}</span>`;
  } else if (run.pending.has(t.id)) {
    ico = '<span class="pspin"></span>'; cls = "run"; tip = T("Running", "运行中");
    time = `<span data-since="${esc(t.ts)}">${fmtDur(secsSince(t.ts))}</span>`;
  } else if (t.status === "background") {
    ico = "⧗"; cls = "bg"; tip = T("Running in the background", "在后台运行");
    if (run.state) time = `<span data-since="${esc(t.ts)}">${fmtDur(secsSince(t.ts))}</span>`;
  } else if (t.status === "pending") {
    ico = "–"; cls = "cut"; tip = T("Stopped before it returned", "没等到结果就停了");
  } else if (t.status === "stopped") {
    ico = "■"; cls = "cut"; tip = T("Stopped", "已停止");
    if (t.endTs && secsBetween(t.ts, t.endTs) >= 1) time = fmtDur(secsBetween(t.ts, t.endTs));
  } else {
    ico = t.status === "error" ? "✗" : "✓"; cls = t.status === "error" ? "err" : "ok";
    tip = t.status === "error" ? T("Failed, or you declined it", "失败了，或者被你拒绝了") : T("Done", "完成");
    if (t.endTs && secsBetween(t.ts, t.endTs) >= 1) time = fmtDur(secsBetween(t.ts, t.endTs));
  }
  if (t.bg) tip += ` (${t.bg})`;
  return `<div class="ptool ${cls}${open ? " open" : ""}" data-action="ptool" data-id="${esc(t.id)}" title="${esc(tip)}">
      <span class="pico">${ico}</span><b class="pname">${esc(t.title)}</b><span class="plabel">${esc(t.label || "")}</span>${t.stat ? `<span class="pstat">${esc(t.stat)}</span>` : ""}<span class="ptime">${time}</span>
    </div>${open ? toolDetail(t, m) : ""}`;
}
function toolDetail(t, m) {
  const d = m.details[t.id];
  if (!d) return `<div class="pdetail"><div class="empty">${T("Loading…", "加载中…")}</div></div>`;
  if (d.err) return `<div class="pdetail"><div class="empty">${esc(d.err)}</div></div>`;
  const LIMIT = 4000;
  const part = (label, text, total, which) => {
    if (!text) return "";
    const full = m.fullTools.has(`${t.id}|${which}`);
    const shown = full ? text : text.slice(0, LIMIT);
    const cut = (total || text.length) - shown.length;
    const capped = (total || 0) > text.length;   // hq sends at most 100k / 200k characters
    const diff = which === "out" && ["Edit", "MultiEdit", "Write"].includes(d.name) && !d.error;
    const body = diff ? shown.split("\n").map((ln) => `<span class="${ln.startsWith("+") ? "dadd" : ln.startsWith("-") ? "drem" : ln.startsWith("@@") ? "dhunk" : ""}">${esc(ln)}</span>`).join("\n") : esc(shown);
    return `<div class="pdlabel">${label}
        <button class="btn small ghost" data-action="copy-tool" data-id="${esc(t.id)}" data-which="${which}">${T("Copy", "复制")}</button>
        ${cut > 0 && !full ? `<button class="btn small ghost" data-action="tool-full" data-id="${esc(t.id)}" data-which="${which}">${T("Show all", "全部显示")}</button>` : ""}</div>
      <pre class="pdpre">${body}${cut > 0 ? `<span class="pdcut">\n… ${T(`${cut.toLocaleString()} more characters`, `还有 ${cut.toLocaleString()} 个字符`)}${full && capped ? T(" — too long to show here; the full text is in the session's transcript", "——太长，这里不显示；完整内容在 session 的对话记录里") : full ? "" : capped ? T(" — Show all or Copy for more", "——全部显示或复制可看更多") : T(" — Show all or Copy for the rest", "——全部显示或复制可看完整内容")}</span>` : ""}</pre>`;
  };
  return `<div class="pdetail">${part(T("Input", "输入"), d.input, d.inputChars, "in")}${part(T("Output", "输出"), d.output, d.outputChars, "out")
    || (d.done ? "" : `<div class="pdlabel">${T("No output yet", "还没有输出")}</div>`)}</div>`;
}
function toolGroup(g, m, run) {
  const n = g.tools.length;
  if (n === 1) return toolRow(g.tools[0], m, run);
  const key = g.tools[0].id;
  const open = m.openGroups.has(key);
  // Folded: the newest call, plus any still going (the rest of the run is one line).
  const shown = open ? g.tools : g.tools.filter((t, i) => i === n - 1 || toolActive(t, run));
  const tally = {};
  for (const t of g.tools) tally[t.title] = (tally[t.title] || 0) + 1;
  const kinds = Object.entries(tally).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([k, c]) => (c > 1 ? `${esc(k)} ×${c}` : esc(k))).join(" · ");
  const failed = g.tools.filter((t) => t.status === "error").length;
  const hidden = n - shown.length;
  // Every call in the run still going: all are shown, so "0 earlier steps" would say nothing.
  const label = open || !hidden ? T(`${n} steps`, `${n} 步`) : T(`${hidden} earlier step${hidden === 1 ? "" : "s"}`, `前面还有 ${hidden} 步`);
  return `<div class="pgroup" data-action="pgroup" data-key="${esc(key)}"><span class="pcaret">${open ? "▾" : hidden ? "▸" : ""}</span> ${label} · ${kinds}${failed ? ` · <span class="bad">${T(`${failed} failed`, `${failed} 个失败`)}</span>` : ""}</div>`
    + shown.map((t) => toolRow(t, m, run)).join("");
}
// The line under the title: what it is doing now, how long this turn has run, its tokens.
function peekStatus(m, s, run) {
  if (m.msgs === null) return "";
  const turn = m.turn;
  let lead, cls;
  if (run.state === "busy") {
    const c = run.current;
    cls = "busy";
    lead = c ? `${T("Running", "正在运行")} <b>${esc(c.title)}</b> <span class="plabel">${esc(c.label || "")}</span>` : T("Thinking…", "思考中…");
  } else if (run.state === "waiting") {
    cls = "wait";
    lead = s.waitingOn ? `${T("Waiting for your OK:", "等你批准：")} <span class="plabel">${esc(s.waitingOn)}</span>` : T("Waiting for your answer in the terminal", "在终端里等你回答");
  } else if (m.live) {
    cls = "idle"; lead = T("Idle — its turn is over", "空闲——这一轮已结束");
  } else {
    cls = "ended"; lead = m.starting ? T("Starting…", "启动中…") : T("Not running", "没在运行");
  }
  const bits = [];
  if (turn) {
    if (run.turnOpen && !turn.done) bits.push(`<span title="${T("This turn so far", "这一轮已用时间")}">⏱ <span data-since="${esc(turn.start)}">${fmtDur(secsSince(turn.start))}</span></span>`);
    else bits.push(T(`last turn ${turn.ms ? fmtDur(turn.ms / 1000) : ""}`, `上一轮 ${turn.ms ? fmtDur(turn.ms / 1000) : ""}`).trim());
    bits.push(`<span title="${T("Tokens Claude wrote this turn (thinking included)", "这一轮 Claude 输出的 token（含思考）")}">↓ ${fmtTok(turn.tokens)} tokens</span>`);
    if (turn.context) bits.push(`<span title="${T("Context size at its latest reply", "最近一次回复时的上下文大小")}">${T("context", "上下文")} ${fmtTok(turn.context)}</span>`);
  }
  return `<div class="pstatus ${cls}"><span class="pdot"></span><span class="plead">${lead}</span><span style="flex:1"></span><span class="pbits">${bits.join(" · ")}</span></div>`;
}
// Claude's own todo list (TodoWrite / TaskCreate), as it last left it.
function peekTodos(m) {
  const td = m.todos;
  if (!td || !td.length) return "";
  const done = td.filter((t) => t.status === "completed").length;
  const cur = td.find((t) => t.status === "in_progress");
  const now = cur ? ` · ${esc(cur.active || cur.text)}` : done === td.length ? T(" · all done", " · 全部完成") : "";
  const mark = { completed: "☑", in_progress: "◐" };
  return `<div class="ptodo">
    <div class="ptodo-head" data-action="ptodo"><span class="pcaret">${m.todoOpen ? "▾" : "▸"}</span> ${T("Claude's todos", "Claude 的待办")} ${done}/${td.length}${now}</div>
    ${m.todoOpen ? `<div class="ptodo-list">${td.map((t) => `<div class="ptodo-item ${esc(t.status)}"><span>${mark[t.status] || "☐"}</span> ${esc(t.text)}</div>`).join("")}</div>` : ""}
  </div>`;
}
// Messages waiting in Claude Code's queue (sent while it was busy, not taken in yet), oldest
// first, just above the reply box: what it will read when this turn ends. Only while the session
// is live and in a turn: a queue never outlives one.
function peekQueue(m, s) {
  const q = m.queued;
  const st = liveState(s);
  if (!m.live || !q || !q.length || (st !== "busy" && st !== "waiting")) return "";
  return `<div class="pqueue">
    <div class="pqueue-head">${T(`Queued · ${q.length} — it reads ${q.length === 1 ? "this" : "these"} when the turn ends`, `排队中 · ${q.length} 条——这一轮结束后它会读到`)}</div>
    ${q.map((x) => `<div class="pqueue-item"><span class="pqueue-text">${esc(x.text)}</span><span class="pqueue-at" data-ago="${esc(x.ts || "")}">${ago(x.ts)}</span></div>`).join("")}
  </div>`;
}
const toolStatus = (m, id) => ((m.items || []).find((x) => x.id === id) || {}).status;
async function loadToolDetail(m, id) {
  const st = toolStatus(m, id);   // before the fetch: a call that ends meanwhile is fetched again
  try { m.details[id] = await apiJSON("peek-tool", { session: m.sid, id }); } catch (e) { m.details[id] = { err: String(e.message || e) }; }
  m.details[id]._st = st;
  if (ui.modal === m) redrawPeek(m);
}
// Running times tick between refreshes without rebuilding the window.
setInterval(() => {
  if (!ui.modal || ui.modal.type !== "peek") return;
  document.querySelectorAll("#modal [data-since]").forEach((el) => { el.textContent = fmtDur(secsSince(el.dataset.since)); });
}, 1000);

document.addEventListener("mousedown", (ev) => {
  // Backdrop only: a drag that starts inside the panel (selecting text) must not close it.
  if (ui.finishAsk && ev.target === $("#confirm")) return answerFinishAsk(null);
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
  if (!t) { closePeek(); return toast(T("That task is gone", "这个任务已经不在了"), true); }
  const ask = m.kind === "ask" ? (t.asks || []).find((a) => a.id === m.id) : null;
  const todo = m.kind === "todo" ? t.todos.find((x) => x.i === m.i) : null;
  const heading = m.kind === "ask" ? `Ask ${esc(m.id)}` : T("Your todo", "你的待办");
  const text = ask ? ask.text : todo ? todo.text : t.waiting_on_me;
  const live = ui.sessions.filter((s) => s.task === t.id);
  const liveIds = new Set(live.map((s) => s.sessionId.slice(0, 8)));
  const past = list(t.sessions).filter((p) => !liveIds.has(String(p).slice(0, 8)));
  const askSession = ask && ask.session ? ui.sessions.find((s) => s.sessionId === ask.session) : null;
  const sessBtn = (sid, label, isLive) =>
    `<button class="btn small" data-action="ctx-peek" data-session="${esc(sid)}">${label}</button>` +
    (isLive ? ` <button class="btn small ghost" data-action="jump" data-session="${esc(sid)}">Jump</button>` : "");
  const origin = !ask ? "" : `<section class="ctx-sec">
      <h4>${T("Where it came from", "从哪里来的")}</h4>
      <div class="meta">${T(`Raised ${ago(ask.ts)}${ask.session ? ` in ${askSession ? `<b>${esc(askSession.title || askSession.project)}</b> (live)` : `session ${esc(ask.session.slice(0, 8))} (ended)`}` : ""}`,
        `${ask.session ? `在${askSession ? ` <b>${esc(askSession.title || askSession.project)}</b>（运行中）` : ` session ${esc(ask.session.slice(0, 8))}（已结束）`}里，` : ""}${ago(ask.ts)}提出`)}</div>
      ${ask.session ? `<div class="row" style="margin:6px 0">${sessBtn(ask.session, T("Open that conversation", "打开那段对话"), Boolean(askSession))}</div>` : ""}
      ${ask.context ? `<div class="md quote">${markdown(ask.context)}</div>`
        : `<div class="empty">${T("The reply that asked this wasn't recorded (asks from before this was added) — open the conversation above.", "提出这个问题的那条回复没有记录下来（这个功能加上之前的 ask）——打开上面的对话看。")}</div>`}
    </section>`;
  box.innerHTML = `<div class="panel" role="dialog" aria-label="${T("Context", "上下文")}">
    <div class="phead">
      <div><div class="meta">${heading} · <span class="chip link" data-action="ctx-goto" data-task="${esc(t.id)}">${esc(t.id)}</span>${esc(t.title)}</div>
        <div class="stitle ctx-title">${esc(text || "")}</div></div>
      <span style="flex:1"></span>
      <button class="btn small" data-action="ctx-goto" data-task="${esc(t.id)}">${T("Show task", "看任务")}</button>
      <button class="btn small" data-action="open" data-path="${esc(t.path)}">${T("Open card", "打开任务卡")}</button>
      <button class="btn small ghost" data-action="close-modal" title="${T("Close (Esc)", "关闭 (Esc)")}">✕</button>
    </div>
    <div class="peek-body">
      ${origin}
      <section class="ctx-sec">
        <h4>${T("Task", "任务")}</h4>
        <div class="meta">${esc(LABEL[t.status] || t.status)} · ${T(`updated ${t.age_days ?? "?"}d ago`, `${t.age_days ?? "?"} 天前更新`)}</div>
        ${t.next ? `<div style="margin-top:4px">${T("Next: ", "下一步：")}${inline(t.next)}</div>` : ""}
        ${t.waiting_on_me ? `<div style="color:var(--amber)">${T("Waiting on you: ", "等你：")}${inline(t.waiting_on_me)}</div>` : ""}
      </section>
      <section class="ctx-sec">
        <h4>${T("Sessions on this task", "这个任务的 session")}</h4>
        ${live.map((s) => `<div class="row ctx-s">${dot(s)}<span>${esc(s.title || s.project)}</span><span class="meta">${esc(statusWord(s))}${ctxTag(s)}</span>${sessBtn(s.sessionId, T("Conversation", "对话"), true)}</div>`).join("")}
        ${past.map((p) => `<div class="row ctx-s"><span class="dot"></span><span class="meta">session ${esc(String(p).slice(0, 8))} · ${T("ended", "已结束")}</span>${sessBtn(String(p), T("History", "历史"), false)}</div>`).join("")}
        ${!live.length && !past.length ? `<div class="empty">${T("No session has been bound to this task yet.", "这个任务还没有绑定过 session。")}</div>` : ""}
      </section>
      <section class="ctx-sec">
        <h4>${T("Task card", "任务卡")}</h4>
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

// What a folded hq block says on its one line: how many answers, or which card fields changed.
function hqSummary(lang, items) {
  if (lang === "hq-resolved") return T(`${items.length} answer${items.length === 1 ? "" : "s"}`, `${items.length} 条`);
  const tally = {};
  // The keys as hq's update_lines reads them: any case, a full-width colon, spaces before it.
  for (const i of items) {
    const m = /^([A-Za-z]+)\s*[:：]/.exec(i);
    const k = m ? m[1].toLowerCase() : i.split(/\s/)[0].slice(0, 12);
    tally[k] = (tally[k] || 0) + 1;
  }
  return Object.entries(tally).map(([k, c]) => esc(c > 1 ? `${k} ×${c}` : k)).join(" · ");
}
function hashText(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}

// `scope` names the message the text is from, so a folded block's open state is that message's
// alone: five replies ending in the same one-line `touch` update must not open together.
function markdown(text, scope = "") {
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
        const title = { "hq-asks": T("Asked you", "问了你"), "hq-resolved": T("Answers recorded", "已记下回答"), "hq-update": T("Card updated", "任务卡已更新") }[lang];
        const list = `<ul>${items.map((i) => `<li>${inline(i)}</li>`).join("")}</ul>`;
        // Questions stay open: they are what the reader has to act on. Recorded answers and card
        // updates are bookkeeping — folded to one line that says what changed, opened on a click.
        if (lang === "hq-asks") { out.push(`<div class="hqblock ${lang}"><div class="hqb-t">${title}</div>${list}</div>`); return; }
        const key = `${scope}|${lang}|${hashText(code)}`;
        const open = ui.hqOpen.has(key);
        out.push(`<div class="hqblock ${lang} fold ${open ? "open" : ""}"><div class="hqb-t hqb-fold" data-action="hqfold" data-key="${esc(key)}" title="${T("Click to show or hide", "点击展开或收起")}"><span class="pcaret">${open ? "▾" : "▸"}</span> ${title} · ${hqSummary(lang, items)}</div>${list}</div>`);
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

// Bring a task into view: its details open in the drawer, over whichever page is showing, and its
// card — if the page has one — scrolls into view and flashes. A search that hides it is cleared.
function revealTask(id) {
  const t = taskById(id);
  if (!t) return toast(T(`${id} not found`, `找不到 ${id}`), true);
  // The secretary's card isn't in the lists: its window is where it lives.
  if (id === secId()) return openSecretary();
  if (!taskMatches(t)) ui.filter = $("#search").value = "";
  openDrawer(id);
}

// Scrolls a card into view inside its column and flashes it.
function flashCard(node) {
  node.scrollIntoView({ behavior: "smooth", block: "nearest" });
  node.classList.add("flash");
  setTimeout(() => node.classList.remove("flash"), 1400);
}

// Text boxes that may hold several lines grow with what is in them — up to five lines, then
// they scroll (the cap is max-height in CSS). Run after every rebuild too: a box redrawn with a
// three-line draft would otherwise come back one line tall.
function fitGrow(el) {
  // The conversation above a growing reply box shrinks; if it was at the bottom, keep it there.
  const body = el.closest(".panel")?.querySelector(".peek-body");
  const pinned = body && body.scrollHeight - body.scrollTop - body.clientHeight < 12;
  // Empty: one line, whatever the placeholder would wrap to in a narrow column.
  // Measuring collapses the box for a moment, which loses its own scroll: past the five lines it
  // grows to, typing on the last line showed the first ones.
  const top = el.scrollTop;
  if (!el.value) el.style.height = "";
  else { el.style.height = "auto"; el.style.height = el.scrollHeight + 2 + "px"; }
  el.scrollTop = top;
  if (pinned) body.scrollTop = body.scrollHeight;
}
function fitAllGrow(root = document) { root.querySelectorAll("textarea.grow").forEach(fitGrow); }
// Boxes are rebuilt with the rest of the page (every refresh, every new message in Peek), and a
// new box starts scrolled to its top: a draft longer than the five lines a box grows to showed its
// first lines while you typed at its end. These keep each box where it was scrolled, by its key
// and whether it is in the conversation window (a session's box in the Sessions column shares
// its key with the window's reply box).
function textScrolls(root) {
  return [...root.querySelectorAll("textarea[data-key]")].filter((t) => t.scrollTop > 0)
    .map((t) => [t.dataset.key, Boolean(t.closest("#modal")), t.scrollTop]);
}
function restoreTextScrolls(root, saved) {
  for (const [key, inModal, top] of saved) {
    root.querySelectorAll(`textarea[data-key="${CSS.escape(key)}"]`).forEach((t) => {
      if (Boolean(t.closest("#modal")) === inModal) t.scrollTop = top;
    });
  }
}

// The button a two-click confirm is waiting on, and how it is drawn after every rebuild.
function confirmKey(d) { return Object.keys(d).filter((k) => k !== "confirm").sort().map((k) => `${k}=${d[k]}`).join("&"); }
// Also disarms: a button in the modal isn't redrawn by render(), so it would stay armed.
function paintArmed() {
  for (const b of document.querySelectorAll("[data-confirm]")) {
    if (ui.armed && confirmKey(b.dataset) === ui.armed) {
      if (!b.classList.contains("armed")) { b.dataset.unarmed = b.innerHTML; b.classList.add("armed"); b.textContent = b.dataset.confirm; }
    } else if (b.classList.contains("armed")) {
      b.classList.remove("armed");
      if (b.dataset.unarmed !== undefined) b.innerHTML = b.dataset.unarmed;
    }
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
      <button class="icon" title="${T("Remove", "移除")}" data-action="att-remove" data-session="${esc(sid)}" data-i="${i}">✕</button></span>`).join("")}</div>`;
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
    if (!f || !/^image\/(png|jpeg|gif|webp)$/.test(f.type)) { toast(T("Only PNG, JPEG, GIF or WebP images", "只支持 PNG、JPEG、GIF 或 WebP 图片"), true); continue; }
    if (f.size > 20 * 1024 * 1024) { toast(T("That image is larger than 20 MB", "这张图片超过 20 MB"), true); continue; }
    try {
      const url = await readAsDataURL(f);
      const saved = await api("saveImage", { data: url });
      // Only a small preview is kept (it is saved with the draft); the full image is the file.
      (ui.atts[sid] = ui.atts[sid] || []).push({ path: saved.path, url: await thumbnail(url) });
      added++;
    } catch (e) { toast(String(e.message || e), true); }
  }
  if (added && sid.startsWith("ask:")) autoPick(sid.slice(4), true);   // an image is an answer too
  if (added) { if (!sid.startsWith("ask:")) ui.msgOpen.add(sid); render(); if (ui.modal && ui.modal.type === "peek" && peekKey(ui.modal) === sid) drawPeek(false); }
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
  const zone = !ui.dragging && ev.target.closest && ev.target.closest(".send, .card.ask, .capture, .c-foot");
  if (!zone || !ev.dataTransfer || ![...ev.dataTransfer.types].includes("Files")) return;
  ev.preventDefault();
  zone.classList.add("dropping");
});
document.addEventListener("dragleave", (ev) => {
  const zone = ev.target.closest && ev.target.closest(".send, .card.ask, .capture, .c-foot");
  if (zone) zone.classList.remove("dropping");
});
document.addEventListener("drop", (ev) => {
  const zone = !ui.dragging && ev.target.closest && ev.target.closest(".send, .card.ask, .capture, .c-foot");
  if (!zone || !ev.dataTransfer || !ev.dataTransfer.files.length) return;
  ev.preventDefault();
  zone.classList.remove("dropping");
  const box = zone.querySelector("textarea[data-session], [data-att]");
  if (box) addImages(box.dataset.session || box.dataset.att, [...ev.dataTransfer.files]);
});

// A busy session queues what it is sent; there is no new turn to wait for.
const isBusy = (sid) => liveState(ui.sessions.find((x) => x.sessionId === sid)) === "busy";

// While a message is on its way (Orca waits up to 5 s to see it submitted) the button is locked,
// so a second click can't type the same message into the session again.
function sendButton(sid, enabled) {
  const inFlight = ui.sending.has(sid);
  return `<button class="btn small primary" data-action="send" data-session="${esc(sid)}" ${enabled && !inFlight ? "" : "disabled"}>${inFlight ? T("Sending…", "发送中…") : T("Send", "发送")}</button>`;
}

async function send(sid) {
  if (sid === SEC) return sendSecretary();
  if (ui.sending.has(sid)) return;
  const key = "msg:" + sid;
  const text = (ui.drafts[key] || "").trim();
  const images = ui.atts[sid] || [];
  if (!text && !images.length) return;
  const message = [text, ...images.map((a) => a.path)].filter(Boolean).join("\n");
  // The button is disabled for such a session; this catches a click from a board seconds old.
  if (onPrompt(ui.sessions.find((x) => x.sessionId === sid))) return toast(ON_PROMPT(), true);
  const queued = isBusy(sid);
  ui.sending.add(sid);
  render();
  // Sending from the conversation window: follow the message down to the bottom.
  if (ui.modal && ui.modal.type === "peek" && ui.modal.sid === sid) drawPeek(true);
  try {
    await api("send", { session: sid, text: message, queue: queued, ...sendExtra(ui.sessions.find((x) => x.sessionId === sid)) });
    delete ui.drafts[key];
    delete ui.atts[sid];
    const withImgs = images.length ? T(` with ${images.length} image${images.length === 1 ? "" : "s"}`, `（带 ${images.length} 张图片）`) : "";
    toast(queued ? T(`Delivered${withImgs} — queued until the session finishes its turn`, `已送达${withImgs}——排队等 session 这一轮结束`) : T(`Sent${withImgs}`, `已发送${withImgs}`));
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
  await act("set", { task: el.dataset.task, fields: [`${el.dataset.field}=${v}`] }, T("Saved", "已保存"));
}

const NO_EXPAND = "input, textarea, select, label, a, .card, .askgroup, .bsess, .atts";

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
    let msg = T(`${done.length} answer${done.length === 1 ? "" : "s"} recorded`, `已记下 ${done.length} 个回答`);
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
        await api("send", { session: sid, text: pushMessageAll(xs), queue: Boolean(s && s.state === "busy"), ...sendExtra(s) });
        sent.push(...xs);
        msg += ` · ${s && s.state === "busy" ? T("queued for", "已排队给") : T("sent to", "已发给")} ${s ? s.title || s.project : sid}`;
      } catch (e) {
        for (const x of xs) { try { await api("delivered", { id: x.a.id, session: sid, undo: true }); } catch (e2) { /* best effort */ } }
        msg += T(` · couldn't reach the session (${e.message || e}); it gets the answers with your next message there`, ` · 联系不上 session（${e.message || e}）；你下次给它发消息时会一起带上这些回答`);
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
      toast(sent.length ? T("Reopened — the message already sent stays in the session", "已重新打开——已经发出的消息还留在 session 里") : T("Reopened", "已重新打开"));
      refresh();
    });
  } finally {
    try { await refresh(); } finally { for (const x of answers) ui.resolving.delete(x.a.id); render(); }
  }
}

// Which Jump button this was, for the pet's jump log (~/.claude/pet/jumps.jsonl, see `hq jumps`).
function jumpSource(el) {
  if (el.closest("#modal")) return ui.modal && ui.modal.type === "context" ? "board-context" : "board-peek";
  if (el.closest(".bsess")) return "board-card";
  if (el.closest(".session")) return "board-sessions";
  return "board";
}

// Where a click started: one pressed in the drawer and let go outside it (slipping off a button,
// say) is still the drawer's, and a slash-command pick hides its list on mousedown.
const DRAWER_KEEPERS = "#drawer, #modal, #confirm, #toast, #settings, #slash, .launch";
let pressedIn = false;
document.addEventListener("mousedown", (ev) => { pressedIn = Boolean(ev.target.closest && ev.target.closest(DRAWER_KEEPERS)); }, true);

document.addEventListener("click", async (ev) => {
  // The "New session ▾" menu closes on any click outside it.
  if (ui.launchMenu && !ev.target.closest(".launch")) { ui.launchMenu = null; render(); }
  const el = ev.target.closest("[data-action]");
  // The task drawer closes on a click anywhere outside it — but not one in a dialog or toast over
  // it, one that ends a text selection, or one on a card or button that opens a drawer itself
  // (they switch or toggle it). A target already gone was redrawn under the click: leave it.
  if (ui.drawer && document.contains(ev.target) && !pressedIn
      && !ev.target.closest(DRAWER_KEEPERS)
      && !(el && ["open-task", "open-sessions", "goto", "ctx-goto", "ask-answer"].includes(el.dataset.action))
      && !String(window.getSelection() || "").trim()) {
    ui.drawer = null;
    render();
  }
  // The secretary's menus close on any click but their own button's, or the evening report's
  // or the scan's switch (you see it flip).
  if (ui.modal && ui.modal.pop && !(el && ["sec-pop", "secretary-reports", "secretary-feed", "secretary-autoclose"].includes(el.dataset.action))) {
    ui.modal.pop = null;
    drawPeek(false);   // (an item clicked in it still acts: its dataset outlives the redraw)
  }
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
      // A card's one-click Yes / No sends no note: the card doesn't show the draft one.
      const note = d.quick ? "" : answerNote(d.id);
      const draftNote = ui.drafts["note:" + d.id], imgs = ui.atts["ask:" + d.id];
      // Later leaves the ask open, so a half-written note and its images stay for tomorrow.
      if (d.res !== "snooze") { delete ui.drafts["note:" + d.id]; delete ui.atts["ask:" + d.id]; }
      const a = tasks().flatMap((t) => t.asks || []).find((x) => x.id === d.id);
      const target = a && pushTarget(a);
      const push = Boolean(target) && wantPush(a);
      delete ui.drafts["push:" + d.id];
      try {
        const made = await answerAsk(a, d.res, note);
        let msg = T(`${d.id} → ${d.res === "todo" ? "@me todo" : d.res === "always" ? "yes, and granted" : d.res}`, `${d.id} → ${(RESOLUTIONS.concat(MORE_RESOLUTIONS).find((r) => r[0] === d.res) || [])[1] || d.res}`);
        if (push) {
          // Mark first: the message starts a turn at once, and that turn's hook must not inject
          // the same answer again. Unmark if the message never got there.
          try {
            // (Later is not an answer: nothing to keep the hook from repeating.)
            if (d.res !== "snooze") await api("delivered", { id: d.id, session: target.sessionId });
            await api("send", { session: target.sessionId, text: pushMessage(a, d.res, note, made), queue: target.state === "busy", ...sendExtra(target) });
            msg += ` · ${target.state === "busy" ? T("queued for", "已排队给") : T("sent to", "已发给")} ${target.title || target.project}`;
          } catch (e) {
            try { await api("delivered", { id: d.id, session: target.sessionId, undo: true }); } catch (e2) { /* best effort */ }
            msg += T(` · couldn't reach the session (${e.message || e}); it gets the answer with your next message there`, ` · 联系不上 session（${e.message || e}）；你下次给它发消息时会一起带上这个回答`);
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
            toast(push ? T(`${d.id} reopened — the message already sent stays in the session`, `${d.id} 已重新打开——已经发出的消息还留在 session 里`) : T(`${d.id} reopened`, `${d.id} 已重新打开`));
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
    case "tidy-todos": return tidyTodos(d.task);
    case "more-res": ui.moreRes.add(d.id); return render();
    case "grant-open": {
      // The box by the button clicked: Needs you, the drawer and the conversation window can each
      // have one. (Asked before render() replaces the button.)
      const where = el.closest("#drawer, #modal");
      ui.granting.has(d.id) ? ui.granting.delete(d.id) : ui.granting.add(d.id); render();
      { const box = [...document.querySelectorAll(`[data-key="${CSS.escape("grant:" + d.id)}"]`)]
          .find((x) => x.closest("#drawer, #modal") === where && x.getClientRects().length);
        if (box) { box.focus(); box.select(); } }
      return;
    }
    case "grant-cancel": ui.granting.delete(d.id); delete ui.drafts["grant:" + d.id]; return render();
    case "grant-preset": ui.drafts["grant:" + d.id] = d.text; saveDrafts(); return render();
    case "grant-preset-task": ui.drafts["addgrant:" + d.for] = d.text; saveDrafts(); return render();
    case "add-grant": {
      const key = "addgrant:" + d.task;
      const text = (ui.drafts[key] || "").trim();
      if (!text) return;
      delete ui.drafts[key];
      ui.adding.delete(`${d.task}:grant`);
      return act("grant", { action: "add", task: d.task, text }, T("Grant added — sessions on this task are told at their next turn", "授权已添加——这个任务的 session 下一轮就会知道"));
    }
    case "grant-revoke": {
      try {
        const g = JSON.parse(await api("grant", { action: "revoke", task: d.task, index: d.i, text: d.text }) || "{}");
        toast(T("Grant revoked — sessions ask again from their next turn", "授权已撤销——session 从下一轮起会重新问"), false, async () => {
          try { await api("grant", { action: "add", task: d.task, text: g.text || d.text, at: g.at || "", source: g.from || "" }); toast(T("Grant restored", "授权已恢复")); }
          catch (e) { toast(String(e.message || e), true); }
          await refresh();
        });
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "show-later": ui.showLater.has(d.task) ? ui.showLater.delete(d.task) : ui.showLater.add(d.task); return render();
    case "forget-session": {
      const t = taskById(d.task);
      if (!t) return;
      const before = list(t.sessions);
      const after = before.filter((x) => !d.session.startsWith(String(x)));
      const set = (v) => api("set", { task: d.task, fields: [`sessions=${JSON.stringify(v)}`] });
      try {
        await set(after);
        toast(T("Removed from this task's sessions", "已从这个任务的 session 里移除"), false, async () => { await set(before); delete ui.history[d.task]; await refresh(); });
      } catch (e) { toast(String(e.message || e), true); }
      delete ui.history[d.task];
      return refresh();
    }
    case "hist-all": ui.histAll.has(d.task) ? ui.histAll.delete(d.task) : ui.histAll.add(d.task); return render();
    case "resume": {
      // Locked while its request is out (waking an Orca tab can take seconds), so a second click
      // can't resume the session twice.
      if (ui.resuming.has(d.session)) return;
      const t = taskById(d.task);
      const place = launchPlace() === "bg" ? "terminal" : launchPlace();
      ui.resuming.add(d.session);
      render();
      try {
        const r = await apiObj("resume", { task: d.task, session: d.session, dir: d.dir || (t && launchDir(t)) || "", where: place, skip: skipPerms(), name: d.name || "", focus: !stayOnBoard() });
        const tab = r.reused || r.woke ? T(`its old ${PLACES[place]} tab`, `原来的 ${PLACES[place]} 标签页`) : PLACES[place];
        toast(stayOnBoard() ? T(`Resumed in ${tab} — bound to ${d.task}; carry on here`, `已在${tab}里续上——绑定到 ${d.task}；在这里接着干`) : T(`Resuming it in ${tab} — bound to ${d.task}`, `正在${tab}里续上——绑定到 ${d.task}`));
        stayWith(d.session, d.name);
      } catch (e) { toast(String(e.message || e), true); } finally { ui.resuming.delete(d.session); }
      delete ui.history[d.task];
      render();
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
        toast(T("Marked handled", "已标为处理好"), false, () => act("set", { task: d.task, fields: [`waiting_on_me=${prev}`] }, T("Undone", "已撤销")));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "ask-answer": {
      // Open the task with its questions on top, at this one, its note box ready to type in —
      // unless the click ended a text selection (copying the question).
      if (el.tagName !== "BUTTON" && String(window.getSelection() || "").trim()) return;
      ui.drawer = d.task; ui.launchMenu = null;
      render();
      const box = d.id ? document.querySelector(`#drawer [data-key="${CSS.escape("note:" + d.id)}"]`) : document.querySelector("#drawer .dr-asks");
      if (box) { box.scrollIntoView({ block: "center" }); if (box.focus) box.focus(); }
      return;
    }
    case "open-task":
      // Only a click on the card itself opens it — not one in a box or on a label, or one that
      // ends a text selection. A second click on the open one closes the drawer.
      if (ev.target !== el && ev.target.closest(NO_EXPAND)) return;
      if (String(window.getSelection() || "").trim()) return;
      if (ui.drawer === d.task) { ui.drawer = null; return render(); }
      return openDrawer(d.task);
    case "drawer-close": ui.drawer = null; return render();
    case "open-sessions": ui.drawer = ui.drawer === "@sessions" ? null : "@sessions"; return render();
    case "drawer-status": {
      const t = taskById(d.task);
      if (!t || t.status === d.s) return;
      return setStatus(d.task, d.s);
    }
    case "launch-menu": ui.launchMenu = ui.launchMenu === d.task ? null : d.task; return render();
    case "goto": return revealTask(d.task);
    case "note-move": return noteMove(d.id, JSON.parse(d.dest));
    case "note-to-task": {
      // What the picker shows, preselected or chosen.
      const sel = el.closest(".qnote-pick") && el.closest(".qnote-pick").querySelector("select");
      const task = (sel && sel.value) || ui.drafts["note-pick:" + d.id];
      if (task) { delete ui.drafts["note-pick:" + d.id]; return noteMove(d.id, { kind: d.kind, task }); }
      return;
    }
    case "note-change": ui.noteOpen.has(d.id) ? ui.noteOpen.delete(d.id) : ui.noteOpen.add(d.id); return render();
    case "note-drop": return act("note-drop", { id: d.id }, T("Deleted — Restore brings it back", "已删掉——点恢复可以找回"));
    case "note-restore": return act("note-restore", { id: d.id }, T("Restored", "已恢复"));
    case "jump": return act("jump", { session: d.session, from: jumpSource(el), view: ui.mode });
    case "decide": {
      if (d.behavior === "allow" && !(ui.allowArmed && ui.allowArmed.ask === d.ask)) {
        clearTimeout(ui.allowArmed && ui.allowArmed.timer);
        ui.allowArmed = { ask: d.ask, timer: setTimeout(() => { ui.allowArmed = null; render(); }, 6000) };
        return render();
      }
      clearTimeout(ui.allowArmed && ui.allowArmed.timer);
      ui.allowArmed = null;
      return act("decide", { session: d.session, ask: d.ask, behavior: d.behavior },
                 d.behavior === "allow" ? T("Allowed", "已允许") : T("Denied", "已拒绝"));
    }
    case "unbind": return act("unbind", { session: d.session }, T("Unbound", "已解绑"));
    case "open": return act("open", { path: d.path });
    case "send": return send(d.session);
    case "peek":
      // A session line or its last words: selecting text there to copy it is not a click.
      if (el.tagName !== "BUTTON" && String(window.getSelection() || "").trim()) return;
      return openPeek(d.session);
    case "att-remove":
      (ui.atts[d.session] || []).splice(Number(d.i), 1);
      render();
      if (ui.modal && ui.modal.type === "peek" && peekKey(ui.modal) === d.session) drawPeek(false);
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
    case "open-secretary": return openSecretary();
    case "secretary-setup": return setupSecretary();
    case "secretary-reports":
      try { ui.secretary = await apiObj("secretary-reports", { on: d.on === "1" }); }
      catch (e) { return toast(String(e.message || e), true); }
      if (ui.modal && ui.modal.secretary) { ui.modal.sec = ui.secretary; drawPeek(false); }
      return toast(d.on === "1" ? T("Evening report on", "定时报告已开启") : T("Evening report off", "定时报告已关闭"));
    case "secretary-feed":
    case "secretary-feed-now":
      try { ui.secretary = await apiObj(d.action, { on: d.on === "1" }); }
      catch (e) { return toast(String(e.message || e), true); }
      if (ui.modal && ui.modal.secretary) { ui.modal.sec = ui.secretary; drawPeek(false); }
      return toast(d.action === "secretary-feed-now" ? T("Scanning…", "正在扫描…") : d.on === "1" ? T("Scan on", "扫描已开启") : T("Scan off", "扫描已关闭"));
    case "secretary-autoclose":
    case "secretary-autoclose-now":
      try { ui.secretary = await apiObj(d.action, { on: d.on === "1" }); }
      catch (e) { return toast(String(e.message || e), true); }
      if (ui.modal && ui.modal.secretary) { ui.modal.sec = ui.secretary; drawPeek(false); }
      return toast(d.action === "secretary-autoclose-now" ? T("Checking…", "正在检查…") : d.on === "1" ? T("Auto-tick on", "自动勾选已开启") : T("Auto-tick off", "自动勾选已关闭"));
    case "secretary-report-now":
      return sendSecretary(T("Write the report that is due now (hq report, then hq report keep).", "现在写今天该写的报告（hq report，写完 hq report keep）。"));
    case "secretary-stop":
      try { await api("secretary-stop"); toast(T("Stopping…", "正在停止…")); } catch (e) { toast(String(e.message || e), true); }
      return refreshPeek();
    case "sec-pop":
      if (ui.modal) { ui.modal.pop = ui.modal.pop === d.pop ? null : d.pop; drawPeek(false); }
      return;
    case "sec-watch":
      if (ui.modal) { ui.modal.watchOpen = !ui.modal.watchOpen; drawPeek(false); }
      return;
    case "sec-quick":
      if (d.text) return sendSecretary(d.text);
      if (!(ui.drafts["msg:" + SEC] || "").trim()) { ui.drafts["msg:" + SEC] = d.fill || ""; saveDrafts(); }
      drawPeek(false);
      { const ta = document.querySelector(`#modal textarea[data-key="msg:${SEC}"]`); if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); } }
      return;
    case "sec-copy": {
      const c = ui.modal && ui.modal.chat && ui.modal.chat[Number(d.i)];
      if (c) await copyText(c.text, T("Message copied", "已复制消息"));
      return;
    }
    case "copy-msg": {
      const m = ui.modal && ui.modal.msgs[Number(d.i)];
      if (m) await copyText(m.text, T("Message copied", "已复制消息"));
      return;
    }
    case "ptool": {
      const m = ui.modal;
      if (!m || String(window.getSelection() || "").trim()) return;   // ended a text selection
      if (m.openTools.has(d.id)) { m.openTools.delete(d.id); return drawPeek(false); }
      m.openTools.add(d.id);
      drawPeek(false);
      const had = m.details[d.id];   // fetched while it ran, or failed: fetch it again
      if (!had || had.err || had._st !== toolStatus(m, d.id)) loadToolDetail(m, d.id);
      return;
    }
    case "hqfold": {
      // Toggled in place: a redraw would rebuild the conversation (and lose a text selection).
      if (String(window.getSelection() || "").trim()) return;
      const open = !ui.hqOpen.has(d.key);
      open ? ui.hqOpen.add(d.key) : ui.hqOpen.delete(d.key);
      const box = el.closest(".hqblock");
      box.classList.toggle("open", open);
      el.querySelector(".pcaret").textContent = open ? "▾" : "▸";
      return;
    }
    case "pgroup": {
      const m = ui.modal;
      if (!m || String(window.getSelection() || "").trim()) return;
      m.openGroups.has(d.key) ? m.openGroups.delete(d.key) : m.openGroups.add(d.key);
      return drawPeek(false);
    }
    case "ptodo":
      if (ui.modal) { ui.modal.todoOpen = !ui.modal.todoOpen; drawPeek(false); }
      return;
    case "tool-full":
      if (ui.modal) { ui.modal.fullTools.add(`${d.id}|${d.which}`); drawPeek(false); }
      return;
    case "copy-tool": {
      const t = ui.modal && ui.modal.details[d.id];
      if (t) await copyText(d.which === "in" ? t.input : t.output, d.which === "in" ? T("Input copied", "已复制输入") : T("Output copied", "已复制输出"));
      return;
    }
    case "copy-all":
      if (ui.modal && ui.modal.secretary) {
        await copyText((ui.modal.chat || []).map((c) => `${c.who === "you" ? T("You", "你") : T("Secretary", "秘书")}:\n${c.text}`).join("\n\n"), T("Conversation copied", "已复制对话"));
        return;
      }
      if (ui.modal) await copyText(ui.modal.msgs.map((m) => `${m.role === "user" ? "You" : "Claude"}:\n${m.text}`).join("\n\n"), T("Conversation copied", "已复制对话"));
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
      const focus = { todo: "addtodo", log: "log", grant: "addgrant" }[d.what];
      const el = focus && document.querySelector(`[data-key="${CSS.escape(focus + ":" + d.task)}"]`);
      if (el) el.focus();
      return;
    }
    case "save-field": {
      const key = `${d.field}:${d.task}`;
      const v = ui.drafts[key] ?? "";
      delete ui.drafts[key];
      ui.adding.delete(`${d.task}:${d.field}`);
      return act("set", { task: d.task, fields: [`${d.field}=${v}`] }, T("Saved", "已保存"));
    }
    case "cancel-field": delete ui.drafts[`${d.field}:${d.task}`]; ui.adding.delete(`${d.task}:${d.field}`); return render();
    case "add-todo": {
      const key = "addtodo:" + d.task;
      const text = (ui.drafts[key] || "").trim();
      if (!text) return;
      delete ui.drafts[key];
      return act("addtodo", { task: d.task, text }, T("Todo added", "待办已添加"));
    }
    case "bind-pick": {
      const sid = ui.drafts["bindpick:" + d.task];
      if (!sid) return toast(T("Choose a session first", "先选一个 session"), true);
      delete ui.drafts["bindpick:" + d.task];
      ui.adding.delete(`${d.task}:bind`);
      return act("bind", { task: d.task, session: sid }, T("Bound — the session learns the task on its next message", "已绑定——session 收到下一条消息时会知道这个任务"));
    }
    case "add-log": {
      const key = "log:" + d.task;
      const text = (ui.drafts[key] || "").trim().replace(/\s*\n+\s*/g, " ");
      if (!text) return;
      delete ui.drafts[key];
      ui.adding.delete(`${d.task}:log`);
      return act("log", { task: d.task, message: text }, T("Note saved", "备注已保存"));
    }
    case "claude-todos-toggle":
      ui.claudeOpen.has(d.task) ? ui.claudeOpen.delete(d.task) : ui.claudeOpen.add(d.task);
      savePref("hq-claude-todos-open", JSON.stringify([...ui.claudeOpen]));
      return render();
    case "ref-more": ui.refMore.has(d.group) ? ui.refMore.delete(d.group) : ui.refMore.add(d.group); return render();
    case "done-toggle": ui.doneOpen.has(d.task) ? ui.doneOpen.delete(d.task) : ui.doneOpen.add(d.task); return render();
    case "log-all": ui.logAll.has(d.task) ? ui.logAll.delete(d.task) : ui.logAll.add(d.task); return render();
    case "toggle-res": ui.resOpen.has(d.task) ? ui.resOpen.delete(d.task) : ui.resOpen.add(d.task); return render();
    case "add-ref": {
      const key = "addref:" + d.task;
      const text = (ui.drafts[key] || "").trim();
      if (!text) return;
      delete ui.drafts[key];
      // Added by hand: a key link, kept on the card even when it is a build or a comment.
      return act("ref", { action: "pin", task: d.task, ref: text }, T("Added", "已添加"));
    }
    case "ref-pin": return act("ref", { action: "pin", task: d.task, ref: d.ref }, T("Kept on the card", "已留在卡上"));
    case "continue": {
      try {
        const out = JSON.parse(await api("continue", { task: d.task }));
        ui.drawer = out.to;
        toast(T(`Continued in ${out.to}`, `已续到 ${out.to}`) + (out.asks && out.asks.length ? T(` — ${out.asks.length} open ask(s) moved with it`, `——${out.asks.length} 条未回应的问题一起搬过去了`) : ""));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "workdir-add": {
      try {
        const t = taskById(d.task);
        const r = await apiObj("pick-folder", { path: (t && list(t.workdirs)[0]) || "", message: T(`A folder for ${d.task}`, `给 ${d.task} 选一个目录`) });
        if (r.path) await act("workdir", { action: "add", task: d.task, path: r.path }, T("Folder added", "已添加目录"));
      } catch (e) { toast(String(e.message || e), true); }
      return;
    }
    case "workdir-remove": {
      const path = d.path;
      try {
        // Undo puts it back where it was (New session starts in the first), even a folder since gone.
        const out = await api("workdir", { action: "remove", task: d.task, path });
        toast(T("Folder removed", "已移除目录"), false, () => act("workdir", { action: "restore", task: d.task, path: out }, T("Restored", "已恢复")));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "ref-remove": {
      const ref = d.ref;
      try {
        // ✕ removes every entry with this link, on the card and in HISTORY.md; hq prints them
        // ({"removed": [{i, ref}, …], "history": [ref, …]}) and Undo puts them all back where they
        // were. An older hq prints nothing: re-add this one.
        const out = await api("ref", { action: "remove", task: d.task, ref });
        let gone = null;
        try { gone = JSON.parse(out); } catch (e) { /* older hq */ }
        const undo = gone && (list(gone.removed).length || list(gone.history).length)
          ? () => act("ref", { action: "restore", task: d.task, ref: JSON.stringify(gone) }, T("Restored", "已恢复"))
          : () => act("ref", { action: "add", task: d.task, ref }, T("Restored", "已恢复"));
        toast(T("Removed", "已移除"), false, undo);
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "sgroup-by": ui.sgroupBy = d.g; savePref("hq-sgroupby", d.g); return render();
    case "scollapse":
      ui.scollapsed.has(d.key) ? ui.scollapsed.delete(d.key) : ui.scollapsed.add(d.key);
      savePref("hq-scollapsed", JSON.stringify([...ui.scollapsed]));
      return render();
    case "project-panel": return goToProject(d.p);   // projects.js
    case "pgrant-revoke": {
      try {
        const g = JSON.parse(await api("grant", { action: "revoke", project: d.p, index: d.i, text: d.text }) || "{}");
        toast(T("Project grant revoked — sessions on its tasks ask again from their next turn", "项目授权已撤销——它的任务的 session 从下一轮起会重新问"), false, async () => {
          try { await api("grant", { action: "add", project: d.p, text: g.text || d.text, at: g.at || "", source: g.from || "" }); toast(T("Grant restored", "授权已恢复")); }
          catch (e) { toast(String(e.message || e), true); }
          await refresh();
        });
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "open-settings": ui.settings = true; return render();
    case "close-settings": closeSettings(); return;
    // The first-run card's "Suggest projects": the list of Projects & duties, then the scan.
    case "scan-open": if (ui.mode !== "projects" || ui.proj) goToProject(""); // fall through to scan
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
      return act("scan-apply", { names }, T(`Created ${names.length} project(s) and sorted tasks into them`, `已创建 ${names.length} 个项目，并把任务归了进去`));
    }
    case "copy-onboard": return copyText("/hq-onboard", T("Copied — paste it into any Claude Code session", "已复制——粘贴到任意 Claude Code session 里"));
    case "new-in-project": return openCreate("task", d.p);   // projects.js
    case "clear-filter": ui.filter = $("#search").value = ""; return render();
    case "mode":
      // The Projects tab, clicked again on a project's page, goes back to the list.
      if (d.m === "projects" && ui.mode === "projects" && ui.proj) return goToProject("");
      ui.mode = d.m; savePref("hq-mode", d.m);
      return d.m === "jobs" || d.m === "projects" ? refresh(true) : render();
    case "focus-toggle": {
      const on = focusIds().includes(d.task);
      return act("focus", { action: on ? "remove" : "add", tasks: [d.task] }, on ? T(`${d.task} off Focus`, `${d.task} 已移出 Focus`) : T(`${d.task} added to Focus`, `${d.task} 已加入 Focus`));
    }
    case "today-add": {
      const v = (ui.drafts["todaypick"] || "").trim();
      const id = (v.match(/T-\d+/i) || [])[0];
      if (!id || !taskById(id.toUpperCase())) return toast(T("Pick a task from the list (type its id or title)", "从列表里选一个任务（输入编号或标题）"), true);
      delete ui.drafts["todaypick"];
      return act("focus", { action: "add", tasks: [id.toUpperCase()] }, T(`${id.toUpperCase()} added to Focus`, `${id.toUpperCase()} 已加入 Focus`));
    }
    case "today-remove": {
      const id = d.task;
      try {
        await api("focus", { action: "remove", tasks: [id] });
        toast(T(`${id} off Focus`, `${id} 已移出 Focus`), false, () => act("focus", { action: "add", tasks: [id] }, T(`${id} back in Focus`, `${id} 已放回 Focus`)));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh();
    }
    case "launch": {
      ui.launchMenu = null;
      const t = taskById(d.task);
      if (!t) return;
      let dir = "";
      try { dir = await ensureLaunchDir(t); } catch (e) { return toast(String(e.message || e), true); }
      if (!dir) return toast(T("No folder picked — the session needs one to start in", "没有选目录——session 得有个目录才能开"));
      const place = launchPlace();
      try {
        const r = await apiObj("launch", { task: t.id, title: t.title, dir, where: place, prompt: LAUNCH_PROMPT(t), skip: skipPerms(), focus: !stayOnBoard() });
        toast(place === "bg" ? T(`Started in the background on ${t.id} — Peek or Attach from its card`, `已在后台为 ${t.id} 开了 session——可从任务卡上 Peek 或 Attach`)
          : stayOnBoard() ? T(`Started on ${t.id} — it reads the card and reports here`, `已为 ${t.id} 开了 session——它会读任务卡，在这里汇报`) : T(`Started in ${PLACES[place]} on ${t.id} — it reads the card and reports`, `已在 ${PLACES[place]} 里为 ${t.id} 开了 session——它会读任务卡并汇报`));
        stayWith(r && r.session, `${t.id} ${t.title}`);
      } catch (e) { toast(String(e.message || e), true); }
      setTimeout(() => refresh(), 2500);
      return;
    }
    case "attach": {
      const place = launchPlace() === "bg" ? "terminal" : launchPlace();
      try { await api("attach", { session: d.session, where: place }); toast(T(`Opening it in ${PLACES[place]}…`, `正在 ${PLACES[place]} 里打开…`)); }
      catch (e) { toast(String(e.message || e), true); }
      return;
    }
    case "open-prompt": return openPrompt(d.session);
    case "prompt-pick": {
      const m = ui.modal;
      if (!m || m.type !== "prompt") return;
      const q = m.questions[Number(d.q)] || {};
      const cur = m.picks[d.q] || new Set();
      if (q.multiSelect) { cur.has(d.label) ? cur.delete(d.label) : cur.add(d.label); m.picks[d.q] = cur; }
      else {
        m.picks[d.q] = cur.has(d.label) ? new Set() : new Set([d.label]);
        // A pick replaces your own words for a single-choice question.
        if (m.picks[d.q].size) { delete ui.drafts[promptOtherKey(m, Number(d.q))]; saveDrafts(); }
      }
      return drawPrompt();
    }
    case "prompt-send": {
      const answers = ui.modal && promptAnswers(ui.modal);
      if (!answers) return;
      return promptSubmit("answer-question", { answers }, T("Answered — it carries on", "已回答——它会接着干"));
    }
    case "plan-approve": return promptSubmit("plan-approve", {}, T("Approved — pressed Enter in its terminal", "已批准——在它的终端里按了回车"));
    case "plan-feedback": {
      const text = (draft(planFeedbackKey(ui.modal)) || "").trim();
      if (!text) return;
      return promptSubmit("plan-feedback", { text }, T("Sent back — it keeps planning", "已发回——它会继续规划"));
    }
    case "interrupt": {
      // One press: the button goes away until the pet has caught up (escHeld).
      if (escHeld(d.session)) return;
      ui.interrupted = { ...(ui.interrupted || {}), [d.session]: Date.now() };
      render();
      try { await api("interrupt", { session: d.session }); toast(T("Pressed Esc — the turn stops in a moment", "已按 Esc——这一轮马上停下")); }
      catch (e) { delete ui.interrupted[d.session]; toast(String(e.message || e), true); }
      setTimeout(render, ESC_HOLD_MS + 100);
      return;
    }
    case "stop-session":
      if (ui.stopArmed !== d.session) {
        ui.stopArmed = d.session;
        render();
        toast(T("Click stop again to end this session — its conversation is kept; Resume picks it up, in the same tab if it is still open", "再点一下停止来结束这个 session——对话保留；之后可以 Resume 续上，标签页还开着就在原标签页里"));
        setTimeout(() => { if (ui.stopArmed === d.session) { ui.stopArmed = null; render(); } }, 4000);
        return;
      }
      ui.stopArmed = null;
      return act("stop-session", { session: d.session }, T("Stopped — its conversation is kept", "已停止——对话保留"));
    case "stop-task-sessions": return stopMany(liveFor(d.task), "task:" + d.task, T(`${d.task}'s sessions`, ` ${d.task} 的 session`));
    case "finish-stop": return answerFinishAsk(true);
    case "finish-keep": return answerFinishAsk(false);
    case "stop-strays": return stopMany(strays(), "strays", T("the sessions on finished tasks", "已结束任务上的 session"));
    case "stop":
      // WKWebView shows no confirm() dialog, so confirm with a second click instead.
      if (ui.stopArmed !== d.session) {
        ui.stopArmed = d.session;
        render();
        toast(T("Click stop again to stop it — its conversation is kept, Attach resumes it", "再点一下停止——对话保留，Attach 可以续上"));
        setTimeout(() => { if (ui.stopArmed === d.session) { ui.stopArmed = null; render(); } }, 4000);
        return;
      }
      ui.stopArmed = null;
      return act("stop", { session: d.session }, T("Stopped", "已停止"));
    case "proj-auto": return act("project", { action: "auto" }, T("Tasks assigned by directory", "已按目录归属任务"));
    // The Projects & duties page and the ＋ New window (projects.js).
    default: if (d.action.startsWith("p-") && typeof projAction === "function") return projAction(d, el, ev);
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
  if (d.action === "finish-stop-pref") { savePref("hq-finish-stop", el.value); return render(); }
  if (d.action === "stay-board") { savePref("hq-stay", el.checked ? "1" : "0"); return render(); }
  // Kept by the pet, which its menu shares; shows at once, the next refresh confirms it.
  if (d.action === "click-target") { ui.clickTarget = el.value; api("click-target", { value: el.value }).catch((e) => toast(String(e.message || e), true)); return render(); }
  // A picked status / project / phase shows at once; the refresh after saving confirms it.
  if (["set-status", "set-project", "set-phase"].includes(d.action)) {
    ui.pointerDown = false;
    const t = taskById(d.task);
    if (t) { t[d.action.slice(4)] = el.value; render(); }
  }
  if (d.action === "set-project") return act("set", { task: d.task, fields: [`project=${el.value}`] }, T("Project saved", "项目已保存"));
  if (d.action === "set-phase") return act("set", { task: d.task, fields: [`phase=${el.value}`] }, T("Phase saved", "阶段已保存"));
  if (el.tagName === "SELECT" && d.key) { ui.drafts[d.key] = el.value; el.blur(); return render(); }
  if (d.action === "set-status") return setStatus(d.task, el.value);
  if (d.action === "bind" && el.value) return act("bind", { task: d.task, session: el.value }, T("Bound — the session learns the task on its next message", "已绑定——session 收到下一条消息时会知道这个任务"));
  if (d.action === "bind-session" && el.value) return act("bind", { task: el.value, session: d.session }, T("Bound — the session learns the task on its next message", "已绑定——session 收到下一条消息时会知道这个任务"));
  if (d.action === "show-done") { ui.showDone = el.checked; savePref("hq-show-done", el.checked ? "1" : "0"); render(); }
  if (d.action === "active-first") { ui.activeFirst = el.checked; savePref("hq-activefirst", el.checked ? "1" : "0"); render(); }
});

// Text that arrives in one go — a paste, a drop, or a dictation app such as Typeless inserting
// what it heard — can bring its line breaks as \r\n, \r or U+2028/2029, each of which the box
// counts as a line of its own, so a paragraph break turned into four or five empty lines. Make
// those plain \n, and keep at most one empty line in a row. Only the inserted text is touched,
// and it goes in through execCommand so Cmd-Z still undoes it; typing, IME commits and autocorrect
// are left alone.
//
// What the beforeinput event says it will insert is not always what lands: on a paste WebKit
// reports the text without its line breaks (or nothing at all), so the breaks slipped past a
// check made only there. So the range being replaced is remembered, and once the text is in, the
// part that arrived is tidied in place.
const BULK = new Set(["insertFromPaste", "insertFromDrop", "insertFromYank", "insertReplacementText", "insertText"]);
const tidyBreaks = (v) => v.replace(/\r\n?|[\u2028\u2029\u0085]/g, "\n").replace(/\n[ \t\u00a0\u3000]*(?=\n)/g, "\n").replace(/\n{3,}/g, "\n\n");
let bulkInsert = null;
document.addEventListener("beforeinput", (ev) => {
  const el = ev.target;
  bulkInsert = null;
  if (el.tagName !== "TEXTAREA" || !ev.cancelable || ev.isComposing || ui.composing || !BULK.has(ev.inputType)) return;
  const text = ev.data ?? (ev.dataTransfer ? ev.dataTransfer.getData("text/plain") : "");
  // A key typed is one character: nothing to tidy, and nothing to check afterwards.
  if (ev.inputType === "insertText" && text && !/[\n\r\u2028\u2029\u0085]/.test(text) && text.length < 3) return;
  const tidy = tidyBreaks(text);
  if (text && tidy !== text) {
    ev.preventDefault();
    document.execCommand("insertText", false, tidy);   // fires its own input event, which saves the draft
    return;
  }
  bulkInsert = { el, before: el.value };
}, true);
// After the insert: tidy just the stretch that arrived, selecting it and typing over it so the
// fix is one more undo step rather than a lost history. Where it arrived is found by comparing
// the text before and after, not taken from the caret: a drop or an autocorrect replacement
// lands somewhere other than the selection.
function tidyInserted(ev) {
  const b = bulkInsert;
  bulkInsert = null;
  const el = ev.target;
  if (!b || b.el !== el || ev.isComposing || ui.composing) return;
  const v = el.value, old = b.before;
  let start = 0;
  while (start < v.length && start < old.length && v[start] === old[start]) start++;
  let tail = 0;
  while (tail < v.length - start && tail < old.length - start && v[v.length - 1 - tail] === old[old.length - 1 - tail]) tail++;
  const end = v.length - tail;
  if (end <= start) return;
  // Reach across the seam only where the arrival itself ends in white space, so its breaks can't
  // stack on blank lines already there; text it merely sits next to is not the paste's to tidy.
  let from = start, to = end;
  if (/\s/.test(v[start])) while (from > 0 && /\s/.test(v[from - 1])) from--;
  if (/\s/.test(v[end - 1])) while (to < v.length && /\s/.test(v[to])) to++;
  const piece = v.slice(from, to);
  const tidy = tidyBreaks(piece);
  if (tidy === piece) return;
  // The caret goes back to the end of the arrival, not past the white space after it.
  const caret = Math.min(from + tidyBreaks(v.slice(from, end)).length, from + tidy.length);
  el.setSelectionRange(from, to);
  document.execCommand("insertText", false, tidy);
  el.setSelectionRange(caret, caret);
}
document.addEventListener("input", (ev) => {
  const el = ev.target;
  if (el.tagName === "TEXTAREA" && bulkInsert) tidyInserted(ev);
  if (el.id === "search") { ui.filter = el.value; return render(); }
  if (el.dataset.key) { ui.drafts[el.dataset.key] = el.value; saveDrafts(); }
  if (ui.modal && ui.modal.type === "prompt" && el.closest("#modal")) syncPromptButtons(el);
  const note = /^note:(.+)$/.exec(el.dataset.key || "");
  if (note) autoPick(note[1], el.value.trim() !== "");
  if (el.dataset.field) render();
  if (el.tagName === "TEXTAREA" && el.classList.contains("grow")) fitGrow(el);
  if (el.tagName === "TEXTAREA" && el.dataset.session) slashUpdate(el);
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

// ---- slash commands in a session's message box: type "/" and pick, as in the terminal.
// What goes in the box is typed into the session's terminal, so a slash command runs there. The
// skills are the session's own, as Claude Code listed them in its transcript (`hq peek --commands`):
// that already accounts for its project, the user's skills and its plugins. Of Claude Code's
// built-in commands only those that do their work without the terminal are offered: one that
// opens a menu (/config, /resume…, or /model with no name) would leave the session sitting in
// it, out of the board's sight (/model is offered for `/model <name>`, which switches without
// one; the bridge refuses it bare), and one that only prints (/context, /cost) prints where the
// board can't see.
const SLASH_BUILTIN = () => [
  { name: "compact", desc: T("Compact the conversation now (add instructions after it if you like)", "现在压缩对话（后面可以接要保留什么的说明）"), builtin: true },
  { name: "clear", desc: T("Start over: a new, empty session in the same terminal", "清空重来：在同一个终端里开一个新的空 session"), builtin: true },
  { name: "model", desc: T("Switch model — follow it with a name: /model opus, /model sonnet, /model haiku", "换模型——后面要接模型名：/model opus、/model sonnet、/model haiku"), builtin: true },
];
const SLASH_MAX = 50;
const slashCache = {};   // sessionId → { at, skills, loading, failed }
function slashQuery(el) {
  if (el.dataset.session === SEC) return null;
  const m = /^\/([^\s]*)$/.exec(el.value);
  return m && !el.disabled && el.selectionStart === el.value.length ? m[1].toLowerCase() : null;
}
function slashSkills(sid) {
  const c = slashCache[sid];
  if (c && (c.loading || Date.now() - c.at < 60_000)) return c.skills || [];
  slashCache[sid] = { at: Date.now(), skills: c ? c.skills : [], loading: true };
  apiJSON("commands", { session: sid }).then((d) => {
    slashCache[sid] = { at: Date.now(), skills: (d && d.skills) || [] };
  }, () => { slashCache[sid] = { at: Date.now(), skills: c ? c.skills : [], failed: true }; })
    // Into whichever box of this session has the cursor now: a refresh may have rebuilt it meanwhile.
    .then(() => {
      const a = document.activeElement;
      if (a && a.tagName === "TEXTAREA" && a.dataset.session === sid) slashUpdate(a);
    });
  return slashCache[sid].skills;
}
function slashUpdate(el) {
  const q = slashQuery(el);
  if (q === null) return slashClose();
  // Esc said no to this text: a refresh putting the cursor back doesn't ask again; typing does.
  if (ui.slashOff && ui.slashOff.key === el.dataset.key && ui.slashOff.value === el.value) return slashClose();
  ui.slashOff = null;
  const all = [...SLASH_BUILTIN(), ...slashSkills(el.dataset.session)];
  // Names that start with what was typed first, then names that contain it anywhere ("review"
  // finds code-review), then — from three letters, when it is a word, not a fragment of every
  // other one — the ones whose description mentions it.
  const rank = (x) => { const n = x.name.toLowerCase(); return n.startsWith(q) ? 0 : n.includes(q) ? 1 : q.length >= 3 && (x.desc || "").toLowerCase().includes(q) ? 2 : 3; };
  const ranked = all.map((x, i) => ({ x, r: rank(x), i })).filter((y) => y.r < 3)
    .sort((a, b) => a.r - b.r || a.i - b.i).slice(0, SLASH_MAX);
  const items = ranked.map((y) => y.x);
  const same = ui.slash && ui.slash.key === el.dataset.key && ui.slash.q === q;
  const keep = same ? items.findIndex((x) => x.name === ui.slash.items[ui.slash.sel]?.name) : -1;
  // Only a name match is chosen for you: text that merely turns up in a description ("/etc",
  // "/tmp") is more likely a path, and Return should stay a new line until you pick with ↑↓.
  ui.slash = { key: el.dataset.key, q, items, sel: keep >= 0 ? keep : ranked.length && ranked[0].r < 2 ? 0 : -1 };
  slashDraw();
}
function slashClose() {
  if (!ui.slash) return;
  ui.slash = null;
  const p = $("#slash");
  if (p) p.hidden = true;
}
// The box it belongs to: the focused one with its key (the Sessions column and the conversation
// window share a key, so the focused one, not the first).
function slashBox() {
  const a = document.activeElement;
  return ui.slash && a && a.tagName === "TEXTAREA" && a.dataset.key === ui.slash.key ? a : null;
}
function slashDraw() {
  const el = slashBox();
  if (!el || !ui.slash.items.length) { const p = $("#slash"); if (p) p.hidden = true; return; }
  let p = $("#slash");
  if (!p) {
    p = document.createElement("div");
    p.id = "slash";
    p.setAttribute("role", "listbox");
    document.body.appendChild(p);
    // A press on a row picks it without taking the cursor out of the box.
    p.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      const row = ev.target.closest("[data-i]");
      if (row) slashPick(Number(row.dataset.i));
    });
  }
  const { items, sel } = ui.slash;
  p.innerHTML = items.map((x, i) => `<div class="srow ${i === sel ? "on" : ""}" role="option" data-i="${i}"${i === sel ? ` aria-selected="true"` : ""}>
      <span class="sname">/${esc(x.name)}</span>${x.builtin ? `<span class="chip">${T("built-in", "内置")}</span>` : ""}<span class="sdesc">${esc(x.desc || "")}</span></div>`).join("")
    + `<div class="shint">${slashCache[el.dataset.session]?.failed
      ? T("Couldn't read this session's skills — hq may need updating (hq/install.sh --yes)", "读不到这个 session 的 skill——hq 可能要更新（hq/install.sh --yes）")
      : T("↑↓ choose · Tab or Return fills it in · Esc closes", "↑↓ 选择 · Tab 或回车填入 · Esc 关闭")}</div>`;
  p.hidden = false;
  slashPlace();
  const on = p.querySelector(".srow.on");
  if (on) on.scrollIntoView({ block: "nearest" });
}
// Above the box (the boxes sit low: the conversation window's is at its foot), or below it when
// there is more room there.
function slashPlace() {
  const p = $("#slash");
  if (!p || p.hidden) return;
  const el = slashBox();
  if (!el) return slashClose();
  const r = el.getBoundingClientRect();
  const w = Math.max(320, Math.min(560, r.width));
  p.style.width = `${w}px`;
  p.style.left = `${Math.max(8, Math.min(r.left, innerWidth - w - 8))}px`;
  const room = r.top - 8, below = innerHeight - r.bottom - 8;
  if (room >= Math.min(p.scrollHeight, 260) || room >= below) {
    p.style.maxHeight = `${Math.min(300, room)}px`; p.style.top = ""; p.style.bottom = `${innerHeight - r.top + 4}px`;
  } else {
    p.style.maxHeight = `${Math.min(300, below)}px`; p.style.bottom = ""; p.style.top = `${r.bottom + 4}px`;
  }
}
function slashPick(i) {
  const el = slashBox();
  const x = ui.slash && ui.slash.items[i];
  if (!el || !x) return;
  slashClose();
  // As typing would: the box's draft, undo and input handlers all see it.
  el.setSelectionRange(0, el.value.length);
  document.execCommand("insertText", false, `/${x.name} `);
}
document.addEventListener("keydown", (ev) => {
  if (!ui.slash || ev.isComposing || !slashBox() || $("#slash")?.hidden !== false) return;
  // With a modifier these keys keep their own meaning (Shift-Tab back, Shift-↑ to select…).
  if (ev.metaKey || ev.ctrlKey || ev.altKey || (ev.shiftKey && ev.key !== "Escape")) return;
  const n = ui.slash.items.length, sel = ui.slash.sel;
  if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
    ui.slash.sel = sel < 0 ? (ev.key === "ArrowDown" ? 0 : n - 1) : (sel + (ev.key === "ArrowDown" ? 1 : n - 1)) % n;
  } else if ((ev.key === "Tab" || ev.key === "Enter") && sel >= 0) {
    slashPick(sel);
  } else if (ev.key === "Escape") {
    const el = slashBox();
    ui.slashOff = { key: el.dataset.key, value: el.value };
    slashClose();
  } else return;
  // Its own keys only: not a new line, not the next field, not closing the conversation window.
  ev.preventDefault();
  ev.stopImmediatePropagation();
  if (ui.slash) slashDraw();
}, true);
// Next tick: a refresh that rebuilds the box focuses its stand-in first and puts the caret back
// right after, and the caret decides whether the list shows.
document.addEventListener("focusin", (ev) => {
  const el = ev.target;
  if (el.tagName === "TEXTAREA" && el.dataset.session) setTimeout(() => { if (document.activeElement === el) slashUpdate(el); }, 0);
});
// Leaving the box closes it — unless the box was only rebuilt by a refresh, which puts the cursor
// straight back into its stand-in.
document.addEventListener("focusout", () => setTimeout(() => { if (ui.slash && !slashBox()) slashClose(); }, 0), true);
document.addEventListener("selectionchange", () => {
  const el = slashBox();
  if (el && slashQuery(el) === null) slashClose();
});
// Follow the box when its column or the conversation scrolls.
document.addEventListener("scroll", (ev) => { if (ev.target.id !== "slash") slashPlace(); }, true);

document.addEventListener("keydown", async (ev) => {
  const el = ev.target;
  if (ev.key === "Escape" && ui.finishAsk) { ev.preventDefault(); return answerFinishAsk(null); }
  if (ev.key === "Escape" && ui.launchMenu) { ev.preventDefault(); ui.launchMenu = null; return render(); }
  if (ev.key === "Escape" && ui.modal && ui.modal.pop) { ev.preventDefault(); ui.modal.pop = null; return drawPeek(false); }
  if (ev.key === "Escape" && ui.modal) { ev.preventDefault(); return closePeek(); }
  if (ev.key === "Escape" && ui.settings) { ev.preventDefault(); return closeSettings(); }
  if (ev.key === "Escape" && ui.drawer && !["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName)) { ev.preventDefault(); ui.drawer = null; return render(); }
  if (ev.key === "Escape" && el.tagName === "TEXTAREA" && el.dataset.session && !(ui.drafts[el.dataset.key] || "").trim()) {
    ui.msgOpen.delete(el.dataset.session); el.blur(); return render();
  }
  if (el.id === "capture" && ev.key === "Escape") { el.blur(); return; }
  if (ev.key !== "Enter" || ev.isComposing) return;  // isComposing: IME (e.g. Pinyin) candidate selection
  if (el.id === "capture") { ev.preventDefault(); return captureSubmit(); }   // focus stays: jot the next one
  if (el.tagName === "TEXTAREA" && el.dataset.session) return;   // Enter is a new line; only Send sends
  if (el.dataset.field) { ev.preventDefault(); return; }   // fields save with their Save button
  if (el.dataset.enter) {
    ev.preventDefault();
    const text = (ui.drafts[el.dataset.key] || "").trim();
    if (!text) return;
    delete ui.drafts[el.dataset.key];
    if (el.dataset.enter === "log") return act("log", { task: el.dataset.task, message: text }, T("Logged", "已记入日志"));
    if (el.dataset.enter === "addtodo") return act("addtodo", { task: el.dataset.task, text }, T("Todo added", "待办已添加"));
    if (el.dataset.enter === "addgrant") { ui.adding.delete(`${el.dataset.task}:grant`); return act("grant", { action: "add", task: el.dataset.task, text }, T("Grant added", "授权已添加")); }
    if (el.dataset.enter === "addref") return act("ref", { action: "add", task: el.dataset.task, ref: text }, T("Added", "已添加"));
  }
});


// ---- reorder projects by dragging a card on Projects & duties.
// Forgiving on purpose: anywhere on the page counts — the nearest card decides the spot. A card
// moves among the cards of its own kind (projects among projects, duties among duties); left or
// right of the nearest card in the grid.
function dropZone(ev) { return ev.target.closest && ev.target.closest("#proj-view.list"); }
function clearDropMarks() { document.querySelectorAll(".drop-before,.drop-after").forEach((n) => n.classList.remove("drop-before", "drop-after")); }
function nearestTarget(zone, x, y) {
  let best = null, dist = Infinity;
  for (const el of zone.querySelectorAll("[data-drag-project]")) {
    if ((el.dataset.kind || "") !== (ui.dragKind || "")) continue;
    const r = el.getBoundingClientRect();
    if (!r.height) continue;
    const mx = r.left + r.width / 2, my = r.top + r.height / 2;
    const d = Math.hypot(x - mx, y - my);
    if (d < dist) { dist = d; best = { el, before: x < mx }; }
  }
  return best;
}
document.addEventListener("dragstart", (ev) => {
  const el = ev.target.closest && ev.target.closest("[data-drag-project]");
  if (!el || (ev.target.closest && ev.target.closest("input, textarea, select"))) return;
  ui.dragging = el.dataset.dragProject;
  ui.dragKind = el.dataset.kind || "";
  ui.dropAt = null;
  ev.dataTransfer.effectAllowed = "move";
  ev.dataTransfer.setData("text/plain", ui.dragging);
  // Marking it has to wait a tick: changing the source element during dragstart cancels the drag.
  setTimeout(() => { if (ui.dragging) el.classList.add("dragging"); }, 0);
});
document.addEventListener("dragover", (ev) => {
  if (!ui.dragging || ui.dragCard) return;
  const zone = dropZone(ev);
  if (!zone) return;
  ev.preventDefault();
  ev.dataTransfer.dropEffect = "move";
  const t = nearestTarget(zone, ev.clientX, ev.clientY);
  clearDropMarks();
  if (!t || t.el.dataset.dragProject === ui.dragging) { ui.dropAt = null; return; }
  t.el.classList.add(t.before ? "drop-before" : "drop-after");
  ui.dropAt = { name: t.el.dataset.dragProject, before: t.before };
});
document.addEventListener("drop", (ev) => {
  const moving = ui.dragging, at = ui.dropAt;
  if (!moving || ui.dragCard || !dropZone(ev)) return;
  ev.preventDefault();
  finishDrag();
  if (!at) return;
  const order = projectNames().filter((n) => n !== moving);
  const i = order.indexOf(at.name);
  if (i < 0) return;
  order.splice(at.before ? i : i + 1, 0, moving);
  // Show the new order right away: the render at dragend would otherwise draw the old one, and
  // steady() would hold it (the pointer is still over the cards) when the saved order comes back.
  const rank = new Map(order.map((n, k) => [n, k]));
  projects().sort((a, b) => (rank.has(a.name) ? rank.get(a.name) : order.length) - (rank.has(b.name) ? rank.get(b.name) : order.length));
  for (const k of Object.keys(ui.shown)) if (k.startsWith("plist:")) delete ui.shown[k];
  act("project", { action: "order", names: order },
    ui.activeFirst ? T("Order saved — projects with live sessions still come first (Active first)", "顺序已保存——有 session 在跑的项目仍然排最前（活跃的在前）") : T("Order saved", "顺序已保存"));
});
function finishDrag() {
  ui.dragging = null;
  ui.dragKind = null;
  ui.dragCard = null;
  ui.dragFrom = null;
  ui.dragRow = null;
  ui.dropAt = null;
  clearDropMarks();
  document.querySelectorAll("[data-lane].drop").forEach((n) => n.classList.remove("drop"));
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

// ---- drag a card to another column: that column's status (see STATUS_OF). Running is the
// sessions' to decide, so nothing is dropped there. In Focus, dropping a card in its own column
// puts it in your order (focus.json, saved with `hq focus order`).
document.addEventListener("dragstart", (ev) => {
  const card = ev.target.closest && ev.target.closest("[data-drag-card]");
  if (!card) return;
  ui.dragging = "card:" + card.dataset.dragCard;      // holds rebuilds until the drop
  ui.dragCard = card.dataset.dragCard;
  // Where the card was drawn when the drag began: a refresh mid-drag can move the task to another
  // lane in the data while the screen (held until the drop) still shows the old one.
  const from = card.closest("[data-lane]");
  ui.dragFrom = from ? from.dataset.lane : null;
  ui.dragRow = card.closest(".swim-row");
  ui.dropAt = null;
  ev.dataTransfer.effectAllowed = "move";
  // Not text/plain: dropped on a message box, that would type the task id into it.
  ev.dataTransfer.setData("application/x-hq-task", ui.dragCard);
  setTimeout(() => card.classList.add("dragging"), 0);
});
document.addEventListener("dragover", (ev) => {
  if (!ui.dragCard) return;
  let zone = ev.target.closest && ev.target.closest("[data-lane]");
  // On a project's page split into phases a card stays in its phase's row: a drop changes status, never the phase.
  if (zone && ui.dragRow && zone.closest(".swim-row") !== ui.dragRow) zone = null;
  document.querySelectorAll("[data-lane].drop").forEach((n) => { if (n !== zone) n.classList.remove("drop"); });
  clearDropMarks();
  if (!zone) { ui.dropAt = null; return; }
  ev.preventDefault();
  ev.dataTransfer.dropEffect = "move";
  zone.classList.add("drop");
  const t = taskById(ui.dragCard);
  ui.dropAt = { lane: zone.dataset.lane };
  if (t && zone.dataset.lane === ui.dragFrom && zone.closest("#today-focus")) {
    let best = null, dist = Infinity;
    for (const el of zone.querySelectorAll("[data-drag-card]")) {
      const r = el.getBoundingClientRect(), mid = r.top + r.height / 2, d = Math.abs(ev.clientY - mid);
      if (d < dist) { dist = d; best = { el, before: ev.clientY < mid }; }
    }
    if (best && best.el.dataset.dragCard !== ui.dragCard) {
      best.el.classList.add(best.before ? "drop-before" : "drop-after");
      ui.dropAt = { lane: zone.dataset.lane, id: best.el.dataset.dragCard, before: best.before };
    }
  }
});
document.addEventListener("drop", async (ev) => {
  const id = ui.dragCard, at = ui.dropAt, from = ui.dragFrom;
  if (!id) return;
  ev.preventDefault();
  finishDrag();
  const t = taskById(id);
  if (!at || !t) return render();
  if (at.lane === from) {
    if (!at.id) return render();
    const order = focusIds().filter((x) => x !== id);
    const i = order.indexOf(at.id);
    if (i < 0) return render();
    order.splice(at.before ? i : i + 1, 0, id);
    const before = focusIds();
    ui.board.focus.ids = order;                    // shows at once; the save follows
    for (const l of LANES) delete ui.shown["focus:" + l];   // the pointer is still over the lane
    render();
    try { await api("focus", { action: "order", tasks: order }); }
    catch (e) {
      toast(String(e.message || e), true);
      ui.board.focus.ids = before;                 // not saved: back to the order hq has
      ui.lastSig = null;
      refresh();
    }
    return;
  }
  if (at.lane === "run") { render(); return toast(T("Running is up to its sessions — start or resume one from the card", "「在跑」由 session 决定——从卡片上新开或接上一个 session"), true); }
  const status = STATUS_OF[at.lane];
  const changed = t.status !== status;
  if (changed) { if (!(await setStatus(id, status))) return; }   // failed: its error toast stays
  else render();
  // Asks, your todos or a working session keep a card where it is, whatever its status says.
  const now = taskById(id) && lane(taskById(id));
  if (now && now !== at.lane && isOpen(taskById(id))) {
    const lead = changed ? T(`${id}: status saved, but`, `${id}：状态已改，但`)
      : T(`${id} is already ${STATUS_SHORT[status] || status}, but`, `${id} 本来就是「${STATUS_SHORT[status] || status}」，但`);
    toast(now === "you" && at.lane === "blocked" ? T(`${lead} a session stopped to wait on you (a permission or a question), so it stays in Needs you`, `${lead}有 session 停下来等你（授权或提问），所以留在「等你」`)
      : now === "you" ? T(`${lead} it stays in Needs you — it has an open ask or a todo of yours, or a session waiting on you`, `${lead}它还有没答的问题、你的待办，或有 session 停下来等你，所以留在「等你」`)
      : now === "run" ? T(`${lead} a session is working on it, so it stays in Running`, `${lead}有 session 在干活，所以留在「在跑」`)
      : T(`${lead} it stays in ${LANE_NAME[now]}`, `${lead}它留在「${LANE_NAME[now]}」`));
  }
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
// Which steady() lists the pointer is over (their data-okey, inner to outer). Leaving one whose
// reorder was held back redraws.
function setHover(keys) {
  const left = [...ui.hover].some((k) => !keys.has(k));
  ui.hover = keys;
  if (left && ui.heldBack) { ui.heldBack = false; setTimeout(render, 0); }
}
document.addEventListener("mouseover", (ev) => {
  const keys = new Set();
  for (let e = ev.target.closest && ev.target.closest("[data-okey]"); e; e = e.parentElement && e.parentElement.closest("[data-okey]")) keys.add(e.dataset.okey);
  if (keys.size !== ui.hover.size || [...keys].some((k) => !ui.hover.has(k))) setHover(keys);
}, true);
document.documentElement.addEventListener("mouseleave", () => setHover(new Set()));
document.addEventListener("mouseup", () => {
  ui.pointerDown = false;
  if (ui.pendingRender) { ui.pendingRender = false; setTimeout(render, 0); }
}, true);
