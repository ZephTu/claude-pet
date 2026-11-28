// Phone access on Windows: the board served to a paired phone's browser over the local network,
// and over Tailscale to the user's own devices. What BoardServer.swift, RemoteAccess.swift and
// Tailnet.swift do on the Mac, with the same rules (windows/CLAUDE.md, "Phone access"):
//
//  - Off until turned on in the board's settings; then it listens on every interface, answers
//    only private addresses (and, with Tailscale turned on too, Tailscale addresses that
//    `tailscale whois` says are devices of this PC's own Tailscale user), and runs nothing for a
//    request without a paired phone's token.
//  - The token is the lock: a paired phone can do anything the board can. Everything else here
//    (private addresses, the Host and Origin checks, the lockout) keeps strangers from getting as
//    far as trying one. Tokens are kept only as their SHA-256.
//  - The same pages and the same operations as the board window: a phone's `POST /api` goes to
//    board.js's handle(), minus what only this PC's own window may do (RemoteAccess.macOnly).
//  - `POST /events` stays open and says when the board may have changed (BoardPush), from
//    board-events.js's file watch.
"use strict";

const http = require("http");
const net = require("net");
const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const zlib = require("zlib");
const { execFile } = require("child_process");

const DEFAULT_PORT = 8790;
// A pasted image travels as a data URL (base64 of up to 20 MB, see saveImage).
const MAX_BODY = 32 * 1024 * 1024;
const MAX_HEADER = 32 * 1024;
// A custom header, not a cookie: a page on another origin can't set it without a CORS preflight,
// which this server never answers.
const TOKEN_HEADER = "x-hq-token";
const DEVICE_HEADER = "x-hq-device";
// The version of an answer the phone already has: the same answer again is sent as {"same": true}.
const HAVE_HEADER = "x-hq-have";
const PAIR_WINDOW = 15 * 60 * 1000;
const MAX_FAILURES = 20;
const LOCKOUT = 10 * 60 * 1000;
// Wrong tokens from anywhere while a pairing code waits: past this many, the code is cancelled.
const MAX_CODE_FAILURES = 100;
// Connections open at once: a phone opens a handful, many more is someone flooding.
const MAX_OPEN = 48;
// BoardPush: a quiet stream is pinged (a NAT or Tailscale's relay drops a silent one), and only so
// many phones hold one at once.
const KEEP_ALIVE = 25 * 1000;
const MAX_STREAMS = 8;
const CLAIM_OP = "pair";

// ------------------------------------------------------------------ addresses

/** An address as Node gives it ("192.168.1.5", "::ffff:192.168.1.5", "fe80::1%12") as bytes:
 * 4 for IPv4, 16 for IPv6; null for anything else. */
function ipBytes(address) {
  let a = String(address || "").trim();
  const zone = a.indexOf("%");
  if (zone >= 0) a = a.slice(0, zone);
  if (a.startsWith("[") && a.endsWith("]")) a = a.slice(1, -1);
  if (net.isIPv4(a)) return a.split(".").map(Number);
  if (!net.isIPv6(a)) return null;
  let tail = [];
  const v4 = a.match(/:(\d+\.\d+\.\d+\.\d+)$/);
  if (v4) {
    tail = v4[1].split(".").map(Number);
    a = a.slice(0, -v4[1].length) + "0:0";
  }
  const [head, rest] = a.includes("::") ? a.split("::") : [a, null];
  const words = (s) => (s ? s.split(":").filter((x) => x !== "") : []);
  const h = words(head), r = rest === null ? [] : words(rest);
  const fill = rest === null ? 0 : 8 - h.length - r.length;
  const all = h.concat(Array(Math.max(0, fill)).fill("0"), r);
  if (all.length !== 8) return null;
  const bytes = [];
  for (const w of all) { const n = parseInt(w, 16); bytes.push(n >> 8, n & 0xff); }
  if (tail.length) bytes.splice(12, 4, ...tail);
  return bytes;
}

const isMapped = (b) => b.length === 16 && b.slice(0, 10).every((x) => x === 0) && b[10] === 0xff && b[11] === 0xff;
const TAILNET6 = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0];
const startsWith = (b, prefix) => prefix.every((x, i) => b[i] === x);

/** A peer on the local network: private IPv4 (10/8, 172.16/12, 192.168/16), link-local,
 * loopback, or the IPv6 equivalents (fc00::/7, fe80::/10, ::1, and IPv4-mapped ones). Tailscale's
 * addresses reach across the internet, and are not. */
function isLocal(b) {
  if (!b) return false;
  if (b.length === 4) {
    const [a, c] = b;
    return a === 10 || a === 127 || (a === 172 && c >= 16 && c <= 31) || (a === 192 && c === 168) || (a === 169 && c === 254);
  }
  if (b.length !== 16) return false;
  if (isMapped(b)) return isLocal(b.slice(12));
  if (b.slice(0, 15).every((x) => x === 0) && b[15] === 1) return true;
  if (startsWith(b, TAILNET6)) return false;
  return (b[0] & 0xfe) === 0xfc || (b[0] === 0xfe && (b[1] & 0xc0) === 0x80);
}

