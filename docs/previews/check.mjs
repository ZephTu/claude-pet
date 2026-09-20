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
                  "long-en","no-terminal","twenty","four-idle","dedupe","all-running","empty"]) {
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

// ---- our own words are never truncated -------------------------------------
//
// The status column is a closed vocabulary. "Response c…" is not a state
// anybody can recognise, and it used to come out at a different length on every
// row because the name and the status shrank in proportion to their own
// content. The project name is the thing that gives.
for (const id of ["single-busy","mixed","three-waiting","snoozed-pinned","long-cn",
                  "long-en","no-terminal","twenty","four-idle","dedupe","all-running"]) {
  const cols = await scenario(`?only=${id}`, `
    const d = document.querySelector('iframe').contentDocument;
    return [...d.querySelectorAll('.row .what.fixed')]
      .filter(e => e.scrollWidth > e.clientWidth + 0.5)
      .map(e => e.textContent);
  `);
  check(`${id}: no status word is truncated`, cols.length === 0, cols.join(" / "));
}

// ---- the list and the message window may not share a pixel ------------------
//
// THE check this file was missing. Every bubble was "inside the 480pt window"
// while sitting squarely on the list's top-right corner: being in the window
// and being clear of the list are different questions, and only the second one
// is about whether you can read either of them.
const RECTS = `
  const d = document.querySelector('iframe').contentDocument;
  const box = el => el.hidden ? null : (r => ({l:r.left, r:r.right, t:r.top, b:r.bottom, w:r.width}))
                                        (el.getBoundingClientRect());
  const P = box(d.getElementById('panel')), B = box(d.getElementById('bubble'));
  const hit = (a,c) => !!a && !!c
    && Math.min(a.r,c.r) - Math.max(a.l,c.l) > 0.5
    && Math.min(a.b,c.b) - Math.max(a.t,c.t) > 0.5;
  return { panel: P, bubble: B, cls: d.getElementById('bubble').className,
           overlap: hit(P,B), stageW: d.getElementById('stage').getBoundingClientRect().width };
`;
for (const id of ["combo-notice","combo-alert","combo-readout","combo-readout-full","combo-warn"]) {
  for (const mir of ["", "&mirror=1"]) {
    const g = await scenario(`?only=${id}${mir}`, RECTS);
    const tag = `${id}${mir ? " mirrored" : ""}`;
    check(`${tag}: list and message window do not intersect`, !g.overlap,
          g.bubble ? `bubble ${Math.round(g.bubble.l)}..${Math.round(g.bubble.r)} `
                   + `panel ${Math.round(g.panel.l)}..${Math.round(g.panel.r)}` : "bubble down");
    if (g.bubble) {
      check(`${tag}: message window still inside the window`,
            g.bubble.l >= -0.5 && g.bubble.r <= g.stageW + 0.5);
    }
  }
}

// ---- what the list takes over, and what it does not -------------------------
const yield_ = await scenario("?only=combo-notice", `
  const f = document.querySelector('iframe'), w = f.contentWindow, d = f.contentDocument;
  const b = d.getElementById('bubble'), p = d.getElementById('panel');
  const seen = () => ({ cls: b.className, up: !b.hidden, doneRows: d.querySelectorAll('.row.done').length });
  const out = {};
  // The list is open in this fixture; a completion arriving now stands aside.
  w.say("something finished", 0, "", "notice");   out.noticeWhileOpen = seen();
  w.say("stretch your legs", 0, "", "chat");      out.chatWhileOpen = seen();
  // These two are not in the list, so they still get through.
  w.say("the 5h window is 92% used", 0, "", "warn"); out.warnWhileOpen = seen();
  w.setMood("urgent", "api-server", "rm -rf build/", null); out.alertWhileOpen = seen();
  w.setMood("busy", null, "", null);
  // Shut the list: a completion is welcome again, and it is sticky.
  w.setPanelOpen(false);
  w.say("something finished", 0, "", "notice");   out.noticeWhileShut = seen();
  // Re-opening takes it down without touching the queue...
  w.setPanelOpen(true);                           out.afterReopen = seen();
  // ...and shutting again does not resurrect it; Swift's next render decides.
  w.setPanelOpen(false);                          out.afterReclose = seen();
  return out;
`);
check("an open list stands a completion down", !yield_.noticeWhileOpen.up, yield_.noticeWhileOpen.cls);
check("...and chatter too", !yield_.chatWhileOpen.up, yield_.chatWhileOpen.cls);
check("a quota warning still gets through", yield_.warnWhileOpen.up && yield_.warnWhileOpen.cls.includes("warn"));
check("so does the alarm", yield_.alertWhileOpen.cls === "alert", yield_.alertWhileOpen.cls);
check("with the list shut, a completion is sticky again",
      yield_.noticeWhileShut.up && yield_.noticeWhileShut.cls.includes("notice"));
check("opening the list takes it down", !yield_.afterReopen.up, yield_.afterReopen.cls);
check("...without clearing the unread record",
      yield_.afterReopen.doneRows === yield_.noticeWhileShut.doneRows
        && yield_.afterReopen.doneRows > 0, String(yield_.afterReopen.doneRows));
check("closing it again does not resurrect the old line", !yield_.afterReclose.up);

// ---- one turn, said once ----------------------------------------------------
const dd = await scenario("?only=dedupe", `
  const d = document.querySelector('iframe').contentDocument;
  const live = [...d.querySelectorAll('.row:not(.done)')].map(r => r.querySelector('.proj').textContent);
  const groups = [...d.querySelectorAll('.group')].map(g => g.firstChild.textContent + "|" + g.querySelector('.gcount').textContent);
  const counts = {};
  let g = null;
  for (const el of d.getElementById('panel').children) {
    if (el.classList.contains('group')) { g = el.firstChild.textContent; counts[g] = 0; }
    else if (el.classList.contains('row') && g) counts[g]++;
  }
  return { live, groups, counts };
`);
check("an idle session under its own unread finish is folded away",
      !dd.live.includes("settled-repo"), dd.live.join(", "));
check("...but one that went back to work is not", dd.live.includes("restarted-repo"));
check("...nor one that is blocked again", dd.live.includes("blocked-repo"));
check("an idle session with no unread finish stays", dd.live.includes("no-finish-repo"));
check("every heading's count matches the rows under it",
      dd.groups.every(g => { const [name, n] = g.split("|"); return dd.counts[name] === Number(n); }),
      JSON.stringify(dd.groups) + " vs " + JSON.stringify(dd.counts));

// ---- the heading may not claim work that is not happening -------------------
const naming = {};
for (const id of ["dedupe","four-idle","all-running","mixed"]) {
  naming[id] = await scenario(`?only=${id}`, `
    const d = document.querySelector('iframe').contentDocument;
    return [...d.querySelectorAll('.group')].map(g => g.firstChild.textContent);
  `);
}
check("a mixed group is not called Running",
      naming.dedupe.includes("Sessions") && !naming.dedupe.includes("Running"),
      JSON.stringify(naming.dedupe));
check("a group of answered sessions is not called Running either",
      !naming.mixed.includes("Running"), JSON.stringify(naming.mixed));
check("a group that really is all running says so",
      naming["all-running"].includes("Running"), JSON.stringify(naming["all-running"]));
check("a lone group still gets no heading at all", naming["four-idle"].length === 0,
      JSON.stringify(naming["four-idle"]));

// ---- a duration and an instant are not the same number ----------------------
const clocks = await scenario("?only=dedupe", `
  const d = document.querySelector('iframe').contentDocument;
  const read = r => ({ proj: (r.querySelector('.proj')||{}).textContent,
                       age: r.querySelector('.age').textContent,
                       ago: !!r.querySelector('.age .ago') });
  return { live: [...d.querySelectorAll('.row:not(.done)')].map(read),
           done: [...d.querySelectorAll('.row.done')].map(read) };
`);
check("a finished row counts backwards", clocks.done.every(r => r.ago && /ago$/.test(r.age)),
      JSON.stringify(clocks.done));
check("an answered row counts backwards too",
      clocks.live.filter(r => r.proj === "no-finish-repo").every(r => r.ago));
check("a running row does not — its number is a duration",
      clocks.live.filter(r => r.proj === "restarted-repo").every(r => !r.ago));
check("nor does a blocked one — that is how long it has waited",
      clocks.live.filter(r => r.proj === "blocked-repo").every(r => !r.ago));

// ---- narrowing must not cost the readout its content ------------------------
// `wantKeys` is what each fixture's DATA implies, not a fixed list: a session
// with nothing in flight and nothing quiet has one clock, and printing three
// would be the bug.
for (const [id, want, wantKeys] of [["combo-readout", false, ["turn"]],
                                    ["combo-readout-full", true, ["tool", "turn", "quiet"]]]) {
  const r = await scenario(`?only=${id}`, `
    const d = document.querySelector('iframe').contentDocument;
    const b = d.getElementById('bubble');
    return { crowded: d.getElementById('stage').classList.contains('crowded'),
             path: !!b.querySelector('.dwhere'), tree: !!b.querySelector('.dtree'),
             meter: !!b.querySelector('.qbar'),
             keys: [...b.querySelectorAll('.dkey')].map(e => e.textContent),
             last: !!b.querySelector('.dlast'),
             clipped: [...b.querySelectorAll('.dkey, .dval')]
                        .filter(e => e.scrollWidth > e.clientWidth + 0.5).length };
  `);
  const tag = want ? "crowded" : "roomy";
  check(`${tag} readout: narrows only when the list is really in the way`, r.crowded === want);
  check(`${tag} readout: keeps every kind of fact`,
        r.path && r.tree && r.meter && r.last, JSON.stringify(r));
  check(`${tag} readout: names exactly the clocks it has`,
        r.keys.length === wantKeys.length && wantKeys.every(k => r.keys.includes(k)),
        r.keys.join(",") + " want " + wantKeys.join(","));
  check(`${tag} readout: no clock is cut off`, r.clipped === 0, String(r.clipped));
}

// ---- the controls the list is the only way to reach -------------------------
//
// Folding a duplicate row away must not fold away the only way to act on it,
// and the hit test was touched to keep that true.
const hits = await scenario("?only=dedupe", `
  const f = document.querySelector('iframe'), w = f.contentWindow, d = f.contentDocument;
  const mid = el => { const r = el.getBoundingClientRect();
                      return [r.left + r.width / 2, r.top + r.height / 2]; };
  const at = el => w.hitRow.apply(null, mid(el));
  const live = [...d.querySelectorAll('.row:not(.done)')];
  const doneRows = [...d.querySelectorAll('.row.done')];
  const blocked = live.find(r => r.querySelector('.proj').textContent === "blocked-repo");
  const folded = doneRows.find(r => r.querySelector('.proj').textContent === "settled-repo");
  return {
    jump:   at(live.find(r => r.querySelector('.proj').textContent === "restarted-repo")),
    mute:   at(blocked.querySelector('.mute')),
    snooze: at(blocked.querySelector('.snooze')),
    read:   at(folded.querySelector('.read')),
    readAll: at(d.querySelector('.read-all')),
    finishedClick: at(folded.querySelector('.proj')),
    // right-click: a folded session is still addressable, a dead one is not
    menuOnFolded: w.rowSessionId.apply(null, mid(folded.querySelector('.proj'))),
    menuOnLive:   w.rowSessionId.apply(null, mid(blocked.querySelector('.proj'))),
  };
`);
check("a running row still jumps to its terminal", hits.jump && hits.jump.action === "jump", JSON.stringify(hits.jump));
check("the × still mutes rather than jumping", hits.mute && hits.mute.action === "mute", JSON.stringify(hits.mute));
check("the clock still snoozes rather than jumping", hits.snooze && hits.snooze.action === "snooze");
check("the ✓ still marks one finish read", hits.read && hits.read.action === "read");
check("`clear` still marks them all", hits.readAll && hits.readAll.action === "readAll");
check("a finished row still opens then clears", hits.finishedClick && hits.finishedClick.action === "openFinished");
check("a folded session is still reachable by right click", hits.menuOnFolded === "s-idle", hits.menuOnFolded);
check("...and so is one whose own row is showing", hits.menuOnLive === "s-wait", hits.menuOnLive);

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
