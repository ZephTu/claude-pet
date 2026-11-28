// Phone access alone, for development (the Mac's `ClaudePet --serve-board PORT`): serves the board
// on PORT beside the installed pet, and prints a pairing link. Its switches and paired phones are
// kept in a scratch prefs file, not the pet's.
//
//   cd windows
//   $env:ELECTRON_RUN_AS_NODE = 1; npx electron scripts/serve-board.js 18790 [--tailnet] [--prefs <file>]
//
// The board's operations run for real (hq, pet-emit) against this user's HQ.
"use strict";

const path = require("path");
const fs = require("fs");
const os = require("os");
const hqBoard = require("../board");
const { BoardServer } = require("../remote");
const { BoardEvents } = require("../board-events");

const args = process.argv.slice(2);
const port = Number(args.find((a) => /^\d+$/.test(a)) || 18790);
const prefsAt = args.includes("--prefs") ? args[args.indexOf("--prefs") + 1] : path.join(os.tmpdir(), `claude-pet-serve-${port}.json`);
const PET_HOME = process.env.PET_HOME || path.join(os.homedir(), ".claude", "pet");
const lang = process.env.CLAUDE_PET_LANG === "zh" ? "zh" : "en";
const L = (en, zh) => (lang === "zh" ? zh : en);

const readPrefs = () => { try { return JSON.parse(fs.readFileSync(prefsAt, "utf8")); } catch (_) { return {}; } };
const writePrefs = (p) => fs.writeFileSync(prefsAt, JSON.stringify(p, null, 1));
writePrefs({ ...readPrefs(), boardServerEnabled: true, boardServerTailnet: args.includes("--tailnet") });

hqBoard.configure({ L, petEmit: process.env.PET_EMIT || path.join(PET_HOME, "pet-emit.exe"), petState: () => ({}) });
const events = new BoardEvents({ roots: () => hqBoard.watchRoots().concat([PET_HOME]), dropReads: hqBoard.dropReads, log: console.error });
const server = new BoardServer({
  handle: hqBoard.handle, readPrefs, writePrefs, root: path.join(__dirname, "..", "..", "Resources", "pet"), petHome: PET_HOME,
  events, log: console.error, L: () => L, lang: () => lang,
});
hqBoard.configure({ remote: server });

(async () => {
  await server.serveForDevelopment(port);
  if (server.lastError) { console.error("serve-board: " + server.lastError); process.exit(1); }
  if (args.includes("--tailnet")) await server.tailnet.current(true);
  const a = await server.pair(args.includes("--tailnet"));
  if (a.error) { console.error("serve-board: " + a.error); process.exit(1); }
  console.log(JSON.stringify({ prefs: prefsAt, url: a.result.url, code: a.result.code, local: a.result.url.replace(/^http:\/\/[^/]+/, `http://localhost:${port}`) }));
})();
