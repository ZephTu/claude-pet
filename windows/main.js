// Claude Pet on Windows — spike (T-129).
//
// The pet's own page (Resources/pet) in a transparent, always-on-top window. Everything the
// page shows comes from `pet-emit --watch`: the same Swift core the Mac app uses works out the
// state and prints it as JSON lines, and this file only hands each line to the page. The page
// never sees mouse events on the Mac either (PetHostView owns them); here preload.js plays that
// part: click-through outside the cat and the panel, drag to move, click to open the list.
"use strict";

const { app, BrowserWindow, protocol, ipcMain, screen, Tray, Menu, nativeImage, shell, clipboard } = require("electron");
const path = require("path");
const fs = require("fs");
const os = require("os");
const readline = require("readline");
const { spawn, execFile } = require("child_process");
const hqBoard = require("./board");
const { BoardServer } = require("./remote");
const { BoardEvents } = require("./board-events");

protocol.registerSchemesAsPrivileged([
  { scheme: "pet", privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } },
]);

const PET_ROOT = app.isPackaged ? path.join(process.resourcesPath, "pet") : path.join(__dirname, "..", "Resources", "pet");
const PET_HOME = process.env.PET_HOME || path.join(os.homedir(), ".claude", "pet");
const PET_EMIT = process.env.PET_EMIT || path.join(PET_HOME, process.platform === "win32" ? "pet-emit.exe" : "pet-emit");
const PREFS = path.join(app.getPath("userData"), "prefs.json");
const LOG = path.join(app.getPath("userData"), "pet.log");
// Builds before productName was set kept their data under the package name: carry the saved
// position and language over once.
const OLD_DATA = path.join(app.getPath("appData"), "claude-pet-windows");
try {
  const old = path.join(OLD_DATA, "prefs.json");
  if (!fs.existsSync(PREFS) && fs.existsSync(old)) {
    fs.mkdirSync(path.dirname(PREFS), { recursive: true });
    fs.copyFileSync(old, PREFS);
  }
} catch (_) {}

// PetLayout.windowSize: the page is laid out for exactly this.
const WIDTH = 480;
const HEIGHT = 280;

let win = null;
let tray = null;
let watcher = null;
let ready = false;
let last = null;

function log(...args) {
  try { fs.appendFileSync(LOG, new Date().toISOString() + " " + args.join(" ") + "\n"); } catch (_) {}
}

function readPrefs() {
  try { return JSON.parse(fs.readFileSync(PREFS, "utf8")); } catch (_) { return {}; }
}

function writePrefs(p) {
  try { fs.writeFileSync(PREFS, JSON.stringify(p)); } catch (_) {}
}

function language() {
  const p = readPrefs();
  if (p.lang === "zh" || p.lang === "en") return p.lang;
  return app.getLocale().toLowerCase().startsWith("zh") ? "zh" : "en";
}

// ------------------------------------------------------------------ settings from the Mac's menu
// Chatter.noticeHoldChoices / noticeCountChoices: a stored value not on offer (a hand-edited
// prefs.json) falls back to the default, as Chatter.noticeHold(stored:) does.
const NOTICE_HOLDS = [10, 30, 60];
const NOTICE_COUNTS = [1, 2, 3];

function noticeHold() {
  const v = readPrefs().noticeHoldSeconds;
  return NOTICE_HOLDS.includes(v) ? v : 30;
}

function noticeCount() {
  const v = readPrefs().noticeCount;
  return NOTICE_COUNTS.includes(v) ? v : 3;
}

// PetSkins: every skin draws the same nine poses from skins/<id>/assets; one missing a picture
// is listed greyed out ("no artwork yet") and never shown.
const SKINS = [{ id: "cat", en: "Cat", zh: "小猫" }, { id: "cultivator", en: "Cultivator", zh: "修仙者" }];
const POSES = ["idle", "working", "waiting", "sleeping", "urgent", "reading", "compacting", "finished", "awaiting-agent"];

function skinComplete(id) {
  return /^[a-z0-9-]+$/.test(id) && POSES.every((p) => fs.existsSync(path.join(PET_ROOT, "skins", id, "assets", p + ".png")));
}

/** PetSkins.resolve: the stored choice while it can still be drawn, the cat otherwise. Worked
 * out once (the tray icon asks on every --watch line), again when the user picks one. */
let resolvedSkin = null;
function skin() {
  if (resolvedSkin) return resolvedSkin;
  const v = readPrefs().skin;
  resolvedSkin = SKINS.some((s) => s.id === v) && skinComplete(v) ? v : "cat";
  return resolvedSkin;
}

function keepListOpen() {
  return readPrefs().keepListOpen === true;
}

/** Bottom-right of the primary display's work area, unless the user dragged it somewhere. */
function startPosition() {
  const p = readPrefs();
  const area = screen.getPrimaryDisplay().workArea;
  if (Number.isFinite(p.x) && Number.isFinite(p.y)) {
    const onScreen = screen.getAllDisplays().some((d) => {
      const a = d.workArea;
      return p.x + WIDTH > a.x && p.x < a.x + a.width && p.y + HEIGHT > a.y && p.y < a.y + a.height;
    });
    if (onScreen) return { x: p.x, y: p.y };
  }
  return { x: area.x + area.width - WIDTH, y: area.y + area.height - HEIGHT };
}

function serveFiles() {
  const root = path.resolve(PET_ROOT);
  protocol.handle("pet", async (request) => {
    const url = new URL(request.url);
    const file = path.resolve(root, "." + decodeURIComponent(url.pathname));
    if (url.host !== "app" || !(file + path.sep).startsWith(root + path.sep) && file !== root) {
      return new Response("not found", { status: 404 });
    }
    try {
      const data = await fs.promises.readFile(file);
      return new Response(data, { headers: { "content-type": mime(file) } });
    } catch (_) {
      return new Response("not found", { status: 404 });
    }
  });
}

function mime(file) {
  const ext = path.extname(file).toLowerCase();
  return {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp", ".json": "application/json", ".svg": "image/svg+xml",
  }[ext] || "application/octet-stream";
}