/** A Tailscale address: 100.64.0.0/10, fd7a:115c:a1e0::/48. */
function isTailnet(b) {
  if (!b) return false;
  if (b.length === 4) return b[0] === 100 && (b[1] & 0xc0) === 64;
  if (b.length !== 16) return false;
  if (isMapped(b)) return isTailnet(b.slice(12));
  return startsWith(b, TAILNET6);
}

/** Whether `address` is in the network `net`/`mask` (same length). */
function inSubnet(address, netw, mask) {
  if (!address || address.length !== netw.length || netw.length !== mask.length || mask.every((x) => x === 0)) return false;
  return address.every((x, i) => (x & mask[i]) === (netw[i] & mask[i]));
}

const hex = (bytes) => bytes.map((x) => x.toString(16).padStart(2, "0")).join("");

/** What wrong tokens count against: the address, or for IPv6 its /64 (anyone gets a new address
 * from their /64 whenever they like); link-local ones by the whole address. */
function lockKey(b) {
  if (isMapped(b)) return lockKey(b.slice(12));
  if (b.length === 4) return b.join(".");
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0x80) return hex(b);
  return hex(b.slice(0, 8)) + "/64";
}

/** Wrong tokens by lockKey: an address that reaches MAX_FAILURES is turned away until LOCKOUT has
 * passed since its last wrong token; a count older than that starts again. */
class Lockout {
  constructor() { this.entries = new Map(); }
  locked(key, now) {
    const e = this.entries.get(key);
    return Boolean(e && e.count >= MAX_FAILURES && now - e.last < LOCKOUT);
  }
  fail(key, now) {
    if (this.entries.size > 1000) for (const [k, e] of this.entries) if (now - e.last >= LOCKOUT) this.entries.delete(k);
    const e = this.entries.get(key) || { count: 0, last: now };
    if (now - e.last >= LOCKOUT) e.count = 0;
    e.count += 1;
    e.last = now;
    this.entries.set(key, e);
  }
  clear(key) { this.entries.delete(key); }
}

/** The host part of a Host header or an origin: no port, no brackets, lower-cased. */
function hostName(raw) {
  let h = String(raw || "").trim().toLowerCase();
  const scheme = h.indexOf("://");
  if (scheme >= 0) h = h.slice(scheme + 3);
  const slash = h.indexOf("/");
  if (slash >= 0) h = h.slice(0, slash);
  if (h.startsWith("[")) {
    const end = h.indexOf("]");
    return end >= 0 ? h.slice(1, end) : h;
  }
  if ((h.match(/:/g) || []).length === 1) h = h.slice(0, h.lastIndexOf(":"));
  return h;
}

/** The name the phone used for this PC must be one a local network gives it: an address, a
 * `.local` name, or the PC's own name. A page elsewhere that points its own domain at this PC's
 * address (DNS rebinding) arrives under that domain, and is turned away. */
function hostAllowed(header, names) {
  if (!header) return false;
  const h = hostName(header);
  if (h === "localhost" || h.endsWith(".local")) return true;
  if (names.some((n) => n && n.toLowerCase() === h)) return true;
  if (h.includes(":")) return /^[0-9a-f:.%]+$/.test(h);
  const parts = h.split(".");
  return parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255);
}

/** A request that says where it came from must come from the page this server serves. */
function originAllowed(origin, host) {
  if (!origin) return true;
  if (!host) return false;
  return hostName(origin) === hostName(host);
}

// ------------------------------------------------------------------ Tailscale

/** This PC on its tailnet, from `tailscale status --json`: { running, login, name, addresses }. */
function tailnetSelf(json) {
  let o;
  try { o = JSON.parse(json); } catch (_) { return null; }
  if (!o || typeof o !== "object" || Array.isArray(o)) return null;
  const me = o.Self || {};
  const tags = Array.isArray(me.Tags) ? me.Tags : [];
  let login = null;
  if (!tags.length && me.UserID !== undefined && o.User && o.User[String(me.UserID)]) {
    login = o.User[String(me.UserID)].LoginName || null;
  }
  let name = typeof me.DNSName === "string" ? me.DNSName : "";
  if (name.endsWith(".")) name = name.slice(0, -1);
  return { running: o.BackendState === "Running", login, name: name ? name.toLowerCase() : null,
    addresses: Array.isArray(me.TailscaleIPs) ? me.TailscaleIPs : [] };
}

/** Whether `tailscale whois --json` describes a device of `login`'s own: logged in as the same
 * user, and not a tagged device (a server or gateway that belongs to no one person). */
function tailnetOwnDevice(json, login) {
  if (!login) return false;
  let o;
  try { o = JSON.parse(json); } catch (_) { return false; }
  const node = o && o.Node, who = o && o.UserProfile && o.UserProfile.LoginName;
  if (!node || typeof who !== "string") return false;
  if (Array.isArray(node.Tags) && node.Tags.length) return false;
  return who.toLowerCase() === login.toLowerCase();
}

/** Tailscale's command line: who this PC is on its tailnet, and whose device a peer is. */
class Tailnet {
  constructor(L, log) {
    this.L = L;
    this.log = log;
    this.me = null;
    this.problem = null;
    this.readAt = 0;
    this.reading = null;
    this.verdicts = new Map();
    this.asking = new Map();
    this.cli = [process.env.TAILSCALE_CLI, path.join(process.env.ProgramFiles || "C:\\Program Files", "Tailscale", "tailscale.exe")]
      .find((p) => p && fs.existsSync(p)) || null;
  }

