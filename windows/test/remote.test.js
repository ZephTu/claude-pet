// Phone access on Windows (remote.js, board-events.js): the Mac's RemoteAccessTests cases for the
// ported checks, and the server itself on a loopback port with a stand-in for the board.
//   cd windows; node --test test/
"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const http = require("http");
const r = require("../remote");
const { BoardEvents, PushGate, relevant } = require("../board-events");

test("addresses as bytes", () => {
  assert.deepStrictEqual(r.ipBytes("192.168.1.5"), [192, 168, 1, 5]);
  assert.deepStrictEqual(r.ipBytes("::ffff:192.168.0.9"), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 0, 9]);
  assert.deepStrictEqual(r.ipBytes("fe80::1%12"), [0xfe, 0x80].concat(Array(13).fill(0), [1]));
  assert.deepStrictEqual(r.ipBytes("::1"), Array(15).fill(0).concat([1]));
  assert.deepStrictEqual(r.ipBytes("fd7a:115c:a1e0::9").slice(0, 6), [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]);
  assert.strictEqual(r.ipBytes("node.local"), null);
});

test("who may connect: the local network, and Tailscale only when on", () => {
  for (const a of ["192.168.1.20", "10.0.0.5", "172.20.1.1", "127.0.0.1", "::ffff:192.168.0.9", "fe80::1", "fd12::", "::1"]) {
    assert.ok(r.isLocal(r.ipBytes(a)), a);
  }
  for (const a of ["8.8.8.8", "172.32.0.1", "100.100.1.1", "2001:db8::", "::ffff:1.2.3.4", "fd7a:115c:a1e0:ab12::9"]) {
    assert.ok(!r.isLocal(r.ipBytes(a)), a);
  }
  for (const a of ["100.64.0.1", "100.127.155.26", "fd7a:115c:a1e0:ab12::9", "::ffff:100.96.1.2"]) assert.ok(r.isTailnet(r.ipBytes(a)), a);
  for (const a of ["100.63.0.1", "100.128.0.1", "192.168.0.2", "fd12::"]) assert.ok(!r.isTailnet(r.ipBytes(a)), a);
  const never = () => false;
  assert.strictEqual(r.admission(r.ipBytes("192.168.0.2"), false, never), "local");
  assert.strictEqual(r.admission(r.ipBytes("100.96.1.2"), false, never), null);
  assert.strictEqual(r.admission(r.ipBytes("100.96.1.2"), true, never), "tailnet");
  assert.strictEqual(r.admission(r.ipBytes("8.8.8.8"), true, never), null);
  assert.strictEqual(r.admission(r.ipBytes("2409:8920:1100:abcd::1"), false, () => true), "local");
  // Through a Tailscale subnet router a far network's private address arrives on this PC's
  // Tailscale address: it is asked about as a Tailscale peer, not let in as local.
  const viaTailscale = r.ipBytes("100.67.91.59");
  assert.strictEqual(r.admission(r.ipBytes("192.168.5.7"), true, never, viaTailscale), "tailnet");
  assert.strictEqual(r.admission(r.ipBytes("192.168.5.7"), false, never, viaTailscale), null);
  assert.strictEqual(r.admission(r.ipBytes("192.168.5.7"), false, never, r.ipBytes("192.168.0.16")), "local");
});

test("a network this PC is on; lock keys", () => {
  const net6 = r.ipBytes("2409:8920:1100:abcd::"), mask = r.ipBytes("ffff:ffff:ffff:ffff::");
  assert.ok(r.inSubnet(r.ipBytes("2409:8920:1100:abcd:1:2:3:4"), net6, mask));
  assert.ok(!r.inSubnet(r.ipBytes("2409:8920:1100:abce:1:2:3:4"), net6, mask));
  assert.ok(!r.inSubnet(r.ipBytes("192.168.0.2"), net6, mask));
  assert.ok(!r.inSubnet(net6, net6, Array(16).fill(0)));
  assert.strictEqual(r.lockKey(r.ipBytes("192.168.0.9")), "192.168.0.9");
  assert.strictEqual(r.lockKey(r.ipBytes("::ffff:192.168.0.9")), "192.168.0.9");
  assert.strictEqual(r.lockKey(r.ipBytes("2409:8920:1100:abcd:1:2:3:4")), "240989201100abcd/64");
  assert.notStrictEqual(r.lockKey(r.ipBytes("fe80::1")), r.lockKey(r.ipBytes("fe80::2")));
});