function createWindow() {
  const pos = startPosition();
  win = new BrowserWindow({
    x: pos.x, y: pos.y, width: WIDTH, height: HEIGHT,
    transparent: true, frame: false, resizable: false, movable: true, hasShadow: false,
    skipTaskbar: true, alwaysOnTop: true, fullscreenable: false, maximizable: false, minimizable: false,
    backgroundColor: "#00000000", show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      additionalArguments: ["--pet-lang=" + language()],
    },
  });
  win.setAlwaysOnTop(true, "floating");
  if (process.platform === "darwin") win.setVisibleOnAllWorkspaces(true);
  // Clicks fall through to whatever is behind, except where preload.js says there is a cat or
  // a panel under the pointer; `forward` keeps mouse moves coming so it can tell.
  win.setIgnoreMouseEvents(true, { forward: true });
  loadPetPage();
  win.webContents.on("did-finish-load", () => {
    ready = true;
    lastDrawn = "";
    // The page loaded at its defaults (WebBridge's onReady): three notices, the list shut.
    run(`window.setMaxNotices(${noticeCount()});`);
    win.webContents.send("pinned", keepListOpen());
    if (keepListOpen()) openPinnedList();
    // As the Mac's onReady: a broken install is said once (checkProblem).
    checkProblem();
    // WKWebView draws a thin overlay scrollbar; Chromium on Windows a wide grey one that eats
    // into the list. Made thin here, leaving the Mac's page as it is.
    win.webContents.insertCSS(
      "::-webkit-scrollbar { width: 6px; height: 6px; background: transparent; }"
      + " ::-webkit-scrollbar-thumb { background: rgba(128,128,128,0.45); border-radius: 3px; }"
      + " ::-webkit-scrollbar-button { display: none; }").catch(() => {});
    // Only the first load: a skin switch reloads the page and must not bring back a hidden pet.
    if (!shownOnce) { shownOnce = true; win.showInactive(); }
    if (last || paused) draw(true);
    if (earlySay && Date.now() < earlySay.until && !paused) run(earlySay.script);
    earlySay = null;
    // PET_SHOT=out.png [PET_SHOT_JS=script]: render the window to a PNG after a few seconds and
    // quit — how CI and a Mac without screen-capture permission check what the window draws.
    // PET_SHOT_BOARD=1: the task board's window instead (the script runs on the board);
    // PET_SHOT_BOARD=T-123: opened at that task, as a click on a session bound to it does.
    // PET_SHOT_HEALTH=1: the connection report's window (tray → Connection Status…).
    if (process.env.PET_SHOT) {
      if (process.env.PET_SHOT_BOARD) openBoard(/^T-\d+$/.test(process.env.PET_SHOT_BOARD) ? process.env.PET_SHOT_BOARD : "");
      if (process.env.PET_SHOT_HEALTH) showHealth();
      setTimeout(async () => {
        try {
          const shot = process.env.PET_SHOT_HEALTH && healthWin ? healthWin
            : process.env.PET_SHOT_BOARD && boardWin ? boardWin : win;
          if (process.env.PET_SHOT_JS) await shot.webContents.executeJavaScript(process.env.PET_SHOT_JS);
          await new Promise((r) => setTimeout(r, 800));
          const img = await shot.webContents.capturePage();
          fs.writeFileSync(process.env.PET_SHOT, img.toPNG());
          console.log("wrote", process.env.PET_SHOT, JSON.stringify(last && { mood: last.mood, pose: last.pose, sessions: (last.sessions || []).length }));
        } catch (e) {
          console.error("shot failed:", e);
          process.exitCode = 1;
        }
        app.quit();
      }, Number(process.env.PET_SHOT_DELAY || 4000));
    }
  });
  win.webContents.on("console-message", (_e, level, message) => { if (level >= 2) log("page:", message); });
  win.on("closed", () => { win = null; ready = false; });
}

let shownOnce = false;
/** A line --watch said before the page was ready to show it (see push). */
let earlySay = null;

/** PetPanel.loadPetPage: the page picks its pictures from `?skin=`. */
function loadPetPage() {
  if (!win) return;
  ready = false;
  // The new page's preload.js starts out thinking clicks fall through, and a hover card asked
  // for on the old page must not land on the new one.
  win.setIgnoreMouseEvents(true, { forward: true });
  detailWanted = "";
  setCardUp(false);
  // The new page starts with the list shut; its layout reports say when it opens.
  tellWatcher("list", false);
  // A second pick before the first page is in aborts that load (ERR_ABORTED).
  win.loadURL("pet://app/index.html?skin=" + skin()).catch((e) => { if (!/ERR_ABORTED/.test(e.message)) log("load failed:", e.message); });
}

/** PetPanel.setSkin: reloaded rather than told, as on the Mac — did-finish-load puts back the
 * state, the open list and the notice limit, so nothing of the old skin is left behind. */
function setSkin(id) {
  if (id === skin() || !SKINS.some((s) => s.id === id) || !skinComplete(id)) return;
  writePrefs({ ...readPrefs(), skin: id });
  resolvedSkin = id;
  loadPetPage();
  updateTray(last);
  buildTray();
}

/** Keep List Open (the Mac's toggleKeepListOpen): the list goes up or down with it, and while it
 * is on nothing but turning it off closes the list (preload.js keeps a click on the cat from it). */
function setKeepListOpen(on) {
  writePrefs({ ...readPrefs(), keepListOpen: on });
  if (win) win.webContents.send("pinned", on);
  if (on) openPinnedList(); else run("window.setPanelOpen(false);");
  buildTray();
}

function openPinnedList() {
  run("window.setPanelOpen(true);");
  // As a click that opens the list: the footer's "N aged out" has been seen.
  panelOpened();
}

/** WebBridge.closePanel: "done with the list now" (after a jump, say); a no-op while pinned. */
function closePanel() {
  if (!keepListOpen()) run("window.setPanelOpen(false);");
}

function setNoticeHold(seconds) {
  writePrefs({ ...readPrefs(), noticeHoldSeconds: seconds });
  buildTray();
}

function setNoticeCount(n) {
  writePrefs({ ...readPrefs(), noticeCount: n });
  run(`window.setMaxNotices(${n});`);
  buildTray();
}

// Take a Nap / Wake Up (the Mac's paused, not kept across a restart either): the cat sleeps
// with nothing listed, says nothing and counts nothing. --watch keeps running and `last` stays
// current (the board's quota and unread counts); the pet draws the fixed state below, and the
// board's dots go empty, as the Mac's come from what the nap pushed. Notices come
// only on the line where a session finished, and those lines are not shown while napping, so
// waking up does not replay what happened meanwhile.
let paused = false;
const NAP = {
  mood: "idle", phase: "", pose: "sleeping", mark: "none", waitingProject: null, waitingOn: "",
  waitingSessionId: "", waitingAskId: "", badge: "", sessions: [], finished: [], hidden: 0,
};

function togglePause() {
  paused = !paused;
  tellWatcher("nap", paused);
  ipcHush();
  draw(true);
  updateTray(last);
  buildTray();
}

function js(value) {
  return JSON.stringify(value === undefined ? null : value);
}

function run(script) {
  if (!win || !ready) return;
  win.webContents.executeJavaScript(script).catch((e) => log("js failed:", e.message));
}

