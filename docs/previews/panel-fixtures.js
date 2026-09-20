/**
 * Fixed panel/bubble data for docs/previews/panel.html.
 *
 * Deliberately hand-written constants rather than anything sampled from the
 * user's own machine: a preview whose contents change between runs cannot be
 * used to compare a before against an after. The shapes here are the ones
 * WebBridge.pushSessions builds — see Sources/ClaudePet/WebBridge.swift.
 */

/** One live-session row, with the fields pet.js actually reads. */
function session(o) {
  return Object.assign({
    sessionId: "s" + Math.random().toString(36).slice(2, 8),
    project: "project",
    state: "busy",
    tool: "",
    detail: "",
    waitedSeconds: 30,
  }, o);
}

/** One finished-turn row. */
function finished(o) {
  return Object.assign({
    sessionId: "f" + Math.random().toString(36).slice(2, 8),
    eventIds: ["e1"],
    label: "project",
    count: 1,
    closed: false,
    agoSeconds: 90,
  }, o);
}

const term = { termKind: "iterm", termHandle: "w0t1p0" };

/**
 * What Claude Code's Notification hook actually sends for a blocked session.
 *
 * It is here to be shown NOT arriving: SessionCopy.note drops it before the
 * payload is built, so `detail` below carries it nowhere. Kept named so the day
 * it reappears on three rows at once, this file says what it is.
 */
const WAITING_HOOK = "Claude is waiting for your input";

