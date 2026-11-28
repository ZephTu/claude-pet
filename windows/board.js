// The HQ task board on Windows: what BoardWindow.swift's BoardBridge does on the Mac.
//
// The page (Resources/pet/board, unchanged) posts {op, ...} to window.webkit.messageHandlers.hq
// (board-preload.js plays it) and gets back hq's answer or an error. Nearly every op only runs
// the hq CLI, with the arguments BoardWindow.perform gives it; what the Mac app keeps beside hq
// (shared prefs, read cards, quick phrases) and the reading area are `pet-emit --board`
// (PetBoard.swift, over the same ClaudePetCore code), and so are the answers to prompts a
// pet-emit holds open. Sessions start and resume in a Windows Terminal or Orca tab. What needs
// typing into a session's terminal, launchd or the secretary answers "not on Windows yet" for now
// (see windows/CLAUDE.md, Next).
"use strict";

const { clipboard, dialog, shell } = require("electron");
const path = require("path");
const fs = require("fs");
const os = require("os");
const crypto = require("crypto");
const { execFile } = require("child_process");

// PET_HQ_HOME (tests, renders): the home hq runs in, as PET_HOME is the pet's data.
const HOME = process.env.PET_HQ_HOME || os.homedir();
const HQ_DIR = path.join(HOME, ".claude", "hq");
// Not Claude Code's own variables (the pet may have been started from a session): hq would take
// the board's calls for that session's (BoardWindow.run strips the same).
const HQ_ENV = Object.fromEntries(Object.entries(process.env)
  .filter(([k]) => k !== "CLAUDECODE" && k !== "CLAUDE_PID" && !k.startsWith("CLAUDE_CODE_")));
