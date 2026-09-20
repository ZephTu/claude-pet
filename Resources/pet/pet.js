const pet = document.getElementById("pet");
const bubble = document.getElementById("bubble");
const panel = document.getElementById("panel");

/**
 * Tell Swift where the panel and bubble actually ended up, so the window can
 * pass clicks through everywhere else. Layout is content-dependent, so this is
 * measured rather than assumed.
 */
function reportLayout() {
  const box = (el) => {
    if (el.hidden) return null;
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  };
  const handler =
    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.layout;
  if (handler) handler.postMessage({ panel: box(panel), bubble: box(bubble) });
}

/* ---- Words ----------------------------------------------------------------
   Every string the user can read lives here rather than inside the markup
   builders below. Two reasons, and the second is the one that bit: state words
   are read TOGETHER — "needs you" in a row and "Needs you" as its heading are
   the same fact printed twice — and that is only visible when they sit next to
   each other in one place. Keeping them here is also what makes a future
   translation a change to this object instead of a hunt through DOM string
   concatenation.

   The panel is English throughout on purpose. Project names, branches and tool
   calls arrive in whatever the repository uses, so the surrounding chrome being
   one language is what keeps a row from reading as a mixture. */
const TEXT = {
  // Group headings.
  needsYou: "Needs you",
  finished: "Finished",
  running: "Running",
  // Row status, first line.
  approval: "Needs approval",
  reply: "Awaiting reply",
  working: "Working",
  quiet: "No recent activity",
  // Short on purpose. "Response complete" is 17 characters in a column that
  // shares ~200pt with the project name, and it pushed the name — the row's
  // first anchor — down to less width than the status word had. It also got
  // truncated to a different length on every row, because both columns were
  // shrinking in proportion to their own content.
  complete: "Answered",
  idle: "Idle",
  later: "later — ",
  done: "done",
  turns: " turns",
  // Second lines and footers.
  closed: "session closed",
  empty: "No live sessions",
  muted: " muted — say something to bring one back",
  droppedTail: " older unread finishes were discarded (queue full)",
  clear: "clear",
  // The alert card.
  approveLabel: "approve",
  replyBody: "waiting on your reply",
  // Quota meters. "used" is stated rather than implied: a bare percentage next
  // to a bar is read as either "how much is gone" or "how much is left", and
  // the two are opposite readings of the same picture.
  quotaUsed: "used",
};

/* ---- The message window ----------------------------------------------------
   ONE element with one variant at a time, not three components racing for the
   same corner — the pet has one mouth. `variant()` is the only thing that
   touches these classes, which is what stops a quota reading from keeping
   `.quota` while a chatter line is rendered into it: the bug that produced a
   sentence laid out in meter columns.

   Rank is the priority order from the design doc. A pushed line may only
   replace something of the SAME rank or lower; hover readouts are exempt
   because the user asked for those directly, and they are still refused while
   the alarm is up. */
const RANK = { alert: 5, notice: 4, warn: 3, quota: 2, readout: 2, chat: 1 };
const VARIANTS = ["alert", "notice", "warn", "quota", "readout", "chat"];

/** What is in the bubble right now; "" when it is down. */
let shown = "";

/**
 * Put the bubble into exactly one variant, clearing whatever it was in.
 * @param {string} name one of VARIANTS, or "" to leave it in no variant at all
 */
function variant(name) {
  bubble.classList.remove.apply(bubble.classList, VARIANTS);
  // Everything except the alarm shares the soft, wrapping, right-anchored base.
  if (name && name !== "alert") bubble.classList.add("chat");
  else bubble.classList.remove("chat");
  if (name) bubble.classList.add(name);
  shown = name || "";
}

/** May a pushed line of this kind take the bubble from what is in it now? */
function mayShow(name) {
  if (pet.dataset.mood === "urgent") return false;   // the alarm owns it outright
  if (!speaking || !shown) return true;
  return RANK[name] >= RANK[shown];
}

/**
 * Called from Swift on every state change.
 * @param {"idle"|"busy"|"waiting"|"urgent"} mood
 * @param {string|null} waitingProject project name for the urgent bubble
 * @param {string} waitingOn what that session is blocked on, e.g. "rm -rf build/"
 */
