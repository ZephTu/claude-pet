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
    id: "empty",
    title: "空列表",
    note: "没有会话时的文案",
    sessions: [],
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
      turn: "18m04s", quiet: "6m", last: "Bash pytest — exit 1", lastBad: true,
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
  window.PANEL_FIXTURES = { SCENARIOS, BUBBLES, WAITING_HOOK };
}
