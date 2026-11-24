// 宣传片里 session 列表面板的演示数据（虚构），驱动真实的 Resources/pet/index.html。
// 用法：ClaudePet --probe-skin index.html out.png "$(cat panel-zh.js); PANEL('open')"
window.PANEL = function (scene) {
  const term = { termKind: "orca", termHandle: "t1" };
  const s = (o) => Object.assign({ sessionId: "s" + o.project, state: "busy", tool: "", detail: "", waitedSeconds: 30 }, o);
  const waiting = s({ sessionId: "s4", project: "发版说明", state: "waiting", asks: "permission", askId: "a1",
    detail: "git push origin release-notes", urgent: true, waitedSeconds: 75, ...term });
  const busy = s({ sessionId: "s2", project: "深色模式", state: "busy", activity: "Bash npm run test:contrast", toolSeconds: 23, branch: "ui/dark", ...term });
  const busy2 = s({ sessionId: "s5", project: "规格索引", state: "busy", activity: "Read indexer.ts", toolSeconds: 4, ...term });
  const ci = s({ sessionId: "s3", project: "CI runner", state: "idle", replied: true, detail: "单元测试需要 Node 22，runner 镜像里还没有。", waitedSeconds: 840, ...term });
  const fin = [{ sessionId: "s1", eventIds: ["e1"], label: "结账重试", count: 1, closed: false, agoSeconds: 180,
    summary: "超时每次都在 4.8 秒复现。写重试之前有三件事要你定——已经放到看板上了。", ...term }];
  if (scene === "open") {
    setSessions([waiting, busy, busy2, ci], 0, fin, 0);
    setPanelOpen(true); setBadge("2"); setMood("waiting", null);
  } else if (scene === "allowed") {
    setSessions([busy, Object.assign({}, waiting, { sessionId: "s4", state: "busy", asks: "", askId: "", urgent: false, detail: "", activity: "Bash git push origin release-notes", toolSeconds: 1 }), busy2, ci], 0, fin, 0);
    setPanelOpen(true); setBadge("1"); setMood("busy", null);
  }
  return "ok";
};
