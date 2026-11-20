// The board's Scheduled view: scheduled jobs — a shell command or a Claude prompt on a
// timetable — with their runs. Loaded after board.js and uses its helpers (api, esc, toast,
// markdown, openPeek…). Jobs themselves are kept and run by the app: see JobsController.swift.
//
// Every string here comes from JT, in English and Chinese. The language follows macOS and can be
// switched in the view; the choice is kept under "hq-lang", for the rest of the board to share.

const JT = {
  en: {
    tab: "Scheduled", loading: "Loading…", newJob: "+ New job",
    count: "{n} jobs", on: "{n} on", runningN: "{n} running", failingN: "{n} failing",
    intro: "Jobs made here run on schedule even when the pet is closed. A run missed while the Mac slept runs once when it wakes.",
    noRunner: "Claude Pet's runner (~/.claude/pet/pet-emit) is missing, so jobs can't run. Reinstall Claude Pet.",
    empty: "No scheduled jobs yet. A job runs a Claude prompt or a shell command on a timetable — a morning summary of last night's CI, a reminder to look at your PRs, a cleanup every Sunday.",
    claude: "Claude", shell: "Shell",
    next: "Next", never: "not run yet", paused: "off", runningFor: "running · {d}",
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
    every: "Every {n} min", everyH: "Every {n} h", daily: "Daily {t}", weekdaysAt: "Weekdays {t}", weeklyAt: "{d} {t}",
    cronAt: "cron {c}", daySep: ", ",
    // form
    newTitle: "New scheduled job", editTitle: "Edit job", kindQ: "What it runs",
    kindClaude: "Claude prompt", kindClaudeD: "One claude -p turn in the background; it can use your skills and MCP tools.",
    kindShell: "Shell command", kindShellD: "A command or script; its exit code and output are kept.",
    name: "Name", namePh: "Morning CI summary", cwd: "Folder (it starts here and reads this folder's CLAUDE.md)", choose: "Choose…",
    prompt: "Prompt (sent as written, every run)",
    promptPh: "/my-skill summarise last night's failed CI jobs and list the three things I should look at today",
    promptHelp: "As in the terminal: start with /skill-name to use a skill, or just describe the work and Claude picks one. Your MCP servers, plugins and hooks load as usual.",
    command: "Command (runs in your login shell, with the PATH your terminal has)", model: "Model", modelDefault: "Default",
    perm: "Permissions — nobody is there to click Allow, so decide now",
    p_standard: "Standard", p_standardD: "Only what your Claude Code settings already allow; anything else is refused and noted in the run.",
    p_edits: "Edit files", p_editsD: "May also edit files in the folder; other requests are still refused.",
    p_all: "Everything", p_allD: "Skips every permission check. Only for prompts you fully trust.",
    session: "Session",
    s_fresh: "New session every run", s_freshD: "Clean and cheap; runs don't see each other.",
    s_resume: "Same session every run", s_resumeD: "Each run continues the last one — for work that needs to remember, like \"what's new since last time\".",
    keep: "Keep the newest", keepTail: "runs' sessions on disk (older ones are deleted; 1 = only the latest)",
    compact: "Compact the session first when its context passes", compactTail: "k tokens (0 = never)",
    limit: "Time limit", minutes: "minutes", budget: "Spending limit per run", usd: "USD (0 = none)",
    when: "When it runs", pr_every: "Every N minutes", pr_daily: "Daily", pr_weekdays: "Weekdays", pr_weekly: "Some days", pr_cron: "Cron",
    everyLbl: "Every", minutesLbl: "minutes", at: "at", cronHelp: "minute hour day month weekday",
    nextThree: "Next: {list}", slept: "Missed while the Mac slept? It runs once when it wakes.",
    notify: "The pet tells you", n_failure: "when it fails", n_always: "after every run", n_never: "never",
    enabled: "On", cancel: "Cancel", save: "Save", saveRun: "Save and run now", saved: "Saved", deleted: "Deleted",
    started: "Started", stopping: "Stopping…",
    // run detail
    input: "Input", output: "Output", reply: "Claude's reply", steps: "What it did ({n} steps)", log: "Log",
    noReply: "No reply — see the log.", tool: "tool", refusedTool: "refused", copyReply: "Copy reply", copied: "Copied",
    turns: "{n} turns", turns1: "1 turn", steps1: "What it did (1 step)", runAgain: "Run again", resumeTip: "Open this run's session in a terminal to keep talking to it",
    convoTip: "Read this run's conversation",
  },
  zh: {
    tab: "定时任务", loading: "加载中…", newJob: "+ 新建定时任务",
    count: "{n} 个任务", on: "{n} 个开着", runningN: "{n} 个在跑", failingN: "{n} 个最近失败",
    intro: "在这里建的任务按时运行，猫关着也照跑。Mac 睡着时错过的那次，醒来后补跑一次。",
    noRunner: "找不到 Claude Pet 的执行程序（~/.claude/pet/pet-emit），任务跑不起来。请重新安装 Claude Pet。",
    empty: "还没有定时任务。定时任务按时间表跑一段 Claude prompt 或一条 Shell 命令——比如每天早上汇总昨晚的 CI、每小时看看 PR 有没有新评论、每周日清一次缓存。",
    claude: "Claude", shell: "Shell",
    next: "下次", never: "还没跑过", paused: "已关闭", runningFor: "运行中 · {d}",
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
    every: "每 {n} 分钟", everyH: "每 {n} 小时", daily: "每天 {t}", weekdaysAt: "工作日 {t}", weeklyAt: "每{d} {t}",
    cronAt: "cron {c}", daySep: "、",
    newTitle: "新建定时任务", editTitle: "编辑定时任务", kindQ: "要定时做的事",
    kindClaude: "Claude prompt", kindClaudeD: "在后台用 claude -p 跑一轮，可以用你的技能和 MCP 工具。",
    kindShell: "Shell 命令", kindShellD: "跑一条命令或脚本，记下退出码和输出。",
    name: "名称", namePh: "早报：昨晚 CI 失败汇总", cwd: "工作目录（从这里启动，会读这里的 CLAUDE.md）", choose: "选择…",
    prompt: "Prompt（每次运行时原样发给 Claude）",
    promptPh: "/my-skill 汇总昨晚失败的 CI job，列出今天要我看的 3 件事",
    promptHelp: "和在终端里一样：开头写 /技能名 就调用那个技能；不写也行，Claude 会按描述自己挑。你的 MCP 服务器、插件、hooks 照常加载。",
    command: "命令（用你的登录 shell 跑，PATH 和终端里一样）", model: "模型", modelDefault: "默认",
    perm: "权限——跑的时候没人点「允许」，所以先说好能做什么",
    p_standard: "标准", p_standardD: "只用你在 Claude Code 设置里已经允许的；其他操作一律拒绝，并记在运行结果里。",
    p_edits: "允许改文件", p_editsD: "还可以改工作目录里的文件；其他需要批准的仍然拒绝。",
    p_all: "全部允许", p_allD: "跳过所有权限检查。只给你完全信任的 prompt 用。",
    session: "Session",
    s_fresh: "每次新开一个 session", s_freshD: "干净、便宜，每次互不影响。",
    s_resume: "每次接着同一个 session", s_resumeD: "每次接着上一次往下聊——适合需要记住上次的任务，比如「跟上次比有什么新的」。",
    keep: "保留最近", keepTail: "次运行的 session（更早的删掉；填 1 就只留最新一次）",
    compact: "上下文超过", compactTail: "k token 时先压缩（0 = 不压缩）",
    limit: "单次最长", minutes: "分钟", budget: "单次花费上限", usd: "美元（0 = 不限）",
    when: "什么时候跑", pr_every: "每隔 N 分钟", pr_daily: "每天", pr_weekdays: "工作日", pr_weekly: "每周几", pr_cron: "cron 表达式",
    everyLbl: "每", minutesLbl: "分钟", at: "时间", cronHelp: "分 时 日 月 周",
    nextThree: "接下来：{list}", slept: "Mac 睡着时错过的那次，醒来后补跑一次。",
    notify: "猫什么时候提醒你", n_failure: "失败时", n_always: "每次跑完", n_never: "不提醒",
    enabled: "打开", cancel: "取消", save: "保存", saveRun: "保存并立即运行", saved: "已保存", deleted: "已删除",
    started: "已开始", stopping: "正在停止…",
    input: "输入", output: "输出", reply: "Claude 的回复", steps: "过程（{n} 步）", log: "日志",
    noReply: "没有回复——看看日志。", tool: "工具", refusedTool: "被拒绝", copyReply: "复制回复", copied: "已复制",
    turns: "{n} 轮", runAgain: "再跑一次", resumeTip: "在终端里打开这次运行的 session，接着跟它聊",
    convoTip: "看这次运行的完整对话",
  },
};