test("lockout", () => {
  const lock = new r.Lockout();
  const t0 = 1e12;
  for (let k = 0; k < r.MAX_FAILURES - 1; k++) lock.fail("a", t0 + k * 1000);
  assert.ok(!lock.locked("a", t0 + 30000));
  const last = t0 + 500000;
  lock.fail("a", last);
  assert.ok(lock.locked("a", last + r.LOCKOUT - 1) && !lock.locked("a", last + r.LOCKOUT) && !lock.locked("b", last));
  lock.fail("a", last + r.LOCKOUT + 1);
  assert.ok(!lock.locked("a", last + r.LOCKOUT + 2), "a count older than the lockout starts again");
  lock.clear("a");
  assert.ok(!lock.locked("a", last));
});

test("Host and Origin", () => {
  assert.ok(r.hostAllowed("DESKTOP-1.local:8790", []) && r.hostAllowed("192.168.0.4:8790", []) && r.hostAllowed("[fe80::1]:8790", []));
  assert.ok(r.hostAllowed("desktop-1:8790", ["DESKTOP-1"]) && r.hostAllowed("node.tail1.ts.net:8790", ["node.tail1.ts.net"]));
  assert.ok(!r.hostAllowed("evil.example.com:8790", ["DESKTOP-1"]) && !r.hostAllowed("1.2.3.4.evil.com", []) && !r.hostAllowed(undefined, []));
  assert.ok(!r.hostAllowed("other.tail1.ts.net:8790", ["node.tail1.ts.net"]));
  assert.ok(r.originAllowed("http://pc.local:8790", "pc.local:8790") && r.originAllowed(undefined, "pc.local:8790"));
  assert.ok(!r.originAllowed("http://evil.example.com", "pc.local:8790"));
});

test("Tailscale: this PC, and whose device a peer is", () => {
  const status = JSON.stringify({ BackendState: "Running", Self: { UserID: 123, DNSName: "Node.tail1.ts.net.", TailscaleIPs: ["100.96.1.2"] },
    User: { 123: { ID: 123, LoginName: "me@example.com" } } });
  assert.deepStrictEqual(r.tailnetSelf(status), { running: true, login: "me@example.com", name: "node.tail1.ts.net", addresses: ["100.96.1.2"] });
  const tagged = r.tailnetSelf(JSON.stringify({ BackendState: "Stopped", Self: { UserID: 123, Tags: ["tag:server"] }, User: { 123: { LoginName: "x" } } }));
  assert.ok(!tagged.running && tagged.login === null);
  assert.strictEqual(r.tailnetSelf("nope"), null);
  const whois = (login, tags) => JSON.stringify({ Node: Object.assign({ Name: "phone.tail1.ts.net." }, tags ? { Tags: tags } : {}), UserProfile: { LoginName: login } });
  assert.ok(r.tailnetOwnDevice(whois("Me@Example.com"), "me@example.com"));
  assert.ok(!r.tailnetOwnDevice(whois("colleague@example.com"), "me@example.com"));
  assert.ok(!r.tailnetOwnDevice(whois("me@example.com", ["tag:connector"]), "me@example.com"));
  assert.ok(!r.tailnetOwnDevice(whois("tagged-devices"), ""));
  assert.ok(!r.tailnetOwnDevice("", "me@example.com"));
});

