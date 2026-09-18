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
    // Naming the actual command is the whole point: it lets the user decide
    // without switching to that terminal.
    const text = waitingOn
      ? waitingProject + ": " + waitingOn
      : waitingProject + " needs you";
    fill(bubble, text, waitingProject);
    bubble.classList.remove("chat");
    bubble.hidden = false;
  } else if (!speaking) {
    bubble.hidden = true;
  }
  reportLayout();
};

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
  bubble.classList.remove("quota", "readout");
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
window.say = function (text, holdMs, emphasis) {
  if (pet.dataset.mood === "urgent") return;  // the alarm is using the bubble
  clearSpeech();
  speaking = true;
  fill(bubble, text, emphasis);
  bubble.classList.add("chat");
  bubble.hidden = false;
  reportLayout();
  if (holdMs > 0) {
    speechTimer = setTimeout(function () {
      clearSpeech();
      bubble.hidden = true;
      bubble.classList.remove("chat");
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
  bubble.classList.add("chat", "quota");
  if (!rows || !rows.length) {
    bubble.textContent = fallback;
    bubble.hidden = false;
    reportLayout();
    return;
  }
  bubble.innerHTML = rows
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
  bubble.classList.remove("chat");
  reportLayout();
};

window.setMood("idle", null);

function ageText(seconds) {
  if (seconds < 60) return seconds + "s";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m";
  return Math.floor(seconds / 3600) + "h";
}

function whatText(s) {
  // A postponed item says when it is coming back, so "later" stays a promise
  // rather than becoming "never".
  if (s.snoozedFor) return "later — " + s.snoozedFor;
  if (s.state === "waiting") return "needs you";
  // `activity` comes from the calls actually in flight. `tool` is only the name
  // of the last one seen, which goes on reading as "running" after it returned.
  if (s.activity) return s.activity;
  if (s.state === "busy") return "thinking";
  // An idle session carrying a notification message is one that finished
  // talking and is waiting on a reply — worth distinguishing from a session
  // that is merely sitting there.
  if (s.detail) return "done talking";
  return "idle";
}

/** Markup for one live-session row. */
function sessionRowHTML(s) {
  const jumpable = s.termHandle ? " jumpable" : "";
  const napped = s.snoozedFor ? " napped" : "";
  // Only a blocked session can be postponed: there is nothing to put off about
  // one that is merely running.
  const clock = s.state === "waiting"
    ? '<span class="snooze" title="Remind me later">\u23f1</span>' : "";
  return (
    '<div class="row' + jumpable + napped + '"><div class="line">' +
    '<span class="dot ' + s.state + '"></span>' +
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
    '<span class="what">' + (f.count > 1 ? f.count + " turns" : "done") + "</span>" +
    '<span class="age">' + ageText(f.agoSeconds) + "</span>" +
    (f.termHandle ? '<span class="jump">\u2197</span>' : "") +
    '<span class="read" title="Mark as read">\u2713</span>' +
    "</div>" +
    (f.closed ? '<div class="detail closed">session closed</div>' : "") +
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
      '<div class="muted-note dropped">' + dropped +
      " older unread finishes were discarded (queue full)</div>";
  }
  if (muted) {
    footer +=
      '<div class="muted-note">' + muted + " muted — say something to bring one back</div>";
  }
  if (!list.length && !done.length) {
    panel.innerHTML = '<div class="empty">No live sessions</div>' + footer;
    hoverRow = null;
    reportLayout();
    return;
  }

  // Three groups, in the order they deserve attention: what wants something
  // from you, what just finished, then everything still running.
  const needs = list.filter(function (s) { return s.state === "waiting"; });
  const others = list.filter(function (s) { return s.state !== "waiting"; });
  function heading(text, extra) {
    return '<div class="group">' + text + (extra || "") + "</div>";
  }

  let html = "";
  if (needs.length) html += heading("Needs you") + needs.map(sessionRowHTML).join("");
  if (done.length) {
    html += heading("Finished", '<span class="read-all" title="Mark all as read">clear</span>')
          + done.map(finishedRowHTML).join("");
  }
  if (others.length) {
    html += (needs.length || done.length ? heading("Running") : "")
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
    rows[i].querySelector(".what").textContent = whatText(s);
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
  bubble.classList.add("chat", "readout");
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
window.flash = function (kind) {
  if (flashTimer) clearTimeout(flashTimer);
  pet.dataset.flash = kind;
  flashTimer = setTimeout(function () {
    delete pet.dataset.flash;
    flashTimer = null;
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
};

window.setBadge = function (text) {
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