/** One line from pet-emit --watch, drawn. */
function push(s) {
  overlay(s);
  last = s;
  pendingDropped += Number(s.dropped) || 0;
  // Pinned open, the list is always being looked at: the note gets its ten seconds from now.
  if (Number(s.dropped) && keepListOpen()) panelOpened();
  draw(false);
  syncTray(s);
  // Sessions that just finished, each in a notice of its own (the page skips them while the
  // list is open), up for the hold picked in the tray. Only on the line they came on: a redraw
  // does not repeat them. None while napping (the Mac's announceFinishes).
  if (!paused) {
    for (const n of s.notices || []) {
      run(`window.notify(${js(n.text)}, ${noticeHold() * 1000}, ${js(n.emphasis)}, ${js(n.sessionId)}, ${opensSomewhere(n.sessionId)});`);
    }
    // The cat speaking up (PetChatter: quota, long context, a rut, a long run, "done", back
    // from away) and its brief reactions to a finish or trouble, as WebBridge.say / flash.
    // --watch already kept quiet while the list, a card or the nap would hide them.
    if (s.say && typeof s.say.text === "string") {
      const hold = Number(s.say.holdMs) || 6000;
      const script = `window.say(${js(s.say.text)}, ${hold}, ${js(s.say.emphasis || "")}, ${js(s.say.variant || "chat")});`;
      // The page still loading (the pet just started, a skin switch): said once it is in,
      // while still worth saying. --watch has already recorded it as said.
      if (ready) run(script); else earlySay = { script, until: Date.now() + hold };
    }
    if (s.flash && typeof s.flash.kind === "string") {
      run(`window.flash(${js(s.flash.kind)}, ${js(s.flash.pose || "")}, ${js(s.flash.mark || "")});`);
    }
  }
  updateTray(s);
}

/** What the pet shows: the last --watch line, or the nap. `force` redraws everything (a page
 * that just loaded, a nap begun or ended). */
let drawnState = null;
function draw(force) {
  const s = paused ? NAP : last;
  if (!s) return;
  const prev = force ? null : drawnState;
  drawnState = s;
  if (!prev || prev.mood !== s.mood || prev.waitingProject !== s.waitingProject || prev.waitingOn !== s.waitingOn
      || prev.waitingAskId !== s.waitingAskId) {
    const ask = { sessionId: s.waitingSessionId || "", askId: s.waitingAskId || "" };
    run(`window.setMood(${js(s.mood)}, ${js(s.waitingProject)}, ${js(s.waitingOn || "")}, "", ${js(ask)});`);
  }
  if (!prev || prev.pose !== s.pose || prev.mark !== s.mark) run(`window.setCatLook(${js(s.pose)}, ${js(s.mark)});`);
  if (!prev || prev.phase !== s.phase) run(`window.setPhase(${js(s.phase)});`);
  if (!prev || prev.badge !== s.badge) run(`window.setBadge(${js(s.badge)});`);
  drawSessions(s);
}

// Unread finishes that aged out unseen. --watch says so on one line, usually when it starts,
// before the list is ever opened: kept for the footer until the list has been open a while.
let pendingDropped = 0;
function panelOpened() {
  if (pendingDropped) setTimeout(() => { pendingDropped = 0; }, 10000);
}
ipcMain.on("panel-opened", panelOpened);

/** The rows, the muted count (the footer's "N muted") and the Finished group. No HQ asks or
 * jobs yet. */
let lastDrawn = "";
function drawSessions(s) {
  // Napping: an empty list, whatever changed underneath (a mute, a read).
  if (paused) s = NAP;
  if (!s) return;
  // Clicks that go to the board (see clickTarget) make a row clickable even with no terminal.
  const boardRows = (rows) => (rows || []).map((r) => (routeOf(r.sessionId, r.termKind).task ? { ...r, opensBoard: true } : r));
  const script = `window.setSessions(${js(boardRows(s.sessions))}, ${Number(s.hidden) || 0}, ${js(boardRows(s.finished))}, ${paused ? 0 : pendingDropped}, [], []);`;
  // As WebBridge: the same payload is not drawn twice (did-finish-load clears it).
  if (script === lastDrawn || !win || !ready) return;
  lastDrawn = script;
  // Rebuilding the list drops the row under the pointer's highlight (and with it the row's ↗,
  // clock and ×); the rows' ages tick every second here, not every five as on the Mac, so
  // preload.js puts it back once the list is redrawn.
  win.webContents.executeJavaScript(script)
    .then(() => { if (win) win.webContents.send("redrawn"); })
    .catch((e) => log("js failed:", e.message));
}

/** A session id from the page, safe as one argument. */
function sessionToken(id) {
  return typeof id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(id) ? id : "";
}

/** `pet-emit --mute | --unmute-all | --snooze`; the next --watch line shows the result. */
function marks(args) {
  execFile(PET_EMIT, args, { windowsHide: true, timeout: 10000 }, (err, _out, stderr) => {
    if (err) log(args[0], "failed:", err.message.trim(), String(stderr || "").trim());
  });
}

// What a click changed, shown at once (as the Mac redraws at once) and kept on top of the
// --watch lines that arrive before pet-emit has written it — rows' ages make one every second —
// so a muted row does not flicker back. Each holds until a line agrees, or PENDING_MS.
const PENDING_MS = 3000;
const pending = { muted: new Map(), snoozed: new Map(), read: [] };

function overlay(s) {
  const now = Date.now();
  const rows = () => s.sessions || [];
  for (const [id, until] of pending.muted) {
    if (now > until || !rows().some((r) => r.sessionId === id)) { pending.muted.delete(id); continue; }
    s.sessions = rows().filter((r) => r.sessionId !== id);
    s.hidden = (Number(s.hidden) || 0) + 1;
  }
  for (const [id, p] of pending.snoozed) {
    const row = rows().find((r) => r.sessionId === id);
    if (now > p.until || !row || row.snoozedFor) { pending.snoozed.delete(id); continue; }
    row.snoozedFor = p.text;
  }
  pending.read = pending.read.filter((p) => now <= p.until);
  if (pending.read.length && s.finished) s.finished = s.finished.filter((r) => !pending.read.some((p) => p.match(r)));
}

/** The tray offers Unmute All while something is muted: rebuilt when that count moves. */
let trayMuted = 0;
function syncTray(s) {
  const n = Number(s && s.hidden) || 0;
  if (n === trayMuted) return;
  trayMuted = n;
  buildTray();
}

/** The row's ×. The list stays open, as on the Mac: muting several in a row is the common case. */
function mute(sessionId) {
  const id = sessionToken(sessionId);
  if (!id) return;
  marks(["--mute", id]);
  if (!last || !last.sessions || !last.sessions.some((r) => r.sessionId === id)) return;
  pending.muted.set(id, Date.now() + PENDING_MS);
  last.sessions = last.sessions.filter((r) => r.sessionId !== id);
  last.hidden = (Number(last.hidden) || 0) + 1;
  drawSessions(last);
  syncTray(last);
}