test("tokens, codes and paired phones", () => {
  const tok = r.newToken();
  assert.ok(/^[A-Za-z0-9_-]{43}$/.test(tok) && tok !== r.newToken());
  const codes = Array.from({ length: 50 }, r.newPairingCode);
  assert.ok(codes.every((c) => c.length === 8 && !/[ILOU]/.test(c) && r.normalizeCode(c) === c));
  assert.strictEqual(new Set(codes).size, codes.length);
  assert.strictEqual(r.normalizeCode("k7qm-3xpa"), "K7QM3XPA");
  assert.strictEqual(r.normalizeCode("O1L0 IIII"), "0110" + "1111");
  assert.strictEqual(r.normalizeCode("short"), null);
  const now = Date.parse("2027-01-15T08:00:00Z");
  const iso = (ms) => new Date(ms).toISOString();
  const all = [
    { id: "a", hash: r.sha256(tok), created: iso(now - 86400000), paired: iso(now - 86000000) },
    { id: "b", hash: r.sha256("fresh"), created: iso(now - 60000) },
    { id: "c", hash: r.sha256("old"), created: iso(now - 3600000) },
  ];
  assert.strictEqual(r.match(tok, all, now), 0);
  assert.strictEqual(r.match("fresh", all, now), 1);
  assert.strictEqual(r.match("old", all, now), null);
  assert.strictEqual(r.match("", all, now), null);
  assert.deepStrictEqual(r.live(all, now).map((d) => d.id), ["a", "b"]);
  assert.strictEqual(r.deviceName("Zeph's iPhone<script>", ""), "Zeph's iPhonescript");
  assert.strictEqual(r.deviceName("", "Mozilla/5.0 (Linux; Android 14)"), "Android");
  assert.strictEqual(r.deviceName("", ""), "Browser");
});

test("what a phone may ask for", () => {
  assert.ok(!r.allowed("remote-tailnet") && !r.allowed("some-new-op") && !r.allowed(""));
  for (const op of ["open", "openPath", "openURL", "attach", "jump", "copy", "pick-folder", "click-target"]) assert.ok(!r.allowed(op), op);
  for (const op of ["board", "peek", "resolve", "send", "decide"]) assert.ok(r.allowed(op), op);
  for (const op of r.PHONE_OPS) assert.ok(!r.PC_ONLY.has(op), op);
  // Every op board.js's perform handles is on exactly one list: a new one goes to the phone on purpose.
  const src = fs.readFileSync(path.join(__dirname, "..", "board.js"), "utf8");
  const body = src.slice(src.indexOf("async function perform("), src.indexOf("\n    default:", src.indexOf("async function perform(")));
  const ops = new Set();
  for (const line of body.split("\n")) {
    if (!/^ {4}case "/.test(line)) continue;
    for (const m of line.matchAll(/case "([^"]+)":/g)) ops.add(m[1]);
  }
  assert.ok(ops.size > 40, `found ${ops.size} ops`);
  const missing = [...ops].filter((op) => !r.PHONE_OPS.has(op) && !r.PC_ONLY.has(op));
  assert.deepStrictEqual(missing, []);
});

test("responses: tags, gzip, pages", () => {
  const tag = r.etag(Buffer.from("x".repeat(100)));
  assert.ok(r.unchanged(tag, tag) && r.unchanged("W/" + tag, tag) && r.unchanged(`"abc", ${tag}`, tag) && r.unchanged("*", tag));
  assert.ok(!r.unchanged('"abc"', tag) && !r.unchanged(undefined, tag));
  assert.ok(r.acceptsGzip("gzip, deflate, br") && r.acceptsGzip("br;q=1.0, GZIP;q=0.8"));
  assert.ok(!r.acceptsGzip("gzip;q=0") && !r.acceptsGzip("deflate") && !r.acceptsGzip(undefined));
  assert.ok(r.compressible("text/javascript; charset=utf-8") && r.compressible("application/json") && r.compressible("image/svg+xml") && !r.compressible("image/png"));
  assert.strictEqual(r.inject("<s>", "<html><HEAD><title>"), "<html><HEAD>\n<s><title>");
});

test("board events: what counts as a change, and when to push", () => {
  assert.ok(relevant("C:/Users/me/claude-hq/tasks/T-1/TASK.md"));
  assert.ok(relevant("C:/Users/me/.claude/pet/sessions/abc.json"));
  for (const p of ["C:/r/.git/index", "C:/r/tasks/.hq-tmp", "C:/r/a.lock", "C:/r/locks/x", "C:/Users/me/.claude/pet/activity/x.jsonl",
    "C:/Users/me/.claude/pet/hud-usage.json", "C:/Users/me/.claude/pet/pet-emit.exe", "C:/r/x.tmp"]) assert.ok(!relevant(p), p);
  const g = new PushGate();
  assert.strictEqual(g.note(1000), 1300);
  assert.strictEqual(g.note(1200), 1500);
  assert.strictEqual(g.note(2400), 2500, "a burst that never goes quiet is pushed maxWait after it began");
  g.fired(2500);
  assert.strictEqual(g.note(3000), 6500, "pushes no closer together than the gap");
});

test("board events: a watch that pushes, and follows a root set up in hq's config", async (t) => {
  const os = require("os");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "board-events-"));
  const hqDir = path.join(tmp, "hq"), root = path.join(tmp, "root");
  fs.mkdirSync(hqDir);
  const config = path.join(hqDir, "config.json");
  const rootOf = () => { try { return JSON.parse(fs.readFileSync(config, "utf8")).root; } catch (_) { return ""; } };
  const roots = () => (rootOf() ? [rootOf(), hqDir] : [hqDir]);
  let dropped = 0;
  const ev = new BoardEvents({ roots, root: rootOf, config, dropReads: () => { dropped += 1; } });
  ev.gate = new PushGate(30, 100, 0);
  const pushes = [];
  ev.on((n) => pushes.push(n));
  t.after(() => { ev.stop(); fs.rmSync(tmp, { recursive: true, force: true }); });
  const until = async (ok, what) => {
    for (let i = 0; i < 100 && !ok(); i++) await new Promise((res) => setTimeout(res, 30));
    assert.ok(ok(), what);
  };
  ev.start();
  assert.strictEqual(ev.watchers.size, 1);
  assert.ok(!ev.running, "no HQ root watched: the pages keep polling");
  // Set up a root as install.sh does, the config before the folder: watched within moments (not
  // at the next minute), and the boards told.
  fs.writeFileSync(config, JSON.stringify({ root }));
  await new Promise((res) => setTimeout(res, 150));
  fs.mkdirSync(root);
  await until(() => ev.watchers.size === 2, "the new root is watched");
  assert.ok(ev.running);
  await until(() => pushes.length >= 1, "a push");
  const n = pushes.length;
  // A card written there: one push for the burst, the kept reads dropped first.
  fs.mkdirSync(path.join(root, "tasks"));
  fs.writeFileSync(path.join(root, "tasks", "TASK.md"), "a");
  fs.writeFileSync(path.join(root, "tasks", "TASK.md"), "b");
  await until(() => pushes.length > n, "a card's change is pushed");
  assert.strictEqual(dropped, pushes.length);
  // Git's own files are not a change.
  await new Promise((res) => setTimeout(res, 200));
  const m = pushes.length;
  fs.mkdirSync(path.join(root, ".git"));
  fs.writeFileSync(path.join(root, ".git", "index"), "x");
  await new Promise((res) => setTimeout(res, 300));
  assert.strictEqual(pushes.length, m, "no push for .git");
  ev.nudge();
  await until(() => pushes.length === m + 1, "a nudge pushes");
});

