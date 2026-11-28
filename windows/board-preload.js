// The board window's bridge: what WKWebView gives the page on the Mac.
//  - window.webkit.messageHandlers.hq.postMessage(body) returns a promise of the answer, or
//    rejects with the error, as a WKScriptMessageHandlerWithReply does (main.js → board.js);
//  - window.PET_LANG, as installLanguageScript sets it.
"use strict";

const { contextBridge, ipcRenderer } = require("electron");

const lang = (process.argv.find((a) => a.startsWith("--pet-lang=")) || "").split("=")[1] === "zh" ? "zh" : "en";
contextBridge.exposeInMainWorld("PET_LANG", lang);
contextBridge.exposeInMainWorld("webkit", {
  messageHandlers: {
    hq: {
      postMessage: async (body) => {
        const a = await ipcRenderer.invoke("hq", body);
        if (a && a.error) throw new Error(a.error);
        return a ? a.result : null;
      },
    },
  },
});
window.addEventListener("DOMContentLoaded", () => { document.documentElement.lang = lang; });
