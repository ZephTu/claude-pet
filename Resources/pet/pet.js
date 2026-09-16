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
 */
window.setMood = function (mood, waitingProject) {
  pet.dataset.mood = mood;
  if (mood === "urgent" && waitingProject) {
    // The alarm owns the bubble outright: it outranks anything being said, and
    // it must not be dismissed by a chatter timer that was already running.
    clearSpeech();
    bubble.textContent = waitingProject + " 等你授权";
    bubble.classList.remove("chat");
    bubble.hidden = false;
  } else if (!speaking) {
    bubble.hidden = true;
  }
  reportLayout();
};

let speaking = false;
let speechTimer = null;

function clearSpeech() {
  speaking = false;
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
 */
window.say = function (text, holdMs) {
  if (pet.dataset.mood === "urgent") return;  // the alarm is using the bubble
  clearSpeech();
  speaking = true;
  bubble.textContent = text;
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
 * The session name of the row under this point, or "" for none.
 *
 * Separate from hitRow because hovering and clicking answer different questions:
 * a row with no terminal we can address is not clickable but still has a name
 * worth showing.
 *
 * @param {number} x
 * @param {number} y
 * @returns {string}
 */
window.rowTitle = function (x, y) {
  const el = document.elementFromPoint(x, y);
  const row = el && el.closest ? el.closest(".row") : null;
  return (row && row.dataset.title) || "";
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
  if (s.state === "waiting") return "等你授权";
  if (s.state === "busy") return s.tool || "忙着";
  // An idle session carrying a notification message is one that finished
  // talking and is waiting on a reply — worth distinguishing from a session
  // that is merely sitting there.
  if (s.detail) return "说完了";
  return "闲着";
}

/**
 * Called from Swift whenever the live session list changes.
 * @param {{project:string,state:string,tool:string,detail:string,waitedSeconds:number}[]} list
 */
window.setSessions = function (list, hiddenCount) {
  const muted = hiddenCount || 0;
  const footer = muted
    ? '<div class="muted-note">还静音着 ' + muted + ' 个，跟它说话就回来</div>'
    : "";
  if (!list.length) {
    panel.innerHTML = '<div class="empty">没有活跃的 session</div>' + footer;
    hoverRow = null;
    reportLayout();
    return;
  }
  panel.innerHTML = list
    .map(function (s) {
      const jumpable = s.termHandle ? " jumpable" : "";
      return (
        '<div class="row' + jumpable + '"><div class="line">' +
        '<span class="dot ' + s.state + '"></span>' +
        '<span class="proj"></span><span class="what"></span>' +
        '<span class="age">' + ageText(s.waitedSeconds) + "</span>" +
        (s.termHandle ? '<span class="jump">\u2197</span>' : "") +
        '<span class="mute" title="静音">\u00d7</span>' +
        "</div>" +
        '<div class="detail"></div></div>'
      );
    })
    .join("") + footer;
  // Fill text via textContent so a project name can never inject markup.
  // The terminal handle goes through dataset for the same reason.
  const rows = panel.querySelectorAll(".row");
  list.forEach(function (s, i) {
    rows[i].querySelector(".proj").textContent = s.project;
    rows[i].querySelector(".what").textContent = whatText(s);
    // A session sharing its project with another shows its name here instead of
    // the notification text: the first column cannot tell them apart.
    const second = rows[i].querySelector(".detail");
    if (s.nameInline && s.title) {
      second.textContent = s.title;
      second.classList.add("name");
    } else {
      second.textContent = s.detail || "";
    }
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
  const row = el.closest(".row.jumpable");
  if (!row) return null;
  return {
    action: "jump",
    kind: row.dataset.termKind || "",
    handle: row.dataset.termHandle || "",
  };
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