function snooze(id, minutes) {
  marks(["--snooze", id, String(minutes)]);
  const row = last && (last.sessions || []).find((r) => r.sessionId === id);
  if (!row) return;
  // Snooze.remaining's wording for a fresh delay (Chatter.duration).
  const text = `${minutes}m`;
  pending.snoozed.set(id, { text, until: Date.now() + PENDING_MS });
  row.snoozedFor = text;
  drawSessions(last);
}

/** The row's clock: 5 / 15 / 30 minutes at the pointer (the Mac's askSnooze). A menu rather
 * than a fixed delay: "later" without saying when is how an item gets lost. */
const SNOOZE_MINUTES = [5, 15, 30];
function askSnooze(sessionId) {
  const id = sessionToken(sessionId);
  if (!id || !win) return;
  const zh = language() === "zh";
  Menu.buildFromTemplate([
    { label: zh ? "多久后提醒我…" : "Remind me in…", enabled: false },
    ...SNOOZE_MINUTES.map((m) => ({ label: zh ? `${m} 分钟` : `${m} minutes`, click: () => snooze(id, m) })),
  ]).popup({ window: win });
}

// ------------------------------------------------------------------ where a click on a session goes
// The Mac's ClickTarget ("Clicking a Session Opens"): its terminal, or its task on the board.
// Kept in prefs.json; the tray and the board's settings show the same value.
function clickTarget() {
  return readPrefs().clickTarget === "board" ? "board" : "terminal";
}

function setClickTarget(value) {
  const v = value === "board" ? "board" : "terminal";
  if (v === clickTarget()) return;
  writePrefs({ ...readPrefs(), clickTarget: v });
  // Rows bound to a task but with no terminal become clickable, or stop being.
  lastDrawn = "";
  if (last) drawSessions(last);
  buildTray();
}

/** ClickTarget.route: { task } for the board, { jump: true } for the terminal, {} for nowhere. */
function routeOf(sessionId, termKind) {
  const task = clickTarget() === "board" && sessionId ? hqBoard.taskBySession()[sessionId] : "";
  if (task) return { task };
  return termKind ? { jump: true } : {};
}

/** Whether a click on the session goes anywhere (the Mac's route(for:) != .nowhere). */
function opensSomewhere(sessionId) {
  const r = routeOf(sessionId, jumpKind(sessionId));
  return !!(r.task || r.jump);
}

/** Opens a session where a click on it goes. False when there is nowhere to go (or that jump is
 * already under way). */
function openSession(sessionId, termKind) {
  const r = routeOf(sessionId, termKind);
  if (r.task) { openBoard(r.task, sessionId); return true; }
  return r.jump ? jump(sessionId) : false;
}

/** The terminal a session's row can jump to, or "" (PetWatch.row's termKind). */
function jumpKind(sessionId) {
  const row = ((last && last.sessions) || []).find((r) => r.sessionId === sessionId);
  return (row && row.termKind) || "";
}

// What pet-emit prints in the pet's language (the hover card, notices): the tray's choice.
function emitEnv() {
  return { ...process.env, CLAUDE_PET_LANG: language() };
}

// ------------------------------------------------------------------ the HQ task board
// BoardWindow on the Mac: an ordinary window (it takes the keyboard) showing the unchanged
// Resources/pet/board page; its requests go to board.js. Opened from the tray menu (the cat's
// right click shows it too), a double click on the cat, or a click on a session bound to a task
// (clickTarget).
let boardWin = null;
// When the board last lost the keyboard: the first click of a double click on the cat takes it.
let boardBlurAt = 0;
// What to show once the board's page has loaded (a click that opened it at a task).
let boardReveal = null;

/** BoardWindow.present: `task` (T-123) opens that task, with `session` picked out. */
function revealScript(task, session) {
  if (!task) return "window.hqRefresh && window.hqRefresh();";
  const t = /^T-\d+$/.test(task) ? task : "";
  const sid = /^[0-9A-Za-z-]+$/.test(session || "") ? session : "";
  return `window.hqReveal && window.hqReveal(${js(t)}, ${js(sid)});`;
}

function openBoard(task = "", session = "") {
  if (boardWin) {
    if (boardWin.isMinimized()) boardWin.restore();
    boardWin.show();
    boardWin.focus();
    // Still loading: did-finish-load runs the newest pick.
    if (boardWin.webContents.isLoading()) boardReveal = revealScript(task, session);
    else boardWin.webContents.executeJavaScript(revealScript(task, session)).catch(() => {});
    return;
  }
  const saved = readPrefs().board || {};
  const onScreen = Number.isFinite(saved.x) && screen.getAllDisplays().some((d) => {
    const a = d.workArea;
    return saved.x + 200 > a.x && saved.x < a.x + a.width && saved.y + 100 > a.y && saved.y < a.y + a.height;
  });
  const area = (onScreen ? screen.getDisplayNearestPoint({ x: saved.x, y: saved.y }) : screen.getPrimaryDisplay()).workArea;
  boardWin = new BrowserWindow({
    width: Math.min(saved.width || 1180, area.width), height: Math.min(saved.height || 760, area.height),
    minWidth: 760, minHeight: 480,
    ...(onScreen ? { x: saved.x, y: saved.y } : {}),
    title: "HQ", backgroundColor: "#23201d", show: false, autoHideMenuBar: true,
    icon: path.join(PET_ROOT, "skins", "cat", "assets", "idle.png"),
    webPreferences: {
      preload: path.join(__dirname, "board-preload.js"),
      contextIsolation: true,
      additionalArguments: ["--pet-lang=" + language()],
    },
  });
  boardWin.removeMenu();
  if (saved.maximized) boardWin.maximize();
  const wc = boardWin.webContents;
  // The board's own pages only (BoardNavigation): a web link opens in the browser, anything
  // else goes nowhere, and no new windows.
  const outside = (url) => { if (/^(https?|mailto):/i.test(url)) shell.openExternal(url); };
  wc.setWindowOpenHandler(({ url }) => { outside(url); return { action: "deny" }; });
  wc.on("will-navigate", (e, url) => {
    if (url.startsWith("pet://app/")) return;
    e.preventDefault();
    outside(url);
  });
  wc.on("console-message", (_e, level, message) => { if (level >= 2) log("board:", message); });
  boardWin.once("ready-to-show", () => boardWin && boardWin.show());
  const remember = () => {
    if (!boardWin || boardWin.isMinimized()) return;
    const maximized = boardWin.isMaximized();
    const b = maximized ? (readPrefs().board || {}) : boardWin.getBounds();
    writePrefs({ ...readPrefs(), board: { x: b.x, y: b.y, width: b.width, height: b.height, maximized } });
  };
  boardWin.on("resized", remember);
  boardWin.on("moved", remember);
  boardWin.on("maximize", remember);
  boardWin.on("unmaximize", remember);
  boardWin.on("closed", () => { boardWin = null; });
  boardWin.on("blur", () => { boardBlurAt = Date.now(); });
  if (task) boardReveal = revealScript(task, session);
  wc.on("did-finish-load", () => {
    const script = boardReveal;
    if (!script) return;
    boardReveal = null;
    wc.executeJavaScript(script).catch(() => {});
  });
  boardWin.loadURL("pet://app/board/board.html");
}

