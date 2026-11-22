// The board's Scheduled view: scheduled jobs — a shell command or a Claude prompt on a
// timetable — with their runs. Loaded after board.js and uses its helpers (api, esc, toast,
// markdown, openPeek…). Jobs themselves are kept and run by the app: see JobsController.swift.
//
// Every string here comes from JT, in English and Chinese. The language follows macOS and can be
// switched in the view — which switches the whole app's language (Settings → Language).

const JT = {
  en: {
    tab: "Scheduled", loading: "Loading…", newJob: "New job",
    count: "{n} jobs", count1: "1 job", on: "{n} on", runningN: "{n} running", failingN: "{n} failing",
    intro: "Jobs made here run on schedule even when the pet is closed. A run missed while the Mac slept runs once when it wakes.",
    noRunner: "Claude Pet's runner (~/.claude/pet/pet-emit) is missing, so jobs can't run. Reinstall Claude Pet.",
    empty: "No scheduled jobs yet. A job runs a Claude prompt or a shell command on a timetable — start from one of these:",
    tpl1: "Summarise last night's CI every morning", tpl1P: "Summarise last night's failed CI jobs and list the three things I should look at today",
    tpl2: "Check my PRs for new comments every hour", tpl2P: "Look at my open PRs for new review comments and list them, if there are any",
    tpl3: "Clear caches once a week",
    claude: "Claude", shell: "Shell",
    next: "Next", never: "not run yet", paused: "Paused", runningFor: "running · {d}", lastRun: "Last",
    runNow: "Run now", stop: "Stop", edit: "Edit", del: "Delete", delSure: "Delete?",
    toggleOn: "Switch on", toggleOff: "Switch off", history: "Runs (newest first)",
    hStart: "Started", hResult: "Result", hTook: "Took", hCost: "Cost", hSummary: "Summary",
    details: "Details", convo: "Conversation", cont: "Continue", lastLines: "Last lines of output",
    st_ok: "Succeeded", st_fail: "Failed", st_timeout: "Timed out", st_stopped: "Stopped", st_skipped: "Skipped",
    st_lost: "Interrupted", st_running: "Running", exitN: "exit {n}", refused: "{n} refused",
    manual: "manual",
    today: "today", tomorrow: "tomorrow", yesterday: "yesterday",
    days: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
    sec: "{n}s", minSec: "{m}m {s}s", hourMin: "{h}h {m}m",
    every: "Every {n} min", everyH: "Every {n} h", hourly: "Every hour", daily: "Daily {t}", weekdaysAt: "Weekdays {t}", weeklyAt: "{d} {t}",
    cronAt: "cron {c}", daySep: ", ",
    // form: a question on the left, its answer on the right
    newTitle: "New scheduled job", editTitle: "Edit job",
    q_what: "What", q_where: "Where", q_whereS: "It starts in this folder and reads its CLAUDE.md",
    q_can: "What it may do", q_canS: "Nobody is there to click Allow", q_tell: "Tell me", q_more: "More", q_moreS: "Usually fine as it is",
    kindClaude: "Claude prompt", kindClaudeD: "One claude -p turn in the background; it can use your skills and MCP tools.",
    kindShell: "Shell command", kindShellD: "A command or script; its exit code and output are kept.",
    name: "Name", namePh: "Morning CI summary", cwd: "Folder", choose: "Choose…",
    prompt: "Prompt",
    promptPh: "/my-skill summarise last night's failed CI jobs and list the three things I should look at today",
    promptHelp: "Sent as written, every run. As in the terminal: start with /skill-name to use a skill, or just describe the work and Claude picks one. Your MCP servers, plugins and hooks load as usual.",
    cmdLbl: "Command", cmdPh: "./scripts/nightly.sh", command: "Runs in your login shell, with the PATH your terminal has.",
    modelDefault: "the default model",
    p_standard: "Only what's allowed", p_standardD: "Only what your Claude Code settings already allow; anything else is refused and noted in the run.",
    p_edits: "Also edit files", p_editsD: "May also edit files in the folder; other requests are still refused.",
    p_all: "Everything", p_allD: "Skips every permission check. Only for prompts you fully trust.",
    m_model: "Use {model}, and stop it after {limit} minutes.", m_limit: "Stop it after {limit} minutes.",
    m_quota: "Skip the run when the weekly quota is at {w}% or the 5-hour quota at {f}% (0 = don't check).",
    quotaQ: "Quota guard — before each run, look at your subscription's limits and skip the run if too much is used, leaving the rest for your own work",
    quotaNow: "Now: week {w} · 5-hour {f}", quotaUnknown: "Now: not known yet — the pet's statusline reading or a first run will tell",
    m_fresh: "Each run {mode}, and the newest {n} runs' sessions are kept on disk (1 = only the latest).",
    m_resume: "Each run {mode}, compacted first when its context is {n}% full (0 = never).",
    s_fresh: "starts a new session", s_freshD: "Clean and cheap; runs don't see each other.",
    s_resume: "continues the same session", s_resumeD: "Each run continues the last one — for work that needs to remember, like \"what's new since last time\".",
    usageCol: "Quota used", usageLbl: "Last run used", weekUp: "week +{n}%", fiveUp: "5h +{n}%", under1: "<1% of the week",
    ctxNow: "session context {n}%",
    skipWeek: "Skipped — weekly quota at {p}% (limit {l}%)", skipFive: "Skipped — 5-hour quota at {p}% (limit {l}%)",
    skipBusy: "Skipped — the previous run was still going",
    when: "When it runs",
    f_weekdays: "every weekday", f_daily: "every day", f_weekly: "on some days", f_hourly: "every hour", f_every: "every few minutes", f_cron: "by cron",
    w_at: "Run {freq} at {time}", w_days: "Run {freq} {days} at {time}", w_hourly: "Run {freq}", w_every: "Run {freq}: every {n} minutes",
    w_cron: "Run {freq} {cron}", cronHelp: "minute hour day month weekday",
    nextThree: "Next:", slept: "Missed while the Mac slept? It runs once when it wakes.",
    n_failure: "when it fails", n_always: "after every run", n_never: "never",
    enabled: "On", cancel: "Cancel", save: "Save", saveRun: "Save and run now", saved: "Saved", deleted: "Deleted",
    started: "Started", stopping: "Stopping…",
    // run detail
    input: "Input", output: "Output", reply: "Claude's reply", steps: "What it did ({n} steps)", log: "Log",
    noReply: "No reply — see the log.", tool: "tool", refusedTool: "refused", copyReply: "Copy reply", copied: "Copied",
    turns: "{n} turns", turns1: "1 turn", steps1: "What it did (1 step)", runAgain: "Run again", resumeTip: "Open this run's session in a terminal to keep talking to it",
    convoTip: "Read this run's conversation",
  },
  zh: {
    tab: "定时任务", loading: "加载中…", newJob: "新建定时任务",
    count: "{n} 个", on: "{n} 个开着", runningN: "{n} 个在跑", failingN: "{n} 个最近失败",
    intro: "在这里建的任务按时运行，猫关着也照跑。Mac 睡着时错过的那次，醒来后补跑一次。",
    noRunner: "找不到 Claude Pet 的执行程序（~/.claude/pet/pet-emit），任务跑不起来。请重新安装 Claude Pet。",
    empty: "还没有定时任务。定时任务按时间表跑一段 Claude prompt 或一条 Shell 命令——从一个模板开始：",
    tpl1: "每天早上汇总昨晚的 CI", tpl1P: "汇总昨晚失败的 CI job，列出今天要我看的 3 件事",
    tpl2: "每小时看 PR 有没有新评论", tpl2P: "看看我开着的 PR 有没有新评论，有就列出来",
    tpl3: "每周清一次缓存",
    claude: "Claude", shell: "Shell",
    next: "下次", never: "还没跑过", paused: "已暂停", runningFor: "运行中 · {d}", lastRun: "上次",
    runNow: "立即运行", stop: "停止", edit: "编辑", del: "删除", delSure: "确定删除？",
    toggleOn: "打开", toggleOff: "关闭", history: "运行历史（新的在上）",
    hStart: "开始", hResult: "结果", hTook: "耗时", hCost: "花费", hSummary: "摘要",
    details: "详情", convo: "对话", cont: "接着聊", lastLines: "输出的最后几行",
    st_ok: "成功", st_fail: "失败", st_timeout: "超时", st_stopped: "已停止", st_skipped: "跳过",
    st_lost: "中断", st_running: "运行中", exitN: "退出码 {n}", refused: "{n} 个工具被拒绝",
    manual: "手动",
    today: "今天", tomorrow: "明天", yesterday: "昨天",
    days: ["周日", "周一", "周二", "周三", "周四", "周五", "周六"],
    sec: "{n} 秒", minSec: "{m} 分 {s} 秒", hourMin: "{h} 小时 {m} 分",
    every: "每 {n} 分钟", everyH: "每 {n} 小时", hourly: "每小时", daily: "每天 {t}", weekdaysAt: "每个工作日 {t}", weeklyAt: "每{d} {t}",
    cronAt: "cron {c}", daySep: "、",
    newTitle: "新建定时任务", editTitle: "编辑定时任务",
    q_what: "做什么", q_where: "在哪跑", q_whereS: "从这里启动，会读这里的 CLAUDE.md",
    q_can: "能做什么", q_canS: "跑的时候没人点「允许」", q_tell: "跑完告诉我", q_more: "更多", q_moreS: "一般不用动",
    kindClaude: "Claude prompt", kindClaudeD: "在后台用 claude -p 跑一轮，可以用你的技能和 MCP 工具。",
    kindShell: "Shell 命令", kindShellD: "跑一条命令或脚本，记下退出码和输出。",
    name: "名称", namePh: "早报：昨晚 CI 失败汇总", cwd: "工作目录", choose: "选择…",
    prompt: "Prompt",
    promptPh: "/my-skill 汇总昨晚失败的 CI job，列出今天要我看的 3 件事",
    promptHelp: "每次运行时原样发给 Claude。和在终端里一样：开头写 /技能名 就调用那个技能；不写也行，Claude 会按描述自己挑。你的 MCP 服务器、插件、hooks 照常加载。",
    cmdLbl: "命令", cmdPh: "./scripts/nightly.sh", command: "用你的登录 shell 跑，PATH 和终端里一样。",
    modelDefault: "默认模型",
    p_standard: "只用已允许的", p_standardD: "只用你在 Claude Code 设置里已经允许的；其他操作一律拒绝，并记在运行结果里。",
    p_edits: "还能改文件", p_editsD: "还可以改工作目录里的文件；其他需要批准的仍然拒绝。",
    p_all: "全部允许", p_allD: "跳过所有权限检查。只给你完全信任的 prompt 用。",
    m_model: "用 {model}，单次最长 {limit} 分钟。", m_limit: "单次最长 {limit} 分钟。",
    m_quota: "周额度用到 {w}% 或 5 小时额度用到 {f}% 时跳过这次（0 = 不检查）。",
    quotaQ: "额度保护——每次跑之前看一眼订阅额度，用得太多就跳过这次，把剩下的留给你自己用",
    quotaNow: "现在：周 {w} · 5 小时 {f}", quotaUnknown: "现在：还不知道——等猫从状态栏读到额度，或者任务跑过一次就有了",
    m_fresh: "每次 {mode}，保留最近 {n} 次运行的 session（填 1 就只留最新一次）。",
    m_resume: "每次 {mode}，上下文用到 {n}% 时先压缩（0 = 不压缩）。",
    s_fresh: "开新 session", s_freshD: "干净、便宜，每次互不影响。",
    s_resume: "接着同一个 session", s_resumeD: "每次接着上一次往下聊——适合需要记住上次的任务，比如「跟上次比有什么新的」。",
    usageCol: "用掉的额度", usageLbl: "上次用了", weekUp: "周 +{n}%", fiveUp: "5 小时 +{n}%", under1: "不到周额度的 1%",
    ctxNow: "session 上下文 {n}%",
    skipWeek: "跳过——周额度已用 {p}%（上限 {l}%）", skipFive: "跳过——5 小时额度已用 {p}%（上限 {l}%）",
    skipBusy: "跳过——上一次还没跑完",
    when: "什么时候跑",
    f_weekdays: "每个工作日", f_daily: "每天", f_weekly: "每周", f_hourly: "每小时", f_every: "每隔几分钟", f_cron: "按 cron 表达式",
    w_at: "{freq} 的 {time} 跑一次", w_days: "{freq} {days} 的 {time} 跑一次", w_hourly: "{freq} 跑一次", w_every: "{freq}：每 {n} 分钟跑一次",
    w_cron: "{freq} {cron}", cronHelp: "分 时 日 月 周",
    nextThree: "接下来：", slept: "Mac 睡着时错过的那次，醒来后补跑一次。",
    n_failure: "失败时", n_always: "每次跑完", n_never: "不提醒",
    enabled: "开着", cancel: "取消", save: "保存", saveRun: "保存并立即跑一次", saved: "已保存", deleted: "已删除",
    started: "已开始", stopping: "正在停止…",
    input: "输入", output: "输出", reply: "Claude 的回复", steps: "过程（{n} 步）", log: "日志",
    noReply: "没有回复——看看日志。", tool: "工具", refusedTool: "被拒绝", copyReply: "复制回复", copied: "已复制",
    turns: "{n} 轮", runAgain: "再跑一次", resumeTip: "在终端里打开这次运行的 session，接着跟它聊",
    convoTip: "看这次运行的完整对话",
  },
};