  run(args) {
    return new Promise((resolve) => {
      if (!this.cli) return resolve(null);
      execFile(this.cli, args, { timeout: 5000, windowsHide: true, maxBuffer: 4 * 1024 * 1024 }, (err, out) => resolve(err ? null : out));
    });
  }

  /** This PC on the tailnet, read again when the last reading is over 30 seconds old. */
  async current(force = false) {
    if (!force && this.readAt && Date.now() - this.readAt < 30000) return this.me;
    if (this.reading) return this.reading;
    this.reading = (async () => {
      const L = this.L();
      if (!this.cli) {
        this.problem = L("Tailscale isn't installed on this PC", "这台电脑没装 Tailscale");
        return null;
      }
      const out = await this.run(["status", "--json", "--peers=false"]);
      const me = out && tailnetSelf(out);
      if (!me) {
        this.problem = L("Tailscale isn't answering — is it running?", "Tailscale 没有回应——它开着吗？");
        return null;
      }
      this.problem = me.running ? null : L("Tailscale isn't connected", "Tailscale 没有连上");
      return me;
    })();
    const value = await this.reading;
    this.reading = null;
    this.me = value;
    this.readAt = Date.now();
    return value;
  }

  refresh() { this.current().catch(() => {}); }

  /** Whether the peer at `address` is a device of the user this PC is logged in as. Asked once per
   * address every couple of minutes (a page load opens several connections at once). */
  async allows(address) {
    const now = Date.now();
    const v = this.verdicts.get(address);
    if (v && now - v.at < (v.ok ? 120000 : 30000)) return v.ok;
    if (this.asking.has(address)) return this.asking.get(address);
    const task = (async () => {
      const me = await this.current();
      if (!me || !me.running || !me.login) return false;
      const out = await this.run(["whois", "--json", address]);
      return Boolean(out) && tailnetOwnDevice(out, me.login);
    })();
    this.asking.set(address, task);
    const ok = await task;
    this.asking.delete(address);
    if (this.verdicts.size > 500) for (const [k, x] of this.verdicts) if (now - x.at >= 120000) this.verdicts.delete(k);
    this.verdicts.set(address, { ok, at: Date.now() });
    if (!ok) this.log(`phone access: refused ${address} over Tailscale: not a device of this PC's user`);
    return ok;
  }
}

// ------------------------------------------------------------------ paired phones

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");

/** 32 random bytes, URL-safe base64: 256 bits no one guesses. */
const newToken = () => crypto.randomBytes(32).toString("base64url");

// Crockford's base32: no I, L, O or U to misread.
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
/** 8 characters to type where scanning won't do: one use, lapses in PAIR_WINDOW, shares the
 * lockout, so 40 bits are plenty. */
function newPairingCode() {
  let s = "";
  for (let i = 0; i < 8; i++) s += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
  return s;
}

/** As typed: case, spaces and dashes don't matter, and O, I and L read as 0, 1 and 1. */
function normalizeCode(typed) {
  const mapped = String(typed).toUpperCase().replace(/[ -]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  return mapped.length === 8 && [...mapped].every((c) => CODE_ALPHABET.includes(c)) ? mapped : null;
}

const time = (iso) => (iso ? Date.parse(iso) : NaN);

/** The devices still valid: paired ones, and pairing codes not yet lapsed. */
function live(devices, now) {
  return devices.filter((d) => d.paired || now - time(d.created) < PAIR_WINDOW);
}

/** The index of the device a token belongs to: every hash compared in full, no early exit. */
function match(token, devices, now) {
  if (!token) return null;
  const h = Buffer.from(sha256(token));
  let found = null;
  devices.forEach((d, i) => {
    const other = Buffer.from(String(d.hash || ""));
    if (other.length !== h.length) return;
    if (crypto.timingSafeEqual(h, other) && (d.paired || now - time(d.created) < PAIR_WINDOW)) found = i;
  });
  return found;
}

/** What to call a phone: the name its page sends, else its browser's User-Agent. */
function deviceName(given, userAgent) {
  const clean = [...String(given || "")].filter((c) => /[\p{L}\p{N}]/u.test(c) || " -_·'".includes(c)).join("").trim();
  if (clean) return [...clean].slice(0, 40).join("");
  const ua = String(userAgent || "");
  for (const [key, name] of [["iPhone", "iPhone"], ["iPad", "iPad"], ["Android", "Android"], ["Macintosh", "Mac"], ["Windows", "Windows"], ["Linux", "Linux"]]) {
    if (ua.includes(key)) return name;
  }
  return "Browser";
}

// What a paired phone may ask for: a list of what is allowed (RemoteAccess.phoneOps). An op the
// board's bridge gains stays this PC's until it is put here on purpose.
const PHONE_OPS = new Set([
  "board", "sessions", "status", "peek", "seen", "commands", "peek-tool", "pet", "history",
  "agents", "prompt", "read-doc",
  "board-prefs", "phrases", "phrase-suggest", "card-seen",
  "resolve", "reopen", "snooze", "delivered", "todo", "set", "log", "focus", "project", "ref",
  "workdir", "continue", "addtodo", "bind", "unbind", "new",
  "note-add", "note-sort", "note-move", "note-drop", "note-restore",
  "launch", "resume", "send", "interrupt", "saveImage", "stop", "stop-session", "decide",
  "answer-question", "plan-feedback", "plan-approve",
  "secretary", "secretary-setup", "secretary-send", "secretary-stop", "secretary-reports",
  "secretary-feed", "secretary-feed-now", "secretary-autoclose", "secretary-autoclose-now",
  "intake-job", "intake-job-set", "intake-job-now",
  "jobs", "job-save", "job-enable", "job-delete", "job-run", "job-stop", "job-preview",
  "job-detail", "job-seen", "job-resume", "recur-save",
]);
// Only this PC's own window: managing phone access, whatever acts on its screen (a folder picker,
// opening files, links or terminals, jumping), its clipboard, and what a click on the pet opens.
const PC_ONLY = new Set([
  "remote", "remote-enable", "remote-tailnet", "remote-pair", "remote-revoke",
  "pick-folder", "open", "openPath", "openURL", "attach", "jump", "copy", "click-target",
]);
const allowed = (op) => PHONE_OPS.has(op);

// ------------------------------------------------------------------ responses

/** A file's version, for If-None-Match: the same bytes, the same tag. */
const etag = (data) => `"${crypto.createHash("sha256").update(data).digest("hex").slice(0, 24)}"`;

/** Whether an If-None-Match header names this version (a list, or `*`). */
function unchanged(ifNoneMatch, tag) {
  if (!ifNoneMatch) return false;
  return ifNoneMatch.split(",").some((t) => { t = t.trim(); return t === "*" || t === tag || t === "W/" + tag; });
}

function acceptsGzip(acceptEncoding) {
  if (!acceptEncoding) return false;
  return acceptEncoding.toLowerCase().split(",").some((part) => {
    const p = part.split(";").map((x) => x.trim());
    return p[0] === "gzip" && !p.slice(1).includes("q=0");
  });
}

const compressible = (type) => /^text\/|javascript|json|svg/.test(type.toLowerCase());

/** Puts `tags` at the top of the page's head: the language and remote flags are set before the
 * page's own scripts run. */
function inject(tags, html) {
  const m = html.match(/<head>/i);
  if (!m) return tags + html;
  const at = m.index + m[0].length;
  return html.slice(0, at) + "\n" + tags + html.slice(at);
}

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
  ".svg": "image/svg+xml", ".json": "application/json", ".ico": "image/x-icon", ".woff2": "font/woff2",
  ".md": "text/plain; charset=utf-8", ".txt": "text/plain; charset=utf-8",
};