function jlang() {
  const p = pref("hq-lang", "");
  if (p === "en" || p === "zh") return p;
  return /^zh/i.test(navigator.language || "") ? "zh" : "en";
}
function jt(key, vars) {
  // English has a singular; Chinese doesn't need one.
  if (vars && vars.n === 1 && JT[jlang()][key + "1"]) key += "1";
  let s = JT[jlang()][key] ?? JT.en[key] ?? key;
  if (vars) for (const k of Object.keys(vars)) s = s.split("{" + k + "}").join(String(vars[k]));
  return s;
}

const jui = { data: null, open: null, form: null, preview: null, previewTimer: null, armed: null, error: "" };

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
    case "every": return s.everyMinutes % 60 === 0 && s.everyMinutes >= 60 ? jt("everyH", { n: s.everyMinutes / 60 }) : jt("every", { n: s.everyMinutes });
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
const tookText = (r) => r.ended ? jdur((new Date(r.ended) - new Date(r.started)) / 1000) : r.status === "running" ? jdur((Date.now() - new Date(r.started)) / 1000) : "—";
const costText = (r) => (r.costUSD != null ? "$" + r.costUSD.toFixed(r.costUSD < 0.1 ? 3 : 2) : "—");

// ------------------------------------------------------------------ the view
function renderJobsView() {
  const d = jui.data;
  const top = $("#jobs-top");
  const box = $("#jobs-list");
  if (!d) { top.innerHTML = ""; box.innerHTML = `<div class="empty">${jt("loading")}</div>`; return; }
  const jobs = d.jobs || [];
  const nOn = jobs.filter((j) => j.enabled).length;
  const nRun = jobs.filter((j) => j.running).length;
  const nFail = jobs.filter((j) => isFail(lastReal(j))).length;
  top.innerHTML = `<div class="jobs-bar">
      <span class="jcounts"><b>${jt("count", { n: jobs.length })}</b> · ${jt("on", { n: nOn })}${nRun ? ` · <span class="jrun">${jt("runningN", { n: nRun })}</span>` : ""}${nFail ? ` · <span class="jfail">${jt("failingN", { n: nFail })}</span>` : ""}</span>
      <span class="spacer"></span>
      <span class="seg" role="group" aria-label="Language">
        <button class="${jlang() === "en" ? "on" : ""}" data-jaction="lang" data-lang="en">EN</button><button class="${jlang() === "zh" ? "on" : ""}" data-jaction="lang" data-lang="zh">中文</button>
      </span>
      <button class="btn primary" data-jaction="new">${jt("newJob")}</button>
    </div>
    <div class="meta jintro">${jt("intro")}</div>
    ${d.runner === false ? `<div class="jwarn">${jt("noRunner")}</div>` : ""}
    ${jui.error ? `<div class="jwarn">${esc(jui.error)}</div>` : ""}`;
  box.innerHTML = !jobs.length ? (jui.form ? "" : `<div class="card jempty">${jt("empty")}</div>`) : jobs.map(jobCard).join("");
  // Looking at the view is seeing its failures: the pet stops counting them.
  const seen = new Date(d.seenAt || 0).getTime();
  if (jobs.some((j) => { const r = lastReal(j); return isFail(r) && new Date(r.ended || 0).getTime() > seen; })
      && document.visibilityState === "visible") {
    d.seenAt = new Date().toISOString();
    api("job-seen").catch(() => {});
  }
}

