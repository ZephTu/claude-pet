#!/bin/bash
# Every board still the film uses, into assets/board/ (2x, 2360 px wide).
set -euo pipefail
PROMO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$PROMO/assets/board"; mkdir -p "$OUT"
S="$PROMO/scripts/shot.sh"
D1="2026-11-24"; D2="2026-11-25"
PICK1='ui.picks["T-014.4"] = "do"; ui.drafts["note:T-014.4"] = "2 次就够——5 秒预算优先";'
PICK2="$PICK1 ui.picks[\"T-014.5\"] = \"do\";"
PICK3="$PICK2 ui.picks[\"T-014.6\"] = \"todo\";"
SENT='const t = taskById("T-014"); t.asks = [];
  t.todos.push({ i: 5, state: "open", owner: "me", text: "合并以后，把压测数据发到 #payments", created: new Date().toISOString() });
  render(); openDrawer("T-014"); toast("已记下 3 个回答 · 已发给 结账重试");'
ANSWERED="${SENT%%toast*}"   # the same state, without the toast
BOTTOM='const d = document.querySelector("#drawer .dr-body"); d.scrollTop = d.scrollHeight;'

NOW="${D1}T10:05:00" "$S" "$OUT/focus.png"        'render();' &
NOW="${D1}T10:05:00" "$S" "$OUT/drawer.png"       'render(); openDrawer("T-014");' &
NOW="${D1}T10:05:00" "$S" "$OUT/ask-1.png"        "$PICK1 render(); openDrawer(\"T-014\");" &
NOW="${D1}T10:05:00" "$S" "$OUT/ask-2.png"        "$PICK2 render(); openDrawer(\"T-014\");" &
wait
NOW="${D1}T10:05:00" "$S" "$OUT/ask-3.png"        "$PICK3 render(); openDrawer(\"T-014\");" &
NOW="${D1}T10:06:00" "$S" "$OUT/ask-sent.png"     "$SENT" &
NOW="${D1}T10:05:00" "$S" "$OUT/drawer-bottom.png" "render(); openDrawer(\"T-014\"); $BOTTOM" &
NOW="${D1}T10:05:00" "$S" "$OUT/peek-1.png"       'render(); openPeek(DEMO_IDS.checkout);' &
wait
NOW="${D2}T09:20:00" DAY2=1 "$S" "$OUT/day2-drawer.png"        'render(); openDrawer("T-014");' &
NOW="${D2}T09:20:00" DAY2=1 "$S" "$OUT/day2-drawer-bottom.png" "render(); openDrawer(\"T-014\"); $BOTTOM" &
NOW="${D2}T09:20:00" DAY2=1 "$S" "$OUT/day2-peek.png"          'render(); openPeek(DEMO_IDS.next);' &
NOW="${D2}T09:20:00" DAY2=1 "$S" "$OUT/day2-peek-typed.png"    'ui.drafts["msg:" + DEMO_IDS.next] = "压测用 200 并发，跑 10 分钟"; render(); openPeek(DEMO_IDS.next);' &
wait
NOW="${D2}T17:02:00" DAY2=1 "$S" "$OUT/jobs.png"       'ui.mode = "jobs"; loadJobs().then(() => render());' &
NOW="${D2}T17:02:00" DAY2=1 "$S" "$OUT/jobs-run.png"   'ui.mode = "jobs"; loadJobs().then(() => { render(); openJobRun("ci-morning"); });' &
NOW="${D2}T18:32:00" DAY2=1 "$S" "$OUT/secretary.png"  'render(); openSecretary();' &
NOW="${D2}T09:20:00" DAY2=1 "$S" "$OUT/day2-focus.png" 'render();' &
wait
NOW="${D1}T10:07:00" "$S" "$OUT/needs.png"    'ui.mode = "needs"; render();' &
NOW="${D1}T10:07:00" "$S" "$OUT/projects.png" 'ui.mode = "projects"; render();' &
NOW="${D1}T10:07:00" "$S" "$OUT/needs-after.png" "$ANSWERED ui.mode = \"needs\"; ui.drawer = null; render();" &
NOW="${D1}T10:07:00" "$S" "$OUT/project.png"  'ui.mode = "projects"; goToProject("shop-api"); render();' &
wait
ls -la "$OUT"