// The app's language (see LANG in board.js), set in right-click Settings → Language.
function jlang() { return LANG; }
function jt(key, vars) {
  // English has a singular; Chinese doesn't need one.
  if (vars && vars.n === 1 && JT[jlang()][key + "1"]) key += "1";
  let s = JT[jlang()][key] ?? JT.en[key] ?? key;
  if (vars) for (const k of Object.keys(vars)) s = s.split("{" + k + "}").join(String(vars[k]));
  return s;
}

// freq: the schedule menu's choice in the form; "hourly" is an every-60-minutes schedule.
const jui = { data: null, open: null, form: null, freq: null, preview: null, previewTimer: null, armed: null, error: "" };

// ------------------------------------------------------------------ data
// Called by board.js's refresh while this view is showing; returns a signature of what it read.
async function loadJobs() {
  try {
    const r = await api("jobs");
    jui.data = typeof r === "string" ? JSON.parse(r) : r;
  } catch (e) {
    jui.data = jui.data || { jobs: [], runner: true };
    jui.error = String(e.message || e);
  }
  return JSON.stringify(jui.data);
}
window.hqShowJobs = () => { ui.mode = "jobs"; savePref("hq-mode", "jobs"); refresh(true); };

const isFail = (r) => r && (r.status === "fail" || r.status === "timeout" || r.status === "lost");
const lastReal = (j) => (j.runs || []).find((r) => r.status !== "skipped" && r.status !== "running") || null;

