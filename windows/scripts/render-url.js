// A web page rendered as a phone's browser shows it, to a PNG (the Mac's `ClaudePet --render-url`):
// for the board that serve-board.js (or the pet's Phone access) serves, with no bridge to the app.
//
//   cd windows
//   $env:RENDER_JS = "<js to run first>"   # optional
//   npx electron (Resolve-Path scripts\render-url.js) out.png [390x844] "<url>"
//
// The URL goes last: Electron 33 on Windows quits at once (exit 127) when an http URL is followed
// by another argument.
"use strict";

const { app, BrowserWindow } = require("electron");
const fs = require("fs");
const os = require("os");
const path = require("path");

const args = process.argv.slice(2);
const out = args[0];
const url = args[args.length - 1];
const size = (args.find((a) => /^\d+x\d+$/.test(a)) || "390x844").split("x").map(Number);
const script = process.env.RENDER_JS || "";
// A user data folder of its own: nothing kept from one render to the next (as a fresh phone).
app.setPath("userData", fs.mkdtempSync(path.join(os.tmpdir(), "render-url-")));

app.whenReady().then(async () => {
  if (!out || !/^https?:\/\//.test(url || "")) {
    console.error("usage: render-url.js out.png [WxH] <url>");
    return app.exit(2);
  }
  const win = new BrowserWindow({ width: size[0], height: size[1], show: false });
  win.webContents.setUserAgent("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1");
  win.webContents.on("console-message", (_e, level, message) => { if (level >= 2) console.error("page:", message); });
  await win.loadURL(url).catch((e) => console.error("load:", e.message));
  await new Promise((r) => setTimeout(r, 4000));
  if (script) await win.webContents.executeJavaScript(script).catch((e) => console.error("script:", e.message));
  await new Promise((r) => setTimeout(r, 2500));
  const img = await win.webContents.capturePage();
  fs.writeFileSync(out, img.toPNG());
  console.log("wrote", out, img.getSize());
  app.quit();
});
