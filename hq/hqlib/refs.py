"""A card's refs: canonical URLs and keys, merging a new ref into the list."""
import re


REF_URL_RE = re.compile(r"https?://[\x21\x23-\x26\x28-\x3b\x3d\x3f-\x7e]+")


# Canonical forms of a link: the thing it is about, not the view of it. A PR's /files tab, a Jira
# issue opened from a board, a Jenkins build's console or test report — each is the PR, the issue,
# the build. A link to one comment stays its own: it is evidence someone chose to keep. And any
# other #fragment is kept (#L10, #/runs/2, #Design all point somewhere else).
# board.js has the same patterns (CANON_* there); keep them in step.
URL_SPLIT_RE = re.compile(r"^(https?://)([^/?#]*)(.*)$", re.S | re.I)
GH_ITEM_RE = re.compile(r"^(/[^/?#]+/[^/?#]+/(?:pull|issues)/[0-9]+)(?:[/?#].*)?$", re.S)
GH_COMMENT_RE = re.compile(r"#(?:issuecomment-|discussion_r|pullrequestreview-|r)[0-9]+$")
JIRA_BROWSE_RE = re.compile(r"^(.*?/browse/[A-Z][A-Z0-9]+-[0-9]+)(?:[/?#].*)?$", re.S)
JIRA_PATH_RE = re.compile(r"^(.*?)/jira/[^?#]*/([A-Z][A-Z0-9]+-[0-9]+)(?:[/?#].*)?$", re.S)
JIRA_SELECTED_RE = re.compile(r"^(.*?)/jira/[^?#]*\?(?:[^#]*&)?selectedIssue=([A-Z][A-Z0-9]+-[0-9]+)(?:[&#].*)?$", re.S)
JIRA_COMMENT_RE = re.compile(r"[?&]focusedCommentId=([0-9]+)|#comment-([0-9]+)$")
JENKINS_BUILD_RE = re.compile(r"^((?:/[^/?#]+)*?(?:/job/[^/?#]+)+/[0-9]+)(?:/([^?#]*))?(?:[?#].*)?$", re.S)
# What may follow a build number on a Jenkins host not named "jenkins": its own pages only, so a
# careers site's /job/engineer/12345/apply is left alone.
JENKINS_VIEW_RE = re.compile(r"^(?:|console\w*|testReport\b.*|artifact\b.*|changes|parameters|"
                             r"pipeline\S*|flowGraphTable|execution\b.*|timestamps\b.*|"
                             r"injectedEnvVars|display\b.*|stages\b.*|api\b.*)/?$", re.S)
URL_TAIL = "/).,;:"


def is_jenkins(host, view=""):
    return "jenkins" in host or bool(JENKINS_VIEW_RE.match(view or ""))


def canonical_url(url):
    """The canonical form of one URL. Scheme and host compare in lower case. Then:
    GitHub  …/<o>/<r>/pull/<n> (or issues/<n>) with anything after it → …/<o>/<r>/pull/<n>,
            except a comment (#issuecomment-, #discussion_r, #pullrequestreview-, #r<n>), which
            stays as written;
    Jira    …/browse/KEY-1 with any query or fragment → …/browse/KEY-1, and a …/jira/…/KEY-1
            page (or one with selectedIssue=KEY-1) → …/browse/KEY-1; a comment (focusedCommentId=N or #comment-N) →
            …/browse/KEY-1?focusedCommentId=N;
    Jenkins …/job/<a>[/job/<b>…]/<build#>/<console, testReport, artifact/…> → …/job/<a>…/<build#>
            (a job URL without a build number stays as it is; on a host without "jenkins" in its
            name, only Jenkins' own pages after the build number count);
    anything else is kept whole, #fragment too (an empty `#` and, with no fragment, a trailing `/`
    go). Trailing `/).,;:` never count."""
    url = str(url).rstrip(URL_TAIL)
    m = URL_SPLIT_RE.match(url)
    if not m:
        return url
    host = m.group(2).lower()
    base, rest = m.group(1).lower() + host, m.group(3)
    g = GH_ITEM_RE.match(rest) if "github" in host else None
    if g:
        # A comment keeps its whole URL: a review comment (#r123) opens only on its /files page.
        return base + (rest if GH_COMMENT_RE.search(rest) else g.group(1))
    j = JIRA_BROWSE_RE.match(rest) or JIRA_PATH_RE.match(rest) or JIRA_SELECTED_RE.match(rest)
    if j:
        c = JIRA_COMMENT_RE.search(rest)
        issue = j.group(1) if j.re is JIRA_BROWSE_RE else j.group(1) + "/browse/" + j.group(2)
        return base + issue + (f"?focusedCommentId={c.group(1) or c.group(2)}" if c else "")
    b = JENKINS_BUILD_RE.match(rest)
    if b and is_jenkins(host, b.group(2)):
        return base + b.group(1)
    rest = rest[:-1] if rest.endswith("#") else rest
    return base + (rest if "#" in rest else rest.rstrip("/"))