function jobCard(j) {
  const runs = j.runs || [];
  const running = runs[0] && runs[0].status === "running" ? runs[0] : null;
  const last = lastReal(j);
  const dot = !j.enabled ? "off" : running ? "run" : isFail(last) ? "fail" : last ? "ok" : "none";
  const squares = runs.slice(0, 12).reverse();
  while (squares.length < 12) squares.unshift(null);
  const lastLine = running ? jt("runningFor", { d: tookText(running) })
    : last ? `${jwhen(last.started)} · ${statusText(last)} · ${tookText(last)}${last.costUSD != null ? " · " + costText(last) : ""}` : jt("never");
  const open = jui.open === j.id;
  const armed = jui.armed === "del:" + j.id;
  const kind = j.kind === "shell" ? jt("shell") : jt("claude");
  return `<section class="card job ${j.enabled ? "" : "disabled"}">
    <div class="jrow">
      <button class="jname" data-jaction="expand" data-id="${esc(j.id)}" aria-expanded="${open}">
        <span class="jdot ${dot}"></span>
        <span class="jtitle"><span class="stitle">${esc(j.name)}</span> <span class="chip">${kind}</span>
          <span class="meta">${esc(scheduleText(j.schedule))} · ${esc(j.cwd || "~")}</span></span>
      </button>
      <div class="jlast">
        <div class="jsquares" aria-label="recent runs">${squares.map((r) => `<span class="sq ${statusClass(r)}" title="${r ? esc(jwhen(r.started) + " · " + statusText(r)) : ""}"></span>`).join("")}</div>
        <div class="meta ${isFail(last) && !running ? "jfail" : ""}">${esc(lastLine)}</div>
      </div>
      <div class="jnext"><div class="meta">${jt("next")}</div><div>${j.enabled ? esc(j.next && j.next[0] ? jwhen(j.next[0]) : "—") : jt("paused")}</div></div>
      <div class="jbtns">
        <button class="switch ${j.enabled ? "on" : ""}" role="switch" aria-checked="${j.enabled}" data-jaction="toggle" data-id="${esc(j.id)}" title="${j.enabled ? jt("toggleOff") : jt("toggleOn")}"><span></span></button>
        ${running ? `<button class="btn small danger" data-jaction="stop" data-id="${esc(j.id)}">${jt("stop")}</button>`
                  : `<button class="btn small" data-jaction="run" data-id="${esc(j.id)}">${jt("runNow")}</button>`}
        <button class="btn small ghost" data-jaction="edit" data-id="${esc(j.id)}">${jt("edit")}</button>
        <button class="btn small ghost ${armed ? "armed" : ""}" data-jaction="delete" data-id="${esc(j.id)}">${armed ? jt("delSure") : jt("del")}</button>
      </div>
    </div>
    ${isFail(last) && !running && last.tail ? `<div class="jalert"><div class="meta">${jt("lastLines")}</div><pre>${esc(last.tail)}</pre></div>` : ""}
    ${open ? historyTable(j) : ""}
  </section>`;
}

