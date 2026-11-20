# Claude Pet — notes for agents working in this repo

## Keep the HQ guide in sync

The task board ships a user guide: `Resources/pet/board/guide.html` (opened from the board's
**Guide** button), with a Chinese and an English section.

Any change to how HQ or the board behaves — the board UI (`Resources/pet/board/board.*`,
`Sources/ClaudePet/BoardWindow.swift`), the `hq` CLI or its hooks (`hq/bin/hq`), the slash
commands or templates (`hq/template/`), or how the board is opened from the pet — must update
**both language sections** of the guide in the same commit, plus `hq/README.md` when the CLI
or file formats change.

## Checks before committing

- `swift build && swift run ClaudePetTests`
- `./hq/tests/test_hq.sh`
- Board layout: `.build/debug/ClaudePet --render-board out.png ["<js to run first>"]` renders the
  live board to a PNG (screen capture would need a permission this app should not ask for).
  For the guide: `"location.href='guide.html'"`.
