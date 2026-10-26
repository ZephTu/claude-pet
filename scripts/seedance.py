#!/usr/bin/env python3
"""Generate one sheet's video through the Volcano Engine (火山方舟) Seedance API.

Development-machine tool, like everything else under art/. The pet itself makes
no network requests.

    python3 scripts/seedance.py to-working             # → art/seedance/videos/to-working.mp4
    python3 scripts/seedance.py to-working --model doubao-seedance-2-0-260128

The API key is read from `key=` in ./.env (git-ignored), never from the command
line, so it stays out of shell history and process listings.

Why the API rather than the Doubao app: the app takes a first frame only, and a
transition's END pose then has to be imagined by the model. Measured on
to-working: a silver laptop instead of the dark one, the screen turned toward
the cat, seam 0.42 against the working loop. The API takes `last_frame`, which
pins the end to the same picture the loop starts from.
"""
import argparse
import base64
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHEETS = ROOT / "art/seedance/sheets"
VIDEOS = ROOT / "art/seedance/videos"
API = "https://ark.cn-beijing.volces.com/api/v3/contents/generations/tasks"


def api_key():
    env = ROOT / ".env"
    for line in env.read_text().splitlines() if env.exists() else []:
        name, _, value = line.partition("=")
        if name.strip() == "key" and value.strip():
            return value.strip().strip("'\"")
    sys.exit("no key=… in .env")


def request(method, url, key, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # The body says what was wrong with the request; the status alone does not.
        sys.exit(f"{method} {url} → {error.code}: {error.read().decode()[:600]}")


def image(path):
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sheet", help="sheet name in scripts/cat-sheets.json, e.g. to-working")
    parser.add_argument("--model", default="doubao-seedance-2-0-mini-260615")
    parser.add_argument("--resolution", default="720p")
    args = parser.parse_args()

    spec = json.loads((ROOT / "scripts/cat-sheets.json").read_text())
    sheet = next((s for s in spec["sheets"] if s["name"] == args.sheet), None)
    if not sheet:
        sys.exit(f"no sheet {args.sheet!r}; have {[s['name'] for s in spec['sheets']]}")
    first, last = SHEETS / f"{args.sheet}-first.png", SHEETS / f"{args.sheet}-last.png"
    prompt = (SHEETS / f"{args.sheet}.txt").read_text().strip()
    for path in (first, last):
        if not path.exists():
            sys.exit(f"missing {path} — run swift scripts/cat-seeds.swift first")

    key = api_key()
    body = {
        "model": args.model,
        "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": image(first)}, "role": "first_frame"},
            {"type": "image_url", "image_url": {"url": image(last)}, "role": "last_frame"},
        ],
        "ratio": "9:16",
        "duration": int(sheet["duration"]),
        "resolution": args.resolution,
        "watermark": False,
    }
    task = request("POST", API, key, body)
    task_id = task.get("id") or sys.exit(f"no task id in {task}")
    print(f"{args.sheet}: task {task_id} on {args.model}", flush=True)

    started = time.time()
    while True:
        time.sleep(10)
        status = request("GET", f"{API}/{task_id}", key)
        state = status.get("status")
        print(f"  {int(time.time() - started):4d}s  {state}", flush=True)
        if state == "succeeded":
            break
        if state in ("failed", "cancelled", "expired"):
            sys.exit(f"task {state}: {json.dumps(status.get('error') or status)[:600]}")
        if time.time() - started > 900:
            sys.exit(f"gave up after 15 minutes; task {task_id} may still finish")

    url = (status.get("content") or {}).get("video_url") or sys.exit(f"no video_url in {status}")
    VIDEOS.mkdir(parents=True, exist_ok=True)
    out = VIDEOS / f"{args.sheet}.mp4"
    with urllib.request.urlopen(url, timeout=120) as response:
        out.write_bytes(response.read())
    usage = status.get("usage") or {}
    print(f"wrote {out.relative_to(ROOT)}  ({out.stat().st_size // 1024} KB)"
          + (f"  tokens {usage.get('total_tokens')}" if usage else ""))


if __name__ == "__main__":
    main()