window.setMood = function (mood, waitingProject, waitingOn, motion) {
  pet.dataset.mood = mood;
  // Empty means "no opinion", which leaves the default (typing) in place.
  if (motion) { pet.dataset.motion = motion; } else { delete pet.dataset.motion; }
  // Waiting splits in two. `waitingOn` is only ever set by PermissionRequest,
  // so its presence is what distinguishes "may I run this" from "answer me".
  if (mood === "waiting" || mood === "urgent") {
    pet.dataset.ask = waitingOn ? "permission" : "question";
  } else {
    delete pet.dataset.ask;
  }
  if (mood === "urgent" && waitingProject) {
    // The alarm owns the bubble outright: it outranks anything being said, and
    // it must not be dismissed by a chatter timer that was already running.
    clearSpeech();
    variant("alert");
    alertCard(waitingProject, waitingOn);
    bubble.hidden = false;
  } else if (!speaking) {
    // Leaving `.alert` on a hidden bubble is how a later chatter line came back
    // wearing the alarm's colours.
    variant("");
    bubble.hidden = true;
  }
  reportLayout();
};

/**
 * The intervention card: WHICH session, then WHAT it wants.
 *
 * Two lines rather than one sentence. "api-server: rm -rf build/" made the
 * project name and the command one run of text, and the eye has to read all of
 * it to find either. Both shapes are the same card so that the two kinds of
 * interruption stay comparable — only the glyph and the second line differ.
 *
 * Naming the actual command is the whole point: it is what lets the user decide
 * without switching to that terminal. It arrives already collapsed, clamped to
 * 48 characters and stripped of leading directories by PermissionSummary, so a
 * heredoc or a long path cannot turn the card into a wall.
 *
 * @param {string} project the session's name
 * @param {string} on what it is blocked on, empty when it wants an answer
 */
function alertCard(project, on) {
  bubble.textContent = "";
  const head = document.createElement("div");
  head.className = "ahead";
  const glyph = document.createElement("span");
  glyph.className = "aglyph";
  // Two shapes, not two colours: with motion reduced and on a colour-blind
  // screen the glyph is still the thing that says which kind of ask this is.
  glyph.textContent = on ? "\u0021" : "\u003f";
  glyph.dataset.ask = on ? "permission" : "question";
  const name = document.createElement("span");
  name.className = "aname";
  // Project names are directory names and tab titles — arbitrary user text.
  name.textContent = project;
  head.append(glyph, name);

  const body = document.createElement("div");
  body.className = "abody";
  if (on) {
    const key = document.createElement("span");
    key.className = "akey";
    key.textContent = TEXT.approveLabel;
    const what = document.createElement("span");
    what.className = "awhat";
    what.textContent = on;
    body.append(key, what);
  } else {
    body.textContent = TEXT.replyBody;
  }
  bubble.append(head, body);
}

let speaking = false;
let speechTimer = null;

/**
 * Writes `text` into `el`, wrapping `emphasis` in a styled span.
 *
 * Built from text nodes rather than innerHTML: session names and project names
 * come from directory names and terminal titles, which are arbitrary user text.
 */
function fill(el, text, emphasis) {
  el.textContent = "";
  const at = emphasis ? text.indexOf(emphasis) : -1;
  if (at < 0) {
    el.textContent = text;
    return;
  }
  if (at > 0) el.appendChild(document.createTextNode(text.slice(0, at)));
  const span = document.createElement("span");
  span.className = "name";
  span.textContent = emphasis;
  el.appendChild(span);
  const rest = text.slice(at + emphasis.length);
  if (rest) el.appendChild(document.createTextNode(rest));
}

function clearSpeech() {
  speaking = false;
  // Every variant, not a hand-kept subset. The subset is what let `.quota`
  // survive into a chatter line and lay a sentence out in meter columns.
  variant("");
  if (speechTimer) {
    clearTimeout(speechTimer);
    speechTimer = null;
  }
}

/**
 * Show a line in the bubble for a while, then take it away.
 *
 * @param {string} text
 * @param {number} holdMs how long to leave it up; 0 keeps it until cleared,
 *   which is what the hover readout uses.
 * @param {string} [emphasis] a substring of `text` to set apart — the session's
 *   name, so the eye lands on WHICH one rather than on "done".
 */
