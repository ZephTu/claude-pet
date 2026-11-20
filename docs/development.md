# Development

**English** · [中文](development.zh-CN.md) · [← README](../README.md)


```bash
swift run ClaudePetTests     # unit tests — not `swift test`, see below
./hooks/test-pet-emit.sh     # hook behaviour tests
./hooks/test-settings-patch.sh  # settings.json round trip — see below
./scripts/build-app.sh       # build ClaudePet.app without installing
```

`PET_DUMP=/tmp/hooks.jsonl claude` makes the hook binary append every payload it receives to
that file, and does nothing at all when the variable is unset. It is a debugging tool, not a
feature — a payload carries the prompt text — but it is the only honest way to learn what a
hook actually sends. Guessing has been wrong more than once here: an earlier quota parser
listed five plausible spellings of the field it needed and missed the real one, so it read
nothing while the README called it unverified.

Tests run through a small hand-written harness as an executable target rather than XCTest: with only the Command Line Tools installed (no full Xcode), **neither XCTest nor swift-testing is available**, so `swift test` cannot run at all.

To watch every state animate, serve the repo (`python3 -m http.server 8777`) and open
`http://127.0.0.1:8777/docs/previews/`; `docs/previews/cat-cycle.js` is what the README's
animation is captured from. Both drive the real `Resources/pet/index.html` rather than keeping
a copy, and both are also what the README's two cat pictures are generated from — one artifact per
job is what stops the documentation drifting a state behind the app, which is exactly how the
last contact sheet ended up short.

The design document in `docs/superpowers/specs/` explains the architecture and, more usefully, why each piece is the way it is. **It is written in Chinese** — the code, comments and this README are English, but that document has not been translated.

The Task Board pictures in the README come from `scripts/board-shots.sh`: it renders the real
board page with made-up data (`docs/previews/board-demo.js`) — never anyone's actual tasks —
and writes `docs/images/board-*.png` and `board-asks.gif`. Run it after `swift build` whenever
the board changes how it looks.

## Three things worth knowing before you change anything

**The hit region is a rectangle in `Sources/ClaudePetCore/PetLayout.swift`, and it must agree with the drawing in `Resources/pet/pet.css`.** Change the art and you must change `PetLayout`, and the other way round. No test can catch a mismatch — they can only lock the Swift half — so this is a convention, not a guardrail.

This is not hypothetical. The mirrored layout was first written as a reflection (`x → width - maxX`), every test passed, and the body box still looked right in a screenshot — because it happens to be symmetric inside the pet. A figure that is not symmetric ended up partly outside its own hit region. What caught it was drawing the rectangles over the rendered page and looking. Do that after any change here.

**The `settings.json` patch is tested against real files, not in process.** It is the only thing here that can break someone else's machine, and the parts that make it safe — the backup, the atomic write, the parse-back, the rollback — exist only on disk; testing them in memory tests nothing. The assertion that matters is the round trip: install then uninstall, and not one field of the user's own hooks may differ.

**Terminal jumping is split in two on purpose.** Everything testable — identifying the terminal, parsing session ids, rejecting AppleScript injection — lives in `Sources/ClaudePetCore/TerminalTarget.swift`. The part that actually spawns processes is in `Sources/ClaudePet/TerminalJump.swift`.
