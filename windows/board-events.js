// The board is told when what it shows may have changed (BoardEvents.swift / BoardPush.swift on
// the Mac): the files the board's reads come from are watched (the HQ root, hq's own folder, the
// pet's session states), and a burst of changes becomes one "changed" after it goes quiet. Each
// change first drops the board's kept reads (they are stale). The board window is told directly
// (main.js: window.hqPush), every phone over its `/events` stream (remote.js).
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
   *  @param o.root       () => the HQ root: pushes count as on only while it is watched
   *  @param o.config     hq's config file: written, the roots are looked at again soon
   *  @param o.dropReads  drops the board's kept reads */
  constructor(o) {
    this.roots = o.roots;
    this.root = o.root || null;
    this.config = o.config ? path.resolve(o.config).toLowerCase() : null;
    this.settle = [];
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

  /** Whether the HQ root is watched (BoardEvents.running): the pages may then poll slowly
   * (hqPushOn). A card edited under a root that couldn't be watched would push nothing. */
  get running() {
    if (!this.root) return this.watchers.size > 0;
    const r = this.root();
    return !!r && this.watchers.has(path.resolve(r));
  }

  start() {
    this.rewatch();
    if (!this.recheck) this.recheck = setInterval(() => this.rewatch(), 60000);
  }

  stop() {
    for (const w of this.watchers.values()) w.close();
    this.watchers.clear();
    if (this.recheck) clearInterval(this.recheck);
    this.recheck = null;
    for (const t of this.settle) clearTimeout(t);
    this.settle = [];
  }

  /** hq's config was written (a root set up or moved, `hq/install.sh --root`): the new root is
   * watched now, not at the next minute's look (the Mac's rewatchIfMoved). Again after a moment
   * and a few seconds: install.sh writes the config before it makes the root's folders, and a
   * read halfway through the write finds no root. */
  configChanged() {
    this.rewatch();
    for (const t of this.settle) clearTimeout(t);
    this.settle = [1000, 5000].map((ms) => setTimeout(() => this.rewatch(), ms));
  }

  /** Watches the roots that exist now, and stops watching those that went. Whether that changed
   * what is watched. */
  rewatch() {
    const before = [...this.watchers.keys()].join("|");
    const want = new Set(this.roots().filter((r) => { try { return fs.statSync(r).isDirectory(); } catch (_) { return false; } })
      .map((r) => path.resolve(r)));
    for (const [r, w] of this.watchers) if (!want.has(r)) { w.close(); this.watchers.delete(r); }
    for (const r of want) {
      if (this.watchers.has(r)) continue;
      try {
        const w = fs.watch(r, { recursive: true }, (_, file) => {
          if (file && this.config && path.resolve(r, String(file)).toLowerCase() === this.config) this.configChanged();
          // No name: events were lost, anything may have changed.
          if (!file || relevant(path.join(r, String(file)).replace(/\\/g, "/"))) this.note();
        });
        w.on("error", () => { w.close(); if (this.watchers.get(r) === w) this.watchers.delete(r); });
        this.watchers.set(r, w);
      } catch (e) {
        this.log(`board events: can't watch ${r}: ${e.message}`);
      }
    }
    const moved = [...this.watchers.keys()].join("|") !== before;
    // A root that appeared (or went): the boards read again, the new root's cards.
    if (moved && before) this.note();
    return moved;
  }

  /** A change no watched file says (a setting, the pet's in-memory state): the boards read again. */
  nudge() { this.note(); }

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
