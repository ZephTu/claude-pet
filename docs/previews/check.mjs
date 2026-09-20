/**
 * Geometry and arbitration checks for docs/previews/panel.html.
 *
 * The Swift harness cannot see a stylesheet, so the things that actually broke
 * this panel before — a row widening past the window and raising a horizontal
 * scrollbar, a bubble drawn half outside a 480pt window, a variant class
 * surviving into the next message — were only ever caught by looking. This
 * checks them instead, against the same fixtures the preview page draws.
 *
 * It drives a headless Chromium over CDP rather than adding a browser test
 * framework to a repository that has no JS build at all.
 *
 *     python3 -m http.server 8777        # from the repo root
 *     "$CHROMIUM" --headless=new --disable-gpu --remote-debugging-port=9333 \
 *                 --user-data-dir=/tmp/pet-cdp about:blank &
 *     node docs/previews/check.mjs
 *
 * Any Chromium will do; the one Playwright installs is at
 * ~/Library/Caches/ms-playwright/chromium-*\/chrome-mac/Chromium.app/Contents/MacOS/Chromium
 */
const port = 9333, BASE = "http://127.0.0.1:8777/docs/previews/panel.html";
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === "page").webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { pending.set(++id, r); ws.send(JSON.stringify({ id, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
await new Promise(r => ws.onopen = r);
await send("Page.enable"); await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 530, height: 400, deviceScaleFactor: 1, mobile: false });

let pass = 0, fail = 0;
const check = (name, ok, extra = "") => { (ok ? pass++ : fail++); console.log(`${ok ? "  ok  " : "FAIL  "} ${name}${extra ? "  " + extra : ""}`); };

async function scenario(q, expr) {
  await send("Page.navigate", { url: BASE + q });
  await new Promise(r => setTimeout(r, 2200));
  const res = await send("Runtime.evaluate", { expression: `(() => { ${expr} })()`, returnByValue: true, awaitPromise: true });
  if (res.exceptionDetails) throw new Error(q + ": " + JSON.stringify(res.exceptionDetails));
  return res.result.value;
}

const GEOM = `
  const f = document.querySelector('iframe'), d = f.contentDocument, w = f.contentWindow;
  const p = d.getElementById('panel'), b = d.getElementById('bubble');
  const r = el => { const x = el.getBoundingClientRect(); return {l:x.left, r:x.right, t:x.top, b:x.bottom, w:x.width, h:x.height}; };
  return { overflowX: p.scrollWidth - p.clientWidth, panel: r(p),
           bubble: b.hidden ? null : r(b), bubbleCls: b.className,
           stageW: d.getElementById('stage').getBoundingClientRect().width };
`;

// ---- every panel scenario: no horizontal overflow, panel inside the stage ----
for (const id of ["single-busy","mixed","three-waiting","snoozed-pinned","long-cn",
                  "long-en","no-terminal","twenty","empty"]) {
  for (const mir of ["", "&mirror=1"]) {
    const g = await scenario(`?only=${id}${mir}`, GEOM);
    check(`${id}${mir ? " mirrored" : ""}: no horizontal scroll`, g.overflowX === 0, `overflow=${g.overflowX}`);
    check(`${id}${mir ? " mirrored" : ""}: panel inside the window`,
          g.panel.l >= 0 && g.panel.r <= g.stageW + 0.5, `${g.panel.l}..${g.panel.r} of ${g.stageW}`);
  }
}

// ---- every bubble variant stays inside the 480pt stage, both ways round -----
for (const id of ["quota-50","quota-92","quota-empty","readout","readout-bad",
                  "chatter","notice","warn","intervention-permission","intervention-question"]) {
  for (const mir of ["", "&mirror=1"]) {
    const g = await scenario(`?only=${id}${mir}`, GEOM);
    check(`${id}${mir ? " mirrored" : ""}: bubble inside the window`,
          g.bubble && g.bubble.l >= 0 && g.bubble.r <= g.stageW + 0.5,
          g.bubble ? `${Math.round(g.bubble.l)}..${Math.round(g.bubble.r)} of ${g.stageW}` : "hidden");
  }
}

// ---- hovering a row must not resize anything -------------------------------
const hover = await scenario("?only=twenty", `
  const f = document.querySelector('iframe'), d = f.contentDocument, w = f.contentWindow;
  const p = d.getElementById('panel');
  const before = { ox: p.scrollWidth - p.clientWidth, h: p.getBoundingClientRect().height, top: p.scrollTop };
  const row = d.querySelectorAll('.row')[1].getBoundingClientRect();
  w.setHoverAt(row.left + 40, row.top + 6);
  const after = { ox: p.scrollWidth - p.clientWidth, h: p.getBoundingClientRect().height, top: p.scrollTop,
                  hot: d.querySelectorAll('.row.hot').length };
  return { before, after };
`);
check("hover adds no horizontal scroll", hover.after.ox === 0, JSON.stringify(hover.after));
check("hover does not change the panel's height", hover.before.h === hover.after.h);
check("hover does not move the scroll position", hover.before.top === hover.after.top);
check("exactly one row is hot", hover.after.hot === 1);

// ---- bubble priority: the variant machinery actually arbitrates -------------
const prio = await scenario("?only=chatter", `
  const w = document.querySelector('iframe').contentWindow;
  const d = document.querySelector('iframe').contentDocument;
  const cls = () => d.getElementById('bubble').className;
  const out = {};
  w.say("quota is 92% used", 0, "", "warn");        out.warn = cls();
  w.say("stretch your legs", 0, "", "chat");        out.chatBlocked = cls();
  w.say("merge audit done", 0, "", "notice");       out.notice = cls();
  w.say("quota is 92% used", 0, "", "warn");        out.warnBlocked = cls();
  w.setMood("urgent", "api-server", "rm -rf build/", null); out.alert = cls();
  w.say("stretch your legs", 0, "", "chat");        out.alertHolds = cls();
  w.showQuota([{label:"5h",percent:50,resetsIn:"x"}], "none"); out.quotaRefused = cls();
  w.setMood("busy", null, "", null);                out.cleared = cls() + "|" + d.getElementById('bubble').hidden;
  w.showQuota([{label:"5h",percent:50,resetsIn:"x"}], "none"); out.quotaNow = cls();
  w.say("stretch your legs", 0, "", "chat");        out.chatDuringReadout = cls();
  w.hush();                                         out.hushed = cls() + "|" + d.getElementById('bubble').hidden;
  w.say("stretch your legs", 0, "", "chat");        out.chatAfterHush = cls();
  return out;
`);
check("a warning takes the bubble", prio.warn.includes("warn"), prio.warn);
check("chatter cannot push a warning out", prio.chatBlocked.includes("warn"), prio.chatBlocked);
check("a completion outranks a warning", prio.notice.includes("notice"), prio.notice);
check("...and a warning cannot take it back", prio.warnBlocked.includes("notice"), prio.warnBlocked);
check("the alarm takes it from anything", prio.alert === "alert", prio.alert);
check("nothing spoken displaces the alarm", prio.alertHolds === "alert", prio.alertHolds);
check("not even a quota readout", prio.quotaRefused === "alert", prio.quotaRefused);
check("leaving urgent clears the alarm class", prio.cleared === "|true", prio.cleared);
check("a quota readout wears exactly chat+quota", prio.quotaNow === "chat quota", prio.quotaNow);
check("chatter cannot talk over a readout the pointer asked for",
      prio.chatDuringReadout === "chat quota", prio.chatDuringReadout);
check("taking the pointer away puts the bubble down", prio.hushed === "|true", prio.hushed);
check("...and the next chatter line does not inherit the meters' layout",
      prio.chatAfterHush === "chat", prio.chatAfterHush);

// ---- the hook boilerplate never reaches a row ------------------------------
const words = await scenario("?only=three-waiting", `
  const d = document.querySelector('iframe').contentDocument;
  return { text: d.getElementById('panel').textContent,
           whats: [...d.querySelectorAll('.row .what')].map(e => e.textContent),
           groups: [...d.querySelectorAll('.group')].map(e => e.firstChild.textContent + "|" + e.querySelector('.gcount').textContent),
           needs: d.querySelectorAll('.row.needs').length,
           urgent: d.querySelectorAll('.row.needs.urgent').length };
`);
check("no row repeats the hook's own sentence", !words.text.includes("Claude is waiting"), words.text.slice(0, 60));
check("no row says 'needs you' under a heading that already does",
      !words.whats.some(w => w.toLowerCase() === "needs you"), JSON.stringify(words.whats));
check("the heading carries its count", words.groups[0] === "Needs you|3", JSON.stringify(words.groups));
check("every blocked row is marked", words.needs === 3);
check("only the ones past the threshold are urgent", words.urgent === 2, String(words.urgent));

// ---- a lone Running group has no heading -----------------------------------
const lone = await scenario("?only=single-busy", `
  const d = document.querySelector('iframe').contentDocument;
  return { groups: d.querySelectorAll('.group').length, rows: d.querySelectorAll('.row').length };
`);
check("one group and nothing to contrast it with gets no heading",
      lone.groups === 0 && lone.rows === 1, JSON.stringify(lone));

// ---- a long name truncates instead of widening the card --------------------
const trunc = await scenario("?only=intervention-question", `
  const f = document.querySelector('iframe'), w = f.contentWindow, d = f.contentDocument;
  w.setMood("urgent", "x".repeat(300), "", null);
  const b = d.getElementById('bubble').getBoundingClientRect();
  const n = d.querySelector('.aname');
  return { w: b.width, right: b.right, clipped: n.scrollWidth > n.clientWidth };
`);
check("a 300-character name cannot widen the card past its cap", trunc.w <= 250, String(trunc.w));
check("...it is truncated instead", trunc.clipped);
check("...and the card stays in the window", trunc.right <= 480.5, String(trunc.right));

console.log(`\n${fail ? "FAILED" : "ALL PASS"} (${pass} passed, ${fail} failed)`);
ws.close(); process.exit(fail ? 1 : 0);