/** The Mac's toggleBoard, for a double click on the cat: put the board away when it is in front
 * (it had the keyboard until the double click's first press took it), else bring it up. */
function toggleBoard() {
  const inFront = boardWin && boardWin.isVisible() && !boardWin.isMinimized()
    && (boardWin.isFocused() || Date.now() - boardBlurAt < 1500);
  if (inFront) boardWin.hide();
  else openBoard();
}

// WebBridge.dotKeys: what the board reads of a pet row.
const DOT_KEYS = new Set(["state", "quiet", "asks", "agent", "struggle", "background", "activity", "replied",
  "context", "contextTokens", "contextBudget", "askId", "approveText", "promptAsk", "askKind"]);

hqBoard.configure({
  L: (en, zh) => (language() === "zh" ? zh : en),
  petEmit: PET_EMIT,
  petEnv: emitEnv,
  // BoardWindow's "pet" read: unread finishes per session (the list's Finished group), and each
  // row's state and held prompt as WebBridge.dotState (the page offers Allow / Deny, a question's
  // picks or a plan's feedback from these). None while napping.
  petState: () => {
    const unread = {};
    for (const r of (last && last.finished) || []) if (r.sessionId) unread[r.sessionId] = (unread[r.sessionId] || 0) + (r.count || 1);
    const dots = {};
    for (const r of (!paused && last && last.sessions) || []) {
      if (!r.sessionId) continue;
      dots[r.sessionId] = Object.fromEntries(Object.entries(r).filter(([k]) => DOT_KEYS.has(k)));
    }
    // The status bar's quota, as --watch last read it (absent when there is no usable reading).
    return { unread, dots, clickTarget: clickTarget(), usage: (last && last.usage) || null };
  },
  onClickTarget: setClickTarget,
  // A reply read on the board: its finishes leave the pet's list too, once (the drawer and Peek
  // say so on every refresh).
  onSeen: (sid) => {
    if (!(((last && last.finished) || []).some((r) => r.sessionId === sid))) return;
    markRead({ session: sid });
  },
});

// Phone access (remote.js): the board served to paired phones, off until turned on in the
// board's settings; told of changes by a watch on hq's and the pet's files (board-events.js).
const boardEvents = new BoardEvents({ roots: () => hqBoard.watchRoots().concat([PET_HOME]), dropReads: hqBoard.dropReads, log });
const phoneAccess = new BoardServer({
  handle: hqBoard.handle, readPrefs, writePrefs, root: PET_ROOT, petHome: PET_HOME, events: boardEvents, log,
  L: () => (en, zh) => (language() === "zh" ? zh : en), lang: language,
});
hqBoard.configure({ remote: phoneAccess });

// Only the board window's own page (BoardNavigation.trusted): its main frame, on pet://app.
ipcMain.handle("hq", (e, body) => {
  if (!boardWin || e.sender !== boardWin.webContents || !e.senderFrame || e.senderFrame !== e.sender.mainFrame
      || !e.senderFrame.url.startsWith("pet://app/")) {
    return { error: "not from the board" };
  }
  return hqBoard.handle(body, boardWin);
});

function startWatcher() {
  if (!fs.existsSync(PET_EMIT)) {
    log("no pet-emit at", PET_EMIT);
    run(`window.say(${js(language() === "zh" ? "找不到 pet-emit，请先运行 install.ps1" : "pet-emit is missing: run install.ps1 first")}, 30000);`);
    setTimeout(startWatcher, 10000);
    return;
  }
  const restart = () => { watcher = null; if (!quitting) setTimeout(startWatcher, 2000); };
  try {
    watcher = spawn(PET_EMIT, ["--watch"], { windowsHide: true, stdio: ["pipe", "pipe", "pipe"], env: emitEnv() });
  } catch (e) {
    log("pet-emit --watch did not start:", e.message);
    return restart();
  }
  // Blocked by antivirus or AppLocker, say: logged and tried again, never an uncaught exception.
  let restarted = false;
  const again = () => { if (!restarted) { restarted = true; restart(); } };
  watcher.on("error", (e) => { log("pet-emit --watch failed:", e.message); again(); });
  watcher.stdin.on("error", () => {});
  // A fresh --watch knows nothing of what the window shows: tell it all of it.
  for (const [key, on] of Object.entries(shellState)) watcher.stdin.write(`${key} ${on ? 1 : 0}\n`);
  log("watching with", PET_EMIT, "pid", watcher.pid);
  readline.createInterface({ input: watcher.stdout }).on("line", (line) => {
    try { push(JSON.parse(line)); } catch (e) { log("bad line:", e.message); }
  });
  watcher.stderr.on("data", (d) => log("pet-emit:", String(d).trim()));
  watcher.on("exit", (code) => {
    log("pet-emit --watch exited", code);
    again();
  });
}

// ------------------------------------------------------------------ connection status
// The Mac's HealthCollector / HealthWindow: `pet-emit --health` runs the checks, health.html shows
// them in a small frameless window beside the pet. `--quick` (hooks missing, pet-emit gone, nowhere
// to write) decides the tray's ⚠ item and the one line the cat says about it.

const PROBLEM_EVERY = 60 * 1000;
let healthWin = null;
let healthDoc = null;           // the report on show, for Copy
let lastJumpFailure = "";
let problem = null;             // --quick's problem, or null
let mentionedProblem = null;    // its key once the cat said it

/** pet-emit --health [args], parsed; null when it did not run or said nothing usable. */
function healthReport(args) {
  return new Promise((resolve) => {
    if (!fs.existsSync(PET_EMIT)) return resolve(null);
    // execFile answers on the pipes' close: a process `claude --version` left behind holding them
    // would keep it waiting past its own timeout.
    const giveUp = setTimeout(() => { log("pet-emit --health: no answer"); resolve(null); }, 25000);
    execFile(PET_EMIT, ["--health", ...args], { windowsHide: true, timeout: 20000, env: emitEnv() }, (err, out) => {
      clearTimeout(giveUp);
      if (err) { log("pet-emit --health failed:", err.message.trim()); return resolve(null); }
      try { resolve(JSON.parse(String(out))); } catch (e) { log("pet-emit --health:", e.message); resolve(null); }
    });
  });
}

