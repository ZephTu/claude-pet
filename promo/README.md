# Claude Pet promo film

A 2:38 Chinese-narrated demo of Claude Pet and HQ, made with [HyperFrames](https://hyperframes.heygen.com)
(HTML rendered to video). It follows one task card, T-014, through a day. The story and shot list are in
`SPEC.md`, the alternatives that were not built are in `STORYLINES.md`, and the last review is in `REVIEW.md`.

All the data on screen is made up: `demo/board-demo-zh.js` (the board) and `demo/panel-zh.js` (the session
list). Board stills render with a stub `hq` (`scripts/nohq/hq`), so your own HQ never leaks into a frame.

## Rebuild

Generated media is not in git. Rebuild it once, in this order, from the repo root after `swift build`:

| Output | Command | Needs |
| --- | --- | --- |
| `assets/board/*.png` | `promo/scripts/shots-all.sh` | `.build/debug/ClaudePet` |
| `assets/panel-*.png` | `promo/scripts/panel.sh` | `.build/debug/ClaudePet` |
| `assets/cat/*.webp`, `clips.json` | `ART=<checkout>/art promo/scripts/cat.sh` | the cat source videos (`art/` is not in git) |
| `assets/bgm/track.wav` | `promo/.venv/bin/python promo/scripts/bgm.py 200 promo/assets/bgm/track.wav` | MusicGen-small (set `HF_ENDPOINT=https://hf-mirror.com` if huggingface.co is unreachable) |
| `assets/vo/*.mp3`, `*.srt` (committed) | `promo/.venv/bin/python promo/scripts/vo.py` | network: the text goes to Microsoft Edge TTS |

The venv: `uv venv promo/.venv && uv pip install --python promo/.venv/bin/python edge-tts pillow numpy soundfile torch transformers`.

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