window.say = function (text, holdMs, emphasis, kind) {
  const name = RANK[kind] ? kind : "chat";
  // A wellness nudge must not take the corner away from a quota warning just
  // because it arrived second — see Chatter.bubble(for:) for which is which.
  if (!mayShow(name)) return;
  clearSpeech();
  speaking = true;
  fill(bubble, text, emphasis);
  variant(name);
  bubble.hidden = false;
  reportLayout();
  if (holdMs > 0) {
    speechTimer = setTimeout(function () {
      clearSpeech();
      bubble.hidden = true;
      reportLayout();
    }, holdMs);
  }
};


/**
 * Show the quota readout as labelled meters.
 *
 * Bars rather than a sentence: two percentages being compared are read at a
 * glance from their lengths, while "5h 28% · week 39%, resets at 15:30" has to
 * be parsed word by word.
 *
 * @param {{label:string, percent:number, resetsIn:string}[]} rows
 * @param {string} fallback shown when there is no usable reading
 */
window.showQuota = function (rows, fallback) {
  if (pet.dataset.mood === "urgent") return;  // the alarm owns the bubble
  clearSpeech();
  speaking = true;
  variant("quota");
  if (!rows || !rows.length) {
    bubble.textContent = fallback;
    bubble.hidden = false;
    reportLayout();
    return;
  }
  // A heading, because a bare percentage beside a bar reads as either "how
  // much is gone" or "how much is left", and those are opposite readings of the
  // same picture. Stated once above the rows rather than repeated on each.
  bubble.innerHTML =
    '<div class="qhead">' + TEXT.quotaUsed + "</div>" +
    rows
      .map(function () {
        return (
          '<div class="qrow"><span class="qlabel"></span>' +
          '<span class="qbar"><span class="qfill"></span></span>' +
          '<span class="qpct"></span><span class="qreset"></span></div>'
        );
      })
      .join("");
  const els = bubble.querySelectorAll(".qrow");
  rows.forEach(function (r, i) {
    const pct = Math.max(0, Math.min(100, r.percent || 0));
    els[i].querySelector(".qlabel").textContent = r.label;
    els[i].querySelector(".qpct").textContent = pct + "%";
    els[i].querySelector(".qreset").textContent = r.resetsIn;
    const fill = els[i].querySelector(".qfill");
    fill.style.width = pct + "%";
    // Colour carries the same warning the pet's own lamp does.
    fill.dataset.level = pct >= 85 ? "high" : pct >= 60 ? "mid" : "low";
  });
  bubble.hidden = false;
  reportLayout();
};

/** Take the bubble down now — used when the pointer leaves the pet. */
window.hush = function () {
  if (!speaking) return;
  clearSpeech();
  bubble.hidden = true;
  reportLayout();
};

window.setMood("idle", null);

function ageText(seconds) {
  if (seconds < 60) return seconds + "s";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m";
  return Math.floor(seconds / 3600) + "h";
}

/**
 * What the status column says, and whether those words are ours.
 *
 * The distinction matters for layout, not for reading: a phrase out of TEXT is
 * a closed vocabulary of six or seven items and must never be truncated —
 * "Response c…" is not a state anybody can recognise. An activity summary is
 * arbitrary-length text from the tool call in flight, so that one may shrink.
 *
 * @returns {{text: string, fixed: boolean}}
 */
function whatText(s) {
  const ours = (text) => ({ text: text, fixed: true });
  // A postponed item says when it is coming back, so "later" stays a promise
  // rather than becoming "never".
  if (s.snoozedFor) return ours(TEXT.later + s.snoozedFor);
  // Blocked splits in two, and they are not the same interruption: one wants a
  // decision, the other wants typing. The row used to say "needs you" for both,
  // directly under a heading that already said "Needs you".
  if (s.state === "waiting") {
    return ours(s.asks === "permission" ? TEXT.approval : TEXT.reply);
  }
  // `activity` comes from the calls actually in flight. `tool` is only the name
  // of the last one seen, which goes on reading as "running" after it returned.
  // The one branch whose text is not ours, and so the one allowed to truncate.
  if (s.activity) return { text: s.activity, fixed: false };
  // Busy on paper, but nothing heard for a while — see StateAggregator.isQuiet.
  // Interrupting a turn emits no hook, so the last thing written stays "busy"
  // forever. This says what is actually known: it stopped saying anything. It
  // deliberately does not say "done", which nothing here is in a position to
  // know, and it corrects itself the moment the next hook lands.
  if (s.quiet) return ours(TEXT.quiet);
  if (s.state === "busy") return ours(TEXT.working);
  // An idle session that has answered is waiting on the next instruction —
  // worth distinguishing from one that is merely sitting there. The flag comes
  // from Swift rather than from the second line's text, so suppressing a
  // boilerplate notification does not silently downgrade the row.
  if (s.replied) return ours(TEXT.complete);
  return ours(TEXT.idle);
}

