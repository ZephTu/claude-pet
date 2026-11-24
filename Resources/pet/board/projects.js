// The board's Projects & duties page, and the ＋ New window. Loaded after board.js and jobs.js and
// uses their helpers (api, act, esc, T, toast, render, refresh, markdown, laneCol, kcard,
// loadJobs, scheduleText, jwhen…).
//
// Two kinds of project sit at the top (PROJECT.md `kind:`): a goal (◆) has an end — done-when
// criteria, a deadline, optional phases its tasks go through; a duty (↻) is ongoing — healthy-when
// criteria, and work that comes in: tasks made from its templates ("常见的活"), recurring jobs that
// make them on a timetable ("定期来活"), and sources that will make them by themselves ("自动来活",
// switches only until the data side lands). A goal can sit under a duty. Tasks in no project are
// "Not in a project".
//
// ui.proj: "" the list page, a project's name its page, "(none)" the tasks in no project.
// Buttons here carry data-action="p-…"; board.js's click handler (which does the two-click
// confirms) hands them to projAction().

ui.proj = pref("hq-proj", "");
// Which part of a project's page is being edited ("<name>|<part>"), and whose recurring-job form
// is open.
const pui = { edit: null, recur: null, doneAll: new Set(), closedOpen: false, busy: false };

const AUTO_SOURCES = [
  ["qahub-ci", T("QA Hub CI failures", "QA Hub 的 CI 失败"), T("a failed CI job of yours becomes a task", "你的 CI job 失败了就建一个任务")],
  ["github-review", T("GitHub review requests", "GitHub 上请你 review"), T("a PR waiting on your review becomes a task", "有 PR 等你 review 就建一个任务")],
  ["jira-filter", T("Jira filter", "Jira 过滤器"), T("a new issue in your filter becomes a task", "过滤器里出现新 issue 就建一个任务")],
];
const projTasks = (name) => listed().filter((t) => (t.project || "") === name);
const projLabel = (pr, name) => (pr && pr.title) || name;
const goalsUnder = (name) => projects().filter((p) => p.defined && p.kind === "goal" && p.parent === name);
const recurJobs = (name) => ((typeof jui !== "undefined" && jui.data && jui.data.jobs) || []).filter((j) => j.recur && j.recur.project === name);
const nextRecur = (name) => recurJobs(name).filter((j) => j.enabled && (j.next || [])[0]).map((j) => j.next[0]).sort()[0] || "";
const ptitle = (name) => { const pr = projectByName(name); return projLabel(pr, name); };

function goToProject(name) {
  grabLaneScrolls();   // under the page being left, before ui.proj names the next one
  ui.mode = "projects"; savePref("hq-mode", "projects");
  ui.proj = name || ""; savePref("hq-proj", ui.proj);
  ui.drawer = null;
  if (ui.modal) closePeek();
  pui.edit = null; pui.recur = null;
  refresh(true);
}
window.hqShowProject = goToProject;

// The four lanes' counts of a set of open tasks: {you, run, ready, blocked}.
function laneCounts(ts) {
  const n = { you: 0, run: 0, ready: 0, blocked: 0 };
  for (const t of ts) { const l = lane(t); if (l in n) n[l]++; }
  return n;
}
const laneBar = (n) => { const total = LANES.reduce((s, l) => s + n[l], 0);
  return `<div class="lbar">${total ? LANES.filter((l) => n[l]).map((l) => `<i class="l-${l}" style="flex:${n[l]}"></i>`).join("") : ""}</div>`; };
const laneNums = (n) => `<div class="lcs">${LANES.map((l) => `<span class="lc l-${l} ${n[l] ? "" : "none"}" title="${esc(LANE_HINT[l])}"><i></i>${n[l]} ${LANE_NAME[l]}</span>`).join("")}</div>`;
// A goal's progress: its criteria ticked when it has some, else its tasks done.
function progress(pr) {
  const crit = pr.criteria || [];
  if (pr.kind === "goal" && crit.length) {
    const d = crit.filter((c) => c.done).length;
    return { d, n: crit.length, what: T(`${d} of ${crit.length} done-when ticked`, `完成标准 ${crit.length} 条达成 ${d} 条`) };
  }
  const st = pr.stats || {};
  const n = (st.open || 0) + (st.done || 0);
  return { d: st.done || 0, n, what: T(`${st.done || 0} of ${n} tasks done`, `${n} 个任务完成了 ${st.done || 0} 个`) };
}
const bigProg = (p) => (p.n ? `<div class="bigprog" title="${esc(p.what)}"><span class="bar"><i style="width:${Math.round(100 * p.d / p.n)}%"></i></span>${p.d}/${p.n}</div>` : "");

// ------------------------------------------------------------------ the list
function projCard(pr, underParent) {
  const open = projTasks(pr.name).filter(isOpen);
  const n = laneCounts(open);
  const st = pr.stats || {};
  const crit = pr.criteria || [];
  const kv = [];
  if (pr.kind === "goal") {
    if (crit.length) kv.push(`${T("done when", "完成标准")} <b>${crit.filter((c) => c.done).length}/${crit.length}</b>`);
    if (pr.due && !projectClosed(pr)) kv.push(dueText(pr.due));
    if (pr.parent && !underParent) kv.push(`<span>↻ ${esc(ptitle(pr.parent))}</span>`);
    if ((pr.phases || []).length) kv.push(`${T("phases", "阶段")} <b>${pr.phases.length}</b>`);
  } else {
    kv.push(`${T("done this week", "本周完成")} <b>${st.done_7d || 0}</b>`);
    if (crit.length) kv.push(`${T("healthy when", "健康标准")} <b>${crit.length}</b>`);
    const nx = nextRecur(pr.name);
    if (nx) kv.push(`${T("next ↻", "下次来活")} <b>${esc(jwhen(nx))}</b>`);
    const kids = goalsUnder(pr.name).length;
    if (kids) kv.push(`◆ <b>${kids}</b>`);
  }
  const tpls = pr.kind === "duty" ? (pr.templates || []) : [];
  return `<div class="pcard k-${esc(pr.kind)} ${projectClosed(pr) ? "closed" : ""}" data-action="p-open" data-p="${esc(pr.name)}" title="${T("Open its page", "打开它的页面")}">
    <div class="pt">${kindIcon(pr)}<span class="nm">${esc(projLabel(pr, pr.name))}</span>
      <span class="st s-${esc(pr.status || "active")}">${PSTATUS_LABEL[pr.status] || esc(pr.status || "")}</span></div>
    ${pr.goal ? `<div class="pg">${esc(pr.goal.replace(/\s+/g, " "))}</div>` : `<div class="pg none">${pr.kind === "duty" ? T("No scope written yet", "还没写职责范围") : T("No goal written yet", "还没写目标")}</div>`}
    ${pr.kind === "goal" ? bigProg(progress(pr)) : ""}
    ${open.length ? laneBar(n) + laneNums(n) : `<div class="lcs"><span class="lc none">${T("No open tasks", "没有进行中的任务")}</span></div>`}
    ${kv.length ? `<div class="kv">${kv.join("")}</div>` : ""}
    ${tpls.length ? `<div class="tplchips">${tpls.map((x) => `<button class="tplchip" data-action="p-tpl-new" data-p="${esc(pr.name)}" data-t="${esc(x.name)}" title="${T("Make a task from this template now", "用这个模板马上建一个任务")}${x.title ? ": " + esc(x.title) : ""}">＋ ${esc(x.name)}</button>`).join("")}</div>` : ""}
  </div>`;
}
const addCard = (kind) => `<button class="pcard add" data-action="p-create" data-k="${kind}">${kind === "goal" ? T("＋ New project", "＋ 新项目") : T("＋ New duty", "＋ 新职责")}
  <span>${kind === "goal" ? T("Something with an end: a goal, done-when, maybe a deadline and phases", "有终点的事：目标、完成标准，可以有截止日期和阶段")
    : T("Something you keep looking after: work comes in from time to time", "长期负责的事：时不时会来活")}</span></button>`;