// ------------------------------------------------------------------ words
function jdur(seconds) {
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return jt("sec", { n: s });
  if (s < 3600) return jt("minSec", { m: Math.floor(s / 60), s: s % 60 });
  return jt("hourMin", { h: Math.floor(s / 3600), m: Math.floor((s % 3600) / 60) });
}
const pad2 = (n) => String(n).padStart(2, "0");
function jwhen(iso) {
  if (!iso) return "—";
  const d = new Date(iso);
  if (isNaN(d)) return "—";
  const time = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
  const day = new Date(d); day.setHours(0, 0, 0, 0);
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const diff = Math.round((day - today) / 86400000);
  if (diff === 0) return `${jt("today")} ${time}`;
  if (diff === 1) return `${jt("tomorrow")} ${time}`;
  if (diff === -1) return `${jt("yesterday")} ${time}`;
  const wd = JT[jlang()].days[d.getDay()];
  return `${wd} ${d.getMonth() + 1}/${d.getDate()} ${time}`;
}
function scheduleText(s) {
  if (!s) return "";
  const t = `${pad2(s.hour ?? 9)}:${pad2(s.minute ?? 0)}`;
  switch (s.kind) {
    case "every":
      if (s.everyMinutes === 60) return jt("hourly");
      return s.everyMinutes % 60 === 0 && s.everyMinutes >= 60 ? jt("everyH", { n: s.everyMinutes / 60 }) : jt("every", { n: s.everyMinutes });
    case "daily": return jt("daily", { t });
    case "weekdays": return jt("weekdaysAt", { t });
    case "weekly": {
      const names = JT[jlang()].days;
      const days = [...(s.days || [])].sort((a, b) => a - b).map((n) => names[n % 7]);
      // Chinese reads 每周一、五: the 周 once.
      const list = jlang() === "zh" ? days.map((x, i) => (i ? x.replace("周", "") : x)).join(jt("daySep")) : days.join(jt("daySep"));
      return jt("weeklyAt", { d: list, t });
    }
    case "cron": return jt("cronAt", { c: s.cron });
    default: return "";
  }
}
function statusText(r) {
  if (!r) return "";
  let s = jt("st_" + r.status);
  if (r.status === "fail" && r.exitCode != null && r.exitCode !== 0) s += ` (${jt("exitN", { n: r.exitCode })})`;
  if (r.status === "ok" && r.denials) s += ` · ${jt("refused", { n: r.denials })}`;
  return s;
}
const statusClass = (r) => !r ? "none" : r.status === "running" ? "run" : isFail(r) ? "fail" : r.status === "ok" && r.denials ? "warn" : r.status === "ok" ? "ok" : "muted";
const runSeconds = (r) => r.ended ? (new Date(r.ended) - new Date(r.started)) / 1000 : r.status === "running" ? (Date.now() - new Date(r.started)) / 1000 : null;
const tookText = (r) => { const s = r.status === "skipped" ? null : runSeconds(r); return s == null ? "—" : jdur(s); };
// What a run used of the subscription: the change in its quota between the run's first and last
// rate-limit reports. The dollar figure (API list price) is only a tooltip — subscribers don't pay it.
function usageText(r) {
  const a = r.quotaBefore, b = r.quotaAfter;
  if (!a || !b) return r.costUSD != null ? costText(r) : "—";
  const same = (x, y) => x && y && x === y;
  const dw = b.week != null && a.week != null && same(a.weekResetAt, b.weekResetAt) ? b.week - a.week : null;
  const df = b.fiveHour != null && a.fiveHour != null && same(a.fiveHourResetAt, b.fiveHourResetAt) ? b.fiveHour - a.fiveHour : null;
  const parts = [];
  if (dw > 0) parts.push(jt("weekUp", { n: dw }));
  if (df > 0) parts.push(jt("fiveUp", { n: df }));
  return parts.length ? parts.join(" · ") : jt("under1");
}
function summaryText(r) {
  const s = r.summary || "";
  let m;
  if ((m = s.match(/^skipped: weekly quota at (\d+)% \(limit (\d+)%\)/))) return jt("skipWeek", { p: m[1], l: m[2] });
  if ((m = s.match(/^skipped: 5-hour quota at (\d+)% \(limit (\d+)%\)/))) return jt("skipFive", { p: m[1], l: m[2] });
  if (/^skipped: the previous run was still going/.test(s)) return jt("skipBusy");
  return s;
}
const quotaNowText = (q) => (q && (q.week != null || q.fiveHour != null))
  ? jt("quotaNow", { w: q.week != null ? q.week + "%" : "?", f: q.fiveHour != null ? q.fiveHour + "%" : "?" }) : jt("quotaUnknown");
