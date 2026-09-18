#!/usr/bin/env python3
"""Builds docs/previews/cat-life.html — the tail/blink/gaze comparison page.

Self-contained on purpose: the five textures are inlined as data URIs so the
file opens by double-clicking it. A page that referenced the PNGs would load
fine and then draw nothing, because a browser refuses to upload a file:// image
into a WebGL texture and the failure is silent.

Run from the repo root: python3 scripts/make-cat-life-preview.py
"""
import base64, json, pathlib, textwrap

root = pathlib.Path("Resources/pet/skins/cat/assets")
names = ["idle", "working", "waiting", "sleeping", "urgent"]
data = {n: "data:image/png;base64," + base64.b64encode((root / f"{n}.png").read_bytes()).decode()
        for n in names}

# Measured off the textures with a labelled 0.1 grid, one pose at a time.
# tail:  cx, cy, rx, ry  (the moving part)   root: the pivot, at the body
# eyes:  cx, cy, rx, ry  (the band across both eyes)
# pupils: left x,y and right x,y
LIFE = {
 # tail:  cx, cy, rx, ry — the moving part, read off a labelled 0.1 grid
 # root:  the pivot, where the tail meets the body
 # eyes:  cx, cy, half-width, half-height — measured, not guessed: the two eye
 #        blobs found by connected components on the dark pixels of each
 #        texture. Eyeballing them off the grid put working's eyes 0.14 too
 #        high, and the blink squashed its nose.
 # pupils: the two blob centres
 "idle":     {"tail":[.17,.70,.11,.12], "root":[.30,.75],
              "eyes":[.532,.330,.190,.075], "pupils":[.404,.349,.659,.318]},
 "working":  {"tail":[.20,.64,.10,.11], "root":[.33,.72],
              "eyes":[.559,.420,.194,.078], "pupils":[.433,.408,.694,.434]},
 "waiting":  {"tail":[.17,.70,.11,.12], "root":[.30,.76],
              "eyes":[.492,.350,.185,.078], "pupils":[.369,.371,.619,.330]},
 # Eyes already drawn shut — a blink here would squash a closed eye, so the
 # band is given no width and contributes nothing.
 "sleeping": {"tail":[.75,.74,.13,.11], "root":[.58,.78],
              "eyes":[.500,.440,.000,.001], "pupils":[.0,.0,.0,.0]},
 "urgent":   {"tail":[.15,.62,.10,.12], "root":[.28,.70],
              "eyes":[.466,.345,.180,.075], "pupils":[.348,.361,.589,.330]},
}

html = pathlib.Path("docs/previews/cat-life.template.html").read_text()
html = html.replace("/*__ASSETS__*/", json.dumps(data))
html = html.replace("/*__LIFE__*/", json.dumps(LIFE))
out = pathlib.Path("docs/previews/cat-life.html")
out.write_text(html)
print(out, f"{out.stat().st_size/1024:.0f}KB")