/** Markup for one live-session row. */
function sessionRowHTML(s) {
  const jumpable = s.termHandle ? " jumpable" : "";
  const napped = s.snoozedFor ? " napped" : "";
  // A 6px dot was the whole signal that a row wanted something. It is carried
  // by a left edge bar and a warm wash as well now — drawn with an inset
  // shadow and a background, so marking a row costs no width and cannot move
  // the column beside it. A postponed row gives the emphasis up: it was put
  // off deliberately, and it must stop competing with the ones that were not.
  const wants = s.state === "waiting" && !s.snoozedFor
    ? (s.urgent ? " needs urgent" : " needs") : "";
  // Only a blocked session can be postponed: there is nothing to put off about
  // one that is merely running.
  const clock = s.state === "waiting"
    ? '<span class="snooze" title="Remind me later">\u23f1</span>' : "";
  return (
    '<div class="row' + wants + jumpable + napped + '"><div class="line">' +
    '<span class="dot ' + (s.quiet ? "quiet" : s.state) + '"></span>' +
    (s.pinned ? '<span class="pin">\u25c6</span>' : "") +
    '<span class="proj"></span><span class="what"></span>' +
    // While a tool is running, the number that answers "is this stuck?" is how
    // long THAT call has been going — not how long the turn has. The turn's own
    // age comes back the moment nothing is running.
    '<span class="age">' + ageText(s.toolSeconds != null ? s.toolSeconds : s.waitedSeconds)
    + "</span>" +
    (s.termHandle ? '<span class="jump">\u2197</span>' : "") +
    clock +
    '<span class="mute" title="Mute this session">\u00d7</span>' +
    "</div>" +
    '<div class="detail"><span class="branch"></span><span class="note"></span></div>'
    + "</div>"
  );
}

/**
 * Markup for one finished-turn row.
 *
 * Deliberately a different shape from a session row: this is a record of
 * something that already happened, not a thing currently running. A row whose
 * session has gone says so rather than offering a jump that cannot work.
 */
function finishedRowHTML(f) {
  const jumpable = f.termHandle ? " jumpable" : "";
  return (
    '<div class="row done' + jumpable + '"><div class="line">' +
    '<span class="dot done"></span>' +
    '<span class="proj"></span>' +
    '<span class="what">' + (f.count > 1 ? f.count + TEXT.turns : TEXT.done) + "</span>" +
    '<span class="age">' + ageText(f.agoSeconds) + "</span>" +
    (f.termHandle ? '<span class="jump">\u2197</span>' : "") +
    '<span class="read" title="Mark as read">\u2713</span>' +
    "</div>" +
    (f.closed ? '<div class="detail closed">' + TEXT.closed + "</div>" : "") +
    "</div>"
  );
}

/**
 * Called from Swift whenever the panel's contents change.
 *
 * @param {object[]} list live sessions
 * @param {number} hiddenCount how many live sessions are muted
 * @param {object[]} finished unread finished turns, newest first
 * @param {number} dropped unread finishes discarded to stay under the cap
 */
