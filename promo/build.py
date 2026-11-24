#!/usr/bin/env python3
"""Writes the film: index.html and compositions/*.html, from SPEC.md's shot list.

Every picture comes from the real app (assets/board/*.png from scripts/shots-all.sh, the
panel stills, the cat's atlases); this file only places them, moves the camera, the cursor
and the cat, and times it all to the narration (assets/vo/*.srt). Run it after changing any
timing, then `npx hyperframes check`.

    python3 build.py
"""
import json
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
FPS_CAT = 12

# ------------------------------------------------------------------ narration
NARR = dict(json.load(open(HERE / "demo/narration.json")))


def srt(sid):
    cues = []
    for block in (HERE / f"assets/vo/{sid}.srt").read_text().strip().split("\n\n"):
        lines = block.strip().split("\n")
        a, b = lines[1].split(" --> ")
        ts = lambda s: (lambda h, m, rest: int(h) * 3600 + int(m) * 60 + float(rest.replace(",", ".")))(*s.split(":"))
        cues.append((ts(a), ts(b), "".join(lines[2:])))
    return cues


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True).stdout
    return float(out.strip())


# ------------------------------------------------------------------ the desktop
# The board window: the 2x stills (2360x1464 = 1180x732 CSS px) shown 1560 wide.
WX, WY, WW, TB = 180, 42, 1560, 28
K = WW / 1180
WH = TB + 732 * K


def bx(cx):
    return WX + cx * K


def by(cy):
    return WY + TB + cy * K


# The pet in the desktop's bottom-right corner (cell top-left, cell size).
CAT = (1650, 835, 220)
CATC = (CAT[0] + CAT[2] / 2, CAT[1] + CAT[2] * 0.55)

# The session list beside the cat: panel-*.png is the 480x280 window at 2x; the panel itself
# is its left 625 px, the still cat to its right is cropped off (ours is animated).
PF = 1.05
PNL = (CAT[0] + 15 - 625 * PF, CAT[1] + CAT[2] - 560 * PF)


def pnl(x, y):
    return PNL[0] + x * PF, PNL[1] + y * PF


CLIPS = json.load(open(HERE / "assets/cat/clips.json"))["clips"]

CSS = r"""
@font-face { font-family: "PF"; font-weight: 400; src: local("PingFangSC-Regular"), local("PingFang SC"); }
@font-face { font-family: "PF"; font-weight: 500; src: local("PingFangSC-Medium"), local("PingFang SC"); }
@font-face { font-family: "PF"; font-weight: 600; src: local("PingFangSC-Semibold"), local("PingFang SC"); }
#root { position: absolute; inset: 0; overflow: hidden; background: #2b2a28; font-family: "PF", sans-serif; color: #e8ebf1; }
#root .grain { position: absolute; inset: 0; opacity: .05; background-size: 256px 256px;
  background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='256' height='256'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' seed='3'/></filter><rect width='256' height='256' filter='url(%23n)'/></svg>"); }
#root .cam { position: absolute; left: 0; top: 0; width: 1920px; height: 1080px; }
#root .win { position: absolute; border-radius: 12px; overflow: hidden; background: #1a1d24;
  box-shadow: 0 24px 60px rgba(0,0,0,.45), 0 0 0 1px rgba(255,255,255,.06); }
#root .win .bar { position: absolute; left: 0; top: 0; right: 0; height: 28px; background: #23262e; }
#root .win .bar i { position: absolute; top: 9px; width: 11px; height: 11px; border-radius: 50%; }
#root .win .bar span { position: absolute; left: 0; right: 0; top: 6px; text-align: center; font-size: 13px; color: #8a909c; }
#root .win img.st { position: absolute; left: 0; width: 100%; }
#root .hl { position: absolute; border: 3px solid #f2a541; border-radius: 10px; opacity: 0; }
#root .cover { position: absolute; background: #1a1d24; opacity: 0; }
#root .typed { position: absolute; white-space: nowrap; color: #e8ebf1; clip-path: inset(0 100% 0 0); }
#root .spr { position: absolute; background-repeat: no-repeat; --f: 0;
  --i: mod(var(--f), var(--n));
  background-position: calc(mod(var(--i), 8) * var(--s) * -1) calc(round(down, var(--i) / 8, 1) * var(--s) * -1); }
#root .cur { position: absolute; left: 0; top: 0; width: 34px; height: 50px; opacity: 0; }
#root .rip { position: absolute; width: 56px; height: 56px; margin: -28px 0 0 -28px; border-radius: 50%;
  border: 3px solid #ef6f5a; opacity: 0; }
#root .term { position: absolute; border-radius: 10px; overflow: hidden; background: #15171c;
  box-shadow: 0 18px 44px rgba(0,0,0,.4), 0 0 0 1px rgba(255,255,255,.06); }
#root .term .tb { position: absolute; left: 0; right: 0; top: 0; height: 30px; background: #22252c; }
#root .term .tb i { position: absolute; top: 10px; width: 11px; height: 11px; border-radius: 50%; }
#root .term .tb span { position: absolute; left: 70px; right: 12px; top: 6px; text-align: center; font-size: 14px; color: #8a909c;
  white-space: nowrap; overflow: hidden; }
#root .term .tc { position: absolute; left: 0; right: 0; top: 30px; bottom: 0; overflow: hidden; padding: 12px 16px; }
#root .term .tl { font-family: "JetBrains Mono", "PF", monospace; white-space: pre-wrap; line-height: 1.5; color: #c9ced8; }
#root .term .tl div { min-height: 1.5em; }
#root .tl .u { color: #f2a541; } #root .tl .t { color: #7cc4a4; } #root .tl .d { color: #8f96a3; }
#root .tl .w { color: #ef6f5a; } #root .tl .b { color: #9db4ff; }
#root .tl .box { border: 1.5px solid #ef6f5a; border-radius: 8px; padding: 8px 12px; margin: 6px 0; }
#root .lab { position: absolute; left: 150px; width: 820px; opacity: 0; }
#root .lab b { display: block; font-size: 104px; font-weight: 600; letter-spacing: -1px; color: #fff; }
#root .lab em { display: block; font-style: normal; font-size: 46px; font-weight: 500; color: #f2a541; margin-top: 14px; }
#root .clock { position: absolute; right: 48px; top: 26px; font-size: 30px; font-weight: 500; color: rgba(255,255,255,.78);
  opacity: 0; letter-spacing: .5px; }
#root .big { position: absolute; left: 0; right: 0; text-align: center; color: #fff; opacity: 0; }
#root .bubble { position: absolute; left: 0; top: 0; padding: 14px 22px; border-radius: 18px; background: #f2a541; color: #1a1d24;
  font-size: 26px; font-weight: 600; white-space: nowrap; opacity: 0; }
#root .dim { position: absolute; inset: 0; background: #000; opacity: 0; }
"""

