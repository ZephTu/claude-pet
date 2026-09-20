# Local patches on top of vendored code

`Resources/pet/skins/cat/cat-pet.js` comes from an external animation kit
(Cat Life v2). Its upgrade path is "check `before_sha256`, drop the new file
in" — which stops working the moment we edit the file. These patches are how
we keep doing it anyway.

Taking a new version of the kit:

1. Replace `cat-pet.js` with the vendor's new file.
2. Replay each patch here: `git apply scripts/patches/<name>.patch`
3. A patch that no longer applies means the vendor touched the same lines.
   Read their version first — if they fixed it themselves, delete the patch
   instead of forcing it through.
4. Regenerate any patch you had to redo: `git diff -- <file> > <patch>`

Failure is loud, which is the point: a patch that silently stopped applying
would be a fix that quietly disappeared.

## zzz-phase.patch

Rebased onto Cat Life v3. v3 was cut from the vendor's own v2, so it carries the
bug back; the patch replayed onto it cleanly, which is the whole reason it
exists. Regenerate against the pristine vendor file, not against a repo commit:

    diff -u --label a/<path> --label b/<path> <vendor file> <our file> > zzz-phase.patch

The three sleeping Zs are pinned to their own bounding boxes in the texture, so
nothing can make them travel the trail; the only thing that can carry a
direction is the order they light up in. Upstream gives small / medium / large
the phases 0 / .33 / .66, which retires them bottom, top, middle — not a
direction, and on screen it reads as the Zs dropping. This reorders them to
bottom, middle, top 1.2s apart, and drops the vertical travel to zero.

Zero travel is the point, not an oversight. Travel was tried at .100 of uv
(10.6 screen pixels) and was worse than upstream: pinned glyphs on different
phases drift apart and back together, so the trio loses its spacing, and each
wrap becomes a visible drop the full height of the travel. Upstream's own .037
is 3.9px on a 120px canvas — too small to read as drift, big enough to read as
a drop.

Measured in a real WebGL render, not by eye: per-glyph ink probes for the
lighting order, and the big Z's vertical centroid held flat across a cycle to
prove nothing moves.
