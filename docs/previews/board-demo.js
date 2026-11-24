// Demo data for the Task Board screenshots in the README — a made-up shop, nothing real.
// Run by scripts/board-shots.sh through `ClaudePet --render-board` (with a stub hq and
// CLAUDE_PET_LANG=en): it replaces what the board loaded with this data and cuts the board off
// from hq, so a screenshot never shows anyone's actual tasks or sessions.
// promo/demo/board-demo-zh.js is the Chinese twin the promo film uses; keep the two in step.
(() => {
  // A fixed clock: set window.DEMO_NOW (ms) before this script so the times on screen are stable.
  if (window.DEMO_NOW) {
    const Real = Date, now = window.DEMO_NOW;
    class D extends Real { constructor(...a) { if (a.length) super(...a); else super(now); } static now() { return now; } }
    window.Date = D;
  }
  const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
  const later = (min) => new Date(Date.now() + min * 60000).toISOString();
  const at = (h, m, dayOffset = 0) => { const d = new Date(); d.setDate(d.getDate() + dayOffset); d.setHours(h, m, 0, 0); return d.toISOString(); };
  const S = {
    checkout: "1f0c2a51-7a1e-4c3b-9d0e-0a1b2c3d4e51",
    dark: "2a7d9e10-4b2c-4f6e-8a1d-1b2c3d4e5f62",
    ci: "3b8e0f21-5c3d-4a7f-9b2e-2c3d4e5f6a73",
    notes: "4c9f1a32-6d4e-4b8a-8c3f-3d4e5f6a7b84",
    sec: "7f2c4d65-3e4f-4a6b-8c7d-2e3f4a5b6c7d",
  };
  const todo = (i, state, owner, text, min) => ({ i, state, owner, text, created: ago(min) });
  const ask = (id, text, session, min) => ({ type: "open", id, task: id.replace(/\.\d+$/, ""), text, session, ts: ago(min), state: "open" });
  const tasks = [
    {
      id: "T-014", title: "Checkout: retry when the payment gateway times out", status: "active",
      project: "shop-api", workdirs: ["/Users/demo/code/shop-api"], refs: ["shop-api#212"], sessions: ["1f0c2a51", "5d0a2b43"],
      next: "Add the retry with backoff behind a flag, then load-test it on staging",
      todos: [todo(1, "done", "claude", "Reproduce the 504 from the gateway sandbox", 300), todo(2, "done", "claude", "Write a failing test for the timeout", 240),
        todo(3, "open", "claude", "Retry with exponential backoff (max 3) behind CHECKOUT_RETRY", 60), todo(4, "open", "me", "Review PR shop-api#212", 30)],
      asks: [
        ask("T-014.4", "Retry 3 times with backoff (0.5s, 1s, 2s) — or 2 times to stay under the 5s checkout budget?", S.checkout, 3),
        ask("T-014.5", "Ship it behind the CHECKOUT_RETRY flag, off by default?", S.checkout, 3),
        ask("T-014.6", "Once it's merged, post the load-test numbers in #payments?", S.checkout, 3),
      ],
      body: "## Log\n- 2026-11-22 16:02:11: Reproduced: the sandbox gateway answers 504 after 4.8s under load\n- 2026-11-23 10:14:37: Failing test in place (test_checkout_timeout)\n- 2026-11-23 11:40:05: Draft PR shop-api#212 open; waiting on the retry policy\n",
      age_days: 2,
    },
    {
      id: "T-016", title: "Dashboard: dark mode polish", status: "active", project: "web-app",
      workdirs: ["/Users/demo/code/web-app"], refs: [], sessions: ["2a7d9e10"],
      next: "Fix the chart palette in dark mode, then send screenshots to design review",
      todos: [todo(1, "done", "claude", "Swap hard-coded greys for theme tokens", 200), todo(2, "open", "claude", "Chart palette: pass the contrast check in dark mode", 90),
        todo(3, "open", "me", "Book the design review with Ana", 50)],
      asks: [], body: "## Log\n- 2026-11-20 09:12:44: 31 hard-coded colours replaced with tokens\n", age_days: 4,
    },
    {
      id: "T-015", title: "Move CI to the new runners", status: "blocked", project: "infra",
      workdirs: ["/Users/demo/code/infra"], refs: [], sessions: ["3b8e0f21"],
      next: "Waiting for the runner image with Node 22 — then switch the main pipeline",
      todos: [todo(1, "open", "me", "Ask the platform team for the Node 22 runner image", 1500), todo(2, "open", "claude", "Switch the lint + unit jobs first", 400)],
      asks: [], body: "## Log\n- 2026-11-18 14:20:09: Lint job green on the new runner\n", age_days: 6,
    },
    {
      id: "T-012", title: "Search: index product specs", status: "active", project: "shop-api",
      workdirs: ["/Users/demo/code/shop-api"], refs: [], sessions: [], next: "Backfill the index for the 40k existing specs",
      todos: [todo(1, "open", "claude", "Backfill job, 500 per batch", 2000)], asks: [ask("T-012.1", "Run the backfill at night, away from the daytime traffic peak?", "9c1e7d20", 20)], body: "", age_days: 9,
    },
    {
      id: "T-011", title: "Fix the flaky login test", status: "waiting-on-me", project: "web-app",
      workdirs: ["/Users/demo/code/web-app"], refs: [], sessions: [], next: "", waiting_on_me: "Decide: quarantine the test this week, or fix the race now?",
      todos: [], asks: [ask("T-011.2", "Quarantine the login test for a week while I fix the race?", "7a2b9e11", 45)], body: "", age_days: 3,
    },
  ];
  // What `hq board --json` says about a listed project with a PROJECT.md.
  const demoProject = (name, kind, o) => ({
    name, paths: ["/Users/demo/code/" + name], defined: true, file: "/Users/demo/hq/projects/" + name + "/PROJECT.md",
    title: o.title || "", kind, status: "active", due: o.due || "", jira: [], fixVersions: [], updated: "2026-11-20",
    parent: "", phases: o.phases || [], auto: [], goal: o.goal || "", out: o.out || "",
    done_when: (o.crit || []).map(([t, d]) => (d ? "- [x] " : "- ") + t).join("\n"),
    criteria: (o.crit || []).map(([t, d], i) => ({ i: i + 1, text: t, done: d })),
    templates: [], raw: {}, brief: o.brief || "", grants: [], stats: o.stats,
  });
  const board = {
    root: "/Users/demo/hq",
    projects: [
      demoProject("shop-api", "goal", {
        title: "Checkout 2.0", due: "2026-12-15",
        goal: "Checkout finishes within 5s even when the payment gateway is flaky; ships with 2.14.",
        out: "The payment gateway's own reliability (infra owns it).",
        crit: [["Payment failure rate under 0.5%", true], ["Gateway timeouts retried automatically", false], ["Load test at 200 concurrent passes", false]],
        brief: "- Repo shop-api: branch from main, one PR per task\n- Run `make test` before committing\n- Never touch production config without asking",
        stats: { open: 2, done: 3, abandoned: 0, done_7d: 1, on_me: 3 } }),
      demoProject("web-app", "goal", {
        title: "Web 2.14", due: "2026-12-05",
        goal: "Release 2.14: dark mode, release notes, no flaky tests.",
        crit: [["Dark mode passes WCAG AA", false], ["CI green 7 days in a row", false]],
        brief: "- Repo web-app: PRs come with screenshots\n- Colours change only through design tokens",
        stats: { open: 2, done: 4, abandoned: 0, done_7d: 2, on_me: 1 } }),
      demoProject("infra", "duty", {
        title: "CI and infrastructure",
        goal: "CI runners, database backups, monitoring and alerts.",
        crit: [["CI on main finishes within 30 minutes", false], ["Every nightly backup succeeds", false]],
        brief: "- Try runner image changes on staging first\n- The backup scripts live in infra/backup",
        stats: { open: 1, done: 6, abandoned: 0, done_7d: 1, on_me: 0 } }),
    ],
    links: [], focus: { today: new Date().toISOString().slice(0, 10), ids: ["T-014", "T-016", "T-015"], last_day: null, carry: [] }, tasks,
  };
  const orca = (h) => ({ kind: "orca", handle: h });
  const sessions = [
    { sessionId: S.checkout, title: "checkout retries", project: "shop-api", cwd: "/Users/demo/code/shop-api", state: "idle", updatedAt: ago(3), terminal: orca("t1"), task: "T-014",
      lastText: "The timeout reproduces every time at 4.8s. Three things to settle before I write the retry — they're on the board." },
    { sessionId: S.dark, title: "dark mode", project: "web-app", cwd: "/Users/demo/code/web-app", state: "busy", updatedAt: ago(0), terminal: orca("t2"), task: "T-016",
      lastText: "Tokens are in. Now checking WCAG contrast for the charts in dark mode." },
    { sessionId: S.ci, title: "CI runner", project: "infra", cwd: "/Users/demo/code/infra", state: "idle", updatedAt: ago(14), terminal: orca("t3"), task: "T-015",
      lastText: "Lint passes on the new runner. Unit tests need Node 22, which the runner image doesn't have yet." },
    { sessionId: S.notes, title: "release notes", project: "web-app", cwd: "/Users/demo/code/web-app", state: "waiting", waitingOn: "git push origin release-notes", updatedAt: ago(1), terminal: orca("t4"), task: null,
      lastText: "Release notes for 2.14 are drafted. Pushing the branch for you to review." },
  ];
  const dots = {
    [S.checkout]: { state: "idle", replied: true, context: 38 },
    [S.dark]: { state: "busy", activity: "Bash npm run test:contrast", context: 61 },
    [S.ci]: { state: "idle", background: 1, context: 22 },
    [S.notes]: { state: "waiting", asks: "permission", context: 84 },
  };
  const history = { "T-014": [
    { sessionId: "5d0a2b43-1c2d-4e3f-8a9b-0c1d2e3f4a5b", cwd: "/Users/demo/code/shop-api", title: "gateway repro", lastAt: ago(60 * 26), live: false,
      lastText: "Reproduced: the sandbox gateway answers 504 after 4.8s under load. Notes are in the task log." },
  ] };
  const peek = [
    { role: "user", text: "Checkout times out when the payment gateway is slow. Find out why and propose a fix.", ts: ago(40) },
    { role: "assistant", text: "Found it. Under load the sandbox gateway answers **504 after 4.8s**, and `chargeCard()` never retries:\n\n```ts\nconst res = await gateway.charge(order); // one attempt, 5s budget\n```\n\nPlan:\n1. Retry with exponential backoff (0.5s, 1s, 2s)\n2. An idempotency key from the order id, so a retry can't charge twice\n3. Ship behind the `CHECKOUT_RETRY` flag\n\nThree things to settle before I write it — they're on the board.", ts: ago(3) },
  ];

  // Scheduled jobs
  const run = (startMin, secs, status, summary, extra = {}) => ({ started: ago(startMin), ended: new Date(Date.now() - startMin * 60000 + secs * 1000).toISOString(), status, summary, ...extra });
  const jobs = {
    runner: true, seenAt: new Date().toISOString(),
    jobs: [
      { id: "ci-morning", name: "Morning CI summary", kind: "claude", enabled: true, cwd: "~/code/shop-api",
        prompt: "Summarize last night's failed CI runs and list the three things I should look at first today",
        schedule: { kind: "weekdays", hour: 9, minute: 0 }, next: [at(9, 0, 1)],
        runs: [run(60 * 2, 94, "ok", "3 failures: 2 are the flaky login test, 1 is real (search index timeout)", { quotaBefore: { week: 57, weekResetAt: "w" }, quotaAfter: { week: 58, weekResetAt: "w" } }),
          run(60 * 26, 81, "ok", "All green"), run(60 * 50, 102, "ok", "1 failure: lint"), run(60 * 74, 77, "ok", "All green"), run(60 * 98, 120, "ok", "2 failures")] },
      { id: "pr-hourly", name: "Hourly check on my PR reviews", kind: "claude", enabled: true, cwd: "~/code",
        prompt: "Check my open PRs for new review comments and list any",
        schedule: { kind: "every", everyMinutes: 60 }, next: [later(23)],
        runs: [run(37, 41, "ok", "1 new comment on shop-api#212"), run(97, 38, "ok", "No new comments"), run(157, 44, "ok", "No new comments"), run(217, 40, "ok", "2 new comments on web-app#88")] },
      { id: "backup", name: "Nightly database snapshot", kind: "shell", enabled: true, cwd: "~/code/infra",
        command: "./scripts/nightly-backup.sh",
        schedule: { kind: "daily", hour: 2, minute: 30 }, next: [at(2, 30, 1)],
        runs: [run(60 * 13, 312, "ok", "exit 0"), run(60 * 37, 298, "ok", "exit 0"), run(60 * 61, 305, "ok", "exit 0")] },
    ],
  };
  const jobDetail = {
    job: jobs.jobs[0], run: jobs.jobs[0].runs[0],
    reply: "**Last night's CI: 3 failures**\n\n1. `search-index` timed out — **a real one**: T-012's backfill slows the database; run it at night\n2. `login.spec` ×2 — the usual suspect, T-011's flaky test\n\nLook at #1 first.",
    steps: [], log: "",
  };

  // The secretary
  const sec = { ready: true, job: "secretary", sessionId: S.sec, task: "T-001", lastAt: ago(2), memory: "secretary",
    schedule: { kind: "weekdays", hour: 18, minute: 30, enabled: true, next: "tomorrow 18:30" },
    reports: [{ date: new Date().toISOString().slice(0, 10), kind: "daily", path: "/Users/demo/hq/secretary/reports/today.md" }],
    state: ["T-015: waiting on the platform team's Node 22 image for 2 days", "T-014: PR shop-api#212 waits for your review"],
    feed: { enabled: true, kind: "cron", cron: "0 9-19 * * 1-5" }, autoclose: { enabled: true, job: "secretary-autoclose", kind: "every", everyMinutes: 5 } };
  const secPeek = [
    { role: "user", text: "Scheduled run: write today's report", ts: ago(4) },
    { role: "assistant", text: "## Evening report · Nov 24\n\n**Moved**\n- **T-014 checkout retries**: reproduced the 504, failing test in place; three questions for you on the board\n- **T-016 dark mode**: chart palette passes the contrast check; waiting for you to book the design review\n\n**Stuck**\n- **T-015 CI migration**: still waiting on the platform team's Node 22 image, 2 days now\n\n**Waiting on you**\n- Review PR shop-api#212\n- Book the design review with Ana", ts: ago(2) },
  ];

  // Cut the board off from hq and the pet: every call is answered from the demo data, nothing is written.
  window.api = async (op, a) => {
    if (op === "jobs") return JSON.stringify(jobs);
    if (op === "job-detail") return JSON.stringify(jobDetail);
    if (op === "secretary") return JSON.stringify(sec);
    return "{}";
  };
  window.apiJSON = async (op, a) => op === "history" ? (history[a.task] || [])
    : op === "peek" ? (a && a.session === S.sec ? { messages: secPeek, found: true, title: "Secretary" }
      : { messages: peek, found: true, title: "checkout retries" })
    : {};
  refresh = async () => {};
  window.hqRefresh = async () => {};   // the app calls this when HQ files change
  const errBar = document.getElementById("error"); if (errBar) errBar.hidden = true;
  ui.readDone = Infinity;   // a read of hq already in flight lands as stale, never over the demo
  saveDrafts = () => {};
  savePref = () => {};   // no remembered tab or project carried from one render to the next
  ui.proj = "";
  ui.board = board; ui.sessions = sessions; ui.dots = dots; ui.unread = { [S.dark]: 1 };
  ui.usage = { five_hour: { used: 34, resets_at: later(131) }, seven_day: { used: 58, resets_at: later(60 * 24 * 3 + 300) } };
  ui.drafts = {}; ui.atts = {}; ui.picks = {}; ui.outbox = {}; ui.expanded = new Set(); ui.adding = new Set(); ui.history = {};
  ui.groupBy = "project"; ui.activeFirst = true; ui.collapsed = new Set();
  ui.secGlance = { busy: false, lastAt: ago(2) };
  ui.mode = "today";
  window.DEMO_IDS = S;
  window.DEMO_JOBS = jobs;
})();