CURSOR_SVG = ('<svg viewBox="0 0 24 36" width="34" height="50"><path d="M2 2 L2 28 L8.5 22 L13 33 L17.5 31 L13 20.5 L21.5 20.5 Z" '
              'fill="#111" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg>')


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Scene:
    def __init__(self, sid, slot, vo_off):
        self.id, self.slot, self.vo_off = sid, slot, vo_off
        self.cues = srt(sid)
        self.cam_html, self.over_html, self.js, self.sfx = [], [], [], []
        self.n = 0
        self.cur_pos = None
        self.win_states = None

    def uid(self, what):
        self.n += 1
        return f"{self.id}-{what}{self.n}"

    # When the narration says `phrase`: its cue's start, plus its share of the cue's length.
    def at(self, phrase, after=0.0):
        for a, b, text in self.cues:
            i = text.find(phrase)
            if i >= 0:
                return round(self.vo_off + a + (i / len(text)) * (b - a) + after, 3)
        raise KeyError(f"{self.id}: {phrase!r} not in narration")

    def t(self, s):
        self.js.append(s)

    # -------------------------------------------------------------- camera
    def cam_xy(self, px, py, s, sx=960, sy=540):
        return round(sx - s * px, 2), round(sy - s * py, 2), s

    def cam_set(self, px, py, s=1.0, sx=960, sy=540):
        x, y, s = self.cam_xy(px, py, s, sx, sy)
        self.t(f'tl.set("#{self.id}-cam", {{ x: {x}, y: {y}, scale: {s} }}, 0);')

    def cam(self, t, px, py, s, dur=0.5, ease="expo.inOut", sx=960, sy=540):
        x, y, s = self.cam_xy(px, py, s, sx, sy)
        self.t(f'tl.to("#{self.id}-cam", {{ x: {x}, y: {y}, scale: {s}, duration: {dur}, ease: "{ease}" }}, {t});')

    # -------------------------------------------------------------- the board window
    def window(self, states, first=None, title="HQ"):
        """states: list of png names in assets/board; the first (or `first`) shows at 0."""
        self.win_states = states
        first = first or states[0]
        imgs = "".join(f'<img class="st" id="{self.id}-im-{s}" src="assets/board/{s}.png" style="top:{TB}px;opacity:{1 if s == first else 0}">'
                       for s in states)
        self.cur_state = first
        self.cam_html.append(
            f'<div class="win" id="{self.id}-win" style="left:{WX}px;top:{WY}px;width:{WW}px;height:{WH:.1f}px">'
            f'<div class="bar"><i style="left:12px;background:#ef6f5a"></i><i style="left:30px;background:#f2c14e"></i>'
            f'<i style="left:48px;background:#7cc4a4"></i><span>{title}</span></div>{imgs}<div id="{self.id}-wo"></div></div>')

    def show(self, t, state, dur=0.2):
        """Cross-dissolve the window to another still (6 frames)."""
        old = self.cur_state
        self.t(f'tl.to("#{self.id}-im-{state}", {{ opacity: 1, duration: {dur}, ease: "none" }}, {t});')
        self.t(f'tl.set("#{self.id}-im-{old}", {{ opacity: 0 }}, {round(t + dur, 3)});')
        self.cur_state = state

    def in_win(self, html):
        """Markup positioned in window pixels, above the stills."""
        mark = f'<div id="{self.id}-wo"></div>'
        k = next(k for k, h in enumerate(self.cam_html) if mark in h)
        self.cam_html[k] = self.cam_html[k].replace(mark, html + mark)

    def highlight(self, t, x, y, w, h, out=None, pad=6):
        """An amber outline around CSS-px rect (x, y, w, h) of the board."""
        i = self.uid("hl")
        self.in_win(f'<div class="hl" id="{i}" style="left:{x * K - pad:.1f}px;top:{TB + y * K - pad:.1f}px;'
                    f'width:{w * K + 2 * pad:.1f}px;height:{h * K + 2 * pad:.1f}px"></div>')
        self.t(f'tl.fromTo("#{i}", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.3, ease: "power2.out" }}, {t});')
        if out:
            self.t(f'tl.to("#{i}", {{ opacity: 0, duration: 0.25 }}, {out});')

    def type_in(self, t, x, y, text, dur, size=12.5, out=None, cover=160):
        """Text typing into a field at CSS px (x, y) of the board, over its placeholder (`cover` px wide)."""
        i = self.uid("ty")
        self.in_win(f'<div class="cover" id="{i}c" style="left:{(x - 2) * K:.1f}px;top:{TB + (y - 2) * K:.1f}px;width:{cover * K:.1f}px;'
                    f'height:{(size + 6) * K:.1f}px"></div>'
                    f'<div class="typed" id="{i}" style="left:{x * K:.1f}px;top:{TB + y * K:.1f}px;font-size:{size * K:.1f}px">{esc(text)}</div>')
        self.t(f'tl.fromTo("#{i}c", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.05 }}, {t});')
        n = max(1, len(text))
        self.t(f'tl.fromTo("#{i}", {{ clipPath: "inset(0 100% 0 0)" }}, {{ clipPath: "inset(0 0% 0 0)", duration: {dur}, ease: "steps({n})" }}, {t});')
        if out:
            self.t(f'tl.set("#{i}, #{i}c", {{ opacity: 0 }}, {out});')
        self.sfx.append((t, "typing", 0.35, min(dur + 0.1, 1.5)))

    # -------------------------------------------------------------- cursor
    def cursor(self, x, y, t_in=0.0):
        self.cam_html.append(f'<div class="cur" id="{self.id}-cur">{CURSOR_SVG}</div>')
        self.t(f'tl.set("#{self.id}-cur", {{ x: {x}, y: {y} }}, 0);')
        self.t(f'tl.to("#{self.id}-cur", {{ opacity: 1, duration: 0.2 }}, {t_in});')
        self.cur_pos = (x, y)

    def cursor_back(self, t, x, y):
        """The cursor again, after cursor_out: one element per scene, so a second cursor() would
        put a twin under the same id (GSAP would move both)."""
        self.t(f'tl.set("#{self.id}-cur", {{ x: {x:.1f}, y: {y:.1f} }}, {t});')
        self.t(f'tl.to("#{self.id}-cur", {{ opacity: 1, duration: 0.2 }}, {t});')
        self.cur_pos = (x, y)

    def move(self, t, x, y, dur=0.6, ease="power2.inOut"):
        self.t(f'tl.to("#{self.id}-cur", {{ x: {x:.1f}, y: {y:.1f}, duration: {dur}, ease: "{ease}" }}, {t});')
        self.cur_pos = (x, y)

    def click(self, t, sfx=True):
        x, y = self.cur_pos
        i = self.uid("rip")
        # immediateRender off: a fromTo would otherwise paint the ring at its start values from 0 s
        self.cam_html.append(f'<div class="rip" id="{i}" style="left:{x:.1f}px;top:{y:.1f}px"></div>')
        self.t(f'tl.fromTo("#{i}", {{ scale: 0.3, opacity: 0.95 }}, {{ scale: 1.5, opacity: 0, duration: 0.45, ease: "power2.out", immediateRender: false }}, {t});')
        self.t(f'tl.to("#{self.id}-cur", {{ scale: 0.85, duration: 0.06, yoyo: true, repeat: 1, transformOrigin: "0 0" }}, {t});')
        if sfx:
            self.sfx.append((t, "click", 0.55, None))

    def cursor_out(self, t):
        self.t(f'tl.to("#{self.id}-cur", {{ opacity: 0, duration: 0.2 }}, {t});')

    # -------------------------------------------------------------- the cat
    def cat(self, name, t_on=0.0, t_off=None, box=CAT, once=False, parent=None, eid=None):
        """One of the cat's real loops (or a one-shot transition with once=True) at box."""
        c = CLIPS[name]
        x, y, s = box
        i = eid or self.uid("cat")
        html = (f'<div class="spr" id="{i}" style="left:{x}px;top:{y}px;width:{s}px;height:{s}px;--s:{s}px;--n:{c["frames"]};'
                f'background-image:url({c["src"]});background-size:{8 * s}px auto;opacity:{1 if t_on <= 0 else 0}"></div>')
        (parent if parent is not None else self.cam_html).append(html)
        if t_on > 0:
            self.t(f'tl.set("#{i}", {{ opacity: 1 }}, {t_on});')
        if once:
            n = c["frames"] - 1
            self.t(f'tl.fromTo("#{i}", {{ "--f": 0 }}, {{ "--f": {n}, duration: {n / FPS_CAT:.3f}, ease: "steps({n})" }}, {t_on});')
        else:
            end = t_off if t_off is not None else self.slot
            n = max(1, int((end - t_on) * FPS_CAT))
            self.t(f'tl.fromTo("#{i}", {{ "--f": 0 }}, {{ "--f": {n}, duration: {n / FPS_CAT:.3f}, ease: "steps({n})" }}, {t_on});')
        if t_off is not None:
            self.t(f'tl.set("#{i}", {{ opacity: 0 }}, {t_off});')
        return i

    # -------------------------------------------------------------- output
    def write(self):
        body = (f'<div class="grain"></div><div class="cam" id="{self.id}-cam">{"".join(self.cam_html)}</div>'
                + "".join(self.over_html))
        js = "\n    ".join([f'tl.set("#{self.id}-cam", {{ transformOrigin: "0 0" }}, 0);'] + self.js)
        html = f"""<template>
  <style>{CSS}</style>
  <div id="root" data-composition-id="{self.id}" data-width="1920" data-height="1080">
    {body}
  </div>
  <script>
    const tl = gsap.timeline({{ paused: true }});
    {js}
    tl.set({{}}, {{}}, {self.slot});
    window.__timelines["{self.id}"] = tl;
  </script>
</template>
"""
        (HERE / "compositions" / f"{self.id}.html").write_text(html)