function historyTable(j) {
  const runs = j.runs || [];
  if (!runs.length) return `<div class="jhist"><div class="empty">${jt("never")}</div></div>`;
  return `<div class="jhist"><div class="meta">${jt("history")}</div><div class="jtable-wrap"><table class="jtable">
    <thead><tr><th>${jt("hStart")}</th><th>${jt("hResult")}</th><th>${jt("hTook")}</th>${j.kind === "claude" ? `<th>${jt("hCost")}</th>` : ""}<th>${jt("hSummary")}</th><th></th></tr></thead>
    <tbody>${runs.map((r) => `<tr>
      <td class="nowrap">${esc(jwhen(r.started))}${r.trigger === "manual" ? ` <span class="chip">${jt("manual")}</span>` : ""}</td>
      <td class="nowrap st-${statusClass(r)}">${esc(statusText(r))}</td>
      <td class="nowrap">${esc(tookText(r))}</td>
      ${j.kind === "claude" ? `<td class="nowrap">${esc(costText(r))}</td>` : ""}
      <td class="jsum">${esc(r.summary || "")}</td>
      <td class="nowrap jacts">${r.status === "skipped" ? "" : `<button class="btn small ghost" data-jaction="detail" data-id="${esc(j.id)}" data-run="${esc(r.id)}">${jt("details")}</button>`}
        ${r.sessionId ? `<button class="btn small ghost" data-jaction="convo" data-id="${esc(j.id)}" data-session="${esc(r.sessionId)}" title="${jt("convoTip")}">${jt("convo")}</button>
        <button class="btn small ghost" data-jaction="resume" data-id="${esc(j.id)}" data-session="${esc(r.sessionId)}" title="${jt("resumeTip")}">${jt("cont")}</button>` : ""}</td>
    </tr>`).join("")}</tbody></table></div></div>`;
}

// ------------------------------------------------------------------ the form
const JOB_DEFAULTS = () => ({
  name: "", kind: "claude", prompt: "", command: "", cwd: "~", enabled: true,
  schedule: { kind: "weekdays", everyMinutes: 60, hour: 9, minute: 0, days: [1], cron: "0 9 * * 1-5" },
  model: "", permission: "standard", timeoutMinutes: 20, maxBudgetUSD: 0,
  sessionMode: "fresh", keepSessions: 20, compactAboveK: 100, notify: "failure",
});