const SCENARIOS = [
  {
    id: "single-busy",
    title: "只有一个 busy",
    note: "面板应紧凑，没有多余分组标题",
    sessions: [
      session({ project: "claude-pet", state: "busy", activity: "Bash npm test",
                toolSeconds: 23, branch: "", ...term }),
    ],
  },
  {
    id: "mixed",
    title: "waiting + busy + finished",
    note: "三组都在，优先级自上而下",
    sessions: [
      session({ project: "api-server", state: "waiting", asks: "permission", detail: "rm -rf build/",
                urgent: true, waitedSeconds: 214, ...term }),
      session({ project: "claude-pet", state: "busy", activity: "Edit pet.css",
                toolSeconds: 8, branch: "ui/panel", ...term }),
      session({ project: "docs-site", state: "idle", replied: true,
                detail: "Finished the migration notes.", waitedSeconds: 640 }),
    ],
    finished: [
      finished({ label: "merge audit", agoSeconds: 130, ...term }),
      finished({ label: "nightly regression", count: 3, agoSeconds: 900, closed: true }),
    ],
  },
  {
    id: "three-waiting",
    title: "3 个 waiting",
    note: "每条要能区分，控件不挤压；第二行重复 hook 原文是本轮要修的点",
    sessions: [
      session({ project: "api-server", state: "waiting", asks: "permission",
                detail: "Edit AppMain.swift", urgent: true,
                waitedSeconds: 412, ...term }),
      session({ project: "claude-pet", state: "waiting", urgent: true,
                waitedSeconds: 96, branch: "ui/panel", ...term }),
      session({ project: "ledger-core", state: "waiting", waitedSeconds: 18 }),
    ],
  },
  {
    id: "snoozed-pinned",
    title: "snooze + pin + muted",
    note: "降级但仍在列表里；pin 标记不改变行的其他样式",
    sessions: [
      session({ project: "api-server", state: "waiting", asks: "permission",
                detail: "git push --force", waitedSeconds: 500,
                snoozedFor: "8m", ...term }),
      session({ project: "claude-pet", state: "busy", pinned: true,
                activity: "Read PetLayout.swift", toolSeconds: 4, ...term }),
      session({ project: "stale-worker", state: "busy", quiet: true, waitedSeconds: 3400 }),
    ],
    hidden: 2,
  },
  {
    id: "long-cn",
    title: "长中文项目名",
    note: "截断要合理，时间和跳转箭头必须留住",
    sessions: [
      session({ project: "贷款证券化平台核心账务与清算服务", state: "waiting",
                asks: "permission", detail: "pytest tests/settlement",
                urgent: true, waitedSeconds: 240, ...term }),
      session({ project: "抵押品管理模块回归测试环境", state: "busy",
                activity: "Bash pytest tests/collateral", toolSeconds: 61,
                branch: "feature/抵押品估值", ...term }),
    ],
  },
  {
    id: "long-en",
    title: "长英文项目名（无空格）",
    note: "无空格长串不能撑破面板、不能出横向滚动条",
    sessions: [
      session({ project: "enterprise-lending-origination-service-adapter-layer",
                state: "waiting", urgent: true, waitedSeconds: 133, ...term }),
      session({ project: "aVeryLongCamelCaseRepositoryNameWithoutAnySpacesAtAll",
                state: "busy", activity: "WebFetch registry.npmjs.org",
                toolSeconds: 12 }),
    ],
  },
  {
    id: "no-terminal",
    title: "无 terminal handle",
    note: "不可跳转的行不应出现 ↗，也不应是 pointer",
    sessions: [
      session({ project: "detached-run", state: "waiting", urgent: true,
                waitedSeconds: 77 }),
      session({ project: "ci-shadow", state: "busy", activity: "Read config.yaml",
                toolSeconds: 3 }),
    ],
    finished: [finished({ label: "closed session", closed: true, agoSeconds: 2400 })],
  },
  {
    id: "twenty",
    title: "20 个 sessions",
    note: "纵向滚动稳定，无横向滚动；Needs you 始终在最上",
    sessions: (function () {
      const out = [];
      for (let i = 0; i < 3; i++) {
        out.push(session({ project: "waiting-repo-" + i, state: "waiting",
                           asks: i === 1 ? "permission" : undefined,
                           detail: i === 1 ? "npm publish" : "",
                           urgent: i > 0, waitedSeconds: 60 * (i + 1), ...term }));
      }
      for (let i = 0; i < 17; i++) {
        out.push(session({ project: "service-" + String(i).padStart(2, "0"),
                           state: i % 4 === 3 ? "idle" : "busy",
                           activity: i % 4 === 3 ? "" : "Bash make build",
                           toolSeconds: i % 4 === 3 ? undefined : 5 + i,
                           quiet: i % 7 === 5 || undefined,
                           ...(i % 3 ? term : {}) }));
      }
      return out;
    })(),
    finished: [finished({ label: "batch job", count: 4, agoSeconds: 300, ...term })],
  },
  {
    // Straight off a real screenshot. Four live sessions, nothing blocked, so
    // there is no heading and every row is competing for the same width — which
    // is what caught the status column truncating at three different lengths.
    id: "four-idle",
    title: "4 个 session，全是 running/idle",
    note: "状态词是固定词表，不该被截断；该让位的是项目名",
    sessions: [
      session({ project: "\ud83e\udd16 20260920-enhancement", state: "busy",
                activity: "Working", waitedSeconds: 300, ...term }),
      session({ project: "Schwab客户bug跟进", state: "idle", replied: true,
                waitedSeconds: 21600, ...term }),
      session({ project: "\ud83e\udd16 20260918-merge-audit", state: "idle",
                replied: true, waitedSeconds: 3600, ...term }),
      session({ project: "\ud83e\udd16 20260920-new requirement", state: "idle",
                replied: true, waitedSeconds: 2760, ...term }),
    ],
  },
  {
    // The three shapes of "this session has an unread finish": still idle (the
    // duplicate), busy again, and blocked again. Only the first may be folded.
    id: "dedupe",
    title: "未读完成 + 同一 session 的实时状态",
    note: "idle 的那条折叠；重新 busy / waiting 的必须照常显示",
    sessions: [
      session({ sessionId: "s-idle", project: "settled-repo", state: "idle",
                replied: true, waitedSeconds: 44, ...term }),
      session({ sessionId: "s-busy", project: "restarted-repo", state: "busy",
                activity: "Bash npm test", toolSeconds: 7, ...term }),
      session({ sessionId: "s-wait", project: "blocked-repo", state: "waiting",
                asks: "permission", detail: "git push --force",
                urgent: true, waitedSeconds: 120, ...term }),
      session({ sessionId: "s-alone", project: "no-finish-repo", state: "idle",
                replied: true, waitedSeconds: 900, ...term }),
    ],
    finished: [
      finished({ sessionId: "s-idle", label: "settled-repo", agoSeconds: 44, ...term }),
      finished({ sessionId: "s-busy", label: "restarted-repo", agoSeconds: 300, ...term }),
      finished({ sessionId: "s-wait", label: "blocked-repo", agoSeconds: 600, ...term }),
    ],
  },
  {
    // Every row genuinely executing, which is the only time the heading may
    // claim it.
    id: "all-running",
    title: "全部在跑",
    note: "只有这种情况标题才写 Running",
    sessions: [
      session({ project: "alpha", state: "busy", activity: "Bash make", toolSeconds: 4, ...term }),
      session({ project: "beta", state: "busy", activity: "Edit main.swift", toolSeconds: 9, ...term }),
    ],
    finished: [finished({ label: "gamma", agoSeconds: 120, ...term })],
  },
  {
    id: "empty",
    title: "空列表",
    note: "没有会话时的文案",
    sessions: [],
  },
];

/**
 * Panel AND message window at once.
 *
 * These are the ones that matter for overlap: a bubble measured on its own is
 * always "inside the window", and that is exactly the check that let the
 * completion notice sit on top of the list's top-right corner.
 */