// ---- the server on a loopback port, with a stand-in for board.js

function harness(t) {
  let prefs = {};
  const calls = [];
  const s = new r.BoardServer({
    handle: async (body) => { calls.push(body); return body.op === "status" ? { result: { ok: true, n: 1 } } : { error: "nope" }; },
    readPrefs: () => JSON.parse(JSON.stringify(prefs)), writePrefs: (p) => { prefs = p; },
    root: path.join(__dirname, "..", "..", "Resources", "pet"), petHome: path.join(__dirname, "no-pet-home"),
    L: () => (en) => en, lang: () => "en",
  });
  s.portOverride = 0;
  Object.defineProperty(s, "port", { configurable: true, get: () => (s.server && s.server.address() ? s.server.address().port : 0) });
  t.after(() => s.stop());
  return { s, calls, prefs: () => prefs };
}

// As a browser's fetch() sends it: a body with its length (a chunked one is refused).
function req(port, method, p, headers = {}, body) {
  const data = body === undefined ? null : Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
  if (data) headers = Object.assign({ "Content-Length": data.length }, headers);
  return new Promise((resolve, reject) => {
    const q = http.request({ host: "127.0.0.1", port, method, path: p, headers: Object.assign({ Host: `localhost:${port}` }, headers) }, (res) => {
      const parts = [];
      res.on("data", (c) => parts.push(c));
      res.on("end", () => {
        const text = Buffer.concat(parts).toString("utf8");
        let json = null;
        try { json = JSON.parse(text); } catch (_) { /* not JSON */ }
        resolve({ status: res.statusCode, headers: res.headers, text, json });
      });
    });
    q.on("error", reject);
    q.end(data || undefined);
  });
}