window.setSessions = function (list, hiddenCount, finished, dropped) {
  const muted = hiddenCount || 0;
  const done = finished || [];
  let footer = "";
  if (dropped > 0) {
    // Losing news quietly is the one thing the queue exists to prevent, so a
    // forced discard is stated rather than absorbed.
    footer +=
      '<div class="muted-note dropped">' + dropped + TEXT.droppedTail + "</div>";
  }
  if (muted) {
    footer += '<div class="muted-note">' + muted + TEXT.muted + "</div>";
  }
  if (!list.length && !done.length) {
    panel.innerHTML = '<div class="empty">' + TEXT.empty + "</div>" + footer;
    hoverRow = null;
    reportLayout();
    return;
  }

  // Three groups, in the order they deserve attention: what wants something
  // from you, what just finished, then everything still running.
  const needs = list.filter(function (s) { return s.state === "waiting"; });
  const others = list.filter(function (s) { return s.state !== "waiting"; });
  /**
   * A heading carries its own count.
   *
   * This is the panel's summary, rather than a separate total pinned to the
   * top: the counts are wanted exactly where the groups are, and a fixed
   * summary row would have to say "1 session" above a single row that is
   * already the whole list. The number is tabular so it cannot shift the
   * heading as it ticks.
   */
  function heading(text, count, extra) {
    return '<div class="group">' + text
      + '<span class="gcount">' + count + "</span>"
      + (extra || "") + "</div>";
  }

  let html = "";
  if (needs.length) {
    html += heading(TEXT.needsYou, needs.length) + needs.map(sessionRowHTML).join("");
  }
  if (done.length) {
    html += heading(TEXT.finished, done.length,
                    '<span class="read-all" title="Mark all as read">' + TEXT.clear + "</span>")
          + done.map(finishedRowHTML).join("");
  }
  if (others.length) {
    // One group and nothing to tell it apart from is not a group. A lone
    // "Running" heading above the only rows there are is pure furniture.
    html += (needs.length || done.length ? heading(TEXT.running, others.length) : "")
          + others.map(sessionRowHTML).join("");
  }
  panel.innerHTML = html + footer;

  // Fill text via textContent so a project name can never inject markup.
  // The terminal handle goes through dataset for the same reason.
  const doneRows = panel.querySelectorAll(".row.done");
  done.forEach(function (f, i) {
    const row = doneRows[i];
    if (!row) return;
    row.querySelector(".proj").textContent = f.label;
    row.dataset.sessionId = f.sessionId || "";
    row.dataset.eventIds = (f.eventIds || []).join(" ");
    if (f.termHandle) {
      row.dataset.termKind = f.termKind || "";
      row.dataset.termHandle = f.termHandle;
    }
  });

  const rows = panel.querySelectorAll(".row:not(.done)");
  needs.concat(others).forEach(function (s, i) {
    rows[i].querySelector(".proj").textContent = s.project;
    // The branch lives on the second line, not the first. On one line it
    // competed with the activity column and won, so "Bash npm test 23s" got
    // squeezed down to "E 47s" — the branch is a disambiguator, and it must
    // never cost the row the thing it is actually reporting.
    rows[i].querySelector(".branch").textContent = s.branch || "";
    const what = whatText(s);
    const whatEl = rows[i].querySelector(".what");
    whatEl.textContent = what.text;
    // Our own words hold their width; only an activity summary gives.
    whatEl.classList.toggle("fixed", what.fixed);
    // A session sharing its project with another shows its name here instead of
    // the notification text: the first column cannot tell them apart.
    const note = rows[i].querySelector(".note");
    if (s.nameInline && s.title) {
      note.textContent = s.title;
      note.classList.add("name");
    } else {
      note.textContent = s.detail || "";
    }
    rows[i].querySelector(".detail").classList
      .toggle("blank", !s.branch && !note.textContent);
    rows[i].dataset.sessionId = s.sessionId || "";
    if (s.title) rows[i].dataset.title = s.title;
    if (s.termHandle) {
      rows[i].dataset.termKind = s.termKind || "";
      rows[i].dataset.termHandle = s.termHandle;
    }
  });
  // Rebuilding the list drops whatever row was highlighted.
  hoverRow = null;
  reportLayout();
};

/**
 * Says why clicking a finished row cleared it instead of opening anything.
 *
 * The row is already marked read by the time this runs — the click did do
 * something, and the line is here so it does not look like nothing happened.
 */
window.explainClosedRow = function () {
  window.say("that session's terminal is gone — cleared the row instead", 4000);
};

/**
 * Called from Swift for every scroll tick over the window. Swift owns the
 * mouse, so the panel cannot scroll itself.
 * @param {number} dy pixels to advance the list by
 */
window.scrollPanel = function (dy) {
  panel.scrollTop += dy;
  return panel.scrollTop;
};

/**
 * Called from Swift on a left click. The page never sees mouse events itself —
 * PetHostView consumes them so that drag and right-click can work at all.
 */