const costText = (r) => (r.costUSD != null ? "$" + r.costUSD.toFixed(r.costUSD < 0.1 ? 3 : 2) : "—");

// The empty page's starting points: each opens the form filled in.
function jobTemplates() {
  const base = JOB_DEFAULTS();
  return [
    { ...base, name: jt("tpl1"), kind: "claude", prompt: jt("tpl1P"), schedule: { ...base.schedule, kind: "weekdays", hour: 9, minute: 0 } },
    { ...base, name: jt("tpl2"), kind: "claude", prompt: jt("tpl2P"), schedule: { ...base.schedule, kind: "every", everyMinutes: 60 } },
    { ...base, name: jt("tpl3"), kind: "shell", command: "find ~/Library/Caches -type f -atime +30 -delete",
      schedule: { ...base.schedule, kind: "weekly", days: [7], hour: 3, minute: 0 } },
  ];
}

// ------------------------------------------------------------------ the view
function renderJobsView() {
  const d = jui.data;
  const top = $("#jobs-top");
  const box = $("#jobs-list");
  // The form is a page of its own: while it is open, the list steps aside.
  top.hidden = box.hidden = Boolean(jui.form);
  if (!d) { top.innerHTML = ""; box.innerHTML = `<div class="empty">${jt("loading")}</div>`; return; }
  const jobs = d.jobs || [];
  const nOn = jobs.filter((j) => j.enabled).length;
  const nRun = jobs.filter((j) => j.running).length;
  const nFail = jobs.filter((j) => isFail(lastReal(j))).length;
  top.innerHTML = `<div class="jhead">
      <h1>${jt("tab")}</h1>
      <span class="jsub">${jobs.length ? `${jt("count", { n: jobs.length })} · ${jt("on", { n: nOn })}${nRun ? ` · <span class="jrun">${jt("runningN", { n: nRun })}</span>` : ""}${nFail ? ` · <span class="jfail">${jt("failingN", { n: nFail })}</span>` : ""}` : ""}</span>
      <span class="spacer"></span>
      <button class="btn primary" data-jaction="new">${jt("newJob")}</button>
    </div>
    <p class="jintro">${jt("intro")}</p>
    ${d.runner === false ? `<div class="jwarn">${jt("noRunner")}</div>` : ""}
    ${jui.error ? `<div class="jwarn">${esc(jui.error)}</div>` : ""}`;
  box.innerHTML = jobs.length ? jobs.map(jobRow).join("") : `<div class="jempty"><p>${jt("empty")}</p>
    <div class="jstarter">${jobTemplates().map((t, i) => `<button data-jaction="tpl" data-i="${i}"><b>${esc(t.name)}</b>
      <span>${t.kind === "shell" ? jt("shell") : jt("claude")} · ${esc(scheduleText(t.schedule))}</span></button>`).join("")}</div></div>`;
  // Looking at the view is seeing its failures: the pet stops counting them.
  const seen = new Date(d.seenAt || 0).getTime();
  if (jobs.some((j) => { const r = lastReal(j); return isFail(r) && new Date(r.ended || r.started || 0).getTime() > seen; })
      && document.visibilityState === "visible") {
    d.seenAt = new Date().toISOString();
    api("job-seen").catch(() => {});
  }
}

// The last runs as small bars, oldest on the left: a failure is full height, a success as tall
// as it was long next to the others, a skipped or stopped run a stub.
function runBars(runs) {
  const shown = runs.slice(0, 12).reverse();
  const longest = Math.max(1, ...shown.map((r) => (r.status === "ok" ? runSeconds(r) || 0 : 0)));
  return shown.map((r) => {
    const c = statusClass(r);
    const h = c === "fail" ? 100 : c === "ok" || c === "warn" ? 35 + Math.round(55 * (runSeconds(r) || 0) / longest) : c === "run" ? 70 : 30;
    return `<i class="${c}" style="height:${h}%" title="${esc(jwhen(r.started) + " · " + statusText(r) + (r.status === "skipped" ? "" : " · " + tookText(r)))}"></i>`;
  }).join("");
}