// ------------------------------------------------------------------ the PC's addresses

// A VPN's or a virtual machine's adapter: its addresses are for the far end or the VM, not for a
// phone on the Wi-Fi.
const TUNNEL = /tailscale|vethernet|hyper-v|wsl|vmware|virtualbox|vbox|zerotier|wireguard|openvpn|vpn|tap-|tun|loopback|npcap|docker/i;

function interfaces() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.internal) continue;
      const bytes = ipBytes(a.address), mask = ipBytes(a.netmask);
      if (!bytes || !mask) continue;
      out.push({ name, bytes, mask, address: a.address, tunnel: TUNNEL.test(name) || isTailnet(bytes) });
    }
  }
  return out;
}

/** A peer in a network this PC is on itself (a public IPv6 address from the home router, say).
 * Tunnels don't count: their peers are anywhere. */
function onLink(peer) {
  const address = isMapped(peer) ? peer.slice(12) : peer;
  return interfaces().some((i) => !i.tunnel && inSubnet(address, i.bytes, i.mask));
}

/** Who may connect at all: "local" (a private address, or one in a network this PC is on),
 * "tailnet" (a Tailscale address, with Tailscale turned on: still to be asked whose device it
 * is), or null (turned away before a byte is read). */
function admission(bytes, tailnetOn, linked = onLink) {
  if (isLocal(bytes) || linked(bytes)) return "local";
  return tailnetOn && isTailnet(bytes) ? "tailnet" : null;
}

/** How a phone on the Wi-Fi reaches this PC: each private IPv4 address on a real network. */
function lanAddresses() {
  const out = [];
  for (const i of interfaces()) {
    if (i.tunnel || i.bytes.length !== 4 || !isLocal(i.bytes) || i.bytes[0] === 169 || i.bytes[0] === 127) continue;
    if (!out.includes(i.address)) out.push(i.address);
  }
  return out;
}

// ------------------------------------------------------------------ the server

class BoardServer {
  /**
   * @param o.handle      board.js's handle(body, win): the board's operations
   * @param o.readPrefs   / o.writePrefs: prefs.json, where the switches and the phones are kept
   * @param o.root        the pet's pages (Resources/pet)
   * @param o.petHome     the pet's data folder (board.json: the board's shared prefs)
   * @param o.L           () => L(en, zh), the pet's language now
   * @param o.lang        () => "en" | "zh"
   * @param o.events      board-events.js: start() and on(fn) for "something changed"
   * @param o.dropReads   drops the board's kept reads (a change makes them stale)
   */
  constructor(o) {
    Object.assign(this, { handle: o.handle, readPrefs: o.readPrefs, writePrefs: o.writePrefs, root: path.resolve(o.root),
      petHome: o.petHome, L: o.L, lang: o.lang, events: o.events, log: o.log || (() => {}) });
    this.tailnet = new Tailnet(o.L, this.log);
    this.server = null;
    this.http = null;
    this.lastError = null;
    this.lockout = new Lockout();
    this.codeFailures = 0;
    this.notice = null;
    this.open = 0;
    this.gzipped = new Map();
    this.streams = [];
    this.pinger = null;
    this.portOverride = null;
    this.watching = false;
  }

