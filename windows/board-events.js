// The board is told when what it shows may have changed (BoardEvents.swift / BoardPush.swift on
// the Mac): the files the board's reads come from are watched (the HQ root, hq's own folder, the
// pet's session states), and a burst of changes becomes one "changed" after it goes quiet. Each
// change first drops the board's kept reads (they are stale). Phone access pushes it to every
// phone's `/events` stream; the board window still polls.
"use strict";

const fs = require("fs");
const path = require("path");

/** Whether a change at `p` (forward slashes) can change what the board shows: not git's own
 * files, lock files, editors' and hq's temporary files, or the pet's files the board doesn't read. */
function relevant(p) {
  const parts = String(p).split("/").filter(Boolean);
  const name = parts[parts.length - 1];
  if (!name) return false;
  if (parts.includes(".git") || parts.includes("locks") || name.endsWith(".lock")) return false;
  if (name === ".DS_Store" || name.startsWith(".hq-") || name.startsWith(".#") || name.endsWith("~")
      || name.endsWith(".swp") || name.endsWith(".tmp")) return false;
  const i = parts.lastIndexOf("pet");
  if (i > 0 && parts[i - 1] === ".claude") {
    const under = parts.slice(i + 1);
    if (!under.length || under[0] === "activity") return false;
    if (under.length === 1 && ["hud-usage.json", "usage-seen.json", "jumps.jsonl", "app.lock", "pet-emit", "pet-emit.exe"].includes(name)) return false;
  }
  return true;
}

/** When to tell the boards (PushGate): once a burst has been quiet for `quiet`, or `maxWait`
 * after its first write, and no closer together than `gap` (each push costs the phones a read). */
class PushGate {
  constructor(quiet = 300, maxWait = 1500, gap = 4000) {
    Object.assign(this, { quiet, maxWait, gap, last: null, first: null });
  }
  note(now) {
    if (this.first === null) this.first = now;
    let at = Math.min(now + this.quiet, this.first + this.maxWait);
    if (this.last !== null && at < this.last + this.gap) at = this.last + this.gap;
    return at;
  }
  fired(now) {
    this.first = null;
    this.last = now;
  }
}

class BoardEvents {
  /** @param o.roots      () => folders to watch (those that exist are watched, looked at again each minute)
   *  @param o.dropReads  drops the board's kept reads */
  constructor(o) {
    this.roots = o.roots;
    this.dropReads = o.dropReads || (() => {});
    this.log = o.log || (() => {});
    this.watchers = new Map();
    this.listeners = [];
    this.gate = new PushGate();
    this.timer = null;
    this.recheck = null;
    this.count = 0;
  }

  on(fn) { this.listeners.push(fn); }

  start() {
    this.rewatch();
    if (!this.recheck) this.recheck = setInterval(() => this.rewatch(), 60000);
  }

  stop() {
    for (const w of this.watchers.values()) w.close();
    this.watchers.clear();
    if (this.recheck) clearInterval(this.recheck);
    this.recheck = null;
  }

  /** Watches the roots that exist now, and stops watching those that went. */
  rewatch() {
    const want = new Set(this.roots().filter((r) => { try { return fs.statSync(r).isDirectory(); } catch (_) { return false; } })
      .map((r) => path.resolve(r)));
    for (const [r, w] of this.watchers) if (!want.has(r)) { w.close(); this.watchers.delete(r); }
    for (const r of want) {
      if (this.watchers.has(r)) continue;
      try {
        const w = fs.watch(r, { recursive: true }, (_, file) => {
          // No name: events were lost, anything may have changed.
          if (!file || relevant(path.join(r, String(file)).replace(/\\/g, "/"))) this.note();
        });
        w.on("error", () => { w.close(); this.watchers.delete(r); });
        this.watchers.set(r, w);
      } catch (e) {
        this.log(`board events: can't watch ${r}: ${e.message}`);
      }
    }
  }

  note() {
    const at = this.gate.note(Date.now());
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.fire(), Math.max(0, at - Date.now()));
  }

  fire() {
    this.timer = null;
    this.gate.fired(Date.now());
    this.dropReads();
    this.count += 1;
    for (const fn of this.listeners) { try { fn(this.count); } catch (e) { this.log("board events: " + e.message); } }
  }
}

module.exports = { BoardEvents, PushGate, relevant };
