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
  last = s;
  if (!prev || prev.mood !== s.mood || prev.waitingProject !== s.waitingProject || prev.waitingOn !== s.waitingOn
      || prev.waitingAskId !== s.waitingAskId) {
    const ask = { sessionId: s.waitingSessionId || "", askId: s.waitingAskId || "" };
    run(`window.setMood(${js(s.mood)}, ${js(s.waitingProject)}, ${js(s.waitingOn || "")}, "", ${js(ask)});`);
  }
  if (!prev || prev.pose !== s.pose || prev.mark !== s.mark) run(`window.setCatLook(${js(s.pose)}, ${js(s.mark)});`);
  if (!prev || prev.phase !== s.phase) run(`window.setPhase(${js(s.phase)});`);
  if (!prev || prev.badge !== s.badge) run(`window.setBadge(${js(s.badge)});`);
  run(`window.setSessions(${js(s.sessions || [])}, 0, [], 0, [], []);`);
  updateTray(s);
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
    watcher = spawn(PET_EMIT, ["--watch"], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
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

/** What preload.js found under a click in the panel (window.hitRow). */
function act(a) {
  if (!a || !a.action) return;
  if (a.action === "decide") {
    execFile(PET_EMIT, ["--decide", a.sessionId, a.askId, a.behavior], { windowsHide: true }, (err) => {
      if (err) log("decide failed:", err.message);
    });
    return;
  }
  // Jumping to a terminal, the board, snooze and mute are not in the spike yet.
  log("not handled yet:", JSON.stringify(a));
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

function buildTray() {
  tray = new Tray(trayImage("idle"));
  const zh = language() === "zh";
  const setLang = (lang) => { writePrefs({ ...readPrefs(), lang }); app.relaunch(); app.quit(); };
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: zh ? "显示 / 隐藏桌宠" : "Show / hide the pet", click: () => win && (win.isVisible() ? win.hide() : win.showInactive()) },
    { label: zh ? "放回右下角" : "Move back to the corner", click: () => {
      writePrefs({ ...readPrefs(), x: undefined, y: undefined });
      const p = startPosition(); if (win) win.setPosition(p.x, p.y);
    } },
    { label: "Language · 语言", submenu: [
      { label: "English", type: "radio", checked: !zh, click: () => setLang("en") },
      { label: "中文", type: "radio", checked: zh, click: () => setLang("zh") },
    ] },
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
