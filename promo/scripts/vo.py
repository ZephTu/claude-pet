# The narration: one mp3 + srt per scene from demo/narration.json, voice 晓伊 through Edge TTS.
# Sends the narration text to Microsoft's online TTS service.
#   .venv/bin/python scripts/vo.py [scene ...]     (no scenes: all of them)
import json, subprocess, sys
from pathlib import Path
PROMO = Path(__file__).resolve().parent.parent
for sid, text in json.load(open(PROMO / "demo/narration.json")):
    if sys.argv[1:] and sid not in sys.argv[1:]:
        continue
    subprocess.run([str(PROMO / ".venv/bin/edge-tts"), "--voice", "zh-CN-XiaoyiNeural", "--rate=+5%", "--text", text,
                    "--write-media", str(PROMO / f"assets/vo/{sid}.mp3"),
                    "--write-subtitles", str(PROMO / f"assets/vo/{sid}.srt")], check=True)
    print(sid)