if (process.env.PET_HQ_HOME) HQ_ENV.USERPROFILE = HOME;
// What claude and the terminals it starts in get: without the variables that say "inside the
// session that started the pet" (a new session would think it is nested in it), but with the
// user's own CLAUDE_CODE_* settings (a provider, a model), which HQ_ENV drops.
const SESSION_VARS = new Set(["CLAUDECODE", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"]);
const CLAUDE_ENV = Object.fromEntries(Object.entries(process.env).filter(([k]) => !SESSION_VARS.has(k.toUpperCase())));
const READ_TIMEOUT = 15000;
const RUN_TIMEOUT = 120000;
// `hq inbox sort` gives its model 120 s: more here, or the board kills python and orphans claude.
const SORT_TIMEOUT = 180000;
// SharedReads.ttl and SharedReads.readOnly (ClaudePetCore): a read every open board polls is
// shared for a moment; anything else drops what is kept, before it runs and after.
const TTL = { board: 2000, sessions: 2000, status: 2000 };
const READ_ONLY = new Set(["board", "sessions", "status", "agents", "pet", "peek", "seen", "card-seen", "commands",
  "peek-tool", "history", "prompt", "read-doc", "remote", "phrase-suggest", "jobs", "job-detail", "job-preview",
  "secretary", "intake-job"]);
// Not starting with "-": an id is passed as an argument, and must not read as an option.
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// `claude agents` changes only when a background session starts or ends (SharedReads.ttl).
const AGENTS_TTL = 20000;
// The board's choice: sessions it starts or resumes skip Claude Code's permission prompts.
const SKIP_FLAG = "--dangerously-skip-permissions";
const ORCA_CLI = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local"),
  "Programs", "orca", "resources", "bin", "orca.exe");

let L = (en, zh) => en;
let petEmit = "";
let petEnv = () => process.env;
let petState = () => ({});
let onSeen = () => {};
let onClickTarget = () => {};
// Sessions a Resume is under way for: a double click must not open the session twice.
const resuming = new Set();
let lastAgents = null;
const kept = new Map();

/** The Python and the entry hq/install.sh put in: bin/hq is a sh script naming its Python
 * (`exec "/c/Users/.../python.exe" -X utf8 ".../hq.py"`). */
function hqCommand() {
  const entry = path.join(HQ_DIR, "bin", "hq.py");
  if (!fs.existsSync(entry)) return null;
  let py = "";
  try {
    const m = fs.readFileSync(path.join(HQ_DIR, "bin", "hq"), "utf8").match(/exec "([^"]+)"/);
    if (m) py = m[1].replace(/^\/([a-zA-Z])\//, (_, d) => d.toUpperCase() + ":\\").replace(/\//g, "\\");
  } catch (_) {}
  if (py && fs.existsSync(py)) return { file: py, args: ["-X", "utf8", entry] };
  // bin/hq names no Python this process can run (moved, or an MSYS path): the launcher's.
  return { file: "py", args: ["-3", "-X", "utf8", entry], fallback: py || "(none named in bin/hq)" };
}

function exec(file, args, { timeout = RUN_TIMEOUT, input, env, cwd } = {}) {
  return new Promise((resolve) => {
    const child = execFile(file, args, { windowsHide: true, timeout, maxBuffer: 64 << 20, env: env || process.env, encoding: "utf8", cwd },
      (err, out, errOut) => resolve({ status: err ? (typeof err.code === "number" ? err.code : -1) : 0,
        out: String(out || ""), err: String(errOut || ""), timedOut: !!(err && err.killed),
        missing: !!(err && err.code === "ENOENT") }));
    // Closed even with nothing to say (a command reading stdin must not wait for the timeout), and
    // a child gone before reading it must not throw in the main process.
    child.stdin.on("error", () => {});
    child.stdin.end(input === undefined ? "" : input);
  });
}

/** hq's stdout as text (the page parses JSON itself), or an error: BoardWindow.hqText. */
async function hq(args, timeout = RUN_TIMEOUT) {
  const cmd = hqCommand();
  if (!cmd) return { error: L("HQ is not installed — run hq/install.sh --root <dir> in Git Bash", "没有安装 HQ — 在 Git Bash 里运行 hq/install.sh --root <dir>") };
  const r = await exec(cmd.file, cmd.args.concat(args), { timeout, env: HQ_ENV });
  if (r.missing) {
    return { error: L(`can't find the Python hq runs with (${cmd.fallback || cmd.file}) — re-run hq/install.sh in Git Bash`,
      `找不到 hq 用的 Python（${cmd.fallback || cmd.file}）— 在 Git Bash 里重新运行 hq/install.sh`) };
  }
  if (r.timedOut) {
    return { error: L(`hq ${args[0] || ""} took over ${Math.round(timeout / 1000)}s — gave up; trying again shortly`,
      `hq ${args[0] || ""} 超过 ${Math.round(timeout / 1000)} 秒没有返回——已放弃，稍后重试`) };
  }
  if (r.status !== 0) return { error: r.err.trim() || L(`hq exited ${r.status}`, `hq 退出码 ${r.status}`) };
  return { result: r.out };
}

/** A read every open board polls, shared for `ttl` ms (SharedReads). */
function shared(key, ttl, fetch) {
  const e = kept.get(key);
  if (e && (e.done === null || Date.now() - e.done < ttl)) return e.promise;
  const entry = { done: null, promise: null };
  entry.promise = fetch().then((a) => {
    if (!a.error) entry.done = Date.now();
    else if (kept.get(key) === entry) kept.delete(key);
    return a;
  });
  kept.set(key, entry);
  return entry.promise;
}

async function board(body) {
  const r = await exec(petEmit, ["--board"], { timeout: READ_TIMEOUT, input: JSON.stringify(body), env: petEnv() });
  try { return JSON.parse(r.out); } catch (_) { return { error: (r.err || "pet-emit --board failed").trim() }; }
}

/** The claude CLI as an .exe: on PATH, else where its Windows installer puts it (hq's
 * find_claude). Never npm's claude.cmd: Windows runs a .cmd through cmd.exe, which parses the
 * command line again (a task title's `&` or `%VAR%` would run or expand), and Node refuses to
 * start one with execFile. Kept a minute: the board asks on every `agents` poll. */
let claudeFound = { at: 0, path: "" };
async function findClaude() {
  if (claudeFound.path && Date.now() - claudeFound.at < 60000) return claudeFound.path;
  const r = await exec("where.exe", ["claude"], { timeout: 5000 });
  const hits = r.status === 0 ? r.out.split(/\r?\n/).map((s) => s.trim()).filter(Boolean) : [];
  let found = hits.find((s) => /\.exe$/i.test(s)) || "";
  // npm's shim: the package's own native binary beside it, when it ships one.
  for (const shim of hits.filter((s) => /\.cmd$/i.test(s))) {
    if (found) break;
    const exe = path.join(path.dirname(shim), "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe");
    if (fs.existsSync(exe)) found = exe;
  }
  if (!found) {
    const local = path.join(HOME, ".local", "bin", "claude.exe");
    if (fs.existsSync(local)) found = local;
  }
  claudeFound = { at: Date.now(), path: found };
  return found;
}

function str(body, key) { return typeof body[key] === "string" ? body[key] : ""; }

// ------------------------------------------------------------------ starting sessions
// BoardWindow.launch / resume / openInTerminal. A tab runs PowerShell with the session's command
// as -EncodedCommand (base64): nothing in it — a task title, a prompt with quotes, `;` or line
// breaks — passes through wt.exe's or a shell's parsing. PowerShell starts claude with the exact
// command line (ProcessStartInfo.Arguments: PowerShell 5.1 mangles quotes in a native call's
// arguments) in the same console, waits, and exits with it, so the tab closes when the session ends.

/** One argument as CommandLineToArgvW reads it back. */
function winArg(a) {
  if (a && !/[\s"]/.test(a)) return a;
  return '"' + a.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, "$1$1") + '"';
}

/** A PowerShell literal ('…'; the curly quotes PowerShell also reads as quotes are doubled too). */
const psQuote = (s) => "'" + s.replace(/['‘’‚‛]/g, "$&$&") + "'";

// Past this, the script goes in a file the encoded stub reads (and deletes): base64 of UTF-16 is
// ~2.7 characters per character, and a command line stops at 32767.
const INLINE_MAX = 8000;

/** The command line a tab runs: `command` (an .exe, then its arguments) started in `dir`.
 * { line, file }: `file` is the script's temp file, if it needed one (deleted by the tab, or by
 * the caller when the tab did not open). */
function tabCommand(dir, command) {
  const [file, ...args] = command.map((a) => String(a).replace(/\0/g, ""));
  const script = [
    "$i = New-Object System.Diagnostics.ProcessStartInfo",
    `$i.FileName = ${psQuote(file)}`,
    `$i.Arguments = ${psQuote(args.map(winArg).join(" "))}`,
    `$i.WorkingDirectory = ${psQuote(dir)}`,
    "$i.UseShellExecute = $false",
    // Not the variables of a session the terminal itself may have been started from.
    ...[...SESSION_VARS].map((k) => `$i.EnvironmentVariables.Remove('${k}')`),
    // A board started with HQ_ROOT (tests, a second root) passes it on to the new session.
    ...(process.env.HQ_ROOT ? [`$i.EnvironmentVariables['HQ_ROOT'] = ${psQuote(process.env.HQ_ROOT)}`] : []),
    "$p = [System.Diagnostics.Process]::Start($i)",
    "$p.WaitForExit()",
    "exit $p.ExitCode",
  ].join("\n");
  const encode = (s) => Buffer.from(s, "utf16le").toString("base64");
  const ps = (s) => ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encode(s)];
  if (encode(script).length <= INLINE_MAX) return { line: ps(script), file: "" };
  const tmp = path.join(os.tmpdir(), `claude-pet-tab-${crypto.randomBytes(6).toString("hex")}.ps1`);
  fs.writeFileSync(tmp, script, "utf8");
  return {
    line: ps(`$f = ${psQuote(tmp)}; $s = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8); `
      + "try { [IO.File]::Delete($f) } catch {}; Invoke-Expression $s"),
    file: tmp,
  };
}

/** A tab's title: one line, no `;` (wt.exe splits its command line there), not starting with "-"
 * (it would read as an option). */
const tabTitle = (t) => String(t).replace(/[\u0000-\u001f\u007f;]/g, " ").trim().replace(/^-+\s*/, "").slice(0, 60) || "claude";

/** Runs `command` in `dir` in a new tab: Windows Terminal ("terminal") or Orca. `focus: false`
 * leaves the board in front (Orca opens the tab without switching; Windows Terminal always comes
 * forward, so the board is brought back after it). */
async function openInTerminal(place, dir, command, title, focus, win) {
  if (place === "iterm2") return { error: L("iTerm2 is a Mac app — pick Terminal or Orca", "iTerm2 是 Mac 上的应用——选 Terminal 或 Orca") };
  if (place !== "terminal" && place !== "orca") return { error: L(`unknown place to open: ${place}`, `不知道要在哪里打开：${place}`) };
  if (place === "orca" && !fs.existsSync(ORCA_CLI)) return { error: L("Orca is not installed", "没有安装 Orca") };
  const { line, file } = tabCommand(dir, command);
  const opened = await (place === "terminal" ? openInWT(line, title, focus, win) : openInOrca(line, dir, title, focus));
  if (opened.error && file) fs.rm(file, { force: true }, () => {});
  return opened;
}

async function openInWT(line, title, focus, win) {
  // -w 0: the most recent window (a new one when none is open); `--` ends wt's own options.
  const r = await exec("wt.exe", ["-w", "0", "new-tab", "--title", tabTitle(title), "--"].concat(line), { timeout: 15000, env: CLAUDE_ENV });
  if (r.missing) return { error: L("Windows Terminal is not installed", "没有安装 Windows Terminal") };
  if (r.status !== 0) return { error: "wt: " + (r.err || r.out).trim().slice(0, 300) };
  if (!focus && win) for (const ms of [700, 1500]) setTimeout(() => { if (!win.isDestroyed()) win.focus(); }, ms);
  return { result: { ok: true } };
}

async function openInOrca(line, dir, title, focus) {
  // Typed into a PowerShell terminal; `exit` closes the tab once the session ends, as on the Mac.
  const typed = line.join(" ") + "; exit";
  const rest = ["--shell", "powershell.exe", "--title", tabTitle(title), "--command", typed].concat(focus ? ["--focus"] : [], ["--json"]);
  // In the Orca workspace for that folder when there is one, else in the current one.
  let r = await exec(ORCA_CLI, ["terminal", "create", "--worktree", "path:" + dir.replace(/\\/g, "/")].concat(rest), { timeout: 30000, env: CLAUDE_ENV });
  if (r.status !== 0) r = await exec(ORCA_CLI, ["terminal", "create"].concat(rest), { timeout: 30000, env: CLAUDE_ENV });
  if (r.status !== 0) return { error: "orca: " + (r.err || r.out).trim().slice(0, 300) };
  // --focus only switches the tab inside Orca; the Mac activates Orca too.
  if (focus) await exec(petEmit, ["--raise-orca"], { timeout: 5000, env: petEnv() });
  return { result: { ok: true } };
}

/** A folder to start in: `~` expanded, and there. */
function startDir(raw) {
  const dir = String(raw || "").trim().replace(/^~(?=$|[\\/])/, HOME);
  try { if (path.isAbsolute(dir) && localPath(dir) && fs.statSync(dir).isDirectory()) return path.normalize(dir); } catch (_) {}
  return null;
}

const noClaude = () => ({ error: L("can't find the claude command", "找不到 claude 命令") });

/** BoardWindow.launch: binds a fresh session id to the task first (so the session starts with
 * the task's rules), then runs `claude --session-id … --name … <prompt>` in the task's folder. */
async function launch(body, win) {
  const dir = startDir(str(body, "dir"));
  if (!dir) return { error: L(`no such directory: ${str(body, "dir")}`, `没有这个目录：${str(body, "dir")}`) };
  const claude = await findClaude();
  if (!claude) return noClaude();
  const task = str(body, "task");
  const name = `${task} ${str(body, "title")}`.slice(0, 60);
  const skip = body.skip === true ? [SKIP_FLAG] : [];
  if (str(body, "where") === "bg") return launchBackground(claude, task, name, dir, str(body, "prompt"), skip);
  const sid = crypto.randomUUID();
  const bound = await hq(["bind", task, `--session=${sid}`]);
  if (bound.error) return bound;
  const opened = await openInTerminal(str(body, "where"), dir, [claude, "--session-id", sid, "--name", name].concat(skip, [str(body, "prompt")]),
    name, body.focus !== false, win);
  if (opened.error) { await hq(["unbind", `--session=${sid}`]); return opened; }
  return { result: { ok: true, session: sid, where: str(body, "where") } };
}

/** BoardWindow.launchBackground: `claude --bg` picks its own session id, so the session is told to
 * bind itself first, and the board binds it too once `claude agents` names it. */
async function launchBackground(claude, task, name, dir, prompt, skip) {
  const first = `Start by running \`~/.claude/hq/bin/hq bind ${task}\` — it binds this background session to the task and prints its rules. Then: `;
  const r = await exec(claude, ["--bg", "--name", name].concat(skip, [first + prompt]), { cwd: dir, env: CLAUDE_ENV, timeout: 60000 });
  const said = r.out + r.err;
  // An untrusted folder can't show its trust prompt in the background; claude says so.
  if (r.status !== 0 || /not trusted/i.test(said)) return { error: "claude --bg: " + (r.err || r.out).trim().slice(0, 300) };
  const short = (said.match(/\b[0-9a-f]{8}\b/) || [])[0];
  if (!short) return { result: { ok: true, where: "bg" } };
  kept.delete("agents");
  for (let i = 0; i < 10; i++) {
    const list = await exec(claude, ["agents", "--json", "--all"], { env: CLAUDE_ENV, timeout: READ_TIMEOUT });
    let rows = [];
    try { rows = JSON.parse(list.out); } catch (_) {}
    const row = Array.isArray(rows) && rows.find((x) => x && x.id === short);
    if (row && typeof row.sessionId === "string" && SESSION_ID.test(row.sessionId)) {
      const who = await hq(["whoami", `--session=${row.sessionId}`]);
      if (!String(who.result || "").includes(task)) await hq(["bind", task, `--session=${row.sessionId}`]);
      return { result: { ok: true, session: row.sessionId, where: "bg", id: short } };
    }
    await new Promise((res) => setTimeout(res, 300));
  }
  return { result: { ok: true, where: "bg", id: short } };
}

/** BoardWindow.resume: `claude --resume <id>` in the folder it ran in (Claude Code keeps a
 * conversation under that folder), bound to the task again, in a new tab. A background place
 * opens a terminal instead: there is nothing to attach to. */
async function resume(body, win) {
  const sid = str(body, "session");
  if (!UUID.test(sid)) return { error: L("not a session id", "不是有效的 session id") };
  const dir = startDir(str(body, "dir"));
  if (!dir) return { error: L(`no such directory: ${str(body, "dir")}`, `没有这个目录：${str(body, "dir")}`) };
  if (resuming.has(sid)) return { error: L("Already resuming this session — give it a moment", "正在续上这个 session，稍等一下") };
  resuming.add(sid);
  try {
    const claude = await findClaude();
    if (!claude) return noClaude();
    const task = str(body, "task");
    const bound = await hq(["bind", task, `--session=${sid}`]);
    if (bound.error) return bound;
    const into = str(body, "where") === "bg" ? "terminal" : str(body, "where");
    // The tab keeps the session's own name, as the pet and the board show it.
    const title = str(body, "name") ? str(body, "name").slice(0, 60) : `${task} ${sid.slice(0, 8)}`;
    const opened = await openInTerminal(into, dir, [claude, "--resume", sid].concat(body.skip === true ? [SKIP_FLAG] : []),
      title, body.focus !== false, win);
    return opened.error ? opened : { result: { ok: true, session: sid, where: into } };
  } finally {
    // Held a little past the answer: the tab is still starting, and a second click would open another.
    setTimeout(() => resuming.delete(sid), 3000);
  }
}

/** Background sessions: `claude agents --json`, shared like the board's reads. A failed read
 * keeps the last list: an empty one would put a background session back in the terminal its
 * record inherited. */
async function agents() {
  const claude = await findClaude();
  if (!claude) return { result: "[]" };
  const a = await shared("agents", AGENTS_TTL, async () => {
    const r = await exec(claude, ["agents", "--json"], { env: CLAUDE_ENV, timeout: READ_TIMEOUT });
    return r.status === 0 ? { result: r.out } : { error: "claude agents failed" };
  });
  if (!a.error) lastAgents = a.result;
  return { result: a.error ? (lastAgents || "[]") : a.result };
}

/** sessionId → its task's id, from hq's bindings (TaskIndex.taskBySession). Read again after 8 s. */
let tasksRead = { at: 0, map: {} };
function taskBySession() {
  if (Date.now() - tasksRead.at < 8000) return tasksRead.map;
  const map = {};
  try {
    const state = JSON.parse(fs.readFileSync(path.join(HQ_DIR, "state", "sessions.json"), "utf8"));
    for (const [sid, entry] of Object.entries(state || {})) {
      if (entry && typeof entry.task === "string" && /^T-\d+$/.test(entry.task)) map[sid] = entry.task;
    }
  } catch (_) {}
  tasksRead = { at: Date.now(), map };
  return map;
}

/** BoardWindow.saveImage: an image pasted into a message box, as a file its path can name. */
function saveImage(dataURL) {
  const m = /^data:(image\/(png|jpeg|gif|webp));base64,(.*)$/s.exec(dataURL || "");
  if (!m) return { error: L("not an image", "不是图片") };
  const data = Buffer.from(m[3], "base64");
  if (data.length > 20 * 1024 * 1024) return { error: L("image is larger than 20 MB", "图片超过 20 MB") };
  const ext = { png: "png", jpeg: "jpg", gif: "gif", webp: "webp" }[m[2]];
  const dir = path.join(HQ_DIR, "attachments");
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
  const file = path.join(dir, `${stamp}-${crypto.randomBytes(3).toString("hex")}.${ext}`);
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, data);
  } catch (e) { return { error: L(`could not save the image: ${e.message}`, `图片没能保存：${e.message}`) }; }
  return { result: { path: file } };
}

// What a click opens in its default app: documents and media. Anything else (a program, a script,
// a link file, source code — .js runs in Windows Script Host) is shown in Explorer instead, as
// BoardWindow.openPath reveals what could run on the Mac.
const DOCUMENTS = new Set(["md", "markdown", "txt", "text", "log", "csv", "tsv", "json", "yaml", "yml", "toml", "xml",
  "pdf", "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "mp4", "mov", "webm", "mp3", "wav", "m4a",
  "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "odt", "ods", "odp"]);

/** A path this machine holds: not on another host (opening \\host\share sends the user's
 * credentials there), not \\?\ or \\.\, no alternate stream (a:b.exe::$DATA). */
function localPath(p) {
  return !/^[\\/]{2}/.test(p) && !p.slice(2).includes(":");
}

function hqRoot() {
  try { return JSON.parse(fs.readFileSync(path.join(HQ_DIR, "config.json"), "utf8")).root || ""; } catch (_) { return ""; }
}

/** BoardWindow.openPath: a path mentioned in a conversation, with its default app. */
async function openPath(raw, cwd) {
  let p = (raw || "").trim().replace(/:\d+(:\d+)?$/, "");
  if (p === "~" || p.startsWith("~/") || p.startsWith("~\\")) p = path.join(HOME, p.slice(1));
  if (!path.isAbsolute(p)) {
    if (!cwd) return { error: L("relative path and no working directory", "是相对路径，但没有工作目录") };
    p = path.join(cwd, p);
  }
  p = path.normalize(p);
  if (!localPath(p)) return { error: L(`not a path on this computer: ${p}`, `不是这台电脑上的路径：${p}`) };
  let st;
  try { st = fs.statSync(p); } catch (_) { return { error: L(`not found: ${p}`, `找不到：${p}`) }; }
  if (!st.isDirectory() && !DOCUMENTS.has(path.extname(p).slice(1).toLowerCase())) {
    shell.showItemInFolder(p);
    return { result: { ok: true, revealed: true } };
  }
  const err = await shell.openPath(p);
  return err ? { error: err } : { result: { ok: true } };
}

const notOnWindows = () => ({ error: L("not on Windows yet", "Windows 版暂不支持") });

async function perform(body, win) {
  const op = str(body, "op");
  switch (op) {
    case "board": case "sessions": case "status": {
      const args = { board: ["board", "--json"], sessions: ["sessions", "--json"], status: ["status", "--focus", "--json"] }[op];
      return shared(op, TTL[op], () => hq(args, READ_TIMEOUT));
    }
    case "peek": {
      // An open conversation shows the newest reply: that is reading it (BoardWindow's onSeen).
      const r = await hq(["peek", str(body, "session"), "-n", "30", "--json", "--meta"], READ_TIMEOUT);
      if (!r.error && SESSION_ID.test(str(body, "session"))) onSeen(str(body, "session"));
      return r;
    }
    case "commands": return hq(["peek", str(body, "session"), "--commands", "--json"]);
    case "peek-tool": return hq(["peek", str(body, "session"), "--tool", str(body, "id"), "--json"]);
    case "seen":
      // A task's drawer showed these sessions' last replies.
      for (const sid of Array.isArray(body.sessions) ? body.sessions : []) if (SESSION_ID.test(String(sid))) onSeen(String(sid));
      return { result: { ok: true } };
    case "pet": {
      // BoardWindow's "pet": the pet's unread finishes and held prompts, and what PetBoard keeps.
      const store = await board({ op: "store" });
      const s = petState();
      return { result: JSON.stringify(Object.assign({ unread: s.unread || {}, dots: s.dots || {}, skin: "cat",
        clickTarget: s.clickTarget || "terminal" }, store.result || {})) };
    }
    // Prompts a pet-emit holds open (PetBoard checks the prompt is still the one up).
    case "prompt": case "decide": return board(body);
    case "answer-question": case "plan-feedback": {
      const r = await board(body);
      if (!r.error) onSeen(str(body, "session"));   // answering means you read it
      return r;
    }
    case "plan-approve":
      // Approving is Enter in the session's terminal (Claude Code ignores a hook's allow for a plan).
      return { error: L("approving a plan from the board is not on Windows yet — Jump and approve it there",
        "Windows 版还不能在看板上批准计划——跳到终端里批准") };
    case "launch": return launch(body, win);
    case "resume": return resume(body, win);
    case "attach": {
      // A background session, in a terminal tab.
      const sid = str(body, "session");
      if (!SESSION_ID.test(sid)) return { error: L("not a session id", "不是有效的 session id") };
      const claude = await findClaude();
      if (!claude) return noClaude();
      const into = str(body, "where") === "bg" ? "terminal" : str(body, "where");
      return openInTerminal(into, HOME, [claude, "attach", sid], "attach " + sid.slice(0, 8), true, win);
    }
    case "stop": {
      // A background session (`claude stop` takes the short id `claude agents` prints).
      const id = str(body, "session");
      if (!SESSION_ID.test(id)) return { error: L("not a session id", "不是有效的 session id") };
      const claude = await findClaude();
      if (!claude) return noClaude();
      kept.delete("agents");
      const r = await exec(claude, ["stop", id], { env: CLAUDE_ENV, timeout: 30000 });
      return r.status === 0 ? { result: { ok: true } } : { error: (r.err || r.out).trim() || "claude stop failed" };
    }
    case "board-prefs": case "card-seen": case "phrases": case "phrase-suggest": case "read-doc":
      return board(body);
    case "agents": return agents();
    case "resolve":
      return hq(["ask", "resolve", str(body, "id"), str(body, "resolution"), "--via", "board", `--note=${str(body, "note")}`]);
    case "reopen": return hq(["ask", "reopen", str(body, "id"), "--via=board"]);
    case "snooze":
      return hq(["ask", "snooze", str(body, "id"), "--via=board"].concat(typeof body.until === "string" ? [`--until=${body.until}`] : []));
    case "delivered":
      return hq(["ask", "delivered", str(body, "id"), `--session=${str(body, "session")}`].concat(body.undo === true ? ["--undo"] : []));
    case "todo": {
      const index = Number.isInteger(body.index) ? String(body.index) : str(body, "index");
      return hq(["todo", str(body, "task"), index, str(body, "state"), "--via=board"].concat(str(body, "text") ? [`--text=${str(body, "text")}`] : []));
    }
    case "set": {
      const fields = Array.isArray(body.fields) ? body.fields.filter((f) => typeof f === "string") : [];
      if (!fields.length) return { error: L("no fields", "没有要改的字段") };
      return hq(["set", str(body, "task")].concat(fields));
    }
    case "log": return hq(["log", str(body, "task"), "--", str(body, "message")]);
    case "focus":
      return hq(["focus", str(body, "action")].concat(Array.isArray(body.tasks) ? body.tasks.map(String) : [], ["--json"]));
    case "project": {
      const action = str(body, "action");
      const opts = [];
      if (action === "add") {
        for (const p of Array.isArray(body.paths) ? body.paths : []) opts.push(`--path=${p}`);
        for (const k of ["kind", "title", "due", "parent"]) if (str(body, k)) opts.push(`--${k}=${str(body, k)}`);
      }
      if (typeof body.to === "string") opts.push(`--to=${body.to}`);
      return hq(["project"].concat(opts, [action, "--"], Array.isArray(body.names) ? body.names.map(String) : []));
    }
    case "ref": return hq(["ref", str(body, "action"), str(body, "task"), "--", str(body, "ref")]);
    case "workdir": return hq(["workdir", str(body, "action"), str(body, "task"), "--", str(body, "path")]);
    case "continue": return hq(["continue", str(body, "task"), "--json"]);
    case "addtodo": return hq(["addtodo", str(body, "task"), "--", str(body, "text")]);
    case "bind": return hq(["bind", str(body, "task"), `--session=${str(body, "session")}`]);
    case "unbind": return hq(["unbind", `--session=${str(body, "session")}`]);
    case "history": return hq(["history", str(body, "task"), "--json"]);
    case "new": {
      const args = ["new"];
      if (str(body, "workdir")) args.push(`--workdir=${str(body, "workdir")}`);
      if (str(body, "project")) args.push(`--project=${str(body, "project")}`);
      for (const k of ["goal", "template", "phase"]) if (str(body, k)) args.push(`--${k}=${str(body, k)}`);
      if (body.focus === false) args.push("--no-focus");
      return hq(args.concat(["--", str(body, "title")]));
    }
    case "note-add": {
      const text = str(body, "text").trim();
      const images = Array.isArray(body.images) ? body.images.filter((i) => typeof i === "string") : [];
      if (!text && !images.length) return { error: L("empty note", "内容是空的") };
      return hq(["inbox", "--json", "--via=board"].concat(images.map((i) => `--image=${i}`), ["--", "add", text]));
    }
    case "note-sort": {
      const claude = await findClaude();
      return hq(["inbox", "--json"].concat(claude ? [`--claude=${claude}`] : [], ["--", "sort", str(body, "id")]), SORT_TIMEOUT);
    }
    case "note-move": {
      const fields = ["task", "owner", "text", "title", "project", "workdir", "next", "state", "status"]
        .filter((k) => str(body, k)).map((k) => `--${k}=${str(body, k)}`)
        .concat((Array.isArray(body.done) ? body.done : []).map((d) => `--done=${d}`));
      return hq(["inbox", "--json"].concat(fields, ["--", "move", str(body, "id"), str(body, "kind")]));
    }
    case "note-drop": return hq(["inbox", "--json", "--", "drop", str(body, "id")]);
    case "note-restore": return hq(["inbox", "--json", "--", "restore", str(body, "id")]);
    case "saveImage": return saveImage(str(body, "data"));
    case "copy":
      clipboard.writeText(str(body, "text"));
      return { result: { ok: true } };
    case "openURL": {
      let url;
      try { url = new URL(str(body, "url")); } catch (_) { url = null; }
      if (!url || !["http:", "https:", "mailto:"].includes(url.protocol)) return { error: L("only web links can be opened", "只能打开网页链接") };
      await shell.openExternal(url.href);
      return { result: { ok: true } };
    }
    case "openPath": return openPath(str(body, "path"), str(body, "cwd"));
    case "open": {
      // A task card or a project's PROJECT.md, in its default app.
      // Only under the task root (the Mac also opens the secretary's files, which Windows lacks).
      const p = path.normalize(str(body, "path"));
      const root = hqRoot() && path.normalize(hqRoot()).toLowerCase() + path.sep;
      if (!/[\\/](TASK|PROJECT)\.md$/.test(p) || !localPath(p) || !root || !p.toLowerCase().startsWith(root) || !fs.existsSync(p)) {
        return { error: L("not a task card or project file", "不是任务卡或项目文件") };
      }
      const err = await shell.openPath(p);
      return err ? { error: err } : { result: { ok: true } };
    }
    case "pick-folder": {
      const r = await dialog.showOpenDialog(win, { properties: ["openDirectory"], message: str(body, "message") || undefined,
        defaultPath: str(body, "path") ? str(body, "path").replace(/^~(?=$|[\\/])/, HOME) : undefined });
      return { result: { path: r.canceled || !r.filePaths.length ? "" : r.filePaths[0] } };
    }
    case "jump": {
      // The session's terminal, as the pet's row click does (pet-emit --jump, WindowsJump).
      const sid = str(body, "session");
      if (!SESSION_ID.test(sid)) return { error: L("no terminal recorded for this session", "没有记录这个 session 的终端") };
      if (str(body, "bg")) return { error: L("it runs in the background, in no terminal", "它在后台运行，不在任何终端里") };
      const r = await exec(petEmit, ["--jump", sid], { timeout: 15000, env: petEnv() });
      return r.status === 0 ? { result: { ok: true } } : { error: r.err.trim() || L("no terminal recorded for this session", "没有记录这个 session 的终端") };
    }
    case "click-target":
      onClickTarget(str(body, "value"));
      return { result: "ok" };
    case "jobs": return { result: JSON.stringify({ jobs: [], runner: false }) };
    default:
      // Typing into a session's terminal (send, interrupt, stop-session), the secretary,
      // scheduled jobs, phone access: Mac only for now.
      return notOnWindows();
  }
}

/** One request from the board window; the shared reads are dropped around anything that
 * may change what hq says (SharedReads.changes). */
async function handle(body, win) {
  if (!body || typeof body !== "object") return { error: L("bad request", "请求有误") };
  const op = str(body, "op");
  if (READ_ONLY.has(op)) return perform(body, win);
  kept.clear();
  try { return await perform(body, win); } finally { kept.clear(); }
}

function configure(opts) {
  if (opts.L) L = opts.L;
  if (opts.petEmit) petEmit = opts.petEmit;
  if (opts.petEnv) petEnv = opts.petEnv;
  if (opts.petState) petState = opts.petState;
  if (opts.onSeen) onSeen = opts.onSeen;
  if (opts.onClickTarget) onClickTarget = opts.onClickTarget;
}

module.exports = { configure, handle, hqCommand, taskBySession, tabCommand, openInTerminal };