function openJobForm(job) {
  const f = JOB_DEFAULTS();
  if (job) {
    for (const k of Object.keys(f)) if (job[k] !== undefined) f[k] = JSON.parse(JSON.stringify(job[k]));
    f.id = job.id;
  }
  jui.form = f;
  jui.formError = "";
  jui.preview = null;
  drawJobForm();
  schedulePreview();
  const n = $("#jf-name");
  if (n) n.focus();
  $("#job-form").scrollIntoView({ block: "nearest" });
}
function closeJobForm() {
  jui.form = null;
  $("#job-form").hidden = true;
  $("#job-form").innerHTML = "";
  renderJobsView();
}

function choice(path, value, label, desc, current) {
  const on = current === value;
  return `<button class="jchoice ${on ? "on" : ""}" aria-pressed="${on}" data-jaction="jf-set" data-path="${path}" data-value="${esc(value)}">
    <b>${label}</b>${desc ? `<span class="meta">${desc}</span>` : ""}</button>`;
}
function drawJobForm() {
  const f = jui.form;
  const box = $("#job-form");
  if (!f) { box.hidden = true; return; }
  const s = f.schedule;
  const presets = ["every", "daily", "weekdays", "weekly", "cron"];
  const dayNames = JT[jlang()].days;
  const time = `${pad2(s.hour)}:${pad2(s.minute)}`;
  box.innerHTML = `<div class="card jform">
    <h3>${f.id ? jt("editTitle") : jt("newTitle")}</h3>
    <div class="jlabel">${jt("kindQ")}</div>
    <div class="jchoices">${choice("kind", "claude", jt("kindClaude"), jt("kindClaudeD"), f.kind)}${choice("kind", "shell", jt("kindShell"), jt("kindShellD"), f.kind)}</div>
    <div class="jgrid2">
      <label><span class="jlabel">${jt("name")}</span><input id="jf-name" type="text" data-jf="name" value="${esc(f.name)}" placeholder="${esc(jt("namePh"))}"></label>
      <label><span class="jlabel">${jt("cwd")}</span><span class="jinline"><input type="text" data-jf="cwd" value="${esc(f.cwd)}"><button class="btn small" data-jaction="jf-pick">${jt("choose")}</button></span></label>
    </div>
    ${f.kind === "claude" ? `
      <label class="jblock"><span class="jlabel">${jt("prompt")}</span>
        <textarea rows="4" data-jf="prompt" placeholder="${esc(jt("promptPh"))}">${esc(f.prompt)}</textarea></label>
      <div class="meta">${jt("promptHelp")}</div>
      <div class="jgrid3">
        <label><span class="jlabel">${jt("model")}</span><select data-jf="model">
          ${[["", jt("modelDefault")], ["sonnet", "Sonnet"], ["opus", "Opus"], ["haiku", "Haiku"]].map(([v, l]) => `<option value="${v}" ${f.model === v ? "selected" : ""}>${l}</option>`).join("")}
          ${f.model && !["sonnet", "opus", "haiku"].includes(f.model) ? `<option value="${esc(f.model)}" selected>${esc(f.model)}</option>` : ""}
        </select></label>
        <label><span class="jlabel">${jt("limit")}</span><span class="jinline"><input type="number" min="1" max="1440" data-jf="timeoutMinutes" data-num="1" value="${f.timeoutMinutes}"> ${jt("minutes")}</span></label>
        <label><span class="jlabel">${jt("budget")}</span><span class="jinline"><input type="number" min="0" step="0.5" data-jf="maxBudgetUSD" data-num="1" value="${f.maxBudgetUSD}"> ${jt("usd")}</span></label>
      </div>
      <div class="jlabel">${jt("perm")}</div>
      <div class="jchoices">${["standard", "edits", "all"].map((p) => choice("permission", p, jt("p_" + p), jt("p_" + p + "D"), f.permission)).join("")}</div>
      <div class="jlabel">${jt("session")}</div>
      <div class="jchoices">${choice("sessionMode", "fresh", jt("s_fresh"), jt("s_freshD"), f.sessionMode)}${choice("sessionMode", "resume", jt("s_resume"), jt("s_resumeD"), f.sessionMode)}</div>
      <div class="jinline">${f.sessionMode === "fresh"
        ? `${jt("keep")} <input type="number" min="1" max="500" class="short" data-jf="keepSessions" data-num="1" value="${f.keepSessions}"> ${jt("keepTail")}`
        : `${jt("compact")} <input type="number" min="0" class="short" data-jf="compactAboveK" data-num="1" value="${f.compactAboveK}"> ${jt("compactTail")}`}</div>
    ` : `
      <label class="jblock"><span class="jlabel">${jt("command")}</span>
        <textarea rows="3" class="mono" data-jf="command">${esc(f.command)}</textarea></label>
      <label class="jinline"><span class="jlabel">${jt("limit")}</span><input type="number" min="1" max="1440" class="short" data-jf="timeoutMinutes" data-num="1" value="${f.timeoutMinutes}"> ${jt("minutes")}</label>
    `}
    <div class="jwhen">
      <div class="jlabel">${jt("when")}</div>
      <div class="seg jpresets">${presets.map((p) => `<button class="${s.kind === p ? "on" : ""}" data-jaction="jf-set" data-path="schedule.kind" data-value="${p}">${jt("pr_" + p)}</button>`).join("")}</div>
      <div class="jinline">
        ${s.kind === "every" ? `${jt("everyLbl")} <input type="number" min="1" class="short" data-jf="schedule.everyMinutes" data-num="1" value="${s.everyMinutes}"> ${jt("minutesLbl")}` : ""}
        ${s.kind === "weekly" ? `<span class="jdays">${[1, 2, 3, 4, 5, 6, 7].map((n) => `<button class="${(s.days || []).includes(n) ? "on" : ""}" aria-pressed="${(s.days || []).includes(n)}" data-jaction="jf-day" data-day="${n}">${esc(dayNames[n % 7])}</button>`).join("")}</span>` : ""}
        ${["daily", "weekdays", "weekly"].includes(s.kind) ? `${jt("at")} <input type="time" data-jf="schedule.time" value="${time}">` : ""}
        ${s.kind === "cron" ? `<input type="text" class="mono" data-jf="schedule.cron" value="${esc(s.cron)}"> <span class="meta">${jt("cronHelp")}</span>` : ""}
      </div>
      <div id="jf-preview" class="meta">${previewText()}</div>
      <div class="meta">${jt("slept")}</div>
    </div>
    <div class="jinline"><span class="jlabel">${jt("notify")}</span>
      ${["failure", "always", "never"].map((n) => `<label class="jradio"><input type="radio" name="jf-notify" data-jf="notify" value="${n}" ${f.notify === n ? "checked" : ""}> ${jt("n_" + n)}</label>`).join("")}
      <label class="jradio"><input type="checkbox" data-jf="enabled" ${f.enabled ? "checked" : ""}> ${jt("enabled")}</label>
    </div>
    ${jui.formError ? `<div class="jwarn">${esc(jui.formError)}</div>` : ""}
    <div class="jfoot">
      <button class="btn ghost" data-jaction="jf-cancel">${jt("cancel")}</button>
      <button class="btn" data-jaction="jf-save" data-run="1">${jt("saveRun")}</button>
      <button class="btn primary" data-jaction="jf-save">${jt("save")}</button>
    </div>
  </div>`;
  box.hidden = false;
}
function previewText() {
  const p = jui.preview;
  if (!p) return "&nbsp;";
  if (p.problem) return `<span class="jfail">${esc(p.problem)}</span>`;
  return esc(jt("nextThree", { list: (p.next || []).map(jwhen).join(" · ") }));
}
function schedulePreview() {
  clearTimeout(jui.previewTimer);
  jui.previewTimer = setTimeout(async () => {
    if (!jui.form) return;
    try { jui.preview = await apiObj("job-preview", { schedule: jui.form.schedule }); } catch (e) { jui.preview = { problem: String(e.message || e) }; }
    const el = $("#jf-preview");
    if (el) el.innerHTML = previewText();
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
    const n = Number(el.value);
    setPath(f, path, isNaN(n) ? 0 : n);
  } else {
    setPath(f, path, el.value);
  }
  if (path.startsWith("schedule.")) schedulePreview();
}
document.addEventListener("input", (ev) => { if (ev.target.dataset && ev.target.dataset.jf) formInput(ev.target); });
document.addEventListener("change", (ev) => { if (ev.target.dataset && ev.target.dataset.jf) formInput(ev.target); });

async function saveJobForm(runAfter) {
  const f = jui.form;
  if (!f) return;
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
  const meta = [jwhen(r.started), tookText(r), r.turns ? jt("turns", { n: r.turns }) : "", r.costUSD != null ? costText(r) : "",
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
    case "lang": savePref("hq-lang", d.lang); if (jui.form) drawJobForm(); return renderJobsView();
    case "new": return openJobForm(null);
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
