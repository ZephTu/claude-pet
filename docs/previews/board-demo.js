// Demo data for the Task Board screenshots in the README — a made-up shop, nothing real.
// Run by scripts/board-shots.sh through `ClaudePet --render-board`: it replaces what the board
// loaded with this data and cuts the board off from hq, so a screenshot never shows anyone's
// actual tasks or sessions. `window.DEMO_SCENE` (set by the caller) picks what to show.
(() => {
  const ago = (min) => new Date(Date.now() - min * 60000).toISOString();
  const later = (min) => new Date(Date.now() + min * 60000).toISOString();
  const S = {
    checkout: "1f0c2a51-7a1e-4c3b-9d0e-0a1b2c3d4e51",
    dark: "2a7d9e10-4b2c-4f6e-8a1d-1b2c3d4e5f62",
    ci: "3b8e0f21-5c3d-4a7f-9b2e-2c3d4e5f6a73",
    notes: "4c9f1a32-6d4e-4b8a-8c3f-3d4e5f6a7b84",
  };
  const todo = (i, state, owner, text, min) => ({ i, state, owner, text, created: ago(min) });
  const ask = (id, text, session, min) => ({ type: "open", id, task: id.replace(/\.\d+$/, ""), text, session, ts: ago(min), state: "open" });
  const tasks = [
    {
      id: "T-014", title: "Checkout: retry when the payment gateway times out", category: "feature", status: "active",
      project: "shop-api", workdirs: ["/Users/demo/code/shop-api"], refs: ["shop-api#212"], sessions: ["1f0c2a51", "5d0a2b43"],
      next: "Add the retry with backoff behind a flag, then load-test it on staging",
      todos: [todo(1, "done", "claude", "Reproduce the 504 from the gateway sandbox", 300), todo(2, "done", "claude", "Write a failing test for the timeout", 240),
        todo(3, "open", "claude", "Retry with exponential backoff (max 3) behind CHECKOUT_RETRY", 60), todo(4, "open", "me", "Review PR shop-api#212", 30)],
      asks: [
        ask("T-014.4", "Retry 3 times with backoff (0.5s, 1s, 2s) — or 2 times to stay under the 5s checkout budget?", S.checkout, 3),
        ask("T-014.5", "Ship it behind the CHECKOUT_RETRY flag, off by default?", S.checkout, 3),
        ask("T-014.6", "Once it's merged, post the load-test numbers in #payments?", S.checkout, 3),
      ],
      body: "## Log\n- 2026-11-19 16:02:11: Reproduced: the sandbox gateway answers 504 after 4.8s under load\n- 2026-11-20 10:14:37: Failing test in place (test_checkout_timeout)\n- 2026-11-20 11:40:05: Draft PR shop-api#212 open; waiting on the retry policy\n",
      age_days: 2,
    },
    {
      id: "T-016", title: "Dashboard: dark mode polish", category: "feature", status: "active", project: "web-app",
      workdirs: ["/Users/demo/code/web-app"], refs: [], sessions: ["2a7d9e10"],
      next: "Fix chart colours in dark mode, then screenshots for the design review",
      todos: [todo(1, "done", "claude", "Swap hard-coded greys for theme tokens", 200), todo(2, "open", "claude", "Chart palette: pass contrast checks in dark mode", 90),
        todo(3, "open", "me", "Book the design review with Ana", 50)],
      asks: [], body: "## Log\n- 2026-11-20 09:12:44: 31 hard-coded colours replaced with tokens\n", age_days: 4,
    },
    {
      id: "T-015", title: "Move CI to the new runners", category: "ops", status: "blocked", project: "infra",
      workdirs: ["/Users/demo/code/infra"], refs: [], sessions: ["3b8e0f21"],
      next: "Waiting on the runner image with Node 22 — then switch the main pipeline",
      todos: [todo(1, "open", "me", "Ask platform team for the Node 22 runner image", 1500), todo(2, "open", "claude", "Switch the lint + unit jobs first", 400)],
      asks: [], body: "## Log\n- 2026-11-18 14:20:09: Lint job green on the new runners\n", age_days: 6,
    },
    {
      id: "T-012", title: "Search: index product variants", category: "feature", status: "active", project: "shop-api",
      workdirs: ["/Users/demo/code/shop-api"], refs: [], sessions: [], next: "Backfill the index for the 40k existing variants",
      todos: [todo(1, "open", "claude", "Backfill job, batches of 500", 2000)], asks: [], body: "", age_days: 9,
    },
    {
      id: "T-011", title: "Fix flaky login test", category: "bug", status: "waiting-on-me", project: "web-app",
      workdirs: ["/Users/demo/code/web-app"], refs: [], sessions: [], next: "", waiting_on_me: "Decide: quarantine the test or fix the race this week?",
      todos: [], asks: [], body: "", age_days: 3,
    },
  ];
  const board = {
    root: "/Users/demo/hq", categories: ["feature", "bug", "ops", "docs"],
    projects: [{ name: "shop-api", paths: ["/Users/demo/code/shop-api"] }, { name: "web-app", paths: ["/Users/demo/code/web-app"] }, { name: "infra", paths: ["/Users/demo/code/infra"] }],
    links: [], focus: { today: new Date().toISOString().slice(0, 10), ids: ["T-014", "T-016", "T-015"], last_day: null, carry: [] }, tasks,
  };
  const orca = (h) => ({ kind: "orca", handle: h });
  const sessions = [
    { sessionId: S.checkout, title: "checkout retries", project: "shop-api", cwd: "/Users/demo/code/shop-api", state: "idle", updatedAt: ago(3), terminal: orca("t1"), task: "T-014",
      lastText: "The timeout reproduces every time at 4.8s. Before I write the retry, three decisions — they're on the board." },
    { sessionId: S.dark, title: "dark mode", project: "web-app", cwd: "/Users/demo/code/web-app", state: "busy", updatedAt: ago(0), terminal: orca("t2"), task: "T-016",
      lastText: "Tokens are in. Now checking the chart palette against WCAG contrast in dark mode." },
    { sessionId: S.ci, title: "ci runners", project: "infra", cwd: "/Users/demo/code/infra", state: "idle", updatedAt: ago(14), terminal: orca("t3"), task: "T-015",
      lastText: "Lint is green on the new runners. The unit job needs Node 22, which the runner image doesn't have yet." },
    { sessionId: S.notes, title: "release notes", project: "web-app", cwd: "/Users/demo/code/web-app", state: "waiting", waitingOn: "git push origin release-notes", updatedAt: ago(1), terminal: orca("t4"), task: null,
      lastText: "Release notes drafted for 2.14. Pushing the branch so you can review." },
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
    { role: "user", text: "The checkout times out when the payment gateway is slow. Find out why and propose a fix.", ts: ago(40) },
    { role: "assistant", text: "Found it. The gateway sandbox answers **504 after 4.8s** under load, and `chargeCard()` has no retry:\n\n```ts\nconst res = await gateway.charge(order); // one attempt, 5s budget\n```\n\nPlan:\n1. Retry with exponential backoff (0.5s, 1s, 2s)\n2. Make the charge idempotent with the order id as the key\n3. Ship behind `CHECKOUT_RETRY`\n\nThree decisions before I write it — they're on the board.", ts: ago(3) },
  ];

  // Cut the board off from hq and the pet: every call answers from the demo, nothing is written.
  window.api = async (op, a) => {
    if (op === "resolve" || op === "delivered" || op === "send" || op === "addtodo" || op === "todo") return "{}";
    return "{}";
  };
  window.apiJSON = async (op, a) => op === "history" ? (history[a.task] || []) : op === "peek" ? { messages: peek, found: true, title: "checkout retries" } : {};
  refresh = async () => {};
  saveDrafts = () => {};
  ui.board = board; ui.sessions = sessions; ui.dots = dots; ui.unread = { [S.dark]: 1 };
  ui.usage = { five_hour: { used: 34, resets_at: later(131) }, seven_day: { used: 58, resets_at: later(60 * 24 * 3 + 300) } };
  ui.drafts = {}; ui.atts = {}; ui.picks = {}; ui.expanded = new Set(); ui.adding = new Set(); ui.history = {};
  ui.groupBy = "project"; ui.activeFirst = true; ui.collapsed = new Set();
  ui.mode = "today";
  window.DEMO_IDS = S;
  // Dates in English whatever the machine's language, so the pictures match the README.
  const day = Date.prototype.toLocaleDateString;
  Date.prototype.toLocaleDateString = function (l, o) { return day.call(this, "en-US", o); };
})();