window.togglePanel = function () {
  panel.hidden = !panel.hidden;
  reportLayout();
  return !panel.hidden;
};

/**
 * Put the panel in a KNOWN state, rather than flipping whatever it is in.
 *
 * The toggle above is fine for a click, which is a request to flip. Everything
 * else — opening a pinned list at launch, the "we are done with the list now"
 * after a jump — knows which state it wants, and a blind flip in those places
 * closes an open panel exactly as happily as it opens a closed one.
 */
window.setPanelOpen = function (open) {
  const want = !open;
  if (panel.hidden !== want) {
    panel.hidden = want;
    reportLayout();
  }
  return !panel.hidden;
};

/**
 * Which session row is under this point, if it is one we can jump to.
 *
 * Swift owns the mouse (see PetHostView), so the page never receives a click of
 * its own — the coordinates arrive from Swift instead, already converted to CSS
 * space. Returns null for empty space, for the pet itself, and for rows whose
 * session has no addressable terminal.
 *
 * @param {number} x
 * @param {number} y
 * @returns {{kind: string, handle: string}|null}
 */
window.hitRow = function (x, y) {
  const el = document.elementFromPoint(x, y);
  if (!el || !el.closest) return null;
  // The × is checked first: it sits inside a row that may also be jumpable, and
  // the smaller target has to win or it would be impossible to press.
  const mute = el.closest(".mute");
  if (mute) {
    const row = mute.closest(".row");
    return { action: "mute", sessionId: (row && row.dataset.sessionId) || "" };
  }
  const clock = el.closest(".snooze");
  if (clock) {
    const row = clock.closest(".row");
    return { action: "snooze", sessionId: (row && row.dataset.sessionId) || "" };
  }
  if (el.closest(".read-all")) return { action: "readAll" };
  const tick = el.closest(".read");
  if (tick) {
    const row = tick.closest(".row");
    return { action: "read", eventIds: idsOf(row) };
  }
  // A finished row opens its session AND clears itself, but only in that order:
  // Swift marks it read after the jump, never before. A row with no handle has
  // nothing to open, so there the click is only the clearing.
  const finished = el.closest(".row.done");
  if (finished) {
    return {
      action: "openFinished",
      kind: finished.dataset.termKind || "",
      handle: finished.dataset.termHandle || "",
      eventIds: idsOf(finished),
    };
  }
  const row = el.closest(".row.jumpable");
  if (!row) return null;
  return {
    action: "jump",
    kind: row.dataset.termKind || "",
    handle: row.dataset.termHandle || "",
  };
};

/**
 * The hover readout for one session row.
 *
 * Structured rather than a paragraph, for the same reason the quota readout is
 * bars: these are four different KINDS of fact — where it is, how full it is,
 * how long it has been, what it last did — and running them together as a
 * sentence makes the eye read all of it to find any of it.
 *
 * @param {{path?:string, worktree?:string, context?:number, model?:string,
 *          turn?:string, quiet?:string, last?:string, lastBad?:boolean}} d
 */
window.showDetail = function (d) {
  if (pet.dataset.mood === "urgent") return;   // the alarm owns the bubble
  clearSpeech();
  speaking = true;
  variant("readout");
  bubble.textContent = "";

  function row(cls) {
    const el = document.createElement("div");
    el.className = cls;
    bubble.appendChild(el);
    return el;
  }
  function span(parent, cls, text) {
    const el = document.createElement("span");
    el.className = cls;
    el.textContent = text;
    parent.appendChild(el);
    return el;
  }

  if (d.path) {
    // Paths and branch names are user text, so every one of these is textContent.
    const head = row("dpath");
    span(head, "dwhere", d.path);
    if (d.worktree) span(head, "dtree", d.worktree);
  }

  if (typeof d.context === "number") {
    const meter = row("qrow");
    span(meter, "qlabel", "ctx");
    const bar = document.createElement("span");
    bar.className = "qbar";
    const fill = document.createElement("span");
    fill.className = "qfill";
    const pct = Math.max(0, Math.min(100, d.context));
    fill.style.width = pct + "%";
    // Same warning ramp as the quota meters and the antenna lamp.
    fill.dataset.level = pct >= 85 ? "high" : pct >= 60 ? "mid" : "low";
    bar.appendChild(fill);
    meter.appendChild(bar);
    span(meter, "qpct", pct + "%");
    if (d.model) span(meter, "qreset", d.model);
  } else if (d.model) {
    span(row("dclocks"), "dmodel", d.model);
  }

  if (d.turn) {
    const clocks = row("dclocks");
    span(clocks, "dkey", "turn");
    span(clocks, "dval", d.turn);
    if (d.quiet) {
      span(clocks, "dkey", "quiet");
      span(clocks, "dval", d.quiet);
    }
  }

  if (d.last) {
    const last = row("dlast");
    span(last, "ddot", d.lastBad ? "\u25b2" : "\u25cf").classList
      .add(d.lastBad ? "bad" : "ok");
    span(last, "dtext", d.last);
  }

  bubble.hidden = false;
  reportLayout();
};

