#!/usr/bin/env python3
"""Players inside the boss: summarise the contact episodes the arena logs
under LOB_CONTACT_PROBE=1 ("contact" in each match report).

    python3 tools/contact_report.py <sim_dir> [--list N]

kind skin     = more than 0.25 m behind the boss's visible hide (SkinProbe)
kind collider = overlapping a solid hitbox while free on the floor
"""
import collections
import glob
import json
import sys


def load(d):
    files = sorted(glob.glob(d + "/matches_w*.ndjson")) or sorted(glob.glob(d + "/*.ndjson"))
    for f in files:
        for line in open(f):
            line = line.strip()
            if line:
                yield json.loads(line)


def main():
    d = sys.argv[1]
    n_list = int(sys.argv[sys.argv.index("--list") + 1]) if "--list" in sys.argv else 12
    ms = list(load(d))
    secs = sum(m["duration"] for m in ms)
    eps = [dict(e, match=i) for i, m in enumerate(ms) for e in m.get("contact", [])]
    print(f"== {d}: {len(ms)} matches, {secs/60:.1f} min of fighting")
    for kind in ("skin", "collider"):
        es = [e for e in eps if e["kind"] == kind]
        t = sum(e["dur"] for e in es)
        print(f"\n[{kind}] {len(es)} episodes, {t:.1f} s inside "
              f"({100*t/max(secs,1)/2:.2f}% of player-time), "
              f"matches affected {len({e['match'] for e in es})}/{len(ms)}")
        if not es:
            continue
        for key in ("state", "where", "act", "tactic", "who"):
            c = collections.Counter()
            for e in es:
                c[e[key]] += e["dur"]
            print(f"  by {key:7s}: " + ", ".join(f"{k} {v:.1f}s" for k, v in c.most_common(8)))
        long = sorted(es, key=lambda e: -e["dur"])[:n_list]
        print("  longest:")
        for e in long:
            print(f"    m{e['match']:02d} t={e['t']:6.1f} {e['dur']:4.1f}s depth={e['depth']:.2f} "
                  f"{e['who']:7s} {e['state']:8s} {e['act']:9s} {e['tactic']:12s} {e['where']} @{e['pos']}")


if __name__ == "__main__":
    main()