function projList() {
  const all = projects();
  const f = filterText();
  const match = (pr) => !f || [pr.name, pr.title, pr.goal].join(" ").toLowerCase().includes(f);
  const live = (kind) => all.filter((p) => p.defined && p.kind === kind && !projectClosed(p) && match(p));
  const goals = live("goal"), duties = live("duty");
  const closed = all.filter((p) => projectClosed(p) && match(p));
  const untyped = all.filter((p) => !p.kind && match(p));
  const loose = listed().filter((t) => isOpen(t) && !t.project);
  const sec = (icon, kind, title, sub, n) => `<div class="sec-h k-${kind}">${icon ? `<i class="ki ${kind}">${icon}</i>` : ""}${title}<span class="c">${n}</span><span class="sub">${sub}</span></div>`;
  let html = `<div class="vhead"><h1>${T("Projects & duties", "项目与职责")}</h1>
      <span class="meta">${T(`${goals.length} projects · ${duties.length} duties`, `${goals.length} 个项目 · ${duties.length} 个职责`)}</span><span class="spacer"></span>
      <button class="btn small" data-action="p-create" data-k="goal">${T("＋ New project", "＋ 新项目")}</button>
      <button class="btn small" data-action="p-create" data-k="duty">${T("＋ New duty", "＋ 新职责")}</button></div>`;
  html += sec("◆", "goal", T("Projects", "项目"), T("have an end — a goal, done-when, tasks under them", "有终点——目标、完成标准、下面挂任务"), goals.length) +
    `<div class="pgrid">${goals.map((x) => projCard(x)).join("")}${f ? "" : addCard("goal")}</div>`;
  html += sec("↻", "duty", T("Duties", "职责"), T("ongoing — work comes in from time to time", "长期负责——时不时来活"), duties.length) +
    `<div class="pgrid">${duties.map((x) => projCard(x)).join("")}${f ? "" : addCard("duty")}</div>`;
  if (untyped.length) {
    html += sec("", "none", T("Not set up yet", "还没定类型"), T("listed projects without a PROJECT.md kind — say what each one is", "列表里有、但还没说是项目还是职责的"), untyped.length) +
      `<div class="plist">${untyped.map((p) => `<div class="prow"><span class="nm link" data-action="p-open" data-p="${esc(p.name)}">${esc(projLabel(p, p.name))}</span>
        <span class="meta">${T(`${projTasks(p.name).filter(isOpen).length} open`, `${projTasks(p.name).filter(isOpen).length} 个进行中`)}</span><span class="spacer"></span>
        <button class="btn small" data-action="p-kind" data-p="${esc(p.name)}" data-k="goal">${T("◆ It's a project", "◆ 设为项目")}</button>
        <button class="btn small" data-action="p-kind" data-p="${esc(p.name)}" data-k="duty">${T("↻ It's a duty", "↻ 设为职责")}</button></div>`).join("")}</div>`;
  }
  html += `<div class="sec-h">${T("Not in a project", "未归属")}<span class="sub">${T("one-off tasks", "零散任务")}</span></div>
    <div class="plist"><div class="prow link" data-action="p-open" data-p="(none)"><span class="nm">${T(`${loose.length} open task${loose.length === 1 ? "" : "s"} in no project`, `${loose.length} 个进行中的任务没有归属`)}</span><span class="spacer"></span><span class="meta">${T("Open ›", "打开 ›")}</span></div></div>`;
  if (closed.length) {
    html += `<div class="sec-h fold ${pui.closedOpen ? "open" : ""}" data-action="p-closed">${T("Finished", "已结束")}<span class="c">${closed.length}</span><span class="sub">${pui.closedOpen ? T("click to fold", "点击收起") : T("click to show", "点击展开")}</span></div>
      ${pui.closedOpen ? `<div class="pgrid">${closed.map((x) => projCard(x)).join("")}</div>` : ""}`;
  }
  return html;
}

// ------------------------------------------------------------------ a project's page
const editing = (name, part) => pui.edit === name + "|" + part;
const editBtn = (name, part) => `<button class="icon pe" data-action="p-edit" data-p="${esc(name)}" data-part="${part}" title="${T("Edit", "编辑")}">✎</button>`;
// A textarea editing one PROJECT.md section in place, its draft kept under pe:<name>:<part>.
function sectionEditor(name, part, hint) {
  return `<textarea class="grow pedit" data-key="pe:${esc(name)}:${part}" rows="4" placeholder="${esc(hint || "")}">${esc(draft(`pe:${name}:${part}`))}</textarea>
    <div class="row pe-acts"><span class="meta">${T("Markdown; saved into PROJECT.md", "Markdown，存进 PROJECT.md")}</span><span class="spacer"></span>
      <button class="btn small ghost" data-action="p-cancel">${T("Cancel", "取消")}</button>
      <button class="btn small primary" data-action="p-save" data-p="${esc(name)}" data-part="${part}">${T("Save", "保存")}</button></div>`;
}
function infoSec(name, part, title, body, hint) {
  return `<section class="pi-sec"><h4>${title}${part ? editBtn(name, part) : ""}</h4>${part && editing(name, part) ? sectionEditor(name, part, hint) : body}</section>`;
}
const mdOr = (text, none) => (text ? `<div class="md">${markdown(text)}</div>` : `<div class="empty">${none}</div>`);