/** Why the jump failed, for the report's "Terminal jump": WindowsJump's own words (pet-emit's
 * `fail`), never the exec error's text, which carries pet-emit's path and the session id. */
function jumpFailure(err, stderr) {
  if (err.killed) return "timed out";
  const line = String(stderr || "").split(/\r?\n/).map((l) => l.trim()).filter(Boolean).pop();
  if (!line) return typeof err.code === "number" ? `exit ${err.code}` : "did not run";
  return line.replace(/^pet-emit:\s*/, "").slice(0, 200);
}

/** The quick check: rebuilds the tray when the problem changes, and (unless `say` is false) has
 * the cat say a new one once, as the Mac's mentionProblem. Once fixed, it is said again if it
 * comes back. */
async function checkProblem({ say = true } = {}) {
  const doc = await healthReport(["--quick"]);
  if (!doc) return;
  const p = doc.problem && doc.problem.key ? doc.problem : null;
  const changed = JSON.stringify(p) !== JSON.stringify(problem);
  problem = p;
  if (changed) buildTray();
  if (!p) { mentionedProblem = null; return; }
  if (!say || paused || mentionedProblem === p.key) return;
  mentionedProblem = p.key;
  const zh = language() === "zh";
  const text = zh ? `${p.name}：${p.detail} — 右键点我看详情` : `${p.name}: ${p.detail} — right-click me for details`;
  run(`window.say(${js(text)}, 12000, ${js(p.name)}, "warn");`);
}

/** Beside the pet, as HealthWindow.show(near:): to its left, else its right, on its screen. */
function placeHealth(height) {
  if (!healthWin || !win) return;
  const pet = win.getBounds();
  const area = screen.getDisplayMatching(pet).workArea;
  const width = healthWin.getBounds().width;
  let x = pet.x - width - 12;
  if (x < area.x) x = pet.x + pet.width + 12;
  x = Math.min(Math.max(x, area.x + 8), area.x + area.width - width - 8);
  let y = Math.round(pet.y + pet.height / 2 - height / 2);
  y = Math.min(Math.max(y, area.y + 8), area.y + area.height - height - 8);
  healthWin.setBounds({ x, y, width, height });
}

/** The report, run afresh each time it is opened (as the Mac: `claude --version` is not run on a
 * timer). Shown without taking the keyboard from what the user was typing in; a click on it
 * gives it the keyboard, and then Esc closes it. */
function showHealth() {
  // Not the Mac's `mentionedProblem = nil`: there the cat speaks only at page load, here
  // checkProblem's minute would say the same problem again right after the user read the report.
  if (!healthWin) {
    healthWin = new BrowserWindow({
      width: 362, height: 120, show: false, frame: false, transparent: true, resizable: false,
      skipTaskbar: true, alwaysOnTop: true, fullscreenable: false, maximizable: false, minimizable: false,
      hasShadow: false, backgroundColor: "#00000000", title: "Claude Pet",
      webPreferences: {
        preload: path.join(__dirname, "health-preload.js"),
        contextIsolation: true,
        additionalArguments: ["--pet-lang=" + language()],
      },
    });
    healthWin.setAlwaysOnTop(true, "floating");
    healthWin.removeMenu();
    const wc = healthWin.webContents;
    wc.setWindowOpenHandler(() => ({ action: "deny" }));
    wc.on("will-navigate", (e) => e.preventDefault());
    healthWin.on("closed", () => { healthWin = null; healthDoc = null; });
    healthWin.loadFile(path.join(__dirname, "health.html"));
  }
  const target = healthWin;
  healthReport(lastJumpFailure ? ["--jump-failure", lastJumpFailure] : []).then((doc) => {
    if (healthWin !== target) return;
    // The page shows the report Copy copies: until a new one is in, the one already up.
    if (doc) healthDoc = doc;
    const send = () => target.webContents.executeJavaScript(`window.showHealth(${js(doc || {})});`).catch(() => {});
    if (target.webContents.isLoading()) target.webContents.once("did-finish-load", send);
    else send();
  });
  // Already up: brought forward. New: shown by its first "fit", with "Checking…" until the
  // report is in (Claude Code's --version takes a moment).
  if (healthWin.isVisible()) healthWin.showInactive();
}

ipcMain.on("health", (e, m) => {
  if (!healthWin || e.sender !== healthWin.webContents || !m) return;
  if (m.op === "copy") {
    if (healthDoc && typeof healthDoc.summary === "string") clipboard.writeText(healthDoc.summary);
  } else if (m.op === "close") {
    healthWin.close();
  } else if (m.op === "fit") {
    const height = Math.min(Math.max(Math.ceil(m.height) + 2, 60), 900);
    placeHealth(height);
    if (!healthWin.isVisible()) healthWin.showInactive();
  }
});

const jumping = new Set();

/** What preload.js found under a click in the panel (window.hitRow). */
function act(a) {
  if (!a || !a.action) return;
  if (a.action === "decide") {
    execFile(PET_EMIT, ["--decide", a.sessionId, a.askId, a.behavior], { windowsHide: true }, (err) => {
      if (err) log("decide failed:", err.message);
    });
    return;
  }
  if (a.action === "openNotice") {
    // As the Mac's openNotice: the notice goes, and its session's terminal comes up and its
    // finishes count as seen; with nowhere to go, the list opens, where the session's row is.
    if (!a.sessionId) return;
    run(`window.dismissNotice(${js(a.sessionId)});`);
    const r = routeOf(a.sessionId, jumpKind(a.sessionId));
    if (r.task || r.jump) {
      openSession(a.sessionId, jumpKind(a.sessionId));
      markRead({ session: a.sessionId });
    } else {
      run("window.setPanelOpen(true);");
    }
    return;
  }
  if (a.action === "jump") {
    // As the Mac: the list has served its purpose once we are jumping away.
    if (openSession(a.sessionId, a.kind)) closePanel();
    return;
  }
  if (a.action === "openBoard") {
    openBoard(a.task || "");
    closePanel();
    return;
  }
  if (a.action === "openFinished") {
    // Go there, then call it seen (WebBridge's openFinished). A row whose session is gone has
    // nowhere to go: the click only clears it and says why; the list stays up.
    const ids = eventIds(a.eventIds);
    const r = routeOf(a.sessionId, a.kind);
    if (r.task || r.jump) {
      if (openSession(a.sessionId, a.kind)) {   // false: that jump is already under way
        markRead(ids);
        closePanel();
      }
    } else {
      markRead(ids);
      run("window.explainClosedRow();");
    }
    return;
  }
  if (a.action === "read") { markRead(eventIds(a.eventIds)); return; }   // the ✓; the list stays up
  if (a.action === "readAll") { markRead("all"); return; }
  if (a.action === "mute") { mute(a.sessionId); return; }
  if (a.action === "snooze") { askSnooze(a.sessionId); return; }
  log("not handled yet:", JSON.stringify(a));
}

