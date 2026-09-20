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

The sleeping Zs drift up and fade. Upstream gives small / medium / large the
phases 0 / .33 / .66, which retires them bottom, top, middle — not a direction,
and it reads on screen as the Zs dropping. This reorders them to bottom,
middle, top 1.2s apart, and raises the travel from 3.9 to 10.6 screen pixels
so the drift is visible at all. Measured in a real WebGL render, not by eye.
