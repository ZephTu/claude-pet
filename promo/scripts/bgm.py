# Local background music: one ~28 s MusicGen-small clip, crossfade-looped to the film's length.
# usage: .venv/bin/python scripts/bgm.py <seconds> <out.wav>
import os, sys, numpy as np, torch, soundfile as sf
from transformers import AutoProcessor, MusicgenForConditionalGeneration
target, out = float(sys.argv[1]), sys.argv[2]
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
dev = "mps" if torch.backends.mps.is_available() else "cpu"
proc = AutoProcessor.from_pretrained("facebook/musicgen-small")
model = MusicgenForConditionalGeneration.from_pretrained("facebook/musicgen-small").to(dev)
prompt = "calm lo-fi hip hop beat, soft electric piano chords, warm vinyl crackle, mellow brushed drums, 84 bpm, cozy late-night desk, no vocals"
torch.manual_seed(7)
inp = proc(text=[prompt], padding=True, return_tensors="pt").to(dev)
audio = model.generate(**inp, do_sample=True, guidance_scale=3.0, max_new_tokens=int(28 * 50))
sr = model.config.audio_encoder.sampling_rate
clip = audio[0, 0].float().cpu().numpy()
sf.write(out.replace(".wav", "-seed.wav"), clip, sr)
xf = int(2.0 * sr); n = int(target * sr)
res = clip.copy()
ramp = np.linspace(0, 1, xf)
while len(res) < n:
    res = np.concatenate([res[:-xf], res[-xf:] * (1 - ramp) + clip[:xf] * ramp, clip[xf:]])
res = res[:n]
fo = int(3 * sr); res[-fo:] *= np.linspace(1, 0, fo)
res = res / (np.abs(res).max() + 1e-9) * 0.8
sf.write(out, res, sr)
print("wrote", out, len(res) / sr, "s on", dev)