function jobRow(j) {
  const runs = j.runs || [];
  // The newest run that isn't a skip: a skip logged while a run goes on must not hide it.
  const current = runs.find((r) => r.status !== "skipped");
  const running = current && current.status === "running" ? current : null;
  const last = lastReal(j);
  const failed = isFail(last) && !running;
  const lastLine = running ? jt("runningFor", { d: tookText(running) })
    : last ? [`${jt("lastRun")} ${jwhen(last.started)}`, last.status === "ok" && !last.denials ? "" : statusText(last), tookText(last)].filter(Boolean).join(" · ")
    : jt("never");
  const open = jui.open === j.id;
  const armed = jui.armed === "del:" + j.id;
  const what = (j.kind === "shell" ? j.command : j.prompt) || "";
  const usage = j.kind === "claude" && last && (last.quotaAfter || last.costUSD != null) ? usageText(last) : "";
  return `<section class="job ${j.enabled ? "" : "off"} ${open ? "open" : ""}">
    <button class="jname" data-jaction="expand" data-id="${esc(j.id)}" aria-expanded="${open}" title="${jt("history")}">
      <span class="jn"><span class="jn-t">${esc(j.name)}</span><span class="jkind ${j.kind === "shell" ? "sh" : ""}">${j.kind === "shell" ? jt("shell") : jt("claude")}</span></span>
      <span class="jd">${esc(what.replace(/\s+/g, " ").trim())}${what.trim() ? " · " : ""}${esc(j.cwd || "~")}</span>
    </button>
    <div class="jsched">${esc(scheduleText(j.schedule))}<small>${j.enabled ? `${jt("next")} ${esc(j.next && j.next[0] ? jwhen(j.next[0]) : "—")}` : jt("paused")}</small></div>
    <div class="jruns-c">
      <div class="jruns" aria-label="recent runs">${runBars(runs)}</div>
      <div class="jruns-l ${failed ? "bad" : running ? "live" : ""}" title="${esc(lastLine)}">${esc(lastLine)}</div>
    </div>
    <div class="jusage">${usage ? `${jt("usageLbl")}<b title="${last.costUSD != null ? esc(costText(last) + " (API list price)") : ""}">${esc(usage)}</b>` : ""}${j.contextPct != null ? `<span>${esc(jt("ctxNow", { n: j.contextPct }))}</span>` : ""}</div>
    <div class="jbtns">
      <button class="switch ${j.enabled ? "on" : ""}" role="switch" aria-checked="${j.enabled}" data-jaction="toggle" data-id="${esc(j.id)}" title="${j.enabled ? jt("toggleOff") : jt("toggleOn")}"><span></span></button>
      ${running ? `<button class="btn small danger" data-jaction="stop" data-id="${esc(j.id)}">${jt("stop")}</button>`
                : `<button class="btn small" data-jaction="run" data-id="${esc(j.id)}">${jt("runNow")}</button>`}
      <button class="btn small ghost" data-jaction="edit" data-id="${esc(j.id)}">${jt("edit")}</button>
      <button class="btn small ghost ${armed ? "armed" : ""}" data-jaction="delete" data-id="${esc(j.id)}">${armed ? jt("delSure") : jt("del")}</button>
    </div>
    ${failed && last.tail ? `<div class="jtail"><b>${jt("lastLines")}</b>${esc(last.tail)}</div>` : ""}
    ${open ? historyTable(j) : ""}
  </section>`;
}

function historyTable(j) {
  const runs = j.runs || [];
  if (!runs.length) return `<div class="jhist"><div class="empty">${jt("never")}</div></div>`;
  return `<div class="jhist"><div class="jhist-h">${jt("history")}</div><div class="jtable-wrap"><table class="jtable">
    <thead><tr><th>${jt("hStart")}</th><th>${jt("hResult")}</th><th>${jt("hTook")}</th>${j.kind === "claude" ? `<th>${jt("usageCol")}</th>` : ""}<th>${jt("hSummary")}</th><th></th></tr></thead>
    <tbody>${runs.map((r) => `<tr>
      <td class="nowrap num">${esc(jwhen(r.started))}${r.trigger === "manual" ? ` <span class="jtag">${jt("manual")}</span>` : ""}</td>
      <td class="nowrap st-${statusClass(r)}">${esc(statusText(r))}</td>
      <td class="nowrap num">${esc(tookText(r))}</td>
      ${j.kind === "claude" ? `<td class="nowrap num" title="${r.costUSD != null ? esc(costText(r) + " (API list price)") : ""}">${r.status === "skipped" ? "—" : esc(usageText(r))}</td>` : ""}
      <td class="jsum">${esc(summaryText(r))}</td>
      <td class="nowrap jacts">${r.status === "skipped" ? "" : `<button class="btn small ghost" data-jaction="detail" data-id="${esc(j.id)}" data-run="${esc(r.id)}">${jt("details")}</button>`}
        ${r.sessionId ? `<button class="btn small ghost" data-jaction="convo" data-id="${esc(j.id)}" data-session="${esc(r.sessionId)}" title="${jt("convoTip")}">${jt("convo")}</button>
        <button class="btn small ghost" data-jaction="resume" data-id="${esc(j.id)}" data-session="${esc(r.sessionId)}" title="${jt("resumeTip")}">${jt("cont")}</button>` : ""}</td>
    </tr>`).join("")}</tbody></table></div></div>`;
}

// ------------------------------------------------------------------ the form
const JOB_DEFAULTS = () => ({
  name: "", kind: "claude", prompt: "", command: "", cwd: "~", enabled: true,
  schedule: { kind: "weekdays", everyMinutes: 60, hour: 9, minute: 0, days: [1], cron: "0 9 * * 1-5" },
  model: "", permission: "standard", timeoutMinutes: 20, skipWeekPct: 90, skipFiveHourPct: 90,
  sessionMode: "fresh", keepSessions: 20, compactAbovePct: 50, notify: "failure",
});

function openJobForm(job) {
  const f = JOB_DEFAULTS();
  if (job) {
    for (const k of Object.keys(f)) if (job[k] !== undefined) f[k] = JSON.parse(JSON.stringify(job[k]));
    if (job.id) f.id = job.id;
  }
  // A new job is named now, not by the first save: Save again after an error (or a double
  // click) then saves the same job instead of making a second one.
  if (!f.id) f.id = "j" + Array.from(crypto.getRandomValues(new Uint8Array(4)), (b) => b.toString(16).padStart(2, "0")).join("");
  jui.form = f;
  jui.freq = null;
  jui.formError = "";
  jui.preview = null;
  drawJobForm();
  renderJobsView();
  schedulePreview();
  const n = $("#jf-name");
  if (n) n.focus();
  $(".jobs-col").scrollTop = 0;
}
function closeJobForm() {
  jui.form = null;
  $("#job-form").hidden = true;
  $("#job-form").innerHTML = "";
  renderJobsView();
}

