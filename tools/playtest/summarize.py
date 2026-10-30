#!/usr/bin/env python3
"""Merge blind tester verdicts (tools/playtest/run_testers.sh output).

    python3 tools/playtest/summarize.py <results_dir>

Prints the median and spread per rubric criterion across raters, each
rater's overall fun / play-again / co-op-required answer, and every worst
moment and fix (the actionable part — scores from LLM raters are noisy and
best read relative to an earlier round).
"""
import json
import re
import statistics as st
import sys
from pathlib import Path

NAMES = {"R1": "telegraphs", "R2": "fairness", "R3": "challenge", "R4": "variety",
         "R5": "counterplay", "R6": "co-op need", "R7": "pacing", "R8": "feedback",
         "R9": "memorable", "R10": "bugs", "R11": "replay"}


def load(path):
    raw = path.read_text()
    if path.name.startswith("claude"):
        try:
            raw = json.loads(raw)["result"]
        except Exception:
            pass
    m = re.search(r"\{.*\}", raw, re.S)
    return json.loads(m.group(0)) if m else None


def main():
    res = Path(sys.argv[1])
    raters = {}
    for f in sorted(res.glob("*.json")):
        if f.name.startswith("aesthetic"):
            continue
        try:
            d = load(f)
        except Exception as e:
            print(f"{f.name}: unreadable ({e})")
            continue
        if d:
            raters[f.stem] = d
    if not raters:
        print("no verdicts")
        return
    print(f"{len(raters)} raters: {', '.join(raters)}")
    for r in NAMES:
        vals = [d["scores"][r]["score"] for d in raters.values() if r in d.get("scores", {})]
        if vals:
            print(f"  {r:>3} {NAMES[r]:<12} median {st.median(vals):.1f}  ({' '.join(map(str, vals))})")
    for k, d in raters.items():
        print(f"- {k}: fun {d.get('overall_fun')}/10, again {d.get('play_again_with_friend', {}).get('answer')}, "
              f"co-op required {d.get('cooperation_required', {}).get('answer')}")
    print("WORST:")
    for k, d in raters.items():
        for w in d.get("worst_moments", []):
            print(f"  [{k}] {w.get('t')}: {w.get('what')}")
    print("FIXES:")
    for k, d in raters.items():
        for x in d.get("top_3_fixes", []):
            print(f"  [{k}] {x}")






def aesthetics(res):
    out = {}
    for f in sorted(Path(res).glob("aesthetic_*.json")):
        try:
            d = load(f)
        except Exception as e:
            print(f"{f.name}: unreadable ({e})")
            continue
        if d:
            out[f.stem] = d
    if not out:
        return
    print(f"AESTHETICS ({len(out)} critics)")
    for k in [f"A{i}" for i in range(1, 11)]:
        vals = [d["scores"][k]["score"] for d in out.values() if k in d.get("scores", {})]
        if vals:
            print(f"  {k:>3} median {st.median(vals):.1f}  ({' '.join(map(str, vals))})")
    for k, d in out.items():
        print(f"- {k}: overall look {d.get('overall_look')}/10")
        for u in d.get("ugliest_moments", []):
            print(f"  UGLY {u.get('where')}: {u.get('what')}")
        for x in d.get("top_5_art_fixes", []):
            print(f"  ART FIX {x}")


if __name__ == "__main__":
    main()
    aesthetics(sys.argv[1])