# ------------------------------------------------------------------ terminals (illustrative)
def term(sc, x, y, w, h, title, lines, size=15, scroll=0.0, eid=None, opacity=1, texture=False):
    i = eid or sc.uid("term")
    body = "".join(f'<div class="{c}">{esc(tx)}</div>' if c != "box" else f'<div class="box">{tx}</div>' for c, tx in lines)
    sc.cam_html.append(
        f'<div class="term" id="{i}"{" data-layout-ignore" if texture else ""} style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;opacity:{opacity}">'
        f'<div class="tb"><i style="left:12px;background:#ef6f5a"></i><i style="left:30px;background:#f2c14e"></i>'
        f'<i style="left:48px;background:#7cc4a4"></i><span>{esc(title)}</span></div>'
        f'<div class="tc"><div class="tl" id="{i}-tl" style="font-size:{size}px">{body}</div></div></div>')
    if scroll:
        sc.t(f'tl.fromTo("#{i}-tl", {{ y: 0 }}, {{ y: {-scroll}, duration: {sc.slot}, ease: "none" }}, 0);')
    return i


PERMISSION = ('<div class="w">Bash command</div><div>  git push origin release-notes</div>'
              '<div class="d">  推送 release-notes 分支</div><div>Do you want to proceed?</div>'
              '<div class="u">❯ 1. Yes</div><div>  2. No</div>')

WALL = [
    ("shop-api — 结账重试", [("u", "> 支付网关慢的时候结账会超时，查一下"), ("", "⏺ Read(src/checkout/charge.ts)"), ("d", "  ⎿  Read 142 lines"),
                         ("", "⏺ Bash(npm test -- checkout)"), ("w", "  ⎿  1 failing: timeout after 5000ms"), ("", "⏺ Read(src/gateway/client.ts)"),
                         ("d", "  ⎿  Read 88 lines"), ("", "⏺ 超时每次都在 4.8 秒复现"), ("", "⏺ Bash(npm run sandbox:504)"), ("d", "  ⎿  504 ×3"),
                         ("", "✻ Thinking…")]),
    ("web-app — 深色模式", [("u", "> 仪表盘的深色模式再打磨一下"), ("", "⏺ Update(src/theme/tokens.ts)"), ("t", "  ⎿  31 additions, 31 removals"),
                        ("", "⏺ Bash(npm run test:contrast)"), ("d", "  ⎿  chart.axis 3.9:1 < 4.5"), ("", "⏺ Update(src/charts/palette.ts)"),
                        ("t", "  ⎿  6 additions"), ("", "⏺ Bash(npm run test:contrast)"), ("t", "  ⎿  all 48 pass"), ("", "✻ Working…")]),
    ("infra — CI runner", [("u", "> 把 CI 迁到新的 runner"), ("", "⏺ Read(.github/workflows/ci.yml)"), ("d", "  ⎿  Read 64 lines"),
                           ("", "⏺ Update(.github/workflows/ci.yml)"), ("t", "  ⎿  runs-on: linux-arm64"), ("", "⏺ Bash(gh run watch)"),
                           ("t", "  ⎿  lint ✓"), ("w", "  ⎿  test ✗ node 22 missing"), ("", "✻ Thinking…")]),
    ("web-app — 发版说明", [("u", "> 写 2.14 的发版说明"), ("", "⏺ Bash(git log v2.13..HEAD)"), ("d", "  ⎿  41 commits"),
                        ("", "⏺ Write(RELEASE_NOTES.md)"), ("t", "  ⎿  Wrote 58 lines"), ("", "⏺ 写好了，推一下分支给你 review"), ("box", PERMISSION)]),
    ("shop-api — 规格索引", [("u", "> 给商品规格建索引"), ("", "⏺ Read(src/search/indexer.ts)"), ("d", "  ⎿  Read 210 lines"),
                          ("", "⏺ Bash(npm run reindex -- --batch 500)"), ("d", "  ⎿  12000 / 40000"), ("d", "  ⎿  16500 / 40000"),
                          ("d", "  ⎿  21000 / 40000"), ("", "✻ Working…")]),
    ("docs — API 文档", [("u", "> 把新的结账接口写进文档"), ("", "⏺ Read(openapi.yaml)"), ("d", "  ⎿  Read 1204 lines"),
                       ("", "⏺ Update(docs/checkout.md)"), ("t", "  ⎿  24 additions"), ("", "⏺ Bash(npm run docs:build)"), ("t", "  ⎿  built in 3.2s"),
                       ("", "✻ Thinking…")]),
    ("web-app — 登录测试", [("u", "> 登录测试又挂了"), ("", "⏺ Bash(npx playwright test login --repeat 20)"), ("w", "  ⎿  3 flaky / 20"),
                        ("", "⏺ Read(tests/login.spec.ts)"), ("d", "  ⎿  Read 96 lines"), ("", "⏺ 是 cookie 写入和跳转的竞态"), ("", "✻ Thinking…")]),
    ("infra — 备份", [("u", "> 看一下昨晚的备份"), ("", "⏺ Bash(./scripts/nightly-backup.sh --dry-run)"), ("t", "  ⎿  snapshot ok · 12.4 GB"),
                    ("", "⏺ Bash(aws s3 ls backups/ | tail -3)"), ("d", "  ⎿  3 objects"), ("", "✻ Working…")]),
]
WALL_RECT = (60, 60, 1500, 960)