const COMBOS = [
  {
    id: "combo-notice",
    title: "面板打开 + 完成通知",
    note: "普通完成气泡应当让位给列表",
    sessions: SCENARIOS.find(s => s.id === "four-idle").sessions,
    finished: [{ sessionId: "f1", eventIds: ["e1"], label: "\ud83e\udd16 20260920-enhancement",
                 count: 1, closed: false, agoSeconds: 44, termKind: "iterm", termHandle: "w0t1p0" }],
    call: ["say", ["\ud83e\udd16 20260920-enhancement came to rest", 0,
                   "\ud83e\udd16 20260920-enhancement", "notice"]],
  },
  {
    id: "combo-alert",
    title: "面板打开 + 紧急提醒",
    note: "alert 不能盖住列表，也不能被列表盖住",
    sessions: SCENARIOS.find(s => s.id === "three-waiting").sessions,
    call: ["setMood", ["urgent", "api-server", "rm -rf build/", null]],
  },
  {
    id: "combo-readout",
    title: "面板打开 + Session Hover 详情",
    note: "hover readout 只在面板打开时出现，必须共存",
    sessions: SCENARIOS.find(s => s.id === "four-idle").sessions,
    call: ["showDetail", [{
      path: "~/Code/claude-pet", worktree: "ui/panel", context: 64,
      model: "opus", turn: "3m12s", quiet: "",
      last: "Edit pet.css", lastBad: false,
    }]],
  },
  {
    id: "combo-readout-full",
    title: "满高面板 + Hover 详情",
    note: "20 条 session 时面板顶到 max-height，避让空间最小",
    sessions: SCENARIOS.find(s => s.id === "twenty").sessions,
    call: ["showDetail", [{
      path: "~/Code/enterprise-lending-origination", worktree: "feature/settlement",
      context: 91, model: "sonnet", tool: "23s", turn: "18m04s", quiet: "6m",
      last: "Bash pytest — exit 1", lastBad: true,
    }]],
  },
  {
    id: "combo-warn",
    title: "面板打开 + 额度告警",
    note: "quota warning 是推送的，面板开着也可能来",
    sessions: SCENARIOS.find(s => s.id === "mixed").sessions,
    finished: SCENARIOS.find(s => s.id === "mixed").finished,
    call: ["say", ["the 5h window is 92% used", 0, "", "warn"]],
  },
];

/** The three bubble readings the plan asks to see side by side. */
const BUBBLES = [
  {
    id: "quota-50",
    title: "quota 50%",
    call: ["showQuota", [[{ label: "5h", percent: 50, resetsIn: "resets 15:30" },
                          { label: "week", percent: 31, resetsIn: "Mon" }], "no reading"]],
  },
  {
    id: "quota-75",
    title: "quota 75%",
    call: ["showQuota", [[{ label: "5h", percent: 75, resetsIn: "resets 15:30" },
                          { label: "week", percent: 62, resetsIn: "Mon" }], "no reading"]],
  },
  {
    id: "quota-92",
    title: "quota 92%",
    call: ["showQuota", [[{ label: "5h", percent: 92, resetsIn: "resets 12m" },
                          { label: "week", percent: 88, resetsIn: "Mon" }], "no reading"]],
  },
  {
    id: "quota-empty",
    title: "quota 无数据",
    call: ["showQuota", [[], "usage unavailable"]],
  },
  {
    id: "readout",
    title: "session hover readout",
    call: ["showDetail", [{
      path: "~/Code/claude-pet", worktree: "ui/panel", context: 64,
      model: "opus", turn: "3m12s", quiet: "",
      last: "Edit pet.css", lastBad: false,
    }]],
  },
  {
    id: "readout-bad",
    title: "readout（上一步失败）",
    call: ["showDetail", [{
      path: "~/Code/ledger-core", context: 91, model: "sonnet",
      tool: "23s", turn: "18m04s", quiet: "6m",
      last: "Bash pytest — exit 1", lastBad: true,
    }]],
  },
  {
    id: "notice",
    title: "completion notice",
    call: ["say", ["merge audit came to rest", 0, "merge audit", "notice"]],
  },
  {
    id: "warn",
    title: "quota warning",
    call: ["say", ["the 5h window is 92% used", 0, "", "warn"]],
  },
  {
    id: "chatter",
    title: "chatter / wellness",
    call: ["say", ["stretch your legs — you have been at this for 90 minutes", 0, "", "chat"]],
  },
  {
    id: "intervention-permission",
    title: "intervention — 授权",
    call: ["setMood", ["urgent", "api-server", "rm -rf build/", null]],
  },
  {
    id: "intervention-question",
    title: "intervention — 等回答",
    call: ["setMood", ["urgent", "贷款证券化平台核心账务服务", "", null]],
  },
];

if (typeof window !== "undefined") {
  window.PANEL_FIXTURES = { SCENARIOS, COMBOS, BUBBLES, WAITING_HOOK };
}
