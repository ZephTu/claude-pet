// The connection report's window (health.html): what the Mac's HealthWindow does with its buttons.
//  - window.health.lang: "zh" or "en", as the pet's;
//  - copy(): the report's pasteable summary to the clipboard (main.js copies the one it holds);
//  - close(), and fit(height) to size the window to the panel.
"use strict";

const { contextBridge, ipcRenderer } = require("electron");

const lang = (process.argv.find((a) => a.startsWith("--pet-lang=")) || "").split("=")[1] === "zh" ? "zh" : "en";
contextBridge.exposeInMainWorld("health", {
  lang,
  copy: () => ipcRenderer.send("health", { op: "copy" }),
  close: () => ipcRenderer.send("health", { op: "close" }),
  fit: (height) => ipcRenderer.send("health", { op: "fit", height: Number(height) || 0 }),
});