test("pairing, the API, revoking", async (t) => {
  const { s, calls } = harness(t);
  await s.setEnabled(true);
  const port = s.server.address().port;
  const pair = (await s.op("remote-pair", {})).result;
  assert.match(pair.code, /^[0-9A-Z]{4}-[0-9A-Z]{4}$/);
  assert.match(pair.qr, /^data:image\/png;base64,/);
  const code = pair.url.split("#pair=")[1];

  // A pairing code buys a token, once, and nothing else.
  assert.strictEqual((await req(port, "POST", "/api", { "X-HQ-Token": code }, { op: "status" })).status, 401);
  const claimed = await req(port, "POST", "/api", { "X-HQ-Token": pair.code.toLowerCase(), "X-HQ-Device": "My%20Phone" }, { op: "pair" });
  const token = claimed.json.result.token;
  assert.ok(token);
  assert.strictEqual((await req(port, "POST", "/api", { "X-HQ-Token": code }, { op: "pair" })).status, 401, "the code is spent");

  const a = await req(port, "POST", "/api", { "X-HQ-Token": token }, { op: "status" });
  assert.deepStrictEqual(a.json.result, { ok: true, n: 1 });
  const same = await req(port, "POST", "/api", { "X-HQ-Token": token, "X-HQ-Have": a.json.tag }, { op: "status" });
  assert.deepStrictEqual(same.json, { same: true });
  assert.strictEqual((await req(port, "POST", "/api", { "X-HQ-Token": token }, { op: "remote-pair" })).json.error, "Only on the PC");
  assert.strictEqual((await req(port, "POST", "/api", { "X-HQ-Token": token }, { op: "jump" })).json.error, "Only on the PC");
  assert.deepStrictEqual(calls.map((c) => c.op), ["status", "status"]);

  const st = s.status();
  assert.strictEqual(st.devices.length, 1);
  assert.ok(st.devices[0].paired && st.devices[0].name === "My Phone" && st.devices[0].lastAddress === "127.0.0.1");

  // A stream, told of changes; closed when its phone is removed.
  const stream = await new Promise((resolve) => {
    const q = http.request({ host: "127.0.0.1", port, method: "POST", path: "/events", headers: { Host: `localhost:${port}`, "X-HQ-Token": token } }, resolve);
    q.setHeader("Content-Length", 2);
    q.end("{}");
  });
  assert.strictEqual(stream.statusCode, 200);
  assert.match(stream.headers["content-type"], /text\/event-stream/);
  let got = "";
  stream.on("data", (c) => { got += c; });
  const ended = new Promise((resolve) => stream.on("close", resolve));
  await new Promise((resolve) => setTimeout(resolve, 100));
  s.pushAll("event: changed\ndata: 1\n\n");
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.match(got, /event: changed\ndata: 1/);
  s.op("remote-revoke", { id: st.devices[0].id });
  await ended;
  assert.strictEqual((await req(port, "POST", "/api", { "X-HQ-Token": token }, { op: "status" })).status, 401, "a removed phone is out");
});

test("refusals: a foreign Host, other origins, methods, files outside the pages, wrong tokens", async (t) => {
  const { s } = harness(t);
  await s.setEnabled(true);
  const port = s.server.address().port;
  assert.strictEqual((await req(port, "GET", "/board/board.html", { Host: "evil.example.com" })).status, 403);
  assert.strictEqual((await req(port, "POST", "/api", { Origin: "http://evil.example.com" }, {})).status, 403);
  assert.strictEqual((await req(port, "GET", "/api")).status, 405);
  assert.strictEqual((await req(port, "POST", "/board/board.html", {}, "x")).status, 405);
  assert.strictEqual((await req(port, "GET", "/%2e%2e/%2e%2e/windows/main.js")).status, 404);
  assert.strictEqual((await req(port, "GET", "/")).headers.location, "/board/board.html");
  const page = await req(port, "GET", "/board/board.html", { "Accept-Encoding": "identity" });
  assert.ok(page.text.includes('window.HQ_REMOTE = true; window.PET_OS = "windows";'));
  assert.strictEqual((await req(port, "GET", "/board/board.html", { "If-None-Match": page.headers.etag })).status, 304);
  const big = await req(port, "GET", "/board/board.js", { "Accept-Encoding": "gzip" });
  assert.strictEqual(big.headers["content-encoding"], "gzip");

  // Wrong tokens: locked out after MAX_FAILURES; a waiting code is cancelled after 100 from anywhere.
  await s.op("remote-pair", {});
  for (let i = 0; i < r.MAX_FAILURES; i++) await req(port, "POST", "/api", { "X-HQ-Token": "wrong" + i }, { op: "status" });
  assert.strictEqual((await req(port, "POST", "/api", { "X-HQ-Token": "wrong" }, { op: "status" })).status, 429);
  s.lockout = new r.Lockout();
  for (let i = 0; i < 100; i++) { s.lockout = new r.Lockout(); await req(port, "POST", "/api", { "X-HQ-Token": "x" + i }, { op: "status" }); }
  assert.ok(s.status().notice && s.status().devices.length === 0, "the code was cancelled");
});