/** pet-emit brings the session's tab to the front. Started by the pet just clicked, so Windows
 * lets it take the foreground. One jump per session at a time: a double click must not retitle
 * the console twice. False when there was nothing to start. */
function jump(sessionId) {
  if (!sessionId || jumping.has(sessionId)) return false;
  jumping.add(sessionId);
  execFile(PET_EMIT, ["--jump", sessionId], { windowsHide: true, timeout: 15000 }, (err, _out, stderr) => {
    jumping.delete(sessionId);
    // The connection report's "Terminal jump" says the last failure until a jump works.
    lastJumpFailure = err ? jumpFailure(err, stderr) : "";
    if (err) log("jump failed:", err.message.trim());
    else if (stderr) log("jump:", String(stderr).trim());
  });
  return true;
}

/** Event ids from the page: strings only, one per line on pet-emit's stdin. */
function eventIds(ids) {
  return (Array.isArray(ids) ? ids : []).filter((id) => typeof id === "string" && id && !/[\r\n]/.test(id) && id.length <= 256);
}

/**
 * `pet-emit --mark-read`: "all", { session }, or a list of event ids (on stdin: a row can stand
 * for hundreds of turns, past the command line's length). The rows go from the list at once,
 * as on the Mac; the next --watch line settles the badge.
 */
function markRead(what) {
  let args, input = "";
  if (what === "all") args = ["--all"];
  else if (what && what.session) args = ["--session", what.session];
  else if (Array.isArray(what) && what.length) { args = ["-"]; input = what.join("\n") + "\n"; }
  else return;
  const child = spawn(PET_EMIT, ["--mark-read", ...args], { windowsHide: true, stdio: ["pipe", "ignore", "pipe"] });
  let complaint = "";
  child.stderr.on("data", (d) => { complaint += d; });
  child.on("error", (e) => log("mark read failed:", e.message));
  child.on("exit", (code) => { if (code) log("mark read failed:", code, complaint.trim()); });
  child.stdin.on("error", () => {});
  child.stdin.end(input);
  const timer = setTimeout(() => child.kill(), 10000);
  child.on("exit", () => clearTimeout(timer));

  const ids = new Set(Array.isArray(what) ? what : []);
  const match = (r) => what === "all" || (!!what.session && r.sessionId === what.session)
    || (r.eventIds || []).some((id) => ids.has(id));
  // Kept off the lines that come before pet-emit has written read.json (see overlay).
  pending.read.push({ match, until: Date.now() + PENDING_MS });
  if (!last || !last.finished) return;
  last.finished = last.finished.filter((r) => !match(r));
  drawSessions(last);
}

const ICONS = { idle: "idle", busy: "working", waiting: "waiting", urgent: "urgent" };

/** The tray icon: the picked skin's picture for the mood; asleep while napping. */
function trayImage(mood) {
  const file = path.join(PET_ROOT, "skins", skin(), "assets", (paused ? "sleeping" : ICONS[mood] || "sleeping") + ".png");
  const img = nativeImage.createFromPath(file);
  return img.isEmpty() ? img : img.resize({ width: 16, height: 16 });
}

function updateTray(s) {
  if (!tray) return;
  tray.setImage(trayImage(s ? s.mood : "idle"));
  if (paused) return tray.setToolTip(language() === "zh" ? "Claude Pet — 小睡中" : "Claude Pet — napping");
  if (!s) return tray.setToolTip("Claude Pet");
  const n = (s.sessions || []).length;
  tray.setToolTip(`Claude Pet — ${s.mood}, ${n} session${n === 1 ? "" : "s"}`);
}

// Launch at login, off until asked for, as on the Mac: a value under HKCU\...\Run named
// ClaudePet (uninstall.ps1 removes it). Only for the installed app: `npx electron .` would
// register electron.exe.
// The path is quoted: Electron writes it into the Run value as given, and an unquoted path with
// a space in it (C:\Users\John Smith\...) runs the wrong thing.
const LOGIN_ITEM = { name: "ClaudePet", path: `"${process.execPath}"` };

/** On Windows openAtLogin only looks for a value named after the AppUserModelID, so the value
 * is found by name among launchItems (checked with Electron 33). Off in Task Manager counts. */
function launchesAtLogin() {
  try {
    return (app.getLoginItemSettings({ path: LOGIN_ITEM.path }).launchItems || [])
      .some((i) => i.name === LOGIN_ITEM.name && i.enabled !== false);
  } catch (_) { return false; }
}

function setLaunchAtLogin(on) {
  // enabled: ticking it again undoes a "Disabled" set in Task Manager's Startup tab.
  app.setLoginItemSettings({ ...LOGIN_ITEM, openAtLogin: on, enabled: on });
  if (launchesAtLogin() !== on) log("launch at login: could not turn it", on ? "on" : "off");
  buildTray();
}

