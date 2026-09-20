#!/usr/bin/env python3
"""Top up Resources/pet/quotes.json, the corpus behind the pet's daily line.

Run on a development machine, never at runtime. The pet makes no network
request at all, and measuring these sources is what settled that: the filtering
that decides whether a line is short enough and kind enough to greet somebody
with cannot be done at 09:00 against an API that may be down, rate-limited, or
in the mood to quote Schopenhauer on human depravity.

    python3 scripts/fetch-quotes.py            # merge new lines into quotes.json
    python3 scripts/fetch-quotes.py --print    # show what it found, write nothing

MERGES rather than rewrites, because the committed corpus is hand-written and
these sources cannot refill it. Measured 2026-09-20:

  - api.quotable.io          dead; the connection is refused outright
  - type.fit                 returns 5 quotes, down from the ~1600 it once served
  - zenquotes.io/api/quotes  50 per IP, the same 50 for hours; 14 survive the sieve
  - v1.hitokoto.cn           200 calls yielded 10 distinct short lines, and they
                             were Tang poetry fragments, not encouragement

So this script is a supplement to human writing, never a substitute for it.
Whatever it adds still gets read before it is committed: these lines land on
somebody's screen first thing in the morning.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

OUT = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "pet" / "quotes.json"

WANT = 120
MAX_EN = 50          # characters; the bubble is one line
MAX_ZH = 22          # CJK glyphs are roughly twice as wide
MIN_LEN = 12         # "Just do it." is not worth a morning

# A greeting is not the place for death, war, God, or being told you are lazy.
# Cheap and blunt on purpose: this is a sieve in front of a human, not a
# substitute for one.
REJECT_EN = re.compile(
    r"\b(death|die[ds]?|dying|kill|war|god|lord|sin|evil|hell|enemy|hate|"
    r"fail(ure|ed)?|lazy|weak|stupid|fool|poverty|suffer|misery|blood)\b",
    re.I,
)
REJECT_ZH = re.compile(
    r"死|亡|杀|战争|上帝|神明|地狱|罪|恶|恨|愚蠢|懒|失败|痛苦|贫穷|血|劣根"
)


def get(url, tries=3):
    """Shell out to curl rather than use urllib.

    The system Python that ships with the Command Line Tools has no CA bundle,
    so every https fetch dies on CERTIFICATE_VERIFY_FAILED. curl carries its own
    trust store and is on every machine this script will ever run on.
    """
    for attempt in range(tries):
        done = subprocess.run(["curl", "-sS", "-m", "10", url],
                              capture_output=True, text=True)
        if done.returncode == 0 and done.stdout.strip():
            try:
                return json.loads(done.stdout)
            except json.JSONDecodeError as exc:
                print(f"  ! {url}: {exc}", file=sys.stderr)
        elif done.stderr.strip():
            print(f"  ! {url}: {done.stderr.strip()}", file=sys.stderr)
        if attempt == tries - 1:
            return None
        time.sleep(2)


def clean(text):
    return " ".join(text.replace("—", "-").split()).strip(' "“”')


def fetch_en():
    """ZenQuotes serves 50 random quotes per call; ask until the pool is full."""
    seen = {}
    for _ in range(12):
        batch = get("https://zenquotes.io/api/quotes") or []
        for item in batch:
            line = clean(item.get("q", ""))
            if not MIN_LEN <= len(line) <= MAX_EN:
                continue
            if REJECT_EN.search(line) or line.endswith(("...", ":")):
                continue
            seen.setdefault(line.lower(), line)
        print(f"  en: {len(seen)} kept")
        if len(seen) >= WANT * 2:
            break
        time.sleep(6)                                  # the free tier rate-limits
    return sorted(seen.values(), key=str.lower)


def fetch_zh():
    """Hitokoto serves one line per call, so this is a long loop of small ones."""
    seen = {}
    for _ in range(WANT * 12):
        item = get(f"https://v1.hitokoto.cn/?c=k&c=i&c=d&max_length={MAX_ZH}", tries=1)
        if not item:
            continue
        line = clean(item.get("hitokoto", ""))
        if not 6 <= len(line) <= MAX_ZH or REJECT_ZH.search(line):
            continue
        seen.setdefault(line, line)
        if len(seen) >= WANT * 2:
            break
    print(f"  zh: {len(seen)} kept")
    return sorted(seen.values())


def merge(existing, found):
    """Existing lines keep their order; anything genuinely new is appended."""
    known = {line.lower() for line in existing}
    return existing + [line for line in found
                       if line.lower() not in known and not known.add(line.lower())]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--print", action="store_true", dest="dump")
    args = ap.parse_args()

    print("fetching en...")
    en_found = fetch_en()
    print("fetching zh...")
    zh_found = fetch_zh()

    if args.dump:
        for label, lines in (("en", en_found), ("zh", zh_found)):
            print(f"\n-- {label}: {len(lines)} --")
            for line in lines:
                print(f"  {line}")
        return

    current = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else {"en": [], "zh": []}
    en = merge(current.get("en", []), en_found)
    zh = merge(current.get("zh", []), zh_found)
    added = (len(en) - len(current.get("en", []))) + (len(zh) - len(current.get("zh", [])))
    if not added:
        print("nothing new; quotes.json left alone")
        return

    OUT.write_text(json.dumps({"en": en, "zh": zh}, ensure_ascii=False, indent=1) + "\n",
                   encoding="utf-8")
    print(f"added {added} line(s) -- READ THEM before committing: git diff {OUT}")


if __name__ == "__main__":
    main()
