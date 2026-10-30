#!/usr/bin/env python3
"""Summarise boss-arena match reports (tools/run_boss_sims.sh output).

    python3 tools/boss_report.py <run_dir or matches.ndjson> [more runs...]

Prints, per run: outcomes, fight length, how falls happened, who did the
damage, and how often each co-op mechanic actually occurred per match —
the numbers the "is this fight fun and does it need both players" call
is made from.
"""
import json
import statistics as st
import sys
from collections import Counter
from pathlib import Path


def load(path):
    p = Path(path)
    files = [p] if p.is_file() else sorted(p.glob("matches_w*.ndjson")) or [p / "matches.ndjson"]
    out = []
    for f in files:
        if f.exists():
            for line in f.read_text().splitlines():
                if line.strip():
                    out.append(json.loads(line))
    return out


def per_match(ms, key):
    return sum(m["events"].get(key, 0) for m in ms) / max(len(ms), 1)


def summarise(name, ms):
    if not ms:
        print(f"== {name}: no matches")
        return
    n = len(ms)
    oc = Counter(m["outcome"] for m in ms)
    wins = [m for m in ms if m["outcome"] == "WIN"]
    print(f"== {name}: {n} matches  ai={ms[0].get('ai_mode')}")
    print("  outcomes: " + ", ".join(f"{k} {v} ({100*v/n:.0f}%)" for k, v in oc.most_common()))
    d = [m["duration"] for m in ms]
    print(f"  duration: median {st.median(d):.0f}s  (wins median {st.median([m['duration'] for m in wins]):.0f}s)" if wins else f"  duration: median {st.median(d):.0f}s")
    print(f"  boss hp left on losses: median {st.median([m['boss_hp_frac'] for m in ms if m['outcome']!='WIN'] or [0]):.2f}")
    falls = Counter((m.get("who"), m.get("fall_cause"), m.get("fall_tactic")) for m in ms if m["outcome"] == "FALL")
    if falls:
        print("  falls: " + ", ".join(f"{w}/{c}/{t} {v}" for (w, c, t), v in falls.most_common()))
    dealt = Counter()
    for m in ms:
        for k, v in m.get("dealt", {}).items():
            dealt[k] += v
    tot = sum(dealt.values()) or 1
    print("  damage share: " + ", ".join(f"{k} {100*v/tot:.0f}%" for k, v in dealt.most_common()))
    close = [m for m in wins if min(m.get("hp_paladin", 1), m.get("hp_archer", 1)) < 0.3 or m.get("dead_paladin") or m.get("dead_archer")]
    if wins:
        print(f"  close wins (someone <30% or down): {len(close)}/{len(wins)}")
    keys = ["slam", "slam_hit", "parry", "poise_break", "stagger", "sweep", "sweep_hit", "sweep_cleared",
            "shift", "climb", "mounted", "shake", "clung", "flung", "hit_head_paladin", "plunge", "hit_plunge_paladin", "spell", "marks", "hit_mark_archer", "ignite", "head_slam", "head_hit", "head_miss", "tail", "struggle", "sweep_high", "covered", "grab", "grabbed", "grab_missed", "rescued", "thrown", "dropped", "gaze", "eye_interrupt",
            "beam_hit", "beam_cover", "roar", "roar_hit", "roar_braced", "downed", "phase2",
            "brazier_out", "brazier_lit", "hit_head_archer",
            "hit_core_archer", "hit_core_paladin", "hit_hand_paladin", "hit_hand_archer",
            "hit_armor_archer", "hit_armor_paladin"]
    print("  per match: " + ", ".join(f"{k} {per_match(ms, k):.1f}" for k in keys if per_match(ms, k) > 0))
    grabbed = sum(m["events"].get("grabbed", 0) for m in ms)
    if grabbed:
        print(f"  rescue rate: {sum(m['events'].get('rescued', 0) for m in ms)}/{grabbed}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    for path in sys.argv[1:]:
        summarise(Path(path).name, load(path))


if __name__ == "__main__":
    main()