function buildTray() {
  if (!tray) tray = new Tray(trayImage(last ? last.mood : "idle"));
  const zh = language() === "zh";
  const setLang = (lang) => { writePrefs({ ...readPrefs(), lang }); app.relaunch(); app.quit(); };
  const muted = trayMuted;
  const hold = noticeHold();
  const count = noticeCount();
  const current = skin();
  // Laid out as the Mac's PetMenu: what gets reached for during a day on the first level, what
  // is set once under Settings.
  tray.setContextMenu(Menu.buildFromTemplate([
    // As the Mac's PetMenu: the first thing wrong with the install, only while there is one.
    ...(problem ? [
      { label: zh ? `⚠ ${problem.name}：${problem.label}…` : `⚠ ${problem.name}: ${problem.label}…`, click: () => showHealth() },
      { type: "separator" },
    ] : []),
    { label: zh ? "任务看板…" : "Task Board…", click: () => openBoard() },
    { type: "separator" },
    { label: paused ? (zh ? "醒来" : "Wake Up") : (zh ? "小睡一会" : "Take a Nap"), click: togglePause },
    { label: zh ? "保持列表展开" : "Keep List Open", type: "checkbox", checked: keepListOpen(),
      click: (item) => setKeepListOpen(item.checked) },
    // As the Mac's menu: only while something is muted.
    ...(muted ? [{ label: zh ? `取消所有静音 (${muted})` : `Unmute All (${muted})`, click: () => { pending.muted.clear(); marks(["--unmute-all"]); } }] : []),
    { type: "separator" },
    { label: zh ? "显示 / 隐藏桌宠" : "Show / hide the pet", click: () => win && (win.isVisible() ? win.hide() : win.showInactive()) },
    { label: zh ? "放回右下角" : "Move back to the corner", click: () => {
      writePrefs({ ...readPrefs(), x: undefined, y: undefined });
      const p = startPosition(); if (win) win.setPosition(p.x, p.y);
    } },
    { type: "separator" },
    { label: zh ? "设置" : "Settings", submenu: [
      ...(app.isPackaged ? [{ label: zh ? "登录时启动" : "Launch at Login", type: "checkbox",
        checked: launchesAtLogin(), click: (item) => setLaunchAtLogin(item.checked) }] : []),
      // Where a click on a row or a notice takes you (the Mac's ClickTarget).
      { label: zh ? "点击 session 时打开" : "Clicking a Session Opens", submenu: [
        { label: zh ? "它的终端" : "Its Terminal", type: "radio", checked: clickTarget() === "terminal", click: () => setClickTarget("terminal") },
        { label: zh ? "任务看板上它的任务" : "Its Task on the Board", type: "radio", checked: clickTarget() === "board", click: () => setClickTarget("board") },
      ] },
      { type: "separator" },
      // The "this session finished" notices above the pet.
      { label: zh ? "气泡停留时间" : "Bubble Duration", submenu: NOTICE_HOLDS.map((s) => (
        { label: zh ? `${s} 秒` : `${s} seconds`, type: "radio", checked: s === hold, click: () => setNoticeHold(s) })) },
      { label: zh ? "同时显示的气泡数" : "Bubbles at Once", submenu: NOTICE_COUNTS.map((n) => (
        { label: String(n), type: "radio", checked: n === count, click: () => setNoticeCount(n) })) },
      { type: "separator" },
      // Who the pet is drawn as; a skin whose pictures are not all there is greyed out.
      { label: zh ? "角色" : "Character", submenu: SKINS.map((s) => {
        const ok = skinComplete(s.id);
        const name = zh ? s.zh : s.en;
        return { label: ok ? name : (zh ? `${name}（还没有图）` : `${name} (no artwork yet)`), type: "radio",
          checked: s.id === current, enabled: ok, click: () => setSkin(s.id) };
      }) },
      { type: "separator" },
      // Named in both languages, so it can be found whichever one is showing.
      { label: "Language · 语言", submenu: [
        { label: "English", type: "radio", checked: !zh, click: () => setLang("en") },
        { label: "中文", type: "radio", checked: zh, click: () => setLang("zh") },
      ] },
      { type: "separator" },
      { label: zh ? "连接状态…" : "Connection Status…", click: () => showHealth() },
      { label: zh ? "打开日志" : "Open the log", click: () => shell.openPath(LOG) },
    ] },
    { type: "separator" },
    { label: zh ? "退出" : "Quit", click: () => app.quit() },
  ]));
}

let dragOrigin = null;
ipcMain.on("interactive", (_e, on) => { if (win) win.setIgnoreMouseEvents(!on, { forward: true }); });
ipcMain.on("drag-start", () => { if (win) { const [x, y] = win.getPosition(); dragOrigin = { x, y, cursor: screen.getCursorScreenPoint() }; } });
ipcMain.on("drag-move", () => {
  if (!win || !dragOrigin) return;
  const c = screen.getCursorScreenPoint();
  win.setPosition(dragOrigin.x + c.x - dragOrigin.cursor.x, dragOrigin.y + c.y - dragOrigin.cursor.y);
});
ipcMain.on("drag-end", () => {
  if (win && dragOrigin) { const [x, y] = win.getPosition(); writePrefs({ ...readPrefs(), x, y }); }
  dragOrigin = null;
});
ipcMain.on("action", (_e, a) => act(a));
// A double click on the cat (preload.js put the list back as the first click found it).
ipcMain.on("board-toggle", () => toggleBoard());
// What the window shows that decides whether the cat may speak (PetChatter.Shell): the list open
// (the page's layout reports, as the Mac's isListOpen), a hover card or the quota up (the Mac's
// dwellShowing), the nap. --watch hears each change on its stdin.
const shellState = { list: false, card: false, nap: false };
function tellWatcher(key, on) {
  if (shellState[key] === on) return;
  shellState[key] = on;
  if (watcher && watcher.stdin && watcher.stdin.writable) watcher.stdin.write(`${key} ${on ? 1 : 0}\n`);
}
function setCardUp(on) {
  cardUp = on;
  tellWatcher("card", on);
}

// The hover card (preload.js's dwell): shown only if the pointer is still on that row when
// pet-emit answers. window.hush takes down whatever the bubble says, so it runs only when a
// card actually went up (the Mac's dwellShowing).
let detailWanted = "";
let cardUp = false;
ipcMain.on("detail", (_e, sessionId) => {
  if (typeof sessionId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(sessionId)) return;
  detailWanted = sessionId;
  execFile(PET_EMIT, ["--detail", sessionId], { windowsHide: true, timeout: 10000, env: emitEnv() }, (err, out) => {
    if (err) return log("detail failed:", err.message.trim());
    const json = String(out).trim();
    if (!json || detailWanted !== sessionId) return;
    try { JSON.parse(json); } catch (_) { return log("detail: not JSON"); }
    setCardUp(true);
    run(`window.showDetail(${json});`);
  });
});
// Resting on the cat (preload.js, with the list closed): the quota meters from the last --watch
// line, or a line about the sessions when there is no usable reading (the Mac's showQuota).
// Not while napping, as on the Mac.
ipcMain.on("quota", () => {
  if (!last || paused) return;
  detailWanted = "";
  setCardUp(true);
  run(`window.showQuota(${js(last.quota || [])}, ${js(last.quotaFallback || "")});`);
});
function ipcHush() {
  detailWanted = "";
  if (cardUp) { setCardUp(false); run("window.hush();"); }
}
ipcMain.on("hush", ipcHush);
// Only layout reports carry `panel` (the page also posts `{skinFailed}` on this channel).
ipcMain.on("layout", (_e, m) => { if (m && "panel" in m) tellWatcher("list", !!m.panel); });
// The Mac checks for a problem on every right-click; the tray icon's own menu has no such moment,
// so it rides on checkProblem's timer.
ipcMain.on("menu", () => {
  let shown = false;
  const show = () => { if (!shown && tray) { shown = true; tray.popUpContextMenu(); } };
  checkProblem({ say: false }).then(show);
  setTimeout(show, 1500);
});

let quitting = false;
app.on("before-quit", () => { quitting = true; if (watcher) watcher.kill(); });

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.whenReady().then(() => {
    serveFiles();
    createWindow();
    buildTray();
    startWatcher();
    phoneAccess.startIfEnabled();
    setInterval(() => checkProblem(), PROBLEM_EVERY);
  });
  app.on("window-all-closed", () => app.quit());
}
