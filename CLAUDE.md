# Claude Pet — notes for agents working in this repo

## Keep the HQ guide in sync

The task board ships a user guide: `Resources/pet/board/guide.html` (opened from the board's
**Guide** button), with a Chinese and an English section.

Any change to how HQ or the board behaves — the board UI (`Resources/pet/board/board.*`,
`Sources/ClaudePet/BoardWindow.swift`), the `hq` CLI or its hooks (`hq/bin/hq`), the slash
commands or templates (`hq/template/`), or how the board is opened from the pet — must update
**both language sections** of the guide in the same commit, plus `hq/README.md` when the CLI
or file formats change.

## Installing the pet

`scripts/install.sh` installs the checkout it runs in, and the last install from any worktree wins.
It refuses (via `scripts/check-main.sh`) when the checkout lacks commits on `origin/main` — install
from main, or merge main into the branch first. Don't reach for `--force` on the user's behalf:
it puts already-merged fixes out of the installed pet. When a merged fix "doesn't work", compare
`shasum ~/Applications/ClaudePet.app/Contents/MacOS/ClaudePet` with the worktrees' `ClaudePet.app` —
a hint, not proof: any later `build-app.sh` in that worktree overwrites its `ClaudePet.app`.

## Checks before committing

- `swift build && swift run ClaudePetTests`
- `./hq/tests/test_hq.sh`
- Board layout: `.build/debug/ClaudePet --render-board out.png ["<js to run first>"]` renders the
  live board to a PNG (screen capture would need a permission this app should not ask for).
  For the guide: `"location.href='guide.html'"`. Add `--size 390x844` for a phone's width.
- Phone access (`BoardServer.swift`): `.build/debug/ClaudePet --serve-board 18790` serves the board
  on its own and prints a pairing link; `.build/debug/ClaudePet --render-url "<that link>" out.png
  ["<js>"]` renders it as a phone's browser does, over HTTP with no bridge. Static files come from
  the build's resource bundle: `swift build` after editing them.