def ref_key(ref):
    """What makes two refs the same: the thing they point to, not their title — "smoke #9 URL" and
    "smoke #9 (passed) URL" are one ref, and so are a PR and its /files tab. Only a ref with
    exactly one URL is keyed by it: its canonical_url, minus the trailing `/` and the `).,;:` a
    sentence leaves stuck to it (the URL regex is ASCII-only, so full-width `）。，；：` never reach
    the match). A ref without a URL (a ticket key), or with two or more, is its own text with
    whitespace collapsed — so merging can't drop a second link.
    A leading `!` (the key mark, see KEY_MARK) is not part of what a ref is.
    The board keys refs the same way (refKey in board.js); keep the two in step."""
    text = unmarked(ref)
    urls = REF_URL_RE.findall(text)
    if len(urls) == 1:
        return canonical_url(urls[0])
    return " ".join(text.split())


# A ref written with a leading "! " is a key link the card keeps even though it points to one step
# of the work (a build, a comment) — see process_ref.
KEY_MARK = "! "


def key_marked(ref):
    return str(ref).lstrip().startswith("!")


def unmarked(ref):
    text = str(ref).strip()
    return text[1:].lstrip() if text.startswith("!") else text


def _lower_host(url):
    m = URL_SPLIT_RE.match(url)
    return m.group(1).lower() + m.group(2).lower() + m.group(3) if m else url


def ref_url_is_canonical(ref):
    """A one-URL ref whose link already is the canonical one (up to the case of its host, and the
    trailing `/).,;:`): its title describes the thing itself, not one view of it."""
    urls = REF_URL_RE.findall(str(ref))
    if len(urls) != 1:
        return False
    u = urls[0].rstrip(URL_TAIL)
    return _lower_host(u) == canonical_url(u)


def with_canonical_url(ref):
    """The ref with its one URL written in canonical form, the title text kept as it is."""
    text = str(ref)
    found = list(REF_URL_RE.finditer(text))
    if len(found) != 1 or ref_url_is_canonical(text):
        return text
    m = found[0]
    u = m.group(0).rstrip(URL_TAIL)
    return text[:m.start()] + canonical_url(u) + text[m.start() + len(u):]


def merge_refs(have, new):
    """`have` with `new` added, one entry per link, at the place the first of them had. An entry
    with no other of its key stays exactly as written. Entries with the same key become one: its
    URL the canonical one, its title that of an entry already linking
    to the canonical URL (it names the thing itself; the newest such one, so a title can move on —
    PR #9 open → merged), else the newest entry's. Duplicates already in `have` collapse the same
    way, and merging the result again changes nothing."""
    order, groups = [], {}
    for r in list(have) + list(new):
        r = str(r).strip()
        if not r:
            continue
        k = ref_key(r)
        if k not in groups:
            groups[k] = []
            order.append(k)
        groups[k].append(r)
    out = []
    for k in order:
        rs = groups[k]
        if len(set(rs)) == 1:      # nothing merged: the link stays exactly as it was written
            out.append(rs[0])
            continue
        # The key mark stays with the link whichever entry's title wins.
        mark = KEY_MARK if any(key_marked(r) for r in rs) else ""
        rs = [unmarked(r) for r in rs]
        exact = [r for r in rs if ref_url_is_canonical(r)]
        out.append(mark + with_canonical_url(exact[-1] if exact else rs[-1]))
    return out