/**
 * Sets the attention badge, or hides it when there is nothing to report.
 *
 * The pill widens for a three-character count ("99+") rather than letting the
 * text spill past its edge.
 *
 * @param {string} text "" to hide
 */
/**
 * Flip the layout so the pet sits on the left and the panel opens to its right.
 *
 * Called from Swift when the window moves near a screen's left edge. The page
 * only moves pixels; PetLayout.mirrored(_:) moves the hit boxes to match, and
 * the two have to be changed together.
 *
 * @param {boolean} on
 */
window.setMirrored = function (on) {
  document.getElementById("stage").classList.toggle("mirrored", !!on);
  reportLayout();
};

/**
 * Turn animation off while keeping every state readable.
 *
 * Also used when the window is not visible at all: a pet nobody can see has no
 * reason to be repainting sixty times a second.
 *
 * @param {boolean} on
 */
let flashTimer = null;

/**
 * A brief reaction that is not a state.
 *
 * A finished turn and a failed tool are moments, not conditions — the session
 * is not "in" them, it just passed through one. Holding a mood for them would
 * mean either lying about the current state or flickering back a second later,
 * so they get a short overlay on top of whatever the pet is actually doing.
 *
 * @param {"done"|"trouble"} kind
 */
window.flash = function (kind, pose, mark) {
  if (flashTimer) clearTimeout(flashTimer);
  pet.dataset.flash = kind;
  // The transient owns the pose and the glyph and puts the steady pair back
  // afterwards rather than letting them be lost. An empty `pose` means "keep
  // the one you have": an interrupted tool happens while the session carries
  // on working.
  if (mark) setMark(mark);
  if (pose) setPose(pose);
  flashTimer = setTimeout(function () {
    delete pet.dataset.flash;
    flashTimer = null;
    setMark(steadyMark);
    setPose(steadyPose);
  }, kind === "trouble" ? 2600 : 1600);
};

/**
 * A phase the session is in the middle of, currently only "compacting".
 * @param {string} phase "" to clear
 */
window.setPhase = function (phase) {
  if (phase) { pet.dataset.phase = phase; } else { delete pet.dataset.phase; }
};

window.setCalm = function (on) {
  document.getElementById("stage").classList.toggle("calm", !!on);
  // CSS cannot stop a WebGL renderer: the cat keeps warping its mesh however
  // many `animation: none` rules are aimed at the canvas element.
  if (cat) cat.setReducedMotion(!!on);
};

window.setBadge = function (text) {
  // The host-drawn count, for skins whose artwork has no chest to put one on.
  // Kept in step with the robot's rather than replacing it: the robot's sits
  // inside its own drawing and moves with it.
  const host = document.getElementById("count");
  host.textContent = text || "";
  host.hidden = !text;

  const g = document.getElementById("badge-count");
  if (!text) { g.classList.remove("on"); return; }
  const w = text.length <= 2 ? 11 : 16;
  const pill = g.querySelector(".badge-pill");
  pill.setAttribute("width", w);
  pill.setAttribute("x", -30 - w / 2);
  g.querySelector(".badge-num").textContent = text;
  g.classList.add("on");
};

/** The event ids a finished row stands for. */
function idsOf(row) {
  if (!row || !row.dataset.eventIds) return [];
  return row.dataset.eventIds.split(" ").filter(Boolean);
}

/**
 * The session id of the row under this point, for the row context menu.
 * Empty string for the pet itself and for empty space.
 *
 * @param {number} x
 * @param {number} y
 * @returns {string}
 */