  get enabled() { return this.readPrefs().boardServerEnabled === true; }
  get tailnetOn() { return this.readPrefs().boardServerTailnet === true; }
  get port() {
    if (this.portOverride) return this.portOverride;
    const p = Number(this.readPrefs().boardServerPort);
    return Number.isInteger(p) && p >= 1024 && p <= 65535 ? p : DEFAULT_PORT;
  }
  get running() { return Boolean(this.server && this.server.listening); }

  setPref(key, value) {
    const p = this.readPrefs();
    if (value === undefined) delete p[key]; else p[key] = value;
    this.writePrefs(p);
  }

  get devices() {
    const d = this.readPrefs().boardServerDevices;
    return Array.isArray(d) ? d.filter((x) => x && typeof x === "object") : [];
  }
  set devices(list) { this.setPref("boardServerDevices", live(list, Date.now())); }

  startIfEnabled() {
    if (!this.enabled) return;
    this.start();
    if (this.tailnetOn) this.tailnet.refresh();
  }

  /** `windows/scripts/serve-board.js`: the server alone, on a port of its own. */
  serveForDevelopment(port) {
    this.portOverride = port;
    return this.start();
  }

  start() {
    if (this.server) return Promise.resolve();
    this.lastError = null;
    this.http = http.createServer({ maxHeaderSize: MAX_HEADER, requestTimeout: 60000, headersTimeout: 30000 },
      (req, res) => this.request(req, res).catch((e) => {
        this.log("phone access: " + (e && e.stack || e));
        if (!res.headersSent) this.send(res, 500, "text/plain", Buffer.alloc(0)); else res.destroy();
      }));
    this.http.keepAliveTimeout = 5000;
    // Turned away before a byte is read: a peer outside the local network, unless it comes over
    // Tailscale (turned on) from a device of this PC's own user.
    const server = net.createServer({ pauseOnConnect: true }, (socket) => this.accept(socket));
    this.server = server;
    return new Promise((resolve) => {
      server.once("error", (e) => {
        this.lastError = e.code === "EADDRINUSE" ? this.L()("the port is taken by another program", "端口被别的程序占用了") : e.message;
        this.log("phone access did not start: " + e.message);
        if (this.server === server) this.server = null;
        resolve();
      });
      server.listen({ port: this.port, host: "::", ipv6Only: false }, () => {
        this.log(`phone access listening on port ${this.port}`);
        if (!this.watching && this.events) {
          this.watching = true;
          this.events.on((n) => this.pushAll(`event: changed\ndata: ${n}\n\n`));
        }
        if (this.events) this.events.start();
        resolve();
      });
    });
  }

  stop() {
    if (this.server) this.server.close();
    this.server = null;
    this.lastError = null;
    this.closeStreams(() => true);
  }

  accept(socket) {
    const bytes = ipBytes(socket.remoteAddress);
    const way = bytes && this.open < MAX_OPEN ? admission(bytes, this.tailnetOn) : null;
    if (!way) return socket.destroy();
    const name = String(socket.remoteAddress).replace(/^::ffff:/, "").replace(/%.*$/, "");
    const tailnet = way === "tailnet";
    this.open += 1;
    socket.once("close", () => { this.open -= 1; });
    socket.on("error", () => {});
    socket.peer = { name, key: lockKey(bytes), tailnet };
    const go = () => { this.http.emit("connection", socket); socket.resume(); };
    if (!tailnet) return go();
    // Not a byte read until Tailscale says whose device it is.
    this.tailnet.allows(name).then((ok) => {
      if (ok && this.tailnetOn && this.running && !socket.destroyed) go(); else socket.destroy();
    }, () => socket.destroy());
  }

  // ---- requests

  async request(req, res) {
    const peer = req.socket.peer || { name: "?", key: "?" };
    const urlPath = String(req.url || "").split("?")[0];
    const L = this.L();
    // Chunked bodies are not something a browser sends with fetch(); refusing them keeps the
    // reader to one shape.
    if (req.headers["transfer-encoding"]) return this.text(res, 400, "bad request");
    const names = [os.hostname()];
    if (this.tailnetOn && this.tailnet.me && this.tailnet.me.name) names.push(this.tailnet.me.name, this.tailnet.me.name.split(".")[0]);
    if (!hostAllowed(req.headers.host, names)) return this.text(res, 403, "This address can't be used for the board.");
    if (urlPath !== "/api" && urlPath !== "/events") {
      if (req.method !== "GET" && req.method !== "HEAD") return this.text(res, 405, "GET only");
      if (Number(req.headers["content-length"] || 0) > 0) return this.text(res, 413, "");
      return this.page(req, res, urlPath);
    }
    if (req.method !== "POST") return this.text(res, 405, "POST only");
    if (!originAllowed(req.headers.origin, req.headers.host)) return this.text(res, 403, "cross-origin request refused");
    const now = Date.now();
    if (this.lockout.locked(peer.key, now)) {
      return this.json(res, 429, { error: L("Too many wrong tokens from this address — try again in 10 minutes", "这个地址试错 token 的次数太多——10 分钟后再试") });
    }
    const all = this.devices;
    if (match(this.presented(req), all, now) === null) {
      this.lockout.fail(peer.key, now);
      if (live(all, now).some((d) => !d.paired)) {
        this.codeFailures += 1;
        if (this.codeFailures >= MAX_CODE_FAILURES) {
          this.devices = all.filter((d) => d.paired);
          this.codeFailures = 0;
          this.notice = L("Too many wrong pairing codes were tried, so the code was cancelled — press Pair a phone for a new one",
            "有人试了太多错误的配对码，这个码已作废——点「配对手机」重新生成");
          this.log(`phone access: pairing code cancelled after ${MAX_CODE_FAILURES} wrong tries`);
        }
      }
      return this.unpaired(res);
    }
    this.lockout.clear(peer.key);
    // Only a paired phone (or a waiting code) gets to send a body.
    const length = Number(req.headers["content-length"] || 0);
    if (!Number.isFinite(length) || length < 0) return this.text(res, 400, "bad request");
    if (length > MAX_BODY) return this.text(res, 413, "");
    const body = await readBody(req, MAX_BODY);
    if (body === null) return this.text(res, 413, "");
    if (urlPath === "/events") return this.stream(req, res, peer);
    return this.api(req, res, body, peer);
  }

