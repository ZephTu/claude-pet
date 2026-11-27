// The part PetHostView plays on the Mac: the page never handles the mouse itself.
//  - over the cat, the panel, the bubble or a notice the window takes clicks; anywhere else
//    they fall through to the desktop (main.js toggles setIgnoreMouseEvents);
//  - press on the cat and move: drag the window; press and release: open or close the list;
//  - a click in the list is looked up with the page's own window.hitRow and sent to main.js;
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

window.addEventListener("mousemove", (e) => {
  if (press) {
    if (!press.dragging && Math.hypot(e.screenX - press.x, e.screenY - press.y) > 4 && press.onPet) {
      press.dragging = true;
      ipcRenderer.send("drag-start");
    }
    if (press.dragging) ipcRenderer.send("drag-move");
    return;
  }
  setInteractive(solidAt(e.clientX, e.clientY));
});

window.addEventListener("mouseleave", () => { if (!press) setInteractive(false); });

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
