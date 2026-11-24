# Claude Pet promo film

A 3:09 Chinese-narrated demo of Claude Pet and HQ, made with [HyperFrames](https://hyperframes.heygen.com)
(HTML rendered to video). It follows one task card, T-014, through a day, and shows a
new one, T-017, filed from a quick note (⌃⌥⌘N) and started with New session, and a finish notice
over the cat that opens its task on the board. The story and shot list are in
`SPEC.md`, the alternatives that were not built are in `STORYLINES.md`, and the last review is in `REVIEW.md`.

All the data on screen is made up: `demo/board-demo-zh.js` (the board) and `demo/panel-zh.js` (the session
list). The quick-note box is a native panel the renderers can't capture, so `build.py` draws it from
`QuickNotePanel.swift`'s size and wording; the pet's bubbles (quick-note replies and finish notices) are real renders. Board stills render with a stub `hq` (`scripts/nohq/hq`), and the demo replaces the board's data,
drafts, picks and outbox before the shutter. A few calls still run for real while the page loads (`claude agents`,
the pet's own settings) but the demo overwrites what they return, so none of your HQ reaches a frame. Some view
prefs (show done, grouping) are read from the debug app's WebKit store, so stills can differ between machines.

## Rebuild

Generated media is not in git, except `assets/cat/clips.json` (which `build.py` reads, and `cat.sh` rewrites)
and the voice-over. Rebuild it once, in this order, from the repo root after `swift build`:

| Output | Command | Needs |
| --- | --- | --- |
| `assets/board/*.png` | `promo/scripts/shots-all.sh` | `.build/debug/ClaudePet` |
| `assets/panel-*.png`, `assets/bubble-*.png` | `promo/scripts/panel.sh` | `.build/debug/ClaudePet`, the venv (crops the bubbles) |
| `assets/cat/*.webp`, `clips.json` | `ART=<checkout>/art promo/scripts/cat.sh` | the cat source videos (`art/` is not in git; nothing in it is written) |
| `assets/bgm/track.wav` | `promo/.venv/bin/python promo/scripts/bgm.py 200 promo/assets/bgm/track.wav` | MusicGen-small (set `HF_ENDPOINT=https://hf-mirror.com` if huggingface.co is unreachable) |
| `assets/vo/*.mp3`, `*.srt` (committed) | `promo/.venv/bin/python promo/scripts/vo.py [scene ...]` | network: the text goes to Microsoft Edge TTS |

Also needs `ffmpeg`/`ffprobe` on PATH (`build.py` reads the voice-over durations). The venv: `uv venv promo/.venv && uv pip install --python promo/.venv/bin/python edge-tts pillow numpy soundfile torch transformers`.

Then, in `promo/`:

```sh
python3 build.py                        # writes index.html and compositions/ from the narration timing
npx hyperframes check                   # 0 errors expected; REVIEW.md lists the warnings kept on purpose
npx hyperframes preview                 # Studio, http://localhost:3002
npx hyperframes render -o renders/claude-pet-promo.mp4
```

`build.py` is the source of truth: edit it, not `index.html` or `compositions/`, which it overwrites.
The voice-over sets the timeline, so changing a line in `demo/narration.json` means rerunning `vo.py`
and then `build.py`.
