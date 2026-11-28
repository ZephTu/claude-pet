// Claude Pet on Windows — spike (T-129).
//
// The pet's own page (Resources/pet) in a transparent, always-on-top window. Everything the
// page shows comes from `pet-emit --watch`: the same Swift core the Mac app uses works out the
// state and prints it as JSON lines, and this file only hands each line to the page. The page
// never sees mouse events on the Mac either (PetHostView owns them); here preload.js plays that
// part: click-through outside the cat and the panel, drag to move, click to open the list.
"use strict";

const { app, BrowserWindow, protocol, ipcMain, screen, Tray, Menu, nativeImage, shell } = require("electron");
const path = require("path");
const fs = require("fs");
const os = require("os");
const readline = require("readline");
const { spawn, execFile } = require("child_process");

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
  win.loadURL("pet://app/index.html");
  win.webContents.on("did-finish-load", () => {
    ready = true;
    lastDrawn = "";
    // WKWebView draws a thin overlay scrollbar; Chromium on Windows a wide grey one that eats
    // into the list. Made thin here, leaving the Mac's page as it is.
    win.webContents.insertCSS(
      "::-webkit-scrollbar { width: 6px; height: 6px; background: transparent; }"
      + " ::-webkit-scrollbar-thumb { background: rgba(128,128,128,0.45); border-radius: 3px; }"
      + " ::-webkit-scrollbar-button { display: none; }").catch(() => {});
    win.showInactive();
    if (last) push(last, true);
    // PET_SHOT=out.png [PET_SHOT_JS=script]: render the window to a PNG after a few seconds and
    // quit — how CI and a Mac without screen-capture permission check what the window draws.
    if (process.env.PET_SHOT) {
      setTimeout(async () => {
        try {
          if (process.env.PET_SHOT_JS) await win.webContents.executeJavaScript(process.env.PET_SHOT_JS);
          await new Promise((r) => setTimeout(r, 800));
          const img = await win.webContents.capturePage();
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

function js(value) {
  return JSON.stringify(value === undefined ? null : value);
}

function run(script) {
  if (!win || !ready) return;
  win.webContents.executeJavaScript(script).catch((e) => log("js failed:", e.message));
}

/** One line from pet-emit --watch, drawn. */
function push(s, force) {
  const prev = force ? null : last;
  if (!force) overlay(s);
  last = s;
  if (!prev || prev.mood !== s.mood || prev.waitingProject !== s.waitingProject || prev.waitingOn !== s.waitingOn
      || prev.waitingAskId !== s.waitingAskId) {
    const ask = { sessionId: s.waitingSessionId || "", askId: s.waitingAskId || "" };
    run(`window.setMood(${js(s.mood)}, ${js(s.waitingProject)}, ${js(s.waitingOn || "")}, "", ${js(ask)});`);
  }
  if (!prev || prev.pose !== s.pose || prev.mark !== s.mark) run(`window.setCatLook(${js(s.pose)}, ${js(s.mark)});`);
  if (!prev || prev.phase !== s.phase) run(`window.setPhase(${js(s.phase)});`);
  if (!prev || prev.badge !== s.badge) run(`window.setBadge(${js(s.badge)});`);
  pendingDropped += Number(s.dropped) || 0;
  drawSessions(s);
  syncTray(s);
  // Sessions that just finished, each in a notice of its own (the page skips them while the
  // list is open). Only on the line they came on: a redraw (force) does not repeat them.
  if (!force) {
    for (const n of s.notices || []) {
      run(`window.notify(${js(n.text)}, ${Number(n.holdMs) || 30000}, ${js(n.emphasis)}, ${js(n.sessionId)}, ${!!jumpKind(n.sessionId)});`);
    }
  }
  updateTray(s);
}

// Unread finishes that aged out unseen. --watch says so on one line, usually when it starts,
// before the list is ever opened: kept for the footer until the list has been open a while.
let pendingDropped = 0;
ipcMain.on("panel-opened", () => {
  if (pendingDropped) setTimeout(() => { pendingDropped = 0; }, 10000);
});

/** The rows, the muted count (the footer's "N muted") and the Finished group. No HQ asks or
 * jobs yet. */
let lastDrawn = "";
function drawSessions(s) {
  const script = `window.setSessions(${js(s.sessions || [])}, ${Number(s.hidden) || 0}, ${js(s.finished || [])}, ${pendingDropped}, [], []);`;
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

/** The terminal a session's row can jump to, or "" (PetWatch.row's termKind). */
function jumpKind(sessionId) {
  const row = ((last && last.sessions) || []).find((r) => r.sessionId === sessionId);
  return (row && row.termKind) || "";
}

// What pet-emit prints in the pet's language (the hover card, notices): the tray's choice.
function emitEnv() {
  return { ...process.env, CLAUDE_PET_LANG: language() };
}

function startWatcher() {
  if (!fs.existsSync(PET_EMIT)) {
    log("no pet-emit at", PET_EMIT);
    run(`window.say(${js(language() === "zh" ? "找不到 pet-emit，请先运行 install.ps1" : "pet-emit is missing: run install.ps1 first")}, 30000);`);
    setTimeout(startWatcher, 10000);
    return;
  }
  const restart = () => { watcher = null; if (!quitting) setTimeout(startWatcher, 2000); };
  try {
    watcher = spawn(PET_EMIT, ["--watch"], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"], env: emitEnv() });
  } catch (e) {
    log("pet-emit --watch did not start:", e.message);
    return restart();
  }
  // Blocked by antivirus or AppLocker, say: logged and tried again, never an uncaught exception.
  let restarted = false;
  const again = () => { if (!restarted) { restarted = true; restart(); } };
  watcher.on("error", (e) => { log("pet-emit --watch failed:", e.message); again(); });
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
    if (jumpKind(a.sessionId)) {
      jump(a.sessionId);
      markRead({ session: a.sessionId });
    } else {
      run("window.setPanelOpen(true);");
    }
    return;
  }
  if (a.action === "jump") {
    // As the Mac: the list has served its purpose once we are jumping away.
    if (jump(a.sessionId)) run("window.setPanelOpen(false);");
    return;
  }
  if (a.action === "openFinished") {
    // Go there, then call it seen (WebBridge's openFinished). A row whose session is gone has
    // nowhere to go: the click only clears it and says why; the list stays up.
    const ids = eventIds(a.eventIds);
    if (a.kind) {
      if (jump(a.sessionId)) {   // false: that jump is already under way
        markRead(ids);
        run("window.setPanelOpen(false);");
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
  // The board is not in the spike yet.
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

function trayImage(mood) {
  const file = path.join(PET_ROOT, "skins", "cat", "assets", (ICONS[mood] || "sleeping") + ".png");
  const img = nativeImage.createFromPath(file);
  return img.isEmpty() ? img : img.resize({ width: 16, height: 16 });
}

function updateTray(s) {
  if (!tray) return;
  tray.setImage(trayImage(s.mood));
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
  tray.setContextMenu(Menu.buildFromTemplate([
    // As the Mac's menu: only while something is muted.
    ...(muted ? [{ label: zh ? `取消所有静音 (${muted})` : `Unmute All (${muted})`, click: () => { pending.muted.clear(); marks(["--unmute-all"]); } },
      { type: "separator" }] : []),
    { label: zh ? "显示 / 隐藏桌宠" : "Show / hide the pet", click: () => win && (win.isVisible() ? win.hide() : win.showInactive()) },
    { label: zh ? "放回右下角" : "Move back to the corner", click: () => {
      writePrefs({ ...readPrefs(), x: undefined, y: undefined });
      const p = startPosition(); if (win) win.setPosition(p.x, p.y);
    } },
    { label: "Language · 语言", submenu: [
      { label: "English", type: "radio", checked: !zh, click: () => setLang("en") },
      { label: "中文", type: "radio", checked: zh, click: () => setLang("zh") },
    ] },
    ...(app.isPackaged ? [{ label: zh ? "登录时启动" : "Launch at Login", type: "checkbox",
      checked: launchesAtLogin(), click: (item) => setLaunchAtLogin(item.checked) }] : []),
    { label: zh ? "打开日志" : "Open the log", click: () => shell.openPath(LOG) },
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
    cardUp = true;
    run(`window.showDetail(${json});`);
  });
});
// Resting on the cat (preload.js, with the list closed): the quota meters from the last --watch
// line, or a line about the sessions when there is no usable reading (the Mac's showQuota).
ipcMain.on("quota", () => {
  if (!last) return;
  detailWanted = "";
  cardUp = true;
  run(`window.showQuota(${js(last.quota || [])}, ${js(last.quotaFallback || "")});`);
});
ipcMain.on("hush", () => {
  detailWanted = "";
  if (cardUp) { cardUp = false; run("window.hush();"); }
});
ipcMain.on("layout", () => {});
ipcMain.on("menu", () => { if (tray) tray.popUpContextMenu(); });

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
  });
  app.on("window-all-closed", () => app.quit());
}