const freqOf = (s) => jui.freq || (s.kind === "every" && s.everyMinutes === 60 ? "hourly" : s.kind);
const qrow = (q, sub, body) => `<div class="q-row"><div class="q">${q}${sub ? `<small>${sub}</small>` : ""}</div><div class="a">${body}</div></div>`;

// "When it runs" as one sentence with its blanks inline: [every weekday] at [09:00].
function scheduleSentence(s) {
  const freq = freqOf(s);
  const dayNames = JT[jlang()].days;
  const sel = `<select class="jchip" data-jfreq="1" aria-label="${esc(jt("when"))}">${["weekdays", "daily", "weekly", "hourly", "every", "cron"].map((k) =>
    `<option value="${k}" ${freq === k ? "selected" : ""}>${jt("f_" + k)}</option>`).join("")}</select>`;
  const time = `<input type="time" class="jchip" data-jf="schedule.time" value="${pad2(s.hour)}:${pad2(s.minute)}">`;
  const days = `<span class="jdays">${[1, 2, 3, 4, 5, 6, 7].map((n) => { const on = (s.days || []).includes(n);
    return `<button class="${on ? "on" : ""}" aria-pressed="${on}" data-jaction="jf-day" data-day="${n}">${esc(dayNames[n % 7])}</button>`; }).join("")}</span>`;
  switch (freq) {
    case "daily": case "weekdays": return jt("w_at", { freq: sel, time });
    case "weekly": return jt("w_days", { freq: sel, days, time });
    case "hourly": return jt("w_hourly", { freq: sel });
    case "every": return jt("w_every", { freq: sel, n: `<input type="number" min="1" class="jchip num" data-jf="schedule.everyMinutes" data-num="1" value="${s.everyMinutes}">` });
    default: return jt("w_cron", { freq: sel, cron: `<input type="text" class="jchip mono" data-jf="schedule.cron" value="${esc(s.cron)}" spellcheck="false"> <span class="jhelp-in">${jt("cronHelp")}</span>` });
  }
}

