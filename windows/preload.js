// The part PetHostView plays on the Mac: the page never handles the mouse itself.
//  - over the cat, the panel, the bubble or a notice the window takes clicks; anywhere else
//    they fall through to the desktop (main.js toggles setIgnoreMouseEvents);
//  - press on the cat and move: drag the window; press and release: open or close the list;
//  - a click in the list is looked up with the page's own window.hitRow and sent to main.js;
//  - resting on a row of the open list: that session's detail card;
//  - right click: the tray's menu.
"use strict";

const { contextBridge, ipcRenderer, webFrame } = require("electron");

const lang = (process.argv.find((a) => a.startsWith("--pet-lang=")) || "").split("=")[1] === "zh" ? "zh" : "en";
contextBridge.exposeInMainWorld("PET_LANG", lang);
// pet.js reports its layout to window.webkit.messageHandlers.layout, as WKWebView provides.
contextBridge.exposeInMainWorld("webkit", {
  messageHandlers: { layout: { postMessage: (m) => ipcRenderer.send("layout", m) } },
});

const SOLID = "#pet, #panel, #bubble, #notices > *";
let interactive = false;
let press = null;

function solidAt(x, y) {
  const el = document.elementFromPoint(x, y);
  const hit = el && el.closest && el.closest(SOLID);
  return !!hit && !hit.hidden;
}

function setInteractive(on) {
  if (on === interactive) return;
  interactive = on;
  ipcRenderer.send("interactive", on);
}

// A press whose mouseup never came (focus taken mid-press, alt-tab) must not leave the window
// holding on to clicks: let it go as soon as no button is down, or the window loses focus.
function release() {
  if (press && press.dragging) ipcRenderer.send("drag-end");
  press = null;
}
window.addEventListener("blur", release);

window.addEventListener("mousemove", (e) => {
  if (press && e.buttons === 0) release();
  if (press) {
    if (!press.dragging && Math.hypot(e.screenX - press.x, e.screenY - press.y) > 4 && press.onPet) {
      press.dragging = true;
      ipcRenderer.send("drag-start");
    }
    if (press.dragging) ipcRenderer.send("drag-move");
    return;
  }
  setInteractive(solidAt(e.clientX, e.clientY));
  hover(e.clientX, e.clientY);
  updateDwell(e.clientX, e.clientY);
});

// Resting the pointer on a row of the open list shows that session's detail card, as
// PetHostView's updateDwell does: the page says which row (window.rowSessionId), main.js asks
// pet-emit --detail, and window.hush takes the card down once the pointer moves on.
const ROW_DWELL_MS = 450;
const dwell = { timer: null, y: null, showing: false, ticket: 0 };

function panelOpen() {
  const p = document.getElementById("panel");
  return !!p && !p.hidden;
}

function endDwell() {
  clearTimeout(dwell.timer);
  dwell.timer = null;
  dwell.y = null;
  dwell.ticket++;
  if (dwell.showing) { dwell.showing = false; ipcRenderer.send("hush"); }
}

function updateDwell(x, y) {
  const el = document.elementFromPoint(x, y);
  if (!panelOpen() || (el && el.closest && el.closest("#pet"))) return endDwell();
  // Onto another row: the first row's card must not stay up.
  if (dwell.y !== null && Math.abs(y - dwell.y) > 2) endDwell();
  dwell.y = y;
  if (dwell.timer || dwell.showing) return;
  const ticket = dwell.ticket;
  dwell.timer = setTimeout(async () => {
    // dwell.timer stays set while the page answers, so no second timer starts meanwhile.
    const id = await webFrame.executeJavaScript(`window.rowSessionId(${x}, ${y})`).catch(() => "");
    if (ticket !== dwell.ticket) return;
    dwell.timer = null;
    if (!id) return;
    dwell.showing = true;
    ipcRenderer.send("detail", id);
  }, ROW_DWELL_MS);
}

// The row under the pointer lights up and shows its ↗, as PetHostView forwards it on the Mac
// (window.setHoverAt; it returns early when the row is the same).
function hover(x, y) {
  webFrame.executeJavaScript(`window.setHoverAt && window.setHoverAt(${x}, ${y})`).catch(() => {});
}

window.addEventListener("mouseleave", () => {
  if (!press) setInteractive(false);
  hover(-1, -1);
  endDwell();
});

window.addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  const el = document.elementFromPoint(e.clientX, e.clientY);
  press = { x: e.screenX, y: e.screenY, onPet: !!(el && el.closest && el.closest("#pet")), dragging: false };
});

window.addEventListener("mouseup", async (e) => {
  if (e.button !== 0 || !press) return;
  const p = press;
  press = null;
  if (p.dragging) { ipcRenderer.send("drag-end"); return; }
  if (p.onPet) { await webFrame.executeJavaScript("window.togglePanel()"); return; }
  const hit = await webFrame.executeJavaScript(`window.hitRow(${e.clientX}, ${e.clientY})`);
  if (hit) ipcRenderer.send("action", hit);
});

window.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  ipcRenderer.send("menu");
});
