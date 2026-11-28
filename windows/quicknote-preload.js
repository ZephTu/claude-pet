// The quick-note box's bridge to main.js (quicknote.html).
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("quickNote", {
  size: (height) => ipcRenderer.send("quicknote:size", Number(height) || 0),
  close: () => ipcRenderer.send("quicknote:close"),
  submit: (text, images) => ipcRenderer.send("quicknote:submit", { text: String(text), images: [...images].map(String) }),
  /** Saves a pasted image's data URL as a file: { path } or { error }. */
  saveImage: (dataURL) => ipcRenderer.invoke("quicknote:image", String(dataURL)),
  onShown: (fn) => ipcRenderer.on("quicknote:shown", () => fn()),
  onRestore: (fn) => ipcRenderer.on("quicknote:restore", (_e, what) => fn(what)),
});