  /** The token a request carries; a pairing code as the phone may have typed it. */
  presented(req) {
    const t = req.headers[TOKEN_HEADER];
    return t ? normalizeCode(t) || t : null;
  }

  unpaired(res) {
    const L = this.L();
    return this.json(res, 401, { error: L("This phone isn't paired, or was removed — pair it again from the PC's board: Settings → Phone access",
      "这台手机还没配对，或已被移除——到电脑上的看板「设置 → 手机访问」重新配对"), pair: true });
  }

  /** Notes when and from where a phone last asked, at most once a minute. Whether it changed. */
  seen(d, peer) {
    const now = Date.now();
    if (d.lastSeen && now - time(d.lastSeen) <= 60000 && d.lastAddress === peer) return false;
    d.lastSeen = new Date(now).toISOString();
    d.lastAddress = peer;
    return true;
  }

  /** `POST /api` with {op, …}: answered {result} or {error}, as the window's messages are. */
  async api(req, res, raw, peer) {
    const L = this.L();
    const now = Date.now();
    const all = this.devices;
    const i = match(this.presented(req), all, now);
    if (i === null) return this.unpaired(res);
    let body;
    try { body = JSON.parse(raw.toString("utf8")); } catch (_) { body = null; }
    if (!body || typeof body !== "object" || Array.isArray(body) || typeof body.op !== "string") return this.json(res, 400, { error: "bad request" });
    const op = body.op;
    // A pairing code buys the phone its own token, once, and nothing else.
    if (!all[i].paired) {
      if (op !== CLAIM_OP) return this.unpaired(res);
      const token = newToken();
      let given = req.headers[DEVICE_HEADER];
      try { given = given && decodeURIComponent(given); } catch (_) { /* as sent */ }
      Object.assign(all[i], { hash: sha256(token), paired: new Date(now).toISOString(),
        name: deviceName(given, req.headers["user-agent"]), lastSeen: new Date(now).toISOString(), lastAddress: peer.name });
      this.devices = all;
      return this.json(res, 200, { result: { token } });
    }
    if (op === CLAIM_OP) return this.json(res, 200, { error: L("This phone is paired already", "这台手机已经配对过了") });
    if (this.seen(all[i], peer.name)) this.devices = all;
    if (!allowed(op)) return this.json(res, 200, { error: L("Only on the PC", "只能在电脑上做") });
    // Sessions start the way this PC's board starts them (one shared choice, board.json's prefs).
    if (["launch", "resume", "job-resume", "send"].includes(op) && body.skip !== undefined) {
      const skip = this.sharedSkip();
      if (skip !== null) body.skip = skip;
    }
    const a = await this.handle(body, null);
    if (a && a.error) return this.json(res, 200, { error: a.error });
    // The board asks for the same things every few seconds: a phone that says which version it
    // has is told only that nothing changed.
    const data = JSON.stringify(a && a.result !== undefined ? a.result : null);
    const tag = etag(data).slice(1, -1);
    if (req.headers[HAVE_HEADER] === tag) return this.json(res, 200, { same: true });
    return this.encoded(req, res, Buffer.from(`{"result":${data},"tag":"${tag}"}`), "application/json");
  }

  sharedSkip() {
    try {
      const doc = JSON.parse(fs.readFileSync(path.join(this.petHome, "board.json"), "utf8"));
      const v = doc && doc.prefs && doc.prefs["hq-skip-perms"];
      return v === undefined ? null : v === "1";
    } catch (_) { return null; }
  }

  // ---- pushes (BoardPush)