window.rowSessionId = function (x, y) {
  const el = document.elementFromPoint(x, y);
  const row = el && el.closest ? el.closest(".row:not(.done)") : null;
  return (row && row.dataset.sessionId) || "";
};

let hoverRow = null;

/**
 * Highlight the jumpable row under this point. Also called with the pointer
 * outside the panel, which clears the highlight.
 *
 * CSS :hover cannot do this job: the page gets no mouse events at all, so Swift
 * forwards pointer moves here. Returns early when nothing changed, which is what
 * keeps a 60Hz stream of calls from touching the DOM 60 times a second.
 *
 * @param {number} x
 * @param {number} y
 */
window.setHoverAt = function (x, y) {
  const el = document.elementFromPoint(x, y);
  const row = el && el.closest ? el.closest(".row") : null;
  if (row === hoverRow) return;
  if (hoverRow) hoverRow.classList.remove("hot");
  hoverRow = row;
  if (row) row.classList.add("hot");
};


/* ---- Skins ---------------------------------------------------------------
 * The robot is CSS: every state it has is a rule, and swapping states costs
 * an attribute write. A painted skin cannot work that way — it has as many
 * poses as it has pictures — so the pose and the glyph are decided in Swift
 * (ClaudePetCore/PetSkin.swift, where they are unit-tested against all eleven
 * pet states) and pushed here. This file only applies them.
 */

/** The live CatPet renderer, or null while the robot is showing. */
let cat = null;
/** What the current STATE calls for, as opposed to a transient flash. */
let steadyMark = "none";
let steadyPose = "idle";

function setMark(token) {
  document.getElementById("mark").dataset.mark = token || "none";
}

function setPose(pose) {
  lastPose = pose || "idle";
  if (cat) cat.setState(lastPose);
}

/**
 * Switch the figure. Safe to call with the skin that is already showing.
 * @param {"robot"|"cat"} name
 */
window.setSkin = function (name) {
  const skin = name === "cat" ? "cat" : "robot";
  if (pet.dataset.skin === skin) return;
  pet.dataset.skin = skin;

  if (skin !== "cat") {
    // Disposed rather than hidden: a hidden canvas still holds its textures
    // and its animation frame, and this thing sits on the desktop all day.
    if (cat) { cat.dispose(); cat = null; }
    return;
  }
  if (cat) return;
  try {
    cat = new CatPet(document.getElementById("cat"), {
      idle: "skins/cat/assets/idle.png",
      working: "skins/cat/assets/working.png",
      waiting: "skins/cat/assets/waiting.png",
      sleeping: "skins/cat/assets/sleeping.png",
      urgent: "skins/cat/assets/urgent.png",
      reading: "skins/cat/assets/reading.png",
      compacting: "skins/cat/assets/compacting.png",
      finished: "skins/cat/assets/finished.png",
      "awaiting-agent": "skins/cat/assets/awaiting-agent.png",
    });
    cat.setReducedMotion(document.getElementById("stage").classList.contains("calm"));
    cat.ready.then(function () { if (cat) cat.setState(lastPose); })
             .catch(function (e) { skinFailed(e); });
  } catch (e) {
    skinFailed(e);
  }
};

/** Whatever pose Swift last asked for, replayed once the textures arrive. */
let lastPose = "idle";

/**
 * Called from Swift on every render. The pose is one of six; the glyph says
 * which KIND of waiting, which the one raised-paw picture cannot.
 */
window.setCatLook = function (pose, mark) {
  steadyPose = pose || "idle";
  steadyMark = mark || "none";
  // A flash in progress owns both; it restores these when it ends. Without this
  // guard a state push arriving mid-flash would cut the "done" bob short — and
  // one of those arrives on every tick.
  if (flashTimer) return;
  setMark(steadyMark);
  setPose(steadyPose);
};

/**
 * A skin that cannot draw itself falls back to the one that always can.
 * Silently showing nothing is the failure this whole app is against.
 */
function skinFailed(error) {
  // eslint-disable-next-line no-console
  console.error("skin failed, falling back to the robot:", error);
  if (cat) { cat.dispose(); cat = null; }
  pet.dataset.skin = "robot";
  const handler =
    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.layout;
  if (handler) handler.postMessage({ skinFailed: String(error) });
}