function criteriaHTML(pr) {
  const crit = pr.criteria || [];
  if (!crit.length) return `<div class="empty">${T("None yet. A line each — what has to be true.", "还没有。一行一条——什么样算达成。")}</div>`;
  if (pr.kind === "duty") return crit.map((c) => `<div class="crit"><span class="sig"></span><span>${esc(c.text)}</span></div>`).join("");
  return crit.map((c) => `<div class="crit"><span class="box ${c.done ? "done" : ""}" data-action="p-check" data-p="${esc(pr.name)}" data-i="${c.i}" data-done="${c.done ? "" : "1"}"
      title="${c.done ? T("Ticked — click to untick", "已达成——点击取消") : T("Tick it when it holds", "达成了就勾上")}">${c.done ? "✓" : ""}</span><span class="${c.done ? "dim" : ""}">${esc(c.text)}</span></div>`).join("");
}
const META_KEYS = (pr) => pr.kind === "duty" ? ["title", "jira"] : ["title", "due", "parent", "phases", "jira", "fixVersions"];
const META_LABEL = { title: T("Title", "标题"), due: T("Due", "截止"), parent: T("Under duty", "归在职责下"), phases: T("Phases", "阶段"), jira: "Jira", fixVersions: "Fix versions" };
const metaVal = (pr, k) => (Array.isArray(pr[k]) ? pr[k].join(", ") : pr[k] || "");
function metaHTML(pr) {
  const name = pr.name;
  if (editing(name, "meta")) {
    const duties = projects().filter((p) => p.defined && p.kind === "duty" && p.name !== name);
    const v = (k) => draft(`pm:${name}:${k}`);
    const inp = (k) => k === "parent"
      ? `<select data-key="pm:${esc(name)}:parent"><option value="">${T("(none)", "（不归）")}</option>${duties.map((d) => `<option value="${esc(d.name)}" ${v("parent") === d.name ? "selected" : ""}>↻ ${esc(projLabel(d, d.name))}</option>`).join("")}</select>`
      : `<input data-key="pm:${esc(name)}:${k}" ${k === "due" ? `type="date"` : ""} value="${esc(v(k))}" placeholder="${k === "phases" ? T("Design, Build, Ship", "设计, 开发, 上线") : k === "jira" ? "PROJ-123, PROJ-456" : ""}">`;
    return `<div class="pmeta-form">${META_KEYS(pr).map((k) => `<div class="field"><label>${META_LABEL[k]}</label>${inp(k)}</div>`).join("")}
      ${pr.kind === "goal" ? `<div class="meta">${T("Phases: comma separated, in order; tasks pick one", "阶段：逗号隔开，按先后；任务从中选一个")}</div>` : ""}
      <div class="row pe-acts"><span class="spacer"></span><button class="btn small ghost" data-action="p-cancel">${T("Cancel", "取消")}</button>
        <button class="btn small primary" data-action="p-meta-save" data-p="${esc(name)}">${T("Save", "保存")}</button></div></div>`;
  }
  const refs = (vals) => vals.map((v) => { const r = resolveRef(v); return r.url
    ? `<a href="#" class="ref chip" data-action="link" data-url="${esc(r.url)}" title="${esc(r.url)}">${esc(v)}</a>` : `<span class="chip">${esc(v)}</span>`; }).join(" ");
  const rows = [];
  if (pr.kind === "goal") {
    rows.push([META_LABEL.due, pr.due ? (projectClosed(pr) ? esc(pr.due) : dueText(pr.due)) : "—"]);
    rows.push([META_LABEL.parent, pr.parent ? `<span class="link" data-action="p-open" data-p="${esc(pr.parent)}">↻ ${esc(ptitle(pr.parent))}</span>` : "—"]);
    rows.push([META_LABEL.phases, (pr.phases || []).length ? pr.phases.map(esc).join(" → ") : "—"]);
  }
  rows.push(["Jira", (pr.jira || []).length ? refs(pr.jira) : "—"]);
  if ((pr.fixVersions || []).length) rows.push(["Fix versions", pr.fixVersions.map(esc).join(", ")]);
  return `<div class="pkv">${rows.map(([k, v]) => `<div><span class="k">${k}</span><span class="v">${v}</span></div>`).join("")}</div>`;
}

function projAside(pr) {
  const name = pr.name, duty = pr.kind === "duty";
  if (!pr.defined || !pr.kind) {
    return `<section class="pi-sec"><h4>${T("Not set up yet", "还没定类型")}</h4>
      <p class="dim">${T("Say what this is, and it gets a PROJECT.md with a goal, criteria and a brief to fill in.", "先说它是什么，就会有一份 PROJECT.md，可以填目标、标准和简报。")}</p>
      <div class="row"><button class="btn small" data-action="p-kind" data-p="${esc(name)}" data-k="goal">${T("◆ It's a project", "◆ 设为项目")}</button>
        <button class="btn small" data-action="p-kind" data-p="${esc(name)}" data-k="duty">${T("↻ It's a duty", "↻ 设为职责")}</button></div></section>`;
  }
  const grants = (pr.grants || []).length
    ? `<div class="grants">${pr.grants.map((g) => `<div class="grant"><span class="t">${esc(g.text)}</span>
        <button class="icon x" title="${T("Revoke — sessions ask again before this kind of step", "撤销——之后 session 遇到这类事情会重新问")}" data-confirm="${T("Revoke?", "撤销？")}" data-action="pgrant-revoke" data-p="${esc(name)}" data-i="${g.i}" data-text="${esc(g.text)}">✕</button></div>`).join("")}</div>`
    : `<div class="empty">${T("None. A session's ask answered with a project grant lands here.", "没有。回答问题时选了项目授权的，会出现在这里。")}</div>`;
  return [
    infoSec(name, "goal", duty ? T("Scope", "职责范围") : T("Goal", "目标"), mdOr(pr.goal, T("Not written yet.", "还没写。")),
      duty ? T("What this duty covers", "这个职责管什么") : T("What this project is for", "这个项目要做成什么")),
    infoSec(name, "out", T("Out of scope", "不管"), mdOr(pr.out, T("Nothing said.", "没写。")), T("What it leaves to others", "哪些事不归它")),
    infoSec(name, "done_when", duty ? T("Healthy when", "健康标准") : T("Done when", "完成标准"), criteriaHTML(pr), T("- one criterion per line", "- 一行一条")),
    `<section class="pi-sec"><h4>${T("Details", "详情")}${editBtn(name, "meta")}</h4>${metaHTML(pr)}</section>`,
    infoSec(name, "brief", T("Brief — given to every session on its tasks", "简报——交给它每个任务的 session"), mdOr(pr.brief, T("Empty: sessions are told nothing about this project.", "空的：session 不会收到这个项目的任何说明。")),
      T("Repos, branches, rules every session here should know", "仓库、分支、每个 session 都该知道的规矩")),
    `<section class="pi-sec"><h4>${T("Grants — hold for every task in it", "授权——对它的每个任务都有效")}</h4>${grants}</section>`,
    (pr.paths || []).length ? `<section class="pi-sec"><h4>${T("Default directories", "默认目录")}</h4><div class="meta">${T("A new task started here, with no project yet, joins this one.", "在这些目录里新建、还没有项目的任务，默认归到这里。")}</div>${pr.paths.map((x) => `<div><code>${esc(x)}</code></div>`).join("")}</section>` : "",
  ].join("");
}

// A quick-add line: Enter makes a task in this project (and phase).
function addLine(name, phases) {
  const ph = phases && phases.length ? `<select data-key="pph:${esc(name)}" title="${T("Phase of the new task", "新任务的阶段")}"><option value="">${T("(no phase)", "（不分阶段）")}</option>
      ${phases.map((p) => `<option value="${esc(p)}" ${draft("pph:" + name) === p ? "selected" : ""}>${esc(p)}</option>`).join("")}</select>` : "";
  return `<div class="addline"><input class="note" data-key="pa:${esc(name)}" data-padd="${esc(name)}" value="${esc(draft("pa:" + name))}"
      placeholder="${name === "(none)" ? T("Add a task in no project… (Enter)", "加一个不归属的任务…（回车）") : T("Add a task here… (Enter)", "在这里加一个任务…（回车）")}">${ph}
    <button class="btn small" data-action="p-add" data-p="${esc(name)}">${T("Add", "添加")}</button>
    <button class="btn small ghost" data-action="p-create" data-k="task" data-p="${esc(name === "(none)" ? "" : name)}" title="${T("With a goal, a category, a session…", "带目标、分类、session……")}">${T("More…", "更多…")}</button></div>`;
}

