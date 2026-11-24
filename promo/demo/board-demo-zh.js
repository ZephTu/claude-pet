// 宣传片用的看板演示数据：一家虚构的网店，全是编的，不碰任何真实任务或 session。
// 由 promo/scripts/shot.sh 通过 `ClaudePet --render-board` 注入（CLAUDE_PET_LANG=zh）。
// 它的英文孪生是 docs/previews/board-demo.js（README 截图用），两边改动要保持一致。
(() => {
  // 固定时钟：调用方可在本脚本前设 window.DEMO_NOW（毫秒），让画面上的时间对上故事。
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
    next: "6e1b3c54-2d3e-4f5a-9b6c-1d2e3f4a5b6c",
    sec: "7f2c4d65-3e4f-4a6b-8c7d-2e3f4a5b6c7d",
  };
  const todo = (i, state, owner, text, min) => ({ i, state, owner, text, created: ago(min) });
  const ask = (id, text, session, min) => ({ type: "open", id, task: id.replace(/\.\d+$/, ""), text, session, ts: ago(min), state: "open" });
  const tasks = [
    {
      id: "T-014", title: "结账：支付网关超时自动重试", status: "active",
      project: "shop-api", workdirs: ["/Users/demo/code/shop-api"], refs: ["shop-api#212"], sessions: ["1f0c2a51", "5d0a2b43"],
      next: "加带退避的重试（放在开关后面），然后在预发环境压测",
      todos: [todo(1, "done", "claude", "在网关沙箱里复现 504", 300), todo(2, "done", "claude", "先写一个超时的失败测试", 240),
        todo(3, "open", "claude", "指数退避重试（最多 3 次），放在 CHECKOUT_RETRY 开关后面", 60), todo(4, "open", "me", "Review PR shop-api#212", 30)],
      asks: [
        ask("T-014.4", "重试 3 次（0.5s、1s、2s 退避），还是只重试 2 次，保证结账在 5 秒内完成？", S.checkout, 3),
        ask("T-014.5", "放在 CHECKOUT_RETRY 开关后面上线，默认关闭？", S.checkout, 3),
        ask("T-014.6", "合并以后，要我把压测数据发到 #payments 吗？", S.checkout, 3),
      ],
      body: "## 决策记录\n- 2026-11-22 16:02:11: 复现了：沙箱网关在压力下 4.8 秒后返回 504\n- 2026-11-23 10:14:37: 失败测试已就位（test_checkout_timeout）\n- 2026-11-23 11:40:05: 草稿 PR shop-api#212 已开，等重试策略定下来\n",
      age_days: 2,
    },
    {
      id: "T-016", title: "仪表盘：深色模式打磨", status: "active", project: "web-app",
      workdirs: ["/Users/demo/code/web-app"], refs: [], sessions: ["2a7d9e10"],
      next: "修好深色模式下的图表配色，然后截图给设计评审",
      todos: [todo(1, "done", "claude", "把写死的灰色换成主题 token", 200), todo(2, "open", "claude", "图表配色：深色模式下通过对比度检查", 90),
        todo(3, "open", "me", "约 Ana 开设计评审", 50)],
      asks: [], body: "## 决策记录\n- 2026-11-20 09:12:44: 31 处写死的颜色换成了 token\n", age_days: 4,
    },
    {
      id: "T-015", title: "CI 迁到新的 runner", status: "blocked", project: "infra",
      workdirs: ["/Users/demo/code/infra"], refs: [], sessions: ["3b8e0f21"],
      next: "等带 Node 22 的 runner 镜像——到了就切主流水线",
      todos: [todo(1, "open", "me", "找平台组要 Node 22 的 runner 镜像", 1500), todo(2, "open", "claude", "先切 lint 和单元测试两个 job", 400)],
      asks: [], body: "## 决策记录\n- 2026-11-18 14:20:09: lint job 在新 runner 上通过\n", age_days: 6,
    },
    {
      id: "T-012", title: "搜索：给商品规格建索引", status: "active", project: "shop-api",
      workdirs: ["/Users/demo/code/shop-api"], refs: [], sessions: [], next: "给现有的 4 万个规格补建索引",
      todos: [todo(1, "open", "claude", "补建索引的任务，每批 500 条", 2000)], asks: [ask("T-012.1", "补建索引要不要放到夜里跑，避开白天的流量高峰？", "9c1e7d20", 20)], body: "", age_days: 9,
    },
    {
      id: "T-011", title: "修好不稳定的登录测试", status: "waiting-on-me", project: "web-app",
      workdirs: ["/Users/demo/code/web-app"], refs: [], sessions: [], next: "", waiting_on_me: "决定：这周先隔离这个测试，还是直接修掉竞态？",
      todos: [], asks: [ask("T-011.2", "登录测试先隔离一周，同时我去修竞态，可以吗？", "7a2b9e11", 45)], body: "", age_days: 3,
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
        title: "结账 2.0", due: "2026-12-15",
        goal: "让结账在支付网关抖动时也能 5 秒内完成，跟 2.14 一起上线。",
        out: "支付网关本身的稳定性（归 infra）。",
        crit: [["支付失败率降到 0.5% 以下", true], ["网关超时自动重试", false], ["200 并发压测通过", false]],
        brief: "- 仓库 shop-api，新分支从 main 拉，一个任务一个 PR\n- 提交前跑 `make test`\n- 不碰生产配置，要改先问",
        stats: { open: 2, done: 3, abandoned: 0, done_7d: 1, on_me: 3 } }),
      demoProject("web-app", "goal", {
        title: "Web 2.14", due: "2026-12-05",
        goal: "2.14 版本：深色模式、发版说明、修掉不稳定的测试。",
        crit: [["深色模式过 WCAG AA", false], ["CI 连续 7 天全绿", false]],
        brief: "- 仓库 web-app，PR 要附截图\n- 改颜色只动 design token",
        stats: { open: 2, done: 4, abandoned: 0, done_7d: 2, on_me: 1 } }),
      demoProject("infra", "duty", {
        title: "CI 与基础设施",
        goal: "CI runner、数据库备份、监控告警。",
        crit: [["main 上的 CI 30 分钟内跑完", false], ["每晚备份都成功", false]],
        brief: "- 改 runner 镜像先在 staging 试\n- 备份脚本在 infra/backup",
        stats: { open: 1, done: 6, abandoned: 0, done_7d: 1, on_me: 0 } }),
    ],
    links: [], focus: { today: new Date().toISOString().slice(0, 10), ids: ["T-014", "T-016", "T-015"], last_day: null, carry: [] }, tasks,
  };
  const orca = (h) => ({ kind: "orca", handle: h });
  const sessions = [
    { sessionId: S.checkout, title: "结账重试", project: "shop-api", cwd: "/Users/demo/code/shop-api", state: "idle", updatedAt: ago(3), terminal: orca("t1"), task: "T-014",
      lastText: "超时每次都在 4.8 秒复现。写重试之前有三件事要你定——已经放到看板上了。" },
    { sessionId: S.dark, title: "深色模式", project: "web-app", cwd: "/Users/demo/code/web-app", state: "busy", updatedAt: ago(0), terminal: orca("t2"), task: "T-016",
      lastText: "token 换好了。现在检查深色模式下图表配色的 WCAG 对比度。" },
    { sessionId: S.ci, title: "CI runner", project: "infra", cwd: "/Users/demo/code/infra", state: "idle", updatedAt: ago(14), terminal: orca("t3"), task: "T-015",
      lastText: "lint 在新 runner 上通过了。单元测试需要 Node 22，runner 镜像里还没有。" },
    { sessionId: S.notes, title: "发版说明", project: "web-app", cwd: "/Users/demo/code/web-app", state: "waiting", waitingOn: "git push origin release-notes", updatedAt: ago(1), terminal: orca("t4"), task: null,
      lastText: "2.14 的发版说明写好了。推一下分支给你 review。" },
  ];
  const dots = {
    [S.checkout]: { state: "idle", replied: true, context: 38 },
    [S.dark]: { state: "busy", activity: "Bash npm run test:contrast", context: 61 },
    [S.ci]: { state: "idle", background: 1, context: 22 },
    [S.notes]: { state: "waiting", asks: "permission", context: 84 },
  };
  const history = { "T-014": [
    { sessionId: "5d0a2b43-1c2d-4e3f-8a9b-0c1d2e3f4a5b", cwd: "/Users/demo/code/shop-api", title: "网关复现", lastAt: ago(60 * 26), live: false,
      lastText: "复现了：沙箱网关在压力下 4.8 秒后返回 504。记录写在任务日志里了。" },
  ] };
  const peek = [
    { role: "user", text: "支付网关慢的时候结账会超时。查一下原因，给个修法。", ts: ago(40) },
    { role: "assistant", text: "找到了。压力下沙箱网关 **4.8 秒后返回 504**，而 `chargeCard()` 没有重试：\n\n```ts\nconst res = await gateway.charge(order); // 只试一次，5 秒预算\n```\n\n计划：\n1. 指数退避重试（0.5s、1s、2s）\n2. 用订单号做幂等键，保证重复扣款不会发生\n3. 放在 `CHECKOUT_RETRY` 开关后面上线\n\n写之前有三件事要你定——已经放到看板上了。", ts: ago(3) },
  ];

  // 定时任务
  const run = (startMin, secs, status, summary, extra = {}) => ({ started: ago(startMin), ended: new Date(Date.now() - startMin * 60000 + secs * 1000).toISOString(), status, summary, ...extra });
  const jobs = {
    runner: true, seenAt: new Date().toISOString(),
    jobs: [
      { id: "ci-morning", name: "每天早上总结 CI", kind: "claude", enabled: true, cwd: "~/code/shop-api",
        prompt: "总结昨晚失败的 CI，列出我今天最该看的三件事",
        schedule: { kind: "weekdays", hour: 9, minute: 0 }, next: [at(9, 0, 1)],
        runs: [run(60 * 2, 94, "ok", "3 个失败：2 个是不稳定的登录测试，1 个是真问题（search 索引超时）", { quotaBefore: { week: 57, weekResetAt: "w" }, quotaAfter: { week: 58, weekResetAt: "w" } }),
          run(60 * 26, 81, "ok", "全部通过"), run(60 * 50, 102, "ok", "1 个失败：lint"), run(60 * 74, 77, "ok", "全部通过"), run(60 * 98, 120, "ok", "2 个失败")] },
      { id: "pr-hourly", name: "每小时看一眼我的 PR 评论", kind: "claude", enabled: true, cwd: "~/code",
        prompt: "看看我开着的 PR 有没有新的 review 评论，有就列出来",
        schedule: { kind: "every", everyMinutes: 60 }, next: [later(23)],
        runs: [run(37, 41, "ok", "shop-api#212 有 1 条新评论"), run(97, 38, "ok", "没有新评论"), run(157, 44, "ok", "没有新评论"), run(217, 40, "ok", "web-app#88 有 2 条新评论")] },
      { id: "backup", name: "每晚备份数据库快照", kind: "shell", enabled: true, cwd: "~/code/infra",
        command: "./scripts/nightly-backup.sh",
        schedule: { kind: "daily", hour: 2, minute: 30 }, next: [at(2, 30, 1)],
        runs: [run(60 * 13, 312, "ok", "exit 0"), run(60 * 37, 298, "ok", "exit 0"), run(60 * 61, 305, "ok", "exit 0")] },
    ],
  };
  const jobDetail = {
    job: jobs.jobs[0], run: jobs.jobs[0].runs[0],
    reply: "**昨晚 CI：3 个失败**\n\n1. `search-index` 超时——**真问题**，T-012 的补索引任务把库拖慢了，建议改成夜里跑\n2. `login.spec` ×2——老朋友，T-011 那个不稳定的测试\n\n今天先看第 1 个。",
    steps: [], log: "",
  };

  // 秘书
  const sec = { ready: true, job: "secretary", sessionId: S.sec, task: "T-001", lastAt: ago(2), memory: "secretary",
    schedule: { kind: "weekdays", hour: 18, minute: 30, enabled: true, next: "明天 18:30" },
    reports: [{ date: new Date().toISOString().slice(0, 10), kind: "daily", path: "/Users/demo/hq/secretary/reports/today.md" }],
    state: ["T-015：等平台组的 Node 22 镜像，已经 2 天", "T-014：PR shop-api#212 等你 review"],
    feed: { enabled: true, kind: "cron", cron: "0 9-19 * * 1-5" }, autoclose: { enabled: true, job: "secretary-autoclose", kind: "every", everyMinutes: 5 } };
  const secPeek = [
    { role: "user", text: "定时运行：现在写今天该写的报告", ts: ago(4) },
    { role: "assistant", text: "## 今天的晚报 · 11 月 25 日\n\n**有进展**\n- **T-014 结账超时重试**：新 session 读卡接手，按你昨天的决定写好了重试（2 次、开关默认关），测试全绿，正在预发压测\n- **T-016 深色模式**：图表配色通过对比度检查，等你约设计评审\n\n**卡住了**\n- **T-015 CI 迁移**：还在等平台组的 Node 22 镜像，已经 2 天\n\n**等你的**\n- Review PR shop-api#212\n- 约 Ana 开设计评审", ts: ago(2) },
  ];

  // 第二天：昨天那个 session 关了，新开的 session 读卡接手。
  const peekNext = [
    { role: "user", text: "接着做 T-014。", ts: ago(12) },
    { role: "assistant", text: "读了任务卡。昨天定下来的：**重试 2 次**（5 秒预算优先），放在 `CHECKOUT_RETRY` 开关后面、默认关闭。\n\n已经写好重试和幂等键，测试全绿：\n\n```\n✓ test_checkout_timeout\n✓ test_retry_twice_then_fail\n✓ test_idempotent_charge\n```\n\n下一步在预发环境压测。", ts: ago(2) },
  ];
  if (window.DEMO_DAY2) {
    const t = tasks[0];
    t.asks = [];
    t.sessions = ["6e1b3c54"];
    t.todos[2].state = "done";
    t.todos.push(todo(5, "open", "claude", "在预发环境压测，压测数据发到 #payments", 10));
    t.next = "在预发环境压测，然后把数据发到 #payments";
    t.body += "- " + new Date(Date.now() - 86400000).toISOString().slice(0, 10) + " 10:21:40: 用户决定：重试 2 次（5 秒预算优先）；开关默认关闭\n- " + new Date().toISOString().slice(0, 10) + " 09:14:02: 新 session 读卡接手：重试与幂等键已实现，测试全绿\n";
    history["T-014"].unshift({ sessionId: S.checkout, cwd: "/Users/demo/code/shop-api", title: "结账重试", lastAt: ago(60 * 15), live: false,
      lastText: "超时每次都在 4.8 秒复现。写重试之前有三件事要你定——已经放到看板上了。" });
    sessions[0] = { sessionId: S.next, title: "结账重试 · 接手", project: "shop-api", cwd: "/Users/demo/code/shop-api", state: "idle", updatedAt: ago(2), terminal: orca("t5"), task: "T-014",
      lastText: "读了任务卡，按昨天的决定写好了重试，测试全绿。下一步压测。" };
    delete dots[S.checkout];
    dots[S.next] = { state: "idle", replied: true, context: 21 };
  }

  // 把看板和 hq、宠物断开：所有调用都从演示数据里回答，什么都不写。
  window.api = async (op, a) => {
    if (op === "jobs") return JSON.stringify(jobs);
    if (op === "job-detail") return JSON.stringify(jobDetail);
    if (op === "secretary") return JSON.stringify(sec);
    return "{}";
  };
  window.apiJSON = async (op, a) => op === "history" ? (history[a.task] || [])
    : op === "peek" ? (a && a.session === S.sec ? { messages: secPeek, found: true, title: "秘书" }
      : a && a.session === S.next ? { messages: peekNext, found: true, title: "结账重试 · 接手" }
      : { messages: peek, found: true, title: "结账重试" })
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