// A raw connection: what a stranger's script can do that a browser won't.
function raw(port, text) {
  const net = require("net");
  return new Promise((resolve) => {
    const c = net.connect(port, "127.0.0.1");
    let got = "", closed = false;
    c.on("data", (d) => { got += d; });
    c.on("error", () => {});
    c.on("close", () => { closed = true; });
    c.write(text);
    resolve({ c, got: () => got, closed: () => closed });
  });
}
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("connections: one request each, refused bodies cut off, all ended when turned off", async (t) => {
  const { s } = harness(t);
  await s.setEnabled(true);
  const port = s.server.address().port;
  // Answered with Connection: close, and closed.
  const a = await raw(port, `GET /board/board.html HTTP/1.1\r\nHost: localhost:${port}\r\n\r\n`);
  await wait(300);
  assert.match(a.got(), /^HTTP\/1.1 200/);
  assert.match(a.got(), /connection: close/i);
  assert.ok(a.closed(), "closed after one answer");
  // A stranger announcing a huge body gets its 401 and is cut off, its body never taken.
  const b = await raw(port, `POST /api HTTP/1.1\r\nHost: localhost:${port}\r\nContent-Length: 1000000000\r\n\r\n` + "x".repeat(1000));
  await wait(300);
  assert.match(b.got(), /^HTTP\/1.1 401/);
  assert.ok(b.closed(), "cut off");
  // Expect: 100-continue is not answered for a stranger.
  const e = await raw(port, `POST /api HTTP/1.1\r\nHost: localhost:${port}\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n`);
  await wait(300);
  assert.ok(!/100 Continue/.test(e.got()) && /^HTTP\/1.1 401/.test(e.got()));
  // A request still arriving when phone access is turned off is ended.
  const c = await raw(port, `GET /board/board.html HTTP/1.1\r\nHost: localhost:${port}\r\n`);
  await wait(100);
  await s.setEnabled(false);
  await wait(100);
  assert.ok(c.closed(), "ended when turned off");
});

test("a request that never finishes arriving is cut off", async (t) => {
  const { s } = harness(t);
  s.connectionMs = 300;   // 60 s in the pet
  await s.setEnabled(true);
  const port = s.server.address().port;
  const slow = await raw(port, `GET / HTTP/1.1\r\nHost: localhost:${port}\r\n`);
  await wait(100);
  assert.ok(!slow.closed() && s.open === 1);
  await wait(400);
  assert.ok(slow.closed(), "cut off after the hold");
  assert.strictEqual(s.open, 0);
});

test("settings: off, on, a port taken", async (t) => {
  const { s, prefs } = harness(t);
  assert.strictEqual(s.status().enabled, false);
  assert.strictEqual((await s.op("remote-pair", {})).error, "turn phone access on first");
  await s.op("remote-enable", { on: true });
  assert.ok(prefs().boardServerEnabled && s.running);
  await s.op("remote-enable", { on: false });
  assert.ok(!s.running && prefs().boardServerEnabled === false);
  // Another program on the port: said in Settings, not thrown.
  const blocker = http.createServer().listen(0);
  await new Promise((resolve) => blocker.once("listening", resolve));
  t.after(() => blocker.close());
  const other = harness(t).s;
  Object.defineProperty(other, "port", { get: () => blocker.address().port });
  const st = (await other.op("remote-enable", { on: true })).result;
  assert.ok(!st.running && st.error === "the port is taken by another program");
});