function board4(items) {
  const by = Object.fromEntries(LANES.map((l) => [l, []]));
  for (const t of items) if (by[lane(t)]) by[lane(t)].push(t);
  return `<div class="board c4">${LANES.map((l) => laneCol(l, steady(`proj:${ui.proj}:${l}`, by[l], laneOrder), { compact: true, noProject: true, okey: `proj:${ui.proj}:${l}` })).join("")}</div>`;
}
// A goal with phases: a row per phase (and one for tasks in none), each the four lanes.
function phaseRows(pr, items) {
  const phases = pr.phases;
  const grid = `style="grid-template-columns:repeat(4,minmax(0,1fr))"`;
  const rows = phases.concat("").map((ph) => {
    const group = items.filter((t) => (ph ? t.phase === ph : !phases.includes(t.phase)));
    if (!ph && !group.length) return "";
    return `<div class="swim-row prow-ph"><div class="swim-head ph-head"><span class="pt">${ph ? esc(ph) : T("No phase", "未分阶段")}</span><span class="meta">${group.length}</span></div>
      <div class="swim-grid" ${grid}>${LANES.map((l) => `<div class="cell l-${l}" data-lane="${l}" data-okey="${esc(`proj:${ui.proj}:${ph}:${l}`)}">${steady(`proj:${ui.proj}:${ph}:${l}`, group.filter((t) => lane(t) === l), laneOrder).map((t) => kcard(t, { compact: true, noProject: true })).join("")}</div>`).join("")}</div></div>`;
  }).join("");
  return `<div class="swim-cols" ${grid}>${LANES.map((l) => laneHead(l, items.filter((t) => lane(t) === l).length)).join("")}</div>${rows}`;
}
function doneList(name) {
  // Last active first (hq's lastActive: the newest log line or the moment it closed), then the
  // higher id (T-1000 above T-999) — a fixed order, where a date alone left a day's tasks to shuffle.
  const at = (t) => String(t.lastActive || t.closed || t.updated || "");
  const done = projTasks(name).filter((t) => !isOpen(t))
    .sort((a, b) => at(b).localeCompare(at(a)) || String(b.id).localeCompare(String(a.id), undefined, { numeric: true }));
  if (!done.length) return "";
  const all = pui.doneAll.has(name);
  const shown = all ? done : done.slice(0, 8);
  return `<div class="sec-h">${T("Finished", "已结束")}<span class="c">${done.length}</span></div><div class="donelist">${shown.map((t) =>
    `<div class="dl" data-action="open-task" data-task="${esc(t.id)}"><span class="id tid" data-task="${esc(t.id)}">${esc(t.id)}</span><span class="t">${esc(t.title)}</span>
      ${t.status === "abandoned" ? `<span class="stag abandoned">${STATUS_SHORT.abandoned}</span>` : ""}<span class="d">${esc(t.closed || t.updated || "")}</span></div>`).join("")}
    ${done.length > shown.length || all ? `<button class="addrow" data-action="p-done-all" data-p="${esc(name)}">${all ? T("Show fewer", "收起") : T(`Show all ${done.length}`, `全部 ${done.length} 个`)}</button>` : ""}</div>`;
}

// A duty's ways of getting work: its templates, recurring jobs, and automatic sources.
function intake(pr) {
  const name = pr.name, tpls = pr.templates || [];
  const tplBox = `<div class="ibox"><h4>${T("Common work", "常见的活")}<span class="c">${tpls.length}</span>${editBtn(name, "templates")}</h4>
    ${tpls.length ? tpls.map((x) => `<div class="irow"><span class="t">${esc(x.name)}<small>${esc(x.title || x.goal || "")}${x.todos.length ? T(` · ${x.todos.length} todos`, ` · ${x.todos.length} 条待办`) : ""}</small></span>
      <button class="btn small" data-action="p-tpl-new" data-p="${esc(name)}" data-t="${esc(x.name)}" title="${T("Make a task from it now", "马上用它建一个任务")}">${T("＋ Make", "＋ 建")}</button></div>`).join("")
      : `<div class="empty">${T("Kinds of task that come up again and again. ✎ to write some.", "反复会来的几类活。点 ✎ 写几条。")}</div>`}</div>`;
  const jobs = recurJobs(name);
  const open = pui.recur === name;
  const v = (k, d) => ui.drafts[`pr:${name}:${k}`] ?? d;
  const tplNow = recurTemplate(pr);
  const freq = v("freq", "weekdays");
  const days = JT[jlang()].days;
  const form = open ? `<div class="recur-form">
      <select data-key="pr:${esc(name)}:tpl">${tpls.map((x) => `<option value="${esc(x.name)}" ${tplNow === x.name ? "selected" : ""}>${esc(x.name)}</option>`).join("")}</select>
      <select data-key="pr:${esc(name)}:freq">${[["daily", jt("f_daily")], ["weekdays", jt("f_weekdays")], ["weekly", T("every week on", "每周")]].map(([k, w]) => `<option value="${k}" ${freq === k ? "selected" : ""}>${w}</option>`).join("")}</select>
      ${freq === "weekly" ? `<select data-key="pr:${esc(name)}:day">${[1, 2, 3, 4, 5, 6, 0].map((d) => `<option value="${d}" ${String(v("day", "1")) === String(d) ? "selected" : ""}>${days[d]}</option>`).join("")}</select>` : ""}
      <input type="time" data-key="pr:${esc(name)}:time" value="${esc(v("time", "09:00"))}">
      <button class="btn small primary" data-action="p-recur-save" data-p="${esc(name)}">${T("Save", "保存")}</button>
      <button class="btn small ghost" data-action="p-recur" data-p="${esc(name)}">${T("Cancel", "取消")}</button></div>` : "";
  const recurBox = `<div class="ibox"><h4>${T("Recurring", "定期来活")}<span class="c">${jobs.length}</span>
      ${tpls.length && !open ? `<button class="icon pe" data-action="p-recur" data-p="${esc(name)}" title="${T("Make a task from a template on a timetable", "按时间表用模板建任务")}">＋</button>` : ""}</h4>
    ${jobs.map((j) => `<div class="irow"><span class="t">${esc(j.recur.template)}<small>${esc(scheduleText(j.schedule))}${j.enabled && (j.next || [])[0] ? ` · ${T("next", "下次")} ${esc(jwhen(j.next[0]))}` : ""}</small>${tpls.some((x) => x.name === j.recur.template) ? "" : `<small class="warn">${T("This common work is gone: the job will fail until it is back (or delete the job)", "这个常见的活已经不在了：在它回来之前这个定期任务会失败（或者删掉这个任务）")}</small>`}</span>
      <button class="switch ${j.enabled ? "on" : ""}" data-action="p-job-toggle" data-id="${esc(j.id)}" data-on="${j.enabled ? "" : "1"}" title="${j.enabled ? T("On — click to pause", "开着——点击暂停") : T("Paused — click to switch on", "暂停中——点击打开")}"><span></span></button>
      <button class="icon x" data-confirm="${T("Delete?", "删除？")}" data-action="p-job-del" data-id="${esc(j.id)}" title="${T("Delete this recurring job", "删掉这个定期任务")}">✕</button></div>`).join("")}
    ${form || (jobs.length ? "" : `<div class="empty">${tpls.length ? T("None. ＋ makes a task from a template on a timetable (a job on the Scheduled page).", "没有。点 ＋ 按时间表用模板建任务（在定时任务页里是一个 job）。") : T("Write a template first; a recurring job makes tasks from one.", "先写一个常见的活；定期来活就是按时用它建任务。")}</div>`)}</div>`;
  const auto = new Set(pr.auto || []);
  const autoBox = `<div class="ibox"><h4>${T("Comes in by itself", "自动来活")}</h4>
    ${AUTO_SOURCES.map(([k, label, what]) => `<div class="irow"><span class="t">${esc(label)}<small>${esc(what)}</small></span>
      <button class="switch ${auto.has(k) ? "on" : ""}" data-action="p-auto" data-p="${esc(name)}" data-k="${k}"><span></span></button></div>`).join("")}
    <div class="meta inote">${T("Only switches for now: nothing makes tasks from these sources yet.", "目前只是开关：接上这些信息来源之后才会自动建任务。")}</div></div>`;
  const tplEdit = editing(name, "templates") ? `<div class="tpl-edit">${sectionEditor(name, "templates",
    T("### Triage\ntitle: Triage {date}\ngoal: Go through today's failures\n- [ ] @claude list the new failures", "### 值班\ntitle: 值班 {date}\ngoal: 过一遍今天的失败\n- [ ] @claude 列出新的失败"))}
    <div class="meta">${T("A ### heading per template: title: (with {date} / {week}), goal:, and - [ ] @owner todo lines.", "每个模板一个 ### 标题：title:（可用 {date} / {week}）、goal:，以及 - [ ] @owner 待办 行。")}</div></div>` : "";
  return `<div class="intake">${tplBox}${recurBox}${autoBox}</div>${tplEdit}`;
}

