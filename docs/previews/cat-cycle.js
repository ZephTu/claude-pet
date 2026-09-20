// The source of docs/images/cat.gif: the REAL pet page, driven through every
// state the cat can draw, cropped to the box the figure and its speech bubble
// occupy.
//
// cycle.html cannot do this one. It freezes CSS animations by setting
// currentTime, which is what makes the robot's GIF step evenly — and the cat
// is a WebGL mesh with no currentTime to set. So the page runs at its own
// speed and `--probe-film` presses the shutter on an absolute tick instead.
//
// Capture, from the repo root:
//
//   ./scripts/build-app.sh
//   ./.build/out/Products/Release/ClaudePet --probe-film index.html \
//       /tmp/frames 130 9 "$(cat docs/previews/cat-cycle.js)"
//   swiftc -O -o /tmp/make-gif scripts/make-gif.swift
//   /tmp/make-gif /tmp/frames docs/images/cat.gif 500 210 460 320 0.111 0.5
//
// 130 frames at 9fps is 14.4s, which is nine states at SLOT each plus the tail.
// The crop is in the 2x snapshot's pixels; 0.5 brings it back to 230x160, the
// scale pet.gif is at.
//
// README 动图的脚本：页面自己按表走状态，探针只管按快门。
// 顺序和停留时间照着 app 自己的 Demo the States 来，说的话也用真实文案。
window.setSkin("cat");
var SLOT = 1600;
var steps = [
  function () { window.setBadge(""); window.hush();
                window.setMood("busy", null, "", "writing");
                window.setCatLook("working", "none"); },
  function () { window.setMood("busy", null, "", "reading");
                window.setCatLook("reading", "none"); },
  function () { window.setPhase("compacting");
                window.setMood("busy", null, "", "");
                window.setCatLook("compacting", "none"); },
  function () { window.setPhase("awaiting-agent");
                window.setCatLook("awaiting-agent", "none"); },
  function () { window.setPhase("");
                window.setBadge("1");
                window.setMood("waiting", "api-server", "");
                window.setCatLook("waiting", "question");
                window.say("api-server is asking you something", 0, ""); },
  function () { window.hush();
                window.setMood("waiting", "api-server", "rm -rf build/");
                window.setCatLook("waiting", "warn"); },
  function () { window.setMood("urgent", "api-server", "rm -rf build/");
                window.setCatLook("urgent", "none"); },
  function () { window.setBadge("2");
                window.setMood("idle", null, "", "");
                window.setCatLook("idle", "none");
                window.flash("done", "finished", "none");
                window.say("api-server done", 0, ""); },
  function () { window.setBadge(""); window.hush();
                window.setMood("idle", null, "", "");
                window.setCatLook("sleeping", "none"); }
];
// 探针在跑完脚本后还要等 2.5s 让贴图到位才开拍，所以这里等齐了再起步。
steps.forEach(function (fn, i) { setTimeout(fn, 2600 + i * SLOT); });
"scheduled " + steps.length + " states";