def wall(sc, opacity=1.0, scroll=True, eid="wall"):
    x0, y0, w, h = WALL_RECT
    cw, ch = (w - 3 * 20) / 4, (h - 20) / 2
    ids = []
    wrap = []
    for k, (title, lines) in enumerate(WALL):
        cx, cy = x0 + (k % 4) * (cw + 20), y0 + (k // 4) * (ch + 20)
        # the busy ones carry on scrolling; the one waiting on you sits still
        ids.append(term(sc, round(cx), round(cy), round(cw), round(ch), title, lines + lines if k != 3 else lines,
                        size=14, scroll=(0 if (k == 3 or not scroll) else 40 + 12 * k), eid=f"{sc.id}-{eid}{k}", opacity=opacity,
                        texture=True))
    return ids


def wall_rect(k):
    x0, y0, w, h = WALL_RECT
    cw, ch = (w - 3 * 20) / 4, (h - 20) / 2
    return x0 + (k % 4) * (cw + 20), y0 + (k // 4) * (ch + 20), cw, ch


# ------------------------------------------------------------------ the shots
def s01():
    sc = Scene("s01", 12.0, 0.8)
    ids = wall(sc)
    x, y, w, h = wall_rect(3)
    sc.cam_html.append(f'<div class="hl" id="s01-alert" style="left:{x - 6}px;top:{y - 6}px;width:{w + 12}px;height:{h + 12}px;'
                       f'border-color:#ef6f5a;border-radius:14px"></div>')
    sc.cat("urgent")
    sc.over_html.append('<div class="clock" id="s01-clock">周二 09:12</div>')
    sc.t('tl.fromTo("#s01-clock", { opacity: 0 }, { opacity: 1, duration: 0.6 }, 0.4);')
    tx, ty, tw, th = wall_rect(0)
    sc.cam_set(tx + tw / 2, ty + th / 2, 1.9)
    sc.cam(0.2, 960, 540, 1.0, dur=6.0, ease="power2.inOut")
    ta = sc.at("还有一个")
    sc.t(f'tl.fromTo("#s01-alert", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.25, yoyo: true, repeat: 5, ease: "power1.inOut" }}, {ta});')
    sc.sfx.append((ta, "notification", 0.35, None))
    sc.cam(ta + 0.2, x + w / 2 + 250, y + h / 2 + 200, 1.35, dur=1.0, ease="power2.inOut")
    sc.cam(sc.at("批准好几分钟", 1.2), 1250, 640, 1.25, dur=1.2, ease="power2.inOut")
    sc.cursor(2000, 760, t_in=10.0)
    sc.move(10.1, CATC[0], CATC[1], dur=1.1)
    return sc


POSES = [("睡着", "sleeping", "都停了"), ("敲键盘", "working", "有人在干活"), ("捧着书", "reading", "在读代码"),
         ("举起爪子", "waiting", "有人在等你"), ("站起来叫", "urgent", "晾了它一分钟")]


def s02():
    sc = Scene("s02", 16.5, 0.5)
    wall(sc, opacity=0.35, scroll=True)
    times = [sc.at(p) - 0.15 for p, _, _ in POSES]
    times[-1] = sc.at("晾它一分钟") - 0.1
    # urgent (carried over from the hook) until the first pose, then each pose in turn
    sc.cat("urgent", 0.0, times[0])
    for k, (word, name, sub) in enumerate(POSES):
        end = times[k + 1] if k + 1 < len(POSES) else None
        sc.cat(name, times[k], end)
        lid = f"s02-lab{k}"
        sc.over_html.append(f'<div class="lab" id="{lid}" style="top:390px"><b>{word}</b><em>{sub}</em></div>')
        sc.t(f'tl.fromTo("#{lid}", {{ opacity: 0, y: 24 }}, {{ opacity: 1, y: 0, duration: 0.6, ease: "power3.out" }}, {times[k]});')
        if end:
            sc.t(f'tl.to("#{lid}", {{ opacity: 0, duration: 0.2 }}, {end - 0.05});')
    sc.cam_set(960, 540, 1.0)
    sc.cam(0.3, CAT[0] + CAT[2] / 2, CAT[1] + CAT[2] / 2, 2.75, dur=0.9, sx=1340, sy=520)
    return sc


def s03():
    sc = Scene("s03", 14.0, 0.6)
    wall(sc, opacity=0.35, scroll=True)
    # the panel: its two real states, cropped to the panel
    for k, name in enumerate(["panel-open", "panel-allowed"]):
        sc.cam_html.append(
            f'<div id="s03-p{k}" style="position:absolute;left:{PNL[0]:.1f}px;top:{PNL[1]:.1f}px;width:{625 * PF:.1f}px;height:{560 * PF:.1f}px;'
            f'overflow:hidden;opacity:0"><img src="assets/{name}.png" style="position:absolute;left:0;top:0;width:{960 * PF:.1f}px"></div>')
    sc.cat("urgent", 0, None, eid="s03-urg")
    t_click = sc.at("点一下猫", 0.25)
    sc.cam_set(CATC[0] - 80, CATC[1] - 30, 2.2)
    sc.cursor(CATC[0] + 30, CATC[1] - 10, 0.0)
    sc.click(t_click)
    sc.t(f'tl.fromTo("#s03-p0", {{ opacity: 0, scale: 0.94, transformOrigin: "100% 100%" }}, '
         f'{{ opacity: 1, scale: 1, duration: 0.55, ease: "power3.out" }}, {t_click + 0.08});')
    sc.sfx.append((t_click + 0.08, "pop", 0.4, None))
    sc.cam(t_click + 0.1, 1330, 760, 1.45, dur=0.8, ease="power2.inOut")
    g = sc.at("等你处理")
    gx, gy = pnl(314, 150)
    sc.cam(g - 0.3, gx, gy, 2.1, dur=0.6)
    ax, ay = pnl(110, 192)
    t_allow = sc.at("直接点允许", 0.55)
    sc.move(t_allow - 0.9, ax, ay, dur=0.8)
    sc.click(t_allow)
    sc.t(f'tl.set("#s03-p1", {{ opacity: 0 }}, 0);')
    sc.t(f'tl.to("#s03-p1", {{ opacity: 1, duration: 0.2, ease: "none" }}, {t_allow + 0.1});')
    sc.t(f'tl.set("#s03-p0", {{ opacity: 0 }}, {t_allow + 0.3});')
    sc.t(f'tl.set("#s03-urg", {{ opacity: 0 }}, {t_allow + 0.35});')
    sc.cat("working", t_allow + 0.35)
    sc.cam(t_allow + 1.0, 1330, 760, 1.45, dur=0.8, ease="power2.inOut")
    sc.move(sc.slot - 1.4, CATC[0], CATC[1], dur=0.9)
    return sc


def s04():
    sc = Scene("s04", 10.5, 0.5)
    wall(sc, opacity=1.0, scroll=True)
    sc.cat("working")
    sc.cam_set(1200, 640, 1.25)
    sc.cam(0.0, 960, 540, 1.0, dur=4.0, ease="power2.inOut")
    sc.window(["focus"], title="HQ")
    t = sc.at("双击小猫", 0.2)
    sc.cursor(CATC[0], CATC[1], 0.0)
    sc.move(t - 0.7, CATC[0] - 10, CATC[1] + 5, dur=0.5)
    sc.click(t)
    sc.click(t + 0.18)
    ox, oy = CATC[0] - WX, CATC[1] - WY
    sc.t(f'tl.set("#s04-win", {{ opacity: 0, scale: 0.06, transformOrigin: "{ox:.0f}px {oy:.0f}px" }}, 0);')
    sc.t(f'tl.to("#s04-win", {{ opacity: 1, scale: 1, duration: 0.7, ease: "power3.out" }}, {t + 0.3});')
    sc.sfx.append((t + 0.3, "whoosh-short", 0.45, None))
    sc.cursor_out(t + 0.6)
    # the pet floats above every window, the board included
    sc.cat("working", t + 0.3, eid="s04-cattop")
    return sc


def board_scene(sid, slot, vo_off, states, cat="working"):
    sc = Scene(sid, slot, vo_off)
    sc.window(states)
    sc.cat(cat)
    sc.cam_set(960, 540, 1.0)
    return sc


def s05():
    sc = board_scene("s05", 12.5, 0.6, ["focus", "drawer", "drawer-bottom"])
    sc.cursor(bx(700), by(520), 0.0)
    sc.move(0.15, bx(110), by(198), dur=0.6)
    sc.click(0.85)
    sc.show(0.95, "drawer")
    sc.cursor_out(1.2)
    sc.cam(sc.at("状态") - 0.2, bx(760), by(134), 1.9, sx=960, sy=420)
    sc.cam(sc.at("下一步") - 0.2, bx(900), by(652), 1.9)
    t = sc.at("待办") - 0.2
    sc.show(t, "drawer-bottom")
    sc.cam(t, bx(900), by(290), 1.9)
    sc.cam(sc.at("日志") - 0.2, bx(900), by(520), 1.9)
    sc.cam(sc.at("绑在卡上"), bx(880), by(400), 1.3, dur=0.8, ease="power2.inOut")
    sc.highlight(sc.at("写回来", -0.3), 637, 446, 527, 150)
    return sc


def s05b():
    sc = board_scene("s05b", 11.0, 0.6, ["drawer-bottom", "projects", "project"])
    sc.cursor(bx(600), by(300), 0.0)
    sc.move(0.1, bx(207), by(26), dur=0.6)
    sc.click(0.75)
    sc.show(0.85, "projects")
    sc.cam(sc.at("项目和职责") - 0.2, bx(420), by(300), 1.45)
    t = sc.at("每个项目", -0.1)
    sc.move(t - 0.7, bx(470), by(160), dur=0.6)
    sc.click(t)
    sc.show(t + 0.1, "project")
    sc.cursor_out(t + 0.3)
    sc.cam(t + 0.1, bx(170), by(205), 2.1, sx=760)
    sc.cam(sc.at("完成标准") - 0.2, bx(170), by(372), 2.1, sx=760)
    sc.cam(sc.at("简报") - 0.2, bx(170), by(630), 2.1, sx=760)
    return sc


# The quick-note box (QuickNotePanel.swift: 520x132 pt, titled 记一笔, top quarter of the screen),
# drawn at the board's scale; native, so --render-board can't take it.
QN_W, QN_H = 520 * K, 132 * K
QN_X, QN_Y = 960 - QN_W / 2, 196
QN_TEXT = "订单导出成 CSV 中文全是乱码，客户在催，今天修掉"
BUBN = 2.0  # the finish notices (assets/bubble-done-*.png), likewise
BUB = 2.4   # the pet's bubbles (assets/bubble-*.png, 2x) shown larger than life, to read at full view


def s05c():
    sc = board_scene("s05c", 20.5, 0.5, ["focus", "qn-focus", "qn-drawer"])
    # ⌃⌥⌘N: the keys, then the box
    t_k = sc.at("按快捷键", -0.1)
    keys = "".join(f'<span style="display:inline-block;min-width:118px;height:118px;margin:0 10px;padding:0 22px;border-radius:22px;'
                   f'background:#f4f5f7;color:#1a1d24;font-size:64px;font-weight:600;line-height:112px;'
                   f'box-shadow:0 8px 0 #9aa0ab,0 18px 40px rgba(0,0,0,.45)">{k}</span>' for k in ["⌃", "⌥", "⌘", "N"])
    sc.over_html.append(f'<div class="big" id="s05c-keys" style="top:690px">{keys}</div>')
    sc.t(f'tl.fromTo("#s05c-keys", {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.3, ease: "back.out(2)" }}, {t_k});')
    sc.t(f'tl.to("#s05c-keys", {{ opacity: 0, duration: 0.25 }}, {t_k + 1.3});')
    for j in range(4):
        sc.sfx.append((t_k + 0.05 + j * 0.07, "click", 0.3, None))
    f = K   # panel points -> desktop px
    sc.cam_html.append(
        f'<div id="s05c-qn" style="position:absolute;left:{QN_X:.1f}px;top:{QN_Y}px;width:{QN_W:.1f}px;height:{QN_H:.1f}px;opacity:0;'
        f'border-radius:{12 * f:.1f}px;background:#2c2d31;box-shadow:0 30px 70px rgba(0,0,0,.55),0 0 0 1px rgba(255,255,255,.14)">'
        f'<i style="position:absolute;left:{8 * f:.1f}px;top:{8 * f:.1f}px;width:{12 * f:.1f}px;height:{12 * f:.1f}px;border-radius:50%;background:#ef6f5a"></i>'
        f'<i style="position:absolute;left:{28 * f:.1f}px;top:{8 * f:.1f}px;width:{12 * f:.1f}px;height:{12 * f:.1f}px;border-radius:50%;background:#55575d"></i>'
        f'<i style="position:absolute;left:{48 * f:.1f}px;top:{8 * f:.1f}px;width:{12 * f:.1f}px;height:{12 * f:.1f}px;border-radius:50%;background:#55575d"></i>'
        f'<div style="position:absolute;left:0;right:0;top:{6 * f:.1f}px;text-align:center;font-size:{13 * f:.1f}px;font-weight:600;color:#b8bcc4">记一笔</div>'
        f'<div class="typed" id="s05c-qtext" style="left:{14 * f:.1f}px;top:{38 * f:.1f}px;font-size:{15 * f:.1f}px">{esc(QN_TEXT)}</div>'
        f'<div style="position:absolute;left:{14 * f:.1f}px;top:{106 * f:.1f}px;font-size:{11 * f:.1f}px;color:#8d919a;white-space:nowrap">'
        f'回车记下 · Shift+回车换行 · 可以粘贴截图 · Esc 关闭</div></div>')
    t_p = t_k + 0.45
    sc.t(f'tl.fromTo("#s05c-qn", {{ opacity: 0, scale: 0.96 }}, {{ opacity: 1, scale: 1, duration: 0.25, ease: "power3.out" }}, {t_p});')
    sc.cam(t_p, 960, QN_Y + QN_H / 2 + 40, 1.75, dur=0.7)
    t_ty = max(sc.at("写一句", -0.3), t_p + 0.6)
    n = len(QN_TEXT)
    sc.t(f'tl.fromTo("#s05c-qtext", {{ clipPath: "inset(0 100% 0 0)" }}, {{ clipPath: "inset(0 0% 0 0)", duration: 1.6, ease: "steps({n})" }}, {t_ty});')
    sc.sfx.append((t_ty, "typing", 0.35, 1.5))
    # Enter: the box closes, the pet says it is sorting, then where the note went
    t_en = t_ty + 2.0
    sc.sfx.append((t_en, "click", 0.5, None))
    sc.t(f'tl.to("#s05c-qn", {{ opacity: 0, scale: 0.97, duration: 0.2, ease: "power2.in" }}, {t_en});')
    sc.cam(t_en + 0.1, 960, 540, 1.0, dur=0.8, ease="power2.inOut")
    for name, w, h in [("sorting", 254, 63), ("filed", 296, 98)]:
        bw, bh = w / 2 * BUB, h / 2 * BUB
        sc.cam_html.append(f'<img id="s05c-b-{name}" src="assets/bubble-{name}.png" style="position:absolute;left:{min(CATC[0] - bw / 2, 1860 - bw):.1f}px;'
                           f'top:{CAT[1] + 18 - bh:.1f}px;width:{bw:.1f}px;height:{bh:.1f}px;opacity:0">')
    t_b1 = t_en + 0.35
    sc.t(f'tl.fromTo("#s05c-b-sorting", {{ opacity: 0, y: 10 }}, {{ opacity: 1, y: 0, duration: 0.25, ease: "power3.out" }}, {t_b1});')
    sc.sfx.append((t_b1, "pop", 0.35, None))
    t_b2 = max(sc.at("建好一张卡", -0.4), t_b1 + 1.6)
    sc.t(f'tl.set("#s05c-b-sorting", {{ opacity: 0 }}, {t_b2});')
    sc.t(f'tl.fromTo("#s05c-b-filed", {{ opacity: 0, y: 10 }}, {{ opacity: 1, y: 0, duration: 0.25, ease: "power3.out" }}, {t_b2});')
    sc.show(t_b2 + 0.1, "qn-focus", dur=0.3)
    sc.sfx.append((t_b2 + 0.1, "chime", 0.3, None))
    sc.highlight(t_b2 + 0.4, 606, 175, 257, 92, out=sc.at("点开它", 0.45))
    # open the card, then New session
    t_c = sc.at("点开它", 0.35)
    sc.cursor(1500, 640, t_c - 1.0)
    sc.move(t_c - 0.9, bx(735), by(205), dur=0.8)
    sc.click(t_c)
    sc.t(f'tl.to("#s05c-b-filed", {{ opacity: 0, duration: 0.3 }}, {t_c + 0.2});')
    sc.show(t_c + 0.1, "qn-drawer")
    sc.cam(t_c + 0.2, bx(880), by(250), 1.85, dur=0.6)
    t_ns = max(sc.at("按新 session", 0.6), t_c + 1.4)
    sc.move(t_ns - 0.7, bx(893), by(235), dur=0.55)
    sc.click(t_ns)
    sc.cursor_out(t_ns + 0.3)
    # the session opens in a terminal, bound to the card, and reads it
    tid = term(sc, 600, 200, 1160, 640, "shop-api — T-017 订单导出 CSV 中文乱码", [
        ("u", "> This session works on HQ task T-017: 订单导出 CSV 中文乱码. Read the task card, then reply in three short lines…"),
        ("", ""), ("", "⏺ Read(~/hq/tasks/T-017-订单导出-csv-中文乱码/TASK.md)"), ("d", "  ⎿  Read 21 lines"), ("", ""),
        ("", "⏺ 状态：刚从快速记录建的卡，还没开始。"), ("", "  下一步：复现乱码——先看订单导出写 CSV 用的编码。"),
        ("", "  等你的：没有，你说开始就动手。")], size=24, eid="s05c-term")
    sc.t(f'tl.set("#{tid}", {{ opacity: 0 }}, 0);')
    sc.t(f'tl.set("#{tid}-tl > div", {{ opacity: 0 }}, 0);')
    t_t = t_ns + 0.35
    sc.t(f'tl.fromTo("#{tid}", {{ opacity: 0, x: 80 }}, {{ opacity: 1, x: 0, duration: 0.45, ease: "power3.out" }}, {t_t});')
    sc.sfx.append((t_t, "whoosh-short", 0.4, None))
    sc.cam(t_t, 1180, 520, 1.0, dur=0.6, ease="power2.inOut")
    sc.t(f'tl.to("#{tid}-tl > div:nth-child(1)", {{ opacity: 1, duration: 0.12 }}, {t_t + 0.3});')
    t_r = max(sc.at("绑在这张卡上", 0.6), t_t + 1.0)
    for k in (3, 4):
        sc.t(f'tl.to("#{tid}-tl > div:nth-child({k})", {{ opacity: 1, duration: 0.12 }}, {t_r + (k - 3) * 0.35:.2f});')
    t_a = max(sc.at("再向你汇报", -0.4), t_r + 0.9)
    for k in (6, 7, 8):
        sc.t(f'tl.to("#{tid}-tl > div:nth-child({k})", {{ opacity: 1, duration: 0.12 }}, {t_a + (k - 6) * 0.4:.2f});')
    return sc


def s06():
    sc = board_scene("s06", 17.5, 0.5, ["drawer", "ask-1", "ask-2", "ask-3", "ask-sent"])
    # the session that asked, off to the left of the board: it gets the answers
    term(sc, -640, 250, 640, 560, "shop-api — 结账重试", [
        ("d", "⏺ 超时每次都在 4.8 秒复现。"), ("", "⏺ 写重试之前有三件事要你定——"), ("", "  已经放到看板上了。"), ("", ""),
        ("d", "  ⎿  等你回答…"), ("", ""),
        ("u", "> 看板上的回答（T-014）："), ("", "  1. 可以——2 次就够，5 秒预算优先"), ("", "  2. 可以"), ("", "  3. 转成你的待办"),
        ("", ""), ("", "⏺ 好，按 2 次重试来写，放在开关后面。"), ("", "✻ Working…")], size=20, eid="s06-term")
    sc.t('tl.set("#s06-term-tl > div:nth-child(n+7)", { opacity: 0 }, 0);')
    sc.cam(0.3, bx(900), by(385), 1.75, dur=0.6)
    sc.highlight(sc.at("挂在卡上", -0.1), 637, 213, 527, 345, out=sc.at("三个问题", -0.3))
    t1 = sc.at("逐条选好", -0.4)
    sc.cursor(bx(1000), by(250), t1 - 0.8)
    sc.move(t1 - 0.8, bx(720), by(311), dur=0.6)
    sc.click(t1 - 0.15)
    sc.type_in(t1, 657, 304, "2 次就够——5 秒预算优先", 0.7, out=t1 + 1.35)
    sc.move(t1 + 0.8, bx(854), by(307), dur=0.4)
    sc.click(t1 + 1.25)
    sc.show(t1 + 1.35, "ask-1")
    sc.move(t1 + 1.5, bx(854), by(417), dur=0.35)
    sc.click(t1 + 1.9)
    sc.show(t1 + 2.0, "ask-2")
    sc.move(t1 + 2.1, bx(1039), by(527), dur=0.35)
    sc.click(t1 + 2.5)
    sc.show(t1 + 2.6, "ask-3")
    # the send move starts only after the third click has landed
    t_send = max(sc.at("一次发回", -0.1), t1 + 2.6 + 0.8)
    sc.move(t_send - 0.8, bx(1129), by(577), dur=0.6)
    sc.click(t_send)
    sc.show(t_send + 0.1, "ask-sent")
    sc.cursor_out(t_send + 0.4)
    # the answers leave the board as one message and land in the session that asked
    zx, zy = sc.cam_xy(560, 560, 0.58)[:2]
    sc.cam(t_send + 0.5, 560, 560, 0.58, dur=1.0, ease="power2.inOut")
    sc.cam_html.append('<div class="bubble" id="s06-bub">3 个回答 → 结账重试</div>')
    sx0, sy0 = bx(1060), by(560)
    ex, ey = -470, 470
    tb = t_send + 1.4
    sc.t(f'tl.set("#s06-bub", {{ x: {sx0:.0f}, y: {sy0:.0f}, scale: 0.6 }}, 0);')
    sc.t(f'tl.to("#s06-bub", {{ opacity: 1, scale: 1.6, duration: 0.25, ease: "power3.out" }}, {tb});')
    sc.t(f'tl.to("#s06-bub", {{ x: {ex}, duration: 1.0, ease: "power2.inOut" }}, {tb + 0.2});')
    sc.t(f'tl.to("#s06-bub", {{ y: {ey - 160}, duration: 0.5, ease: "power2.out" }}, {tb + 0.2});')
    sc.t(f'tl.to("#s06-bub", {{ y: {ey}, duration: 0.5, ease: "power2.in" }}, {tb + 0.7});')
    sc.t(f'tl.to("#s06-bub", {{ opacity: 0, scale: 0.8, duration: 0.2 }}, {tb + 1.2});')
    sc.sfx.append((tb + 0.15, "whoosh-short", 0.45, None))
    sc.sfx.append((tb + 1.2, "pop", 0.45, None))
    for k in range(7, 14):
        sc.t(f'tl.to("#s06-term-tl > div:nth-child({k})", {{ opacity: 1, duration: 0.15 }}, {tb + 1.3 + (k - 7) * 0.18:.2f});')
    sc.t('tl.to("#s06-term-tl > div:nth-child(5)", { opacity: 0.25, duration: 0.2 }, %s);' % (tb + 1.2))
    # then close in on the session reading them
    sc.cam(tb + 1.3, -320, 560, 1.45, dur=0.8, ease="power2.inOut")
    return sc


def s06b():
    sc = board_scene("s06b", 10.0, 0.6, ["ask-sent", "needs-after"])
    sc.cursor(bx(700), by(400), 0.0)
    sc.move(0.1, bx(316), by(26), dur=0.6)
    sc.click(0.75)
    sc.show(0.85, "needs-after")
    sc.cursor_out(1.0)
    sc.cam(sc.at("等你回答的问题", -0.3), bx(222), by(300), 1.85)
    t = sc.at("你欠着的待办", -0.3)
    sc.cam(t, bx(617), by(300), 1.85)
    sc.highlight(t + 0.4, 446, 262, 342, 40)
    sc.cam(sc.at("从上往下", -0.2), 960, 540, 1.0, dur=0.8, ease="power2.inOut")
    return sc


def s07():
    sc = Scene("s07", 14.0, 0.6)
    tclose = sc.at("关掉", 0.1)
    term(sc, 420, 170, 1080, 700, "shop-api — 结账重试", [
        ("u", "> 写吧，按看板上定的来"), ("", "⏺ Update(src/checkout/charge.ts)"), ("t", "  ⎿  38 additions, 6 removals"),
        ("", "⏺ Write(src/checkout/idempotency.ts)"), ("t", "  ⎿  Wrote 52 lines"), ("", "⏺ Bash(npm test -- checkout)"),
        ("t", "  ⎿  24 passing"), ("", "⏺ 重试和幂等键写好了，测试全绿。进展已写回 T-014。")], size=28, eid="s07-old")
    sc.cat("working", 0, tclose + 1.0)
    sc.cat("sleeping", tclose + 1.0, sc.at("新开一个", -0.2))
    sc.over_html.append('<div class="dim" id="s07-dim"></div>')
    sc.over_html.append('<div class="clock" id="s07-c1">周二 18:40</div><div class="clock" id="s07-c2">周三 09:05</div>')
    sc.over_html.append('<div class="big" id="s07-big" style="top:420px;font-size:96px;font-weight:600">第二天 · 09:05</div>')
    sc.t('tl.to("#s07-c1", { opacity: 1, duration: 0.4 }, 0.2);')
    sc.cam_set(960, 540, 1.0)
    sc.cursor(1300, 700, 0.0)
    sc.move(tclose - 0.8, 432, 186, dur=0.7)
    sc.click(tclose)
    sc.t(f'tl.to("#s07-old", {{ opacity: 0, scale: 0.92, duration: 0.3, ease: "power2.in" }}, {tclose + 0.1});')
    sc.cursor_out(tclose + 0.3)
    t2 = sc.at("第二天", -0.9)
    sc.t(f'tl.to("#s07-dim", {{ opacity: 0.8, duration: 0.5 }}, {tclose + 0.5});')
    sc.t(f'tl.to("#s07-c1", {{ opacity: 0, duration: 0.2 }}, {t2 + 0.3});')
    sc.t(f'tl.fromTo("#s07-big", {{ opacity: 0, scale: 0.96 }}, {{ opacity: 1, scale: 1, duration: 0.6, ease: "power3.out" }}, {t2});')
    sc.t(f'tl.to("#s07-c2", {{ opacity: 1, duration: 0.3 }}, {t2 + 0.5});')
    tnew = sc.at("新开一个", -0.2)
    sc.t(f'tl.to("#s07-big", {{ opacity: 0, duration: 0.3 }}, {tnew - 0.3});')
    sc.t(f'tl.to("#s07-dim", {{ opacity: 0, duration: 0.5 }}, {tnew - 0.3});')
    term(sc, 420, 170, 1080, 700, "shop-api — 结账重试 · 接手", [
        ("u", "> 接着做 T-014"), ("", "⏺ 先读任务卡 T-014"), ("d", "  ⎿  状态 · 下一步 · 待办 · 日志"),
        ("", "⏺ 昨天定了：重试 2 次，放在 CHECKOUT_RETRY 开关后面，默认关闭。"), ("", "⏺ 重试和幂等键已经写好、测试全绿。"),
        ("", "⏺ 下一步：在预发环境压测。"), ("", "✻ Working…")], size=28, eid="s07-new", opacity=0)
    sc.t(f'tl.set("#s07-new-tl > div", {{ opacity: 0 }}, 0);')
    sc.t(f'tl.fromTo("#s07-new", {{ opacity: 0, y: 30 }}, {{ opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }}, {tnew});')
    for k in range(1, 8):
        sc.t(f'tl.to("#s07-new-tl > div:nth-child({k})", {{ opacity: 1, duration: 0.12 }}, {tnew + 0.4 + (k - 1) * 0.45:.2f});')
    sc.cat("working", tnew, sc.at("事情记在卡上", -0.4) + 0.45)
    # and the card says so: a line in the log
    tcard = sc.at("事情记在卡上", -0.4)
    sc.window(["day2-drawer-bottom"])
    sc.t(f'tl.set("#s07-win", {{ opacity: 0 }}, 0);')
    sc.t(f'tl.fromTo("#s07-win", {{ opacity: 0, scale: 0.97 }}, {{ opacity: 1, scale: 1, duration: 0.45, ease: "power3.out" }}, {tcard});')
    sc.cat("working", tcard, None)
    sc.cam(tcard + 0.2, bx(880), by(500), 1.8, dur=0.6)
    sc.highlight(tcard + 0.8, 637, 488, 420, 24)
    return sc


def s08():
    """Settings → a click on a session opens its task on the board; a finish notice, clicked."""
    sc = Scene("s08", 20.0, 0.5)
    wall(sc, opacity=0.35, scroll=True)
    sc.window(["day2-focus", "day2-settings", "day2-reveal-drawer", "day2-reveal", "day2-reveal-typed"])
    sc.cat("working", 0, None)
    sc.cam_set(960, 540, 1.0)
    # the setting
    sc.cursor(bx(700), by(400), 0.0)
    sc.move(0.1, bx(1113), by(25), dur=0.6)
    sc.click(0.75)
    sc.show(0.85, "day2-settings")
    sc.cam(sc.at("在宠物上点击", -0.4), bx(590), by(414), 1.65, dur=0.6)
    sc.move(sc.at("在宠物上点击", -0.3), bx(890), by(411), dur=0.6)
    t_set = sc.at("设成看板上", -0.1)
    sc.highlight(t_set, 227, 372, 726, 85, out=t_set + 1.4)
    sc.move(t_set + 1.2, bx(932), by(135), dur=0.5)
    sc.click(t_set + 1.8)
    sc.show(t_set + 1.9, "day2-focus")
    sc.cursor_out(t_set + 2.0)
    # the board goes away into the pet; a session finishes
    t_close = max(sc.at("之后", -0.3), t_set + 2.1)
    sc.cam(t_close, 960, 540, 1.0, dur=0.5, ease="power2.inOut")
    ox, oy = CATC[0] - WX, CATC[1] - WY
    sc.t(f'tl.to("#s08-win", {{ opacity: 0, scale: 0.06, transformOrigin: "{ox:.0f}px {oy:.0f}px", duration: 0.5, ease: "power2.in" }}, {t_close + 0.2});')
    sc.sfx.append((t_close + 0.2, "whoosh-short", 0.35, None))
    bw, bh = 296 * BUBN / 2, 238 * BUBN / 2
    bl, bt = min(CATC[0] - bw / 2, 1860 - bw), CAT[1] + 18 - bh
    for k in (1, 2):
        sc.cam_html.append(f'<img id="s08-n{k}" src="assets/bubble-done-{k}.png" style="position:absolute;left:{bl:.1f}px;top:{bt:.1f}px;'
                           f'width:{bw:.1f}px;height:{bh:.1f}px;opacity:0">')
    t_n1 = max(sc.at("哪个 session 干完了", 0.2), t_close + 0.8)
    sc.t(f'tl.fromTo("#s08-n1", {{ opacity: 0, y: 8 }}, {{ opacity: 1, y: 0, duration: 0.2, ease: "power2.out" }}, {t_n1});')
    sc.sfx.append((t_n1, "pop", 0.35, None))
    t_n2 = max(sc.at("冒出气泡", -0.1), t_n1 + 0.9)
    sc.t(f'tl.to("#s08-n2", {{ opacity: 1, duration: 0.15, ease: "none" }}, {t_n2});')
    sc.t(f'tl.set("#s08-n1", {{ opacity: 0 }}, {t_n2 + 0.15});')
    sc.sfx.append((t_n2, "notification", 0.35, None))
    sc.cam(t_n1 - 0.3, 1600, 760, 1.6, dur=0.7)
    # click the checkout one: the board opens at its task, the session picked out, its conversation open
    t_c = sc.at("点一下气泡", 0.35)
    sc.cursor_back(t_c - 1.1, 1480, 930)
    sc.move(t_c - 1.0, bl + bw / 2, bt + bh * 0.72, dur=0.8)
    sc.click(t_c)
    sc.t(f'tl.to("#s08-n2", {{ opacity: 0, duration: 0.2 }}, {t_c + 0.15});')
    sc.cursor_out(t_c + 0.2)
    sc.show(t_c, "day2-reveal-drawer", dur=0.05)
    sc.t(f'tl.to("#s08-win", {{ opacity: 1, scale: 1, duration: 0.6, ease: "power3.out" }}, {t_c + 0.2});')
    sc.sfx.append((t_c + 0.2, "whoosh-short", 0.4, None))
    sc.cam(t_c + 0.2, 960, 540, 1.0, dur=0.6, ease="power2.inOut")
    sc.highlight(t_c + 0.8, 630, 301, 541, 73, out=t_c + 1.6)
    t_pk = max(sc.at("对话也已经展开", -0.3), t_c + 1.4)
    sc.show(t_pk, "day2-reveal")
    sc.cam(t_pk + 0.1, bx(560), by(380), 1.3, dur=0.6)
    tr = max(sc.at("在这里就能回复", -0.3), t_pk + 0.9)
    sc.cam(tr, bx(596), by(640), 1.45, dur=0.6, sy=700)   # the box and 发送 both in frame, above the captions
    sc.cursor_back(tr, bx(700), by(560))
    sc.move(tr, bx(300), by(675), dur=0.6)
    sc.click(tr + 0.65)
    sc.type_in(tr + 0.8, 124, 668, "压测用 200 并发，跑 10 分钟", 1.1, out=tr + 2.0, cover=330)
    sc.show(tr + 1.95, "day2-reveal-typed")
    sc.move(tr + 2.1, bx(1043), by(671), dur=0.6)
    sc.click(tr + 2.8)
    return sc


def s09():
    sc = board_scene("s09", 10.0, 0.5, ["day2-focus", "jobs", "jobs-run"])
    sc.cursor(bx(700), by(400), 0.0)
    sc.move(0.1, bx(412), by(26), dur=0.6)
    sc.click(0.75)
    sc.show(0.85, "jobs")
    sc.cursor_out(1.0)
    sc.cam(sc.at("按时间表", -0.3), bx(470), by(238), 1.75)
    sc.cam(sc.at("Claude", -0.3), bx(230), by(238), 1.75)
    t = sc.at("猫关着也照跑", -0.2)
    sc.cam(t, 960, 540, 1.0, dur=0.6)
    sc.cursor_back(t, bx(700), by(300))
    sc.move(t, bx(606), by(165), dur=0.6)
    sc.click(t + 0.7)
    sc.show(t + 0.8, "jobs-run")
    sc.cursor_out(t + 1.0)
    sc.cam(t + 1.0, bx(500), by(250), 1.6, dur=0.6)
    return sc


def s10():
    sc = board_scene("s10", 9.5, 0.6, ["jobs-run", "secretary"])
    sc.over_html.append('<div class="clock" id="s10-clock">周三 18:30</div>')
    sc.t('tl.to("#s10-clock", { opacity: 1, duration: 0.4 }, 0.3);')
    sc.cursor(bx(700), by(400), 0.0)
    sc.move(0.1, bx(981), by(26), dur=0.6)
    sc.click(0.8)
    sc.show(0.9, "secretary")
    sc.sfx.append((1.1, "chime", 0.35, None))
    sc.cursor_out(1.1)
    sc.cam(1.6, bx(300), by(340), 1.7, dur=0.6)
    sc.highlight(sc.at("每个任务的进展", -0.2), 112, 286, 395, 40)
    return sc


def s11():
    sc = Scene("s11", 11.0, 1.4)
    sc.window(["secretary"])
    sc.cam_set(960, 540, 1.0)
    ox, oy = CATC[0] - WX, CATC[1] - WY
    sc.t(f'tl.to("#s11-win", {{ opacity: 0, scale: 0.06, transformOrigin: "{ox:.0f}px {oy:.0f}px", duration: 0.6, ease: "power2.in" }}, 0.4);')
    sc.sfx.append((0.4, "whoosh-short", 0.4, None))
    # the cat winds down, then drifts to the middle for the end card
    sc.cat("working", 0, 1.2)
    sc.cat("idle_to_sleeping", 1.2, 3.2, once=True)
    sc.cat("sleeping", 3.2, None, eid="s11-sleep")
    # all three cat layers move together
    tm = 3.6
    tx, ty, ts = 960 - (CAT[0] + CAT[2] / 2), 330 - (CAT[1] + CAT[2] / 2), 1.6
    sc.t(f'tl.to("#s11-sleep", {{ x: {tx}, y: {ty}, scale: {ts}, duration: 1.0, ease: "power2.inOut" }}, {tm});')
    sc.over_html.append('<div class="big" id="s11-name" style="top:540px;font-size:110px;font-weight:600;letter-spacing:-1px">Claude Pet</div>')
    sc.over_html.append('<div class="big" id="s11-line" style="top:690px;font-size:46px;font-weight:500;color:#f2a541">session 随时可以关，事情记在卡上</div>')
    sc.over_html.append('<div class="big" id="s11-url" style="top:790px;font-size:36px;font-weight:400;color:rgba(255,255,255,.72)">github.com/ZephTu/claude-pet</div>')
    sc.t(f'tl.fromTo("#s11-line", {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.6, ease: "power3.out" }}, {sc.at("session")});')
    sc.t(f'tl.fromTo("#s11-name", {{ opacity: 0, y: 20 }}, {{ opacity: 1, y: 0, duration: 0.6, ease: "power3.out" }}, {sc.at("Claude Pet", -0.1)});')
    sc.t(f'tl.fromTo("#s11-url", {{ opacity: 0 }}, {{ opacity: 1, duration: 0.6 }}, {sc.at("Claude Pet", 0.6)});')
    sc.sfx.append((sc.at("Claude Pet", -0.1), "chime", 0.3, None))
    return sc


# ------------------------------------------------------------------ captions
PUNCT = "，。？！；：、"


def vis_len(s):
    return sum(1 if ord(ch) > 0x2e80 else 0.55 for ch in s)


def chunks(text, limit=16):
    parts, cur = [], ""
    for ch in text:
        cur += ch
        if ch in PUNCT:
            parts.append(cur)
            cur = ""
    if cur:
        parts.append(cur)
    out = []
    for p in parts:
        if out and vis_len(out[-1] + p) <= limit and out[-1][-1] not in "。？！；":
            out[-1] += p
        else:
            out.append(p)
    return out


def caption_text(s):
    s = s.strip()
    while s and s[-1] in "，。；：、":
        s = s[:-1]
    return s.replace("——", " —— ")


# ------------------------------------------------------------------ assembly
def main():
    (HERE / "compositions").mkdir(exist_ok=True)
    scenes = [s01(), s02(), s03(), s04(), s05(), s05b(), s05c(), s06(), s06b(), s07(), s08(), s09(), s10(), s11()]
    start = 0.0
    hosts, audio, caps = [], [], []
    for sc in scenes:
        sc.write()
        sc.start = start
        hosts.append(f'      <div id="{sc.id}" data-composition-id="{sc.id}" data-composition-src="compositions/{sc.id}.html" '
                     f'data-start="{start:.3f}" data-duration="{sc.slot}" data-track-index="0" data-track-kind="graphics" '
                     f'data-width="1920" data-height="1080"></div>')
        vo = HERE / f"assets/vo/{sc.id}.mp3"
        audio.append(f'      <audio id="vo-{sc.id}" src="assets/vo/{sc.id}.mp3" data-start="{start + sc.vo_off:.3f}" '
                     f'data-duration="{duration(vo):.3f}" data-track-index="2" data-volume="1"></audio>')
        for a, b, text in sc.cues:
            cs = chunks(text)
            total = sum(vis_len(c) for c in cs)
            t = start + sc.vo_off + a
            for c in cs:
                d = (b - a) * vis_len(c) / total
                caps.append((round(t, 3), round(d, 3), caption_text(c)))
                t += d
        start += sc.slot
    total = round(start, 3)
    sfx_lines = []
    for sc in scenes:
        for k, (t, name, vol, dur) in enumerate(sc.sfx):
            d = dur if dur else duration(HERE / f"assets/sfx/{name}.mp3")
            sfx_lines.append((sc.start + t, name, vol, d))
    sfx_lines.sort()
    # one lane unless two overlap
    lanes_end = []
    sfx_html = []
    for i, (t, name, vol, d) in enumerate(sfx_lines):
        lane = next((k for k, e in enumerate(lanes_end) if e <= t), None)
        if lane is None:
            lane = len(lanes_end)
            lanes_end.append(0)
        lanes_end[lane] = t + d
        sfx_html.append(f'      <audio id="sfx{i:02d}" src="assets/sfx/{name}.mp3" data-start="{t:.3f}" data-duration="{d:.3f}" '
                        f'data-track-index="{4 + lane}" data-volume="{vol}"></audio>')

    cap_divs = "\n".join(
        f'    <div class="cap clip" id="cap{i:03d}" data-start="{t:.3f}" data-duration="{max(0.4, d - 0.02):.3f}" data-track-index="0">'
        f'<span>{esc(text)}</span></div>' for i, (t, d, text) in enumerate(caps))
    (HERE / "compositions/captions.html").write_text(f"""<template>
  <style>
    @font-face {{ font-family: "PF"; font-weight: 500; src: local("PingFangSC-Medium"), local("PingFang SC"); }}
    #root {{ position: absolute; inset: 0; pointer-events: none; }}
    #root .cap {{ position: absolute; left: 0; right: 0; bottom: 116px; text-align: center; }}
    #root .cap span {{ display: inline-block; padding: 8px 24px 10px; border-radius: 10px; background: rgba(0,0,0,.6);
      font-family: "PF", sans-serif; font-weight: 500; font-size: 40px; line-height: 1.3; color: #fff; }}
  </style>
  <div id="root" data-composition-id="captions" data-width="1920" data-height="1080">
{cap_divs}
  </div>
  <script>
    const tl = gsap.timeline({{ paused: true }});
    tl.set({{}}, {{}}, {total});
    window.__timelines["captions"] = tl;
  </script>
</template>
""")

    index = f"""<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <title>Claude Pet — 一张卡走完一天</title>
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.15.0/dist/gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: #2b2a28; }}
      #main {{ position: relative; width: 1920px; height: 1080px; }}
    </style>
  </head>
  <body>
    <!-- Generated by build.py — edit that, then run it again. -->
    <div id="main" data-composition-id="main" data-start="0" data-duration="{total}" data-width="1920" data-height="1080">
{chr(10).join(hosts)}
      <div id="captions" data-composition-id="captions" data-composition-src="compositions/captions.html" data-start="0"
        data-duration="{total}" data-track-index="1" data-track-kind="captions" data-width="1920" data-height="1080"></div>
{chr(10).join(audio)}
      <audio id="bgm" src="assets/bgm/track.wav" data-start="0" data-duration="{total}" data-track-index="3" data-volume="0.12"
        data-fade-out="3"></audio>
{chr(10).join(sfx_html)}
    </div>
    <script>
      window.__timelines = window.__timelines || {{}};
      window.__timelines["main"] = gsap.timeline({{ paused: true }});
    </script>
  </body>
</html>
"""
    (HERE / "index.html").write_text(index)
    print(f"{len(scenes)} scenes, {total:.1f} s, {len(caps)} captions, {len(sfx_lines)} sfx")


if __name__ == "__main__":
    main()