// The template a recurring-job form is on: its draft, unless that template is gone since.
function recurTemplate(pr) {
  const tpls = pr.templates || [], picked = ui.drafts[`pr:${pr.name}:tpl`];
  return tpls.some((x) => x.name === picked) ? picked : ((tpls[0] || {}).name || "");
}

function projDetail(name) {
  const items = (name === "(none)" ? listed().filter((t) => !t.project) : projTasks(name)).filter((t) => isOpen(t) && taskMatches(t));
  const crumb = (pr) => `<div class="bc"><span class="link" data-action="p-open" data-p="">${T("Projects & duties", "项目与职责")}</span>${pr && pr.parent ? ` › <span class="link" data-action="p-open" data-p="${esc(pr.parent)}">↻ ${esc(ptitle(pr.parent))}</span>` : ""} ›</div>`;
  const n = laneCounts(items);
  if (name === "(none)") {
    return `<div class="pd-head">${crumb(null)}<h1>${T("Not in a project", "未归属")}</h1><div class="r2">${laneNums(n)}</div></div>
      <div class="pd solo"><div class="pd-main">${addLine("(none)")}${board4(items)}</div></div>`;
  }
  const pr = projectByName(name) || { name, defined: false, paths: [], grants: [], stats: null };
  const duty = pr.kind === "duty";
  const statuses = duty ? ["active", "paused"] : ["active", "paused", "done", "abandoned"];
  const st = pr.stats || {};
  const head = `<div class="pd-head">${crumb(pr)}
    <h1>${kindIcon(pr)}${esc(projLabel(pr, name))}${pr.title && pr.title !== name ? `<span class="pname">${esc(name)}</span>` : ""}
      ${pr.defined && pr.kind ? `<span class="seg pstat">${statuses.map((s) => `<button class="${(pr.status || "active") === s ? "on" : ""}" data-action="p-status" data-p="${esc(name)}" data-s="${s}">${PSTATUS_LABEL[s]}</button>`).join("")}</span>` : ""}</h1>
    <div class="r2">${pr.kind === "goal" ? bigProg(progress(pr)) : pr.kind === "duty"
      ? `<div class="kvs"><span>${T("open", "进行中")} <b>${st.open || 0}</b></span><span>${T("done this week", "本周完成")} <b>${st.done_7d || 0}</b></span>${nextRecur(name) ? `<span>${T("next ↻", "下次来活")} <b>${esc(jwhen(nextRecur(name)))}</b></span>` : ""}</div>` : ""}
      ${laneNums(n)}<span class="spacer"></span>
      ${pr.defined && pr.file ? `<button class="btn small ghost" data-action="open" data-path="${esc(pr.file)}" title="${esc(pr.file)}">PROJECT.md</button>` : ""}
      <button class="btn small primary" data-action="p-create" data-k="task" data-p="${esc(name)}">${T("＋ New task", "＋ 新任务")}</button></div></div>`;
  let main = "";
  if (duty) {
    main += intake(pr) + addLine(name);
    const kids = goalsUnder(name);
    if (kids.length) main += `<div class="sec-h k-goal"><i class="ki goal">◆</i>${T("Projects under it", "归在它下面的项目")}<span class="c">${kids.length}</span></div><div class="pgrid">${kids.map((k) => projCard(k, true)).join("")}</div>`;
    main += `<div class="sec-h">${T("Tasks", "任务")}<span class="c">${items.length}</span></div>` + board4(items);
  } else {
    const phases = pr.phases || [];
    main += addLine(name, phases);
    if (phases.length) main += phaseRows(pr, items);
    else {
      if (pr.kind === "goal") main += `<div class="mstone">${T("No phases. A long project can be split into phases (Design → Build → Ship); tasks then sit in a row per phase.", "没分阶段。长一点的项目可以分阶段（设计 → 开发 → 上线），任务就按阶段一行一行排。")}
        <button class="btn small ghost" data-action="p-edit" data-p="${esc(name)}" data-part="meta">${T("Add phases", "加阶段")}</button></div>`;
      main += board4(items);
    }
  }
  main += doneList(name);
  return head + `<div class="pd"><aside class="pd-info">${projAside(pr)}</aside><div class="pd-main">${main}</div></div>`;
}

function renderProjectsView() {
  const box = $("#proj-view");
  if (ui.proj && ui.proj !== "(none)" && !projectByName(ui.proj) && !listed().some((t) => t.project === ui.proj)) { ui.proj = ""; savePref("hq-proj", ""); }
  box.className = ui.proj ? "detail" : "list";
  box.innerHTML = ui.proj ? projDetail(ui.proj) : `<div class="pscroll">${projList()}</div>`;
}