  /** `POST /events`: held open and told of every change. POST with the token in its header, as
   * /api has it: the page reads it with fetch, not EventSource, which can't send one. */
  stream(req, res, peer) {
    const all = this.devices;
    const i = match(this.presented(req), all, Date.now());
    if (i === null || !all[i].paired) return this.unpaired(res);
    if (this.seen(all[i], peer.name)) this.devices = all;
    res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "X-Accel-Buffering": "no" });
    // Long enough that a browser hands over what it has at once rather than waiting for more.
    res.write(": " + " ".repeat(2048) + "\n\n");
    req.socket.setTimeout(0);
    req.socket.setNoDelay(true);
    const s = { res, device: all[i].id, peer };
    this.streams.push(s);
    while (this.streams.length > MAX_STREAMS) this.streams.shift().res.destroy();
    res.on("close", () => {
      this.streams = this.streams.filter((x) => x !== s);
      if (!this.streams.length && this.pinger) { clearInterval(this.pinger); this.pinger = null; }
    });
    if (!this.pinger) this.pinger = setInterval(() => this.ping(), KEEP_ALIVE);
  }

  pushAll(text) {
    for (const s of this.streams) s.res.write(text);
  }

  /** Keeps quiet streams open; ends those whose phone is gone, and over Tailscale those from a
   * device no longer the user's own. */
  ping() {
    const ids = new Set(live(this.devices, Date.now()).filter((d) => d.paired).map((d) => d.id));
    this.closeStreams((device) => !ids.has(device));
    this.pushAll(": ping\n\n");
    for (const s of this.streams) {
      if (!s.peer.tailnet) continue;
      this.tailnet.allows(s.peer.name).then((ok) => { if (!ok || !this.tailnetOn) s.res.destroy(); });
    }
  }

  closeStreams(gone) {
    for (const s of this.streams.slice()) if (gone(s.device, s)) s.res.destroy();
  }

  // ---- files

  /** The pet's own files (the board, the guide, the cat's pictures), with the language, "remote"
   * and "windows" set at the top of each page. */
  async page(req, res, urlPath) {
    if (urlPath === "/" || urlPath === "/board" || urlPath === "/board/") {
      return this.send(res, 302, "text/plain", Buffer.alloc(0), { Location: "/board/board.html" });
    }
    if (urlPath === "/manifest.webmanifest") return this.manifest(res);
    let rel;
    try { rel = decodeURIComponent(urlPath); } catch (_) { return this.text(res, 404, "not found"); }
    const file = path.resolve(this.root, "." + rel);
    if (!file.startsWith(this.root + path.sep)) return this.text(res, 404, "not found");
    let data;
    try { data = await fs.promises.readFile(file); } catch (_) { return this.text(res, 404, "not found"); }
    const ext = path.extname(file).toLowerCase();
    if (ext !== ".html") return this.cachable(req, res, data, MIME[ext] || "application/octet-stream");
    const lang = this.lang() === "zh" ? "zh" : "en";
    const tags = [
      `<script>window.PET_LANG = "${lang}"; document.documentElement.lang = "${lang}"; window.HQ_REMOTE = true; window.PET_OS = "windows";</script>`,
      `<meta name="apple-mobile-web-app-capable" content="yes">`,
      `<meta name="mobile-web-app-capable" content="yes">`,
      `<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">`,
      `<meta name="theme-color" content="#23201d">`,
      `<link rel="manifest" href="/manifest.webmanifest">`,
      `<link rel="apple-touch-icon" href="/skins/cat/assets/idle.png">`,
    ].join("\n");
    // A phone zooms into a text box whose type is smaller than 16px, and stays zoomed: the
    // page's scale is held at 1 instead (pinching still zooms). Full screen under the notch.
    const html = inject(tags, data.toString("utf8")).replace('content="width=device-width, initial-scale=1"',
      'content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover"');
    return this.cachable(req, res, Buffer.from(html), "text/html; charset=utf-8");
  }

  manifest(res) {
    const m = { name: "HQ", short_name: "HQ", start_url: "/board/board.html", display: "standalone",
      background_color: "#23201d", theme_color: "#23201d",
      icons: [{ src: "/skins/cat/assets/idle.png", sizes: "any", type: "image/png" }] };
    return this.send(res, 200, "application/manifest+json", Buffer.from(JSON.stringify(m)));
  }

  /** A file the phone may keep: sent again only when it has changed (304 otherwise). */
  cachable(req, res, body, type) {
    const tag = etag(body);
    if (unchanged(req.headers["if-none-match"], tag)) return this.send(res, 304, type, Buffer.alloc(0), { ETag: tag }, true);
    return this.encoded(req, res, body, type, tag);
  }

  /** Compressed when the phone takes gzip and it's worth it: over a slow link the board's scripts
   * and its data are most of the wait. */
  encoded(req, res, body, type, tag) {
    const extra = tag ? { ETag: tag } : {};
    if (body.length > 1024 && compressible(type) && acceptsGzip(req.headers["accept-encoding"])) {
      let z = tag && this.gzipped.get(tag);
      if (!z) z = zlib.gzipSync(body);
      if (z.length < body.length) {
        if (tag) {
          if (this.gzipped.size > 64) this.gzipped.clear();
          this.gzipped.set(tag, z);
        }
        body = z;
        extra["Content-Encoding"] = "gzip";
        extra.Vary = "Accept-Encoding";
      }
    }
    return this.send(res, 200, type, body, extra, Boolean(tag));
  }

  send(res, status, type, body, extra = {}, cached = false) {
    res.writeHead(status, Object.assign({ "Content-Type": type, "Content-Length": body.length,
      "Cache-Control": cached ? "no-cache" : "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer" }, extra));
    res.end(body);
  }

  text(res, status, s) { return this.send(res, status, "text/plain; charset=utf-8", Buffer.from(s)); }
  json(res, status, o) { return this.send(res, status, "application/json", Buffer.from(JSON.stringify(o))); }

  // ---- the board's settings (this PC's window only)

  /** The board's `remote*` ops. */
  async op(op, body) {
    switch (op) {
      case "remote": return { result: this.status() };
      case "remote-enable": return this.setEnabled(body.on === true);
      case "remote-tailnet": return this.setTailnet(body.on === true);
      case "remote-pair": return this.pair(body.via === "tailnet");
      case "remote-revoke": return this.revoke(String(body.id || ""));
      default: return { error: "unknown op" };
    }
  }

  async setEnabled(on) {
    this.setPref("boardServerEnabled", on);
    if (on) await this.start(); else this.stop();
    return { result: this.status() };
  }

  async setTailnet(on) {
    this.setPref("boardServerTailnet", on);
    // A phone's stream over Tailscale must not outlive the switch.
    if (!on) this.closeStreams((_, s) => s.peer.tailnet);
    if (on) await this.tailnet.current(true);
    return { result: this.status() };
  }

  /** A pairing code for one more phone: the address to open with the code after `#` (a fragment
   * never leaves the phone's browser), the same as a QR code, and the code alone to type. */
  async pair(overTailnet) {
    const L = this.L();
    if (!this.running) return { error: L("turn phone access on first", "先打开手机访问") };
    let base;
    if (overTailnet) {
      const url = this.tailnetOn && this.tailnetURL();
      if (!url) return { error: L("Tailscale isn't ready on this PC", "这台电脑上的 Tailscale 还没就绪") };
      base = url;
    } else {
      base = this.baseURLs()[0] || `http://localhost:${this.port}`;
    }
    const code = newPairingCode();
    // One code waits at a time: a new one cancels the last, if it went unused.
    const all = live(this.devices, Date.now()).filter((d) => d.paired);
    const id = crypto.randomUUID().slice(0, 8);
    all.push({ id, name: L("New phone", "新手机"), hash: sha256(code), created: new Date().toISOString() });
    this.devices = all;
    this.codeFailures = 0;
    this.notice = null;
    const url = `${base}/board/board.html#pair=${code}`;
    let qr = "";
    try { qr = await require("qrcode").toDataURL(url, { errorCorrectionLevel: "M", scale: 8, margin: 2 }); } catch (e) { this.log("qr: " + e.message); }
    return { result: { url, qr, code: `${code.slice(0, 4)}-${code.slice(4)}`, id } };
  }

  revoke(id) {
    this.devices = this.devices.filter((d) => d.id !== id);
    this.closeStreams((device) => device === id);
    return { result: this.status() };
  }

  status() {
    const L = this.L();
    const list = live(this.devices, Date.now()).map((d) => {
      const o = { id: d.id, name: d.name, paired: Boolean(d.paired) };
      if (d.lastSeen) o.lastSeen = d.lastSeen;
      if (d.lastAddress) o.lastAddress = d.lastAddress;
      return o;
    });
    const o = { enabled: this.enabled, running: this.running, port: this.port, urls: this.baseURLs(), devices: list };
    if (this.lastError) o.error = this.lastError;
    if (this.notice) o.notice = this.notice;
    if (this.tailnetOn) {
      const t = this.tailnet;
      t.refresh();
      const tn = { on: true };
      const url = this.tailnetURL();
      if (url) tn.url = url;
      if (t.me && t.me.login) tn.login = t.me.login;
      if (t.problem) tn.problem = t.problem;
      else if (t.me && t.me.running && !t.me.login) {
        tn.problem = L("This PC is a tagged device on its tailnet, so it has no user whose devices could be let in",
          "这台电脑在 tailnet 里是带标签的设备，没有所属用户，所以没法判断哪些是你的设备");
      }
      o.tailnet = tn;
    } else {
      o.tailnet = { on: false };
    }
    return o;
  }

  /** This PC's address over Tailscale: its MagicDNS name, the same at home and away. */
  tailnetURL() {
    const me = this.tailnet.me;
    return me && me.running && me.login && me.name ? `http://${me.name}:${this.port}` : null;
  }

  baseURLs() { return lanAddresses().map((a) => `http://${a}:${this.port}`); }
}

/** The request's body, or null once it passes `max`. */
function readBody(req, max) {
  return new Promise((resolve) => {
    const parts = [];
    let n = 0, over = false;
    req.on("data", (c) => {
      if (over) return;
      n += c.length;
      if (n > max) { over = true; resolve(null); req.destroy(); return; }
      parts.push(c);
    });
    req.on("end", () => { if (!over) resolve(Buffer.concat(parts)); });
    req.on("error", () => { if (!over) { over = true; resolve(null); } });
  });
}

module.exports = {
  BoardServer, Tailnet, Lockout, admission,
  ipBytes, isLocal, isTailnet, inSubnet, lockKey, hostName, hostAllowed, originAllowed,
  tailnetSelf, tailnetOwnDevice, sha256, newToken, newPairingCode, normalizeCode, live, match, deviceName,
  allowed, PHONE_OPS, PC_ONLY, etag, unchanged, acceptsGzip, compressible, inject,
  DEFAULT_PORT, PAIR_WINDOW, MAX_FAILURES, LOCKOUT,
};