function drawJobForm() {
  const f = jui.form;
  const box = $("#job-form");
  if (!f) { box.hidden = true; return; }
  const num = (path, value, min, max) => `<input type="number" min="${min}" max="${max}" class="jchip num" data-jf="${path}" data-num="1" value="${value}">`;
  const limit = num("timeoutMinutes", f.timeoutMinutes, 1, 1440);
  const claude = f.kind === "claude";
  const model = `<select class="jchip" data-jf="model">
    ${[["", jt("modelDefault")], ["sonnet", "Sonnet"], ["opus", "Opus"], ["haiku", "Haiku"]].map(([v, l]) => `<option value="${v}" ${f.model === v ? "selected" : ""}>${l}</option>`).join("")}
    ${f.model && !["sonnet", "opus", "haiku"].includes(f.model) ? `<option value="${esc(f.model)}" selected>${esc(f.model)}</option>` : ""}</select>`;
  const mode = `<select class="jchip" data-jf="sessionMode">${["fresh", "resume"].map((m) => `<option value="${m}" ${f.sessionMode === m ? "selected" : ""}>${jt("s_" + m)}</option>`).join("")}</select>`;

  const what = `<div class="jkind-row"><span class="jkindsw" role="group">${["claude", "shell"].map((k) =>
      `<button class="${f.kind === k ? "on" : ""}" aria-pressed="${f.kind === k}" data-jaction="jf-set" data-path="kind" data-value="${k}">${jt(k === "claude" ? "kindClaude" : "kindShell")}</button>`).join("")}</span>
      <span class="jhelp-in">${jt(claude ? "kindClaudeD" : "kindShellD")}</span></div>
    <input id="jf-name" class="jfield jname-in" type="text" data-jf="name" value="${esc(f.name)}" placeholder="${esc(jt("namePh"))}" aria-label="${esc(jt("name"))}">
    ${claude
      ? `<textarea class="jfield" rows="4" data-jf="prompt" placeholder="${esc(jt("promptPh"))}" aria-label="${esc(jt("prompt"))}">${esc(f.prompt)}</textarea>
         <div class="jhelp">${jt("promptHelp")}</div>`
      : `<textarea class="jfield mono" rows="3" data-jf="command" placeholder="${esc(jt("cmdPh"))}" aria-label="${esc(jt("cmdLbl"))}" spellcheck="false">${esc(f.command)}</textarea>
         <div class="jhelp">${jt("command")}</div>`}`;
  const where = `<div class="jinl"><input class="jfield" type="text" data-jf="cwd" value="${esc(f.cwd)}" aria-label="${esc(jt("cwd"))}" spellcheck="false">
    <button class="btn" data-jaction="jf-pick">${jt("choose")}</button></div>`;
  const when = `<div class="jsentence">${scheduleSentence(f.schedule)}</div>
    <div id="jf-preview" class="jupcoming">${previewHTML()}</div>
    <div class="jhelp">${jt("slept")}</div>`;
  const can = `<div class="jopts" role="radiogroup">${["standard", "edits", "all"].map((p) => { const on = f.permission === p;
    return `<button class="jopt ${on ? "on" : ""}" role="radio" aria-checked="${on}" data-jaction="jf-set" data-path="permission" data-value="${p}">
      <span class="jradio"></span><span><b>${jt("p_" + p)}</b><span>${jt("p_" + p + "D")}</span></span></button>`; }).join("")}</div>`;
  const tell = `<div class="jinl"><span class="seg jseg" role="group">${["failure", "always", "never"].map((n) =>
      `<button class="${f.notify === n ? "on" : ""}" aria-pressed="${f.notify === n}" data-jaction="jf-set" data-path="notify" data-value="${n}">${jt("n_" + n)}</button>`).join("")}</span>
    <label class="jon"><input type="checkbox" class="jswitch" data-jf="enabled" ${f.enabled ? "checked" : ""}> ${jt("enabled")}</label></div>`;
  const more = `<div class="jmore">${claude ? `
      <div>${jt("m_model", { model, limit })}</div>
      <div title="${esc(jt("quotaQ"))}">${jt("m_quota", { w: num("skipWeekPct", f.skipWeekPct, 0, 100), f: num("skipFiveHourPct", f.skipFiveHourPct, 0, 100) })}
        <span class="jfaint">${esc(quotaNowText(jui.data && jui.data.quota))}</span></div>
      <div>${f.sessionMode === "fresh" ? jt("m_fresh", { mode, n: num("keepSessions", f.keepSessions, 1, 500) })
                                       : jt("m_resume", { mode, n: num("compactAbovePct", f.compactAbovePct, 0, 100) })}
        <span class="jfaint">${jt(f.sessionMode === "fresh" ? "s_freshD" : "s_resumeD")}</span></div>`
    : `<div>${jt("m_limit", { limit })}</div>`}</div>`;

  box.innerHTML = `<div class="jsheet">
    <div class="jhead"><h1>${f.id ? jt("editTitle") : jt("newTitle")}</h1></div>
    ${qrow(jt("q_what"), "", what)}
    ${qrow(jt("q_where"), jt("q_whereS"), where)}
    ${qrow(jt("when"), "", when)}
    ${claude ? qrow(jt("q_can"), jt("q_canS"), can) : ""}
    ${qrow(jt("q_tell"), "", tell)}
    ${qrow(jt("q_more"), jt("q_moreS"), more)}
    ${jui.formError ? `<div class="jwarn">${esc(jui.formError)}</div>` : ""}
    <div class="jsheet-foot">
      <button class="btn ghost" data-jaction="jf-cancel">${jt("cancel")}</button>
      <button class="btn" data-jaction="jf-save" data-run="1">${jt("saveRun")}</button>
      <button class="btn primary" data-jaction="jf-save">${jt("save")}</button>
    </div>
  </div>`;
  box.hidden = false;
}
// The next three times, as chips; or what is wrong with the schedule.
function previewHTML() {
  const p = jui.preview;
  if (!p) return "&nbsp;";
  if (p.problem) return `<span class="jfail">${esc(p.problem)}</span>`;
  return `<span class="jfaint">${jt("nextThree")}</span>${(p.next || []).map((t) => `<span class="jup">${esc(jwhen(t))}</span>`).join("")}`;
}
function schedulePreview() {
  clearTimeout(jui.previewTimer);
  jui.previewTimer = setTimeout(async () => {
    if (!jui.form) return;
    try { jui.preview = await apiObj("job-preview", { schedule: jui.form.schedule }); } catch (e) { jui.preview = { problem: String(e.message || e) }; }
    const el = $("#jf-preview");
    if (el) el.innerHTML = previewHTML();
  }, 250);
}
function setPath(obj, path, value) {
  const parts = path.split(".");
  let o = obj;
  for (const p of parts.slice(0, -1)) o = o[p];
  o[parts[parts.length - 1]] = value;
}
function formInput(el) {
  const f = jui.form;
  if (!f) return;
  const path = el.dataset.jf;
  if (path === "schedule.time") {
    const [h, m] = String(el.value || "").split(":").map(Number);
    if (!isNaN(h) && !isNaN(m)) { f.schedule.hour = h; f.schedule.minute = m; }
  } else if (el.type === "checkbox") {
    setPath(f, path, el.checked);
  } else if (el.type === "radio") {
    if (el.checked) setPath(f, path, el.value);
  } else if (el.dataset.num) {
    const n = Math.round(Number(el.value));
    setPath(f, path, isNaN(n) ? 0 : n);
  } else {
    setPath(f, path, el.value);
  }
  if (path.startsWith("schedule.")) schedulePreview();
  // The session sentence changes with its mode.
  if (path === "sessionMode") drawJobForm();
}
document.addEventListener("input", (ev) => { if (ev.target.dataset && ev.target.dataset.jf) formInput(ev.target); });
document.addEventListener("change", (ev) => {
  const el = ev.target;
  if (!el.dataset) return;
  if (el.dataset.jf) return formInput(el);
  // The schedule menu: "every hour" is every 60 minutes; leaving it for "every few minutes" starts at 30.
  if (el.dataset.jfreq && jui.form) {
    const s = jui.form.schedule;
    const v = el.value;
    if (v === "hourly") { s.kind = "every"; s.everyMinutes = 60; }
    else if (v === "every") { if (s.kind !== "every" || s.everyMinutes === 60) s.everyMinutes = 30; s.kind = "every"; }
    else s.kind = v;
    jui.freq = v;
    drawJobForm();
    schedulePreview();
  }
});

async function saveJobForm(runAfter) {
  const f = jui.form;
  if (!f || jui.saving) return;
  jui.saving = true;
  try {
    const r = await apiObj("job-save", { job: f });
    if (runAfter && r.id) await api("job-run", { id: r.id });
    toast(runAfter ? jt("started") : jt("saved"));
    jui.open = r.id || jui.open;
    closeJobForm();
  } catch (e) {
    jui.formError = String(e.message || e);
    drawJobForm();
    return;
  } finally {
    jui.saving = false;
  }
  setTimeout(() => refresh(true), runAfter ? 600 : 0);
}