// ------------------------------------------------------------------ ＋ New
// One window for a task, a project or a duty (ui.modal.type "create"). Fields keep their drafts
// (nt:* for a task, ng:* a project, nd:* a duty) until created or cancelled.
const CREATE_KINDS = [
  ["task", T("Task", "任务"), T("one piece of work", "一件具体的事")],
  ["goal", T("◆ Project", "◆ 项目"), T("has an end: goal, done-when", "有终点：目标、完成标准")],
  ["duty", T("↻ Duty", "↻ 职责"), T("ongoing: work comes in", "长期负责：时不时来活")],
];
function openCreate(kind, project) {
  if (ui.modal) closePeek();
  ui.drawer = null;
  if (project !== undefined && kind === "task") { ui.drafts["nt:proj"] = project; delete ui.drafts["nt:tpl"]; delete ui.drafts["nt:phase"]; }
  ui.modal = { type: "create", kind: kind || "task" };
  drawCreate();
  render();
  const first = $("#modal [data-first]");
  if (first) first.focus();
}
window.hqNew = openCreate;
const dv = (k, d = "") => ui.drafts[k] ?? d;
const fld = (label, body, hint, small) => `<div class="f"><div class="fl">${label}${small ? `<small>${small}</small>` : ""}</div>${body}${hint ? `<div class="fh">${hint}</div>` : ""}</div>`;
const tin = (key, ph, extra = "") => `<input class="note" data-key="${key}" value="${esc(dv(key))}" placeholder="${esc(ph || "")}" ${extra}>`;
const tarea = (key, ph, rows = 3) => `<textarea class="grow" data-key="${key}" rows="${rows}" placeholder="${esc(ph || "")}">${esc(dv(key))}</textarea>`;
function projectPicker(key, value, opt = {}) {
  const all = projects();
  const group = (label, list) => list.length ? `<optgroup label="${esc(label)}">${list.map((p) => `<option value="${esc(p.name)}" ${p.name === value ? "selected" : ""}>${p.kind ? KIND_ICON[p.kind] + " " : ""}${esc(projLabel(p, p.name))}</option>`).join("")}</optgroup>` : "";
  const open = (p) => !projectClosed(p) || p.name === value;
  return `<select data-key="${key}">${opt.none}${group(T("Projects", "项目"), all.filter((p) => p.kind === "goal" && open(p)))}${group(T("Duties", "职责"), all.filter((p) => p.kind === "duty" && open(p)))}${group(T("Not set up", "未定类型"), all.filter((p) => !p.kind && open(p)))}</select>`;
}
function createTask() {
  const cats = categories();
  const proj = dv("nt:proj");
  const pr = proj ? projectByName(proj) : null;
  const tpls = pr && pr.kind === "duty" ? pr.templates || [] : [];
  const phases = pr && pr.kind === "goal" ? pr.phases || [] : [];
  const dirs = [...new Set(ui.sessions.map((s) => s.cwd).concat(...tasks().map((t) => list(t.workdirs))).filter(Boolean))].sort();
  const cat = dv("nt:cat", cats.includes("other") ? "other" : cats[0] || "");
  const left = fld(T("Title", "标题"), tin("nt:title", T("What is this task?", "这个任务是做什么的？"), "data-first data-csubmit"))
    + fld(T("Goal", "目标"), tarea("nt:goal", T("What done looks like — goes into the card's Goal", "做成什么样——写进任务卡的「目标」"), 4), "", T("optional", "可不填"))
    + fld(T("Belongs to", "归属"), projectPicker("nt:proj", proj, { none: `<option value="">${T("(by workdir, else none)", "（按工作目录，没有就不归属）")}</option>` }))
    + (phases.length ? fld(T("Phase", "阶段"), `<select data-key="nt:phase"><option value="">${T("(none)", "（不分阶段）")}</option>${phases.map((p) => `<option value="${esc(p)}" ${dv("nt:phase") === p ? "selected" : ""}>${esc(p)}</option>`).join("")}</select>`) : "")
    + (tpls.length ? fld(T("Start from common work", "从常见的活开始"), `<div class="pickp">${tpls.map((x) => `<button class="${dv("nt:tpl") === x.name ? "on" : ""}" data-action="p-pick-tpl" data-t="${esc(x.name)}">${esc(x.name)}</button>`).join("")}</div>`,
      T("Fills the title and goal; its todos come along", "填好标题和目标，带上它的待办")) : "");
  const right = fld(T("Category", "分类"), `<select data-key="nt:cat"><option value="" ${cat ? "" : "selected"}>${T("(none)", "（不分类）")}</option>${cats.map((c) => `<option value="${esc(c)}" ${c === cat ? "selected" : ""}>${esc(c)}</option>`).join("")}</select>`)
    + fld(T("Workdir", "工作目录"), tin("nt:dir", T("optional — a path; binding a session adds its directory", "可不填——一个路径；绑定 session 会加上它的目录"), `list="nt-dirs"`) + `<datalist id="nt-dirs">${dirs.map((d) => `<option value="${esc(d)}">`).join("")}</datalist>`)
    + fld(T("Bind a session", "绑定 session"), `<select data-key="nt:session"><option value="">—</option>${ui.sessions.filter((s) => !s.task).map((s) => `<option value="${esc(s.sessionId)}" ${s.sessionId === dv("nt:session") ? "selected" : ""}>${esc(s.title || s.project)}</option>`).join("")}</select>`,
      T("A live session with no task yet", "还没绑任务的、正在运行的 session"))
    + `<label class="toggle cm-check"><input type="checkbox" data-key="nt:focus" ${dv("nt:focus", true) ? "checked" : ""}> ${T("Add it to Focus", "加进 Focus")}</label>`;
  return [left, right];
}
function createProject(kind) {
  const p = kind === "goal" ? "ng:" : "nd:";
  const duties = projects().filter((x) => x.defined && x.kind === "duty" && !projectClosed(x));
  const name = fld(T("Name", "名字"), tin(p + "name", kind === "goal" ? "visa-renewal" : "ci-watch", "data-first"), T("A short name — also its folder: letters, digits, - and _", "短名字，也是它的文件夹名：字母、数字、- 和 _"))
    + fld(T("Title", "标题"), tin(p + "title", kind === "goal" ? T("Renew the work visa", "续签工作签证") : T("Watch the nightly CI", "盯夜间 CI")), "", T("optional", "可不填"));
  if (kind === "goal") {
    return [name
      + fld(T("Goal", "目标"), tarea("ng:goal", T("What it is to achieve", "要做成什么")))
      + fld(T("Out of scope", "不管"), tarea("ng:out", T("What it leaves to others", "哪些事不归它"), 2), "", T("optional", "可不填"))
      + fld(T("Done when", "完成标准"), tarea("ng:crit", T("One per line", "一行一条"), 3), T("Ticked off on its page", "在它的页面上勾"), T("one per line", "一行一条")),
    fld(T("Due", "截止"), `<input class="note" type="date" data-key="ng:due" value="${esc(dv("ng:due"))}">`, "", T("optional", "可不填"))
      + (duties.length ? fld(T("Under a duty", "归在职责下"), `<select data-key="ng:parent"><option value="">${T("(none)", "（不归）")}</option>${duties.map((d) => `<option value="${esc(d.name)}" ${dv("ng:parent") === d.name ? "selected" : ""}>↻ ${esc(projLabel(d, d.name))}</option>`).join("")}</select>`, T("A project that is part of something you look after", "属于你长期负责的某件事的项目")) : "")
      + fld(T("Phases", "阶段"), tin("ng:phases", T("Design, Build, Ship", "设计, 开发, 上线")), T("Comma separated, in order — or leave it", "逗号隔开、按先后——不分就不填"), T("optional", "可不填"))
      + fld(T("Brief", "简报"), tarea("ng:brief", T("Given to every session on its tasks: repos, branches, rules", "交给它每个任务的 session：仓库、分支、规矩"), 3), "", T("optional", "可不填"))
      + fld(T("First tasks", "先建的任务"), tarea("ng:subs", T("One per line", "一行一个"), 3), "", T("one per line", "一行一个"))];
  }
  return [name
    + fld(T("Scope", "职责范围"), tarea("nd:goal", T("What this duty covers", "这个职责管什么")))
    + fld(T("Out of scope", "不管"), tarea("nd:out", T("What it leaves to others", "哪些事不归它"), 2), "", T("optional", "可不填"))
    + fld(T("Healthy when", "健康标准"), tarea("nd:crit", T("One per line", "一行一条"), 3), "", T("one per line", "一行一条"))
    + fld(T("Brief", "简报"), tarea("nd:brief", T("Given to every session on its tasks", "交给它每个任务的 session"), 3), "", T("optional", "可不填")),
  fld(T("Common work", "常见的活"), tarea("nd:tpl", T("### Triage\ntitle: Triage {date}\ngoal: Go through today's failures\n- [ ] @claude list the new failures", "### 值班\ntitle: 值班 {date}\ngoal: 过一遍今天的失败\n- [ ] @claude 列出新的失败"), 7),
    T("A ### heading per kind of task; its page then has a ＋ for each, and can make them on a timetable", "每类活一个 ### 标题；它的页面上每类都有一个「＋ 建」，也能按时间表自动建"), T("optional", "可不填"))
    + fld(T("Comes in by itself", "自动来活"), AUTO_SOURCES.map(([k, label, what]) => `<label class="toggle cm-check" title="${esc(what)}"><input type="checkbox" data-key="nd:auto:${k}" ${dv("nd:auto:" + k, false) ? "checked" : ""}> ${esc(label)}</label>`).join(""),
      T("Only switches for now: nothing makes tasks from these sources yet", "目前只是开关：接上信息来源之后才会自动建任务"))];
}
function drawCreate() {
  const m = ui.modal;
  if (!m || m.type !== "create") return;
  const box = $("#modal");
  const taScrolls = textScrolls(box);
  const [left, right] = m.kind === "task" ? createTask() : createProject(m.kind);
  box.innerHTML = `<div class="panel cm" role="dialog" aria-label="${T("New", "新建")}">
    <div class="cm-head"><b>${T("New", "新建")}</b><div class="kseg">${CREATE_KINDS.map(([k, n, s]) => `<button class="k-${k} ${m.kind === k ? "on" : ""}" data-action="p-ckind" data-k="${k}"><span class="n">${n}</span><span class="s">${s}</span></button>`).join("")}</div>
      <button class="btn small ghost" data-action="close-modal" title="${T("Close (Esc)", "关闭 (Esc)")}">✕</button></div>
    <div class="cm-body"><div class="cm-col">${left}</div><div class="cm-col">${right}</div></div>
    <div class="cm-foot"><span class="meta">${m.kind === "task" ? T("Enter in the title creates it", "在标题里按回车就创建") : T("Saved as projects/<name>/PROJECT.md", "存成 projects/<名字>/PROJECT.md")}</span><span class="spacer"></span>
      <button class="btn ghost" data-action="p-ccancel">${T("Cancel", "取消")}</button>
      <button class="btn primary" data-action="p-csubmit" ${pui.busy ? "disabled" : ""}>${T("Create", "创建")}</button></div></div>`;
  box.hidden = false;
  fitAllGrow(box);
  restoreTextScrolls(box, taScrolls);
}
function clearDrafts(prefix) { for (const k of Object.keys(ui.drafts)) if (k.startsWith(prefix)) delete ui.drafts[k]; saveDrafts(); }
const lines = (s) => String(s || "").split("\n").map((x) => x.replace(/^\s*(?:[-*]\s+(?:\[[ xX]\]\s+)?)?/, "").trim()).filter(Boolean);

async function submitCreate() {
  const m = ui.modal;
  if (!m || pui.busy) return;
  pui.busy = true;
  try {
    if (m.kind === "task") {
      const title = dv("nt:title").trim(), tpl = dv("nt:tpl");
      if (tpl && !((projectByName(dv("nt:proj")) || {}).templates || []).some((x) => x.name === tpl)) {
        delete ui.drafts["nt:tpl"];
        saveDrafts();
        toast(T(`The common work "${tpl}" is gone — pick again`, `常见的活"${tpl}"已经不在了，请重新选`), true);
        return;
      }
      if (!title && !tpl) { toast(T("Give the task a title", "给任务起个标题"), true); return; }
      const out = await api("new", { title, goal: dv("nt:goal").trim(), category: dv("nt:cat", categories().includes("other") ? "other" : categories()[0] || ""),
        workdir: dv("nt:dir").trim(), project: dv("nt:proj"), template: tpl, phase: dv("nt:phase"), focus: dv("nt:focus", true) !== false });
      const id = String(out).split("\n")[0].trim();
      const sid = dv("nt:session");
      if (sid) await api("bind", { task: id, session: sid });
      clearDrafts("nt:");
      closePeek();
      ui.drawer = id;
      toast(T(`Created ${id}`, `已创建 ${id}`));
      return refresh();
    }
    const p = m.kind === "goal" ? "ng:" : "nd:";
    const title = dv(p + "title").trim();
    let name = dv(p + "name").trim();
    if (!name) name = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    if (!name) { toast(T("Give it a name", "起个名字"), true); return; }
    await api("project", { action: "add", kind: m.kind, title, due: m.kind === "goal" ? dv("ng:due") : "", parent: m.kind === "goal" ? dv("ng:parent") : "", names: [name] });
    // The rest one by one: the project exists now, so a failure below leaves it to finish on its page.
    const crit = lines(dv(p + "crit")).map((x) => "- " + x).join("\n");
    const secs = [["goal", dv(p + "goal")], ["out", dv(p + "out")], ["done_when", crit], ["brief", dv(p + "brief")]];
    if (m.kind === "duty") secs.push(["templates", dv("nd:tpl")]);
    for (const [k, text] of secs) if (String(text).trim()) await api("project", { action: "section", names: [name, k, String(text).trim()] });
    const set = [];
    if (m.kind === "goal" && dv("ng:phases").trim()) set.push("phases=" + dv("ng:phases").split(/[,，]/).map((x) => x.trim()).filter(Boolean).join(","));
    if (m.kind === "duty") { const on = AUTO_SOURCES.map(([k]) => k).filter((k) => dv("nd:auto:" + k, false)); if (on.length) set.push("auto=" + on.join(",")); }
    if (set.length) await api("project", { action: "set", names: [name, ...set] });
    if (m.kind === "goal") for (const sub of lines(dv("ng:subs"))) await api("new", { title: sub, project: name, focus: false });
    clearDrafts(p);
    toast(m.kind === "goal" ? T(`Project ${name} created`, `已建项目 ${name}`) : T(`Duty ${name} created`, `已建职责 ${name}`));
    goToProject(name);
  } catch (e) {
    toast(String(e.message || e), true);
    refresh();
  } finally {
    pui.busy = false;
    if (ui.modal && ui.modal.type === "create") drawCreate();
  }
}