// ------------------------------------------------------------------ one run
async function openJobRun(id, run) {
  const m = { type: "jobrun", id, run };
  ui.modal = m;
  const box = $("#modal");
  box.innerHTML = `<div class="panel" role="dialog"><div class="phead"><div class="stitle">${jt("loading")}</div><span style="flex:1"></span>
    <button class="btn small ghost" data-action="close-modal">✕</button></div></div>`;
  box.hidden = false;
  let d;
  try { d = await apiObj("job-detail", { id, run }); } catch (e) { closePeek(); return toast(String(e.message || e), true); }
  if (ui.modal !== m) return;
  m.detail = d;
  const j = d.job || {}, r = d.run || {};
  // The last text step is the reply itself, shown above already.
  const steps = (d.steps || []).filter((s, i, all) => !(i === all.length - 1 && s.kind === "text" && d.reply && d.reply.trim().startsWith(s.text.replace(/…$/, "").trim().slice(0, 200))));
  const meta = [jwhen(r.started), tookText(r), r.turns ? jt("turns", { n: r.turns }) : "", j.kind === "claude" && (r.quotaAfter || r.costUSD != null) ? usageText(r) : "",
                j.kind === "claude" ? (j.model || jt("modelDefault")) : "", j.cwd || ""].filter(Boolean).join(" · ");
  const stepHTML = steps.map((s) => s.kind === "text"
    ? `<li class="jstep text"><div class="md">${markdown(s.text)}</div></li>`
    : `<li class="jstep ${s.error ? "err" : ""}"><div><span class="chip">${esc(s.tool)}</span> <code>${esc(s.input)}</code></div>${s.result ? `<pre>${esc(s.result)}</pre>` : ""}</li>`).join("");
  box.innerHTML = `<div class="panel jrun-panel" role="dialog" aria-label="${esc(j.name)}">
    <div class="phead">
      <div><div class="stitle">${esc(j.name)} <span class="jpill st-${statusClass(r)}">${esc(statusText(r))}</span></div><div class="meta">${esc(meta)}</div></div>
      <span style="flex:1"></span>
      ${d.reply ? `<button class="btn small" data-jaction="copy-reply">${jt("copyReply")}</button>` : ""}
      ${r.sessionId ? `<button class="btn small" data-jaction="convo" data-id="${esc(j.id)}" data-session="${esc(r.sessionId)}" title="${jt("convoTip")}">${jt("convo")}</button>
        <button class="btn small" data-jaction="resume" data-id="${esc(j.id)}" data-session="${esc(r.sessionId)}" title="${jt("resumeTip")}">${jt("cont")}</button>` : ""}
      <button class="btn small" data-jaction="run" data-id="${esc(j.id)}">${jt("runAgain")}</button>
      <button class="btn small ghost" data-action="close-modal" title="Esc">✕</button>
    </div>
    <div class="peek-body jrun-body">
      <h4>${jt("input")}</h4>
      <pre class="jinput">${esc(j.kind === "claude" ? j.prompt : j.command)}</pre>
      <h4>${j.kind === "claude" ? jt("reply") : jt("output")}</h4>
      ${j.kind === "claude"
        ? (d.reply ? `<div class="md jreply">${markdown(d.reply)}</div>` : `<div class="empty">${jt("noReply")}</div>`)
        : `<pre class="jlog">${esc(d.log || "")}</pre>`}
      ${steps.length ? `<details ${isFail(r) ? "" : "open"}><summary>${jt("steps", { n: steps.length })}</summary><ol class="jsteps">${stepHTML}</ol></details>` : ""}
      ${j.kind === "claude" && (d.log || "").trim() ? `<details ${isFail(r) ? "open" : ""}><summary>${jt("log")}</summary><pre class="jlog">${esc(d.log)}</pre></details>` : ""}
    </div>
  </div>`;
}

// ------------------------------------------------------------------ clicks
document.addEventListener("click", async (ev) => {
  const el = ev.target.closest("[data-jaction]");
  if (!el) return;
  const d = el.dataset;
  const job = () => ((jui.data && jui.data.jobs) || []).find((j) => j.id === d.id);
  switch (d.jaction) {
    case "new": return openJobForm(null);
    case "tpl": return openJobForm(jobTemplates()[Number(d.i)]);
    case "edit": return openJobForm(job());
    case "expand": jui.open = jui.open === d.id ? null : d.id; return renderJobsView();
    case "toggle": {
      const j = job();
      try { await api("job-enable", { id: d.id, on: !(j && j.enabled) }); } catch (e) { toast(String(e.message || e), true); }
      return refresh(true);
    }
    case "run":
      try { await api("job-run", { id: d.id }); toast(jt("started")); } catch (e) { return toast(String(e.message || e), true); }
      jui.open = d.id;
      return setTimeout(() => refresh(true), 600);
    case "stop":
      try { await api("job-stop", { id: d.id }); toast(jt("stopping")); } catch (e) { return toast(String(e.message || e), true); }
      return setTimeout(() => refresh(true), 1500);
    case "delete": {
      // Twice, like the rest of the board: the first click arms it for 4 s.
      const key = "del:" + d.id;
      if (jui.armed !== key) {
        jui.armed = key;
        setTimeout(() => { if (jui.armed === key) { jui.armed = null; renderJobsView(); } }, 4000);
        return renderJobsView();
      }
      jui.armed = null;
      try { await api("job-delete", { id: d.id }); toast(jt("deleted")); } catch (e) { toast(String(e.message || e), true); }
      return refresh(true);
    }
    case "detail": return openJobRun(d.id, d.run);
    case "convo": {
      const j = job();
      closePeek();
      return openPeek(d.session, null, { title: (j ? j.name : "") });
    }
    case "resume": {
      const j = job();
      const place = launchPlace() === "bg" ? "terminal" : launchPlace();
      try {
        await api("job-resume", { id: d.id, session: d.session, where: place, skip: skipPerms(), focus: !stayOnBoard() });
        closePeek();
        stayWith(d.session, j ? j.name : "");
      } catch (e) { toast(String(e.message || e), true); }
      return;
    }
    case "copy-reply": {
      const m = ui.modal;
      if (m && m.detail && m.detail.reply) { await api("copy", { text: m.detail.reply }); toast(jt("copied")); }
      return;
    }
    // the form
    case "jf-set": {
      setPath(jui.form, d.path, d.value);
      drawJobForm();
      if (d.path.startsWith("schedule.")) schedulePreview();
      return;
    }
    case "jf-day": {
      const s = jui.form.schedule;
      const n = Number(d.day);
      s.days = s.days.includes(n) ? s.days.filter((x) => x !== n) : [...s.days, n].sort((a, b) => a - b);
      drawJobForm();
      return schedulePreview();
    }
    case "jf-pick": {
      try {
        const r = await apiObj("pick-folder", { path: jui.form.cwd });
        if (r.path) { jui.form.cwd = r.path; drawJobForm(); }
      } catch (e) { toast(String(e.message || e), true); }
      return;
    }
    case "jf-cancel": return closeJobForm();
    case "jf-save": return saveJobForm(Boolean(d.run));
  }
});