// ------------------------------------------------------------------ actions
async function projAction(d) {
  const name = d.p;
  const run = async (fn, ok) => { try { await fn(); if (ok) toast(ok); } catch (e) { toast(String(e.message || e), true); } return refresh(true); };
  switch (d.action) {
    case "p-open": return goToProject(name);
    case "p-closed": pui.closedOpen = !pui.closedOpen; return render();
    case "p-create": return openCreate(d.k, d.p);
    case "p-ckind": ui.modal.kind = d.k; drawCreate(); { const f = $("#modal [data-first]"); if (f) f.focus(); } return;
    case "p-ccancel": {
      const m = ui.modal;
      clearDrafts(m.kind === "task" ? "nt:" : m.kind === "goal" ? "ng:" : "nd:");
      return closePeek();
    }
    case "p-csubmit": return submitCreate();
    case "p-pick-tpl": {
      const pr = projectByName(dv("nt:proj"));
      const x = pr && (pr.templates || []).find((t) => t.name === d.t);
      if (!x) return;
      if (dv("nt:tpl") === d.t) { delete ui.drafts["nt:tpl"]; return drawCreate(); }
      ui.drafts["nt:tpl"] = d.t;
      // Its {date} is filled when the task is made.
      ui.drafts["nt:title"] = x.title || x.name;
      if (x.goal) ui.drafts["nt:goal"] = x.goal;
      saveDrafts();
      return drawCreate();
    }
    case "p-kind": return run(() => api("project", { action: "set", names: [name, "kind=" + d.k] }), d.k === "goal" ? T("Now a project", "已设为项目") : T("Now a duty", "已设为职责"));
    case "p-status": return run(() => api("project", { action: "set", names: [name, "status=" + d.s] }), T("Status saved", "状态已保存"));
    case "p-check": return run(() => api("project", { action: "check", names: [name, String(d.i), d.done ? "done" : "open"] }));
    case "p-edit": {
      const pr = projectByName(name) || {};
      const part = d.part;
      if (editing(name, part)) { pui.edit = null; return render(); }
      pui.edit = name + "|" + part;
      if (part === "meta") for (const k of META_KEYS(pr)) ui.drafts[`pm:${name}:${k}`] = metaVal(pr, k);
      // The section as written in PROJECT.md, comments and all (the parsed one drops details).
      else ui.drafts[`pe:${name}:${part}`] = (pr.raw || {})[part] || "";
      render();
      const el = document.querySelector(`#proj-view [data-key="${CSS.escape(part === "meta" ? `pm:${name}:title` : `pe:${name}:${part}`)}"]`);
      if (el) { el.focus(); if (el.setSelectionRange) el.setSelectionRange(el.value.length, el.value.length); }
      return;
    }
    case "p-cancel": pui.edit = null; return render();
    case "p-save": {
      const key = `pe:${name}:${d.part}`;
      const text = draft(key);
      // The editor stays open with its text until the save went through.
      return run(async () => {
        await api("project", { action: "section", names: [name, d.part, text] });
        if (pui.edit === name + "|" + d.part) pui.edit = null;
        delete ui.drafts[key];
        saveDrafts();
      }, T("Saved", "已保存"));
    }
    case "p-meta-save": {
      const pr = projectByName(name) || {};
      const fields = [];
      for (const k of META_KEYS(pr)) {
        let v = draft(`pm:${name}:${k}`).trim();
        if (["phases", "jira", "fixVersions"].includes(k)) v = v.split(/[,，]/).map((x) => x.trim()).filter(Boolean).join(",");
        if (v !== metaVal(pr, k).split(", ").join(["phases", "jira", "fixVersions"].includes(k) ? "," : ", ")) fields.push(`${k}=${v}`);
      }
      const close = () => { if (pui.edit === name + "|meta") pui.edit = null; clearDrafts(`pm:${name}:`); };
      if (!fields.length) { close(); return render(); }
      return run(async () => { await api("project", { action: "set", names: [name, ...fields] }); close(); }, T("Saved", "已保存"));
    }
    case "p-add": return addTask(name);
    case "p-done-all": pui.doneAll.has(name) ? pui.doneAll.delete(name) : pui.doneAll.add(name); return render();
    case "p-tpl-new": {
      try {
        const out = await api("new", { title: "", project: name, template: d.t });
        const id = String(out).split("\n")[0].trim();
        ui.drawer = id;
        toast(T(`Created ${id}`, `已创建 ${id}`));
      } catch (e) { toast(String(e.message || e), true); }
      return refresh(true);
    }
    case "p-auto": {
      const pr = projectByName(name) || {};
      const on = new Set(pr.auto || []);
      on.has(d.k) ? on.delete(d.k) : on.add(d.k);
      pr.auto = [...on];   // shows at once; the refresh confirms it
      render();
      return run(() => api("project", { action: "set", names: [name, "auto=" + AUTO_SOURCES.map(([k]) => k).filter((k) => on.has(k)).join(",")] }));
    }
    case "p-recur": pui.recur = pui.recur === name ? null : name; return render();
    case "p-recur-save": {
      const pr = projectByName(name) || {};
      const v = (k, dflt) => ui.drafts[`pr:${name}:${k}`] ?? dflt;
      const [hh, mm] = String(v("time", "09:00")).split(":").map(Number);
      const kind = v("freq", "weekdays");
      // The form's Sunday is 0 (as Date#getDay); a job's days are 1–7, Sunday 7.
      const schedule = { kind, hour: hh || 0, minute: mm || 0, days: [Number(v("day", "1")) || 7] };
      const template = recurTemplate(pr);
      if (!template) return toast(T("Write a template first", "先写一个常见的活"), true);
      return run(async () => {
        await api("recur-save", { project: name, template, schedule, enabled: true });
        if (pui.recur === name) pui.recur = null;
        clearDrafts(`pr:${name}:`);
      }, T("Recurring job saved — it is also on the Scheduled page", "已保存——在定时任务页里也能看到"));
    }
    case "p-job-toggle": return run(() => api("job-enable", { id: d.id, on: Boolean(d.on) }));
    case "p-job-del": return run(() => api("job-delete", { id: d.id }), T("Deleted", "已删除"));
  }
}
async function addTask(name) {
  const key = "pa:" + name;
  const title = draft(key).trim();
  if (!title) return;
  const phase = draft("pph:" + name);
  delete ui.drafts[key];
  saveDrafts();
  try {
    const out = await api("new", { title, project: name === "(none)" ? "" : name, phase, focus: false });
    toast(T(`Created ${String(out).split("\n")[0].trim()}`, `已创建 ${String(out).split("\n")[0].trim()}`));
  } catch (e) { ui.drafts[key] = title; toast(String(e.message || e), true); }
  refresh(true);
}

document.addEventListener("keydown", (ev) => {
  const el = ev.target;
  if (ev.key !== "Enter" || ev.shiftKey || ev.isComposing || ui.composing || ev.keyCode === 229) return;
  if (el.dataset && el.dataset.padd !== undefined && el.tagName === "INPUT") { ev.preventDefault(); return addTask(el.dataset.padd); }
  // In the ＋ New window: Enter in the task's title, or ⌘Enter anywhere, creates.
  if (ui.modal && ui.modal.type === "create" && el.closest && el.closest("#modal")
      && ((el.dataset && el.dataset.csubmit !== undefined) || ev.metaKey)) { ev.preventDefault(); submitCreate(); }
});
// A dropdown in the ＋ New window changes what it shows (a project's phases, a duty's templates);
// board.js has saved its draft by now.
document.addEventListener("change", (ev) => {
  const el = ev.target;
  if (!ui.modal || ui.modal.type !== "create" || el.tagName !== "SELECT" || !el.closest("#modal")) return;
  if (el.dataset.key === "nt:proj") { delete ui.drafts["nt:tpl"]; delete ui.drafts["nt:phase"]; }
  drawCreate();
});
$("#new-task").addEventListener("click", () => openCreate("task"));
