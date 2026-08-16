#!/usr/bin/env python3
"""Fold saved pose JSON back into enemies/bobba_anims.gd.

The animation lab saves to tests/anim_lab/poses/<Clip>.json, and BobbaAnims
loads those over its built-in keys at runtime. That is what makes iterating
fast, but it leaves the source reading as the truth when it is not — the file
says one thing and the game plays another.

Baking resolves that: the JSON is written into the GDScript, so git records
what actually runs. Do it before committing an animation change.

    tools/bake_poses.py                 bake every saved clip
    tools/bake_poses.py AxeAttack       bake one
    tools/bake_poses.py --check         exit 1 if source and JSON disagree

--check is the useful one in a hook or before a release: it answers "is the
committed animation the one I tuned?" without changing anything.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POSES = ROOT / "tests/anim_lab/poses"
TARGET = ROOT / "enemies/bobba_anims.gd"


def gd_for(spec):
    """The clip as GDScript, matching the style already in the file."""
    out = ["\t\t{"]
    head = '\t\t\t"name": "%s", "base": "%s", "length": %.2f,' % (
        spec["name"], spec.get("base", "Idle"), float(spec.get("length", 0.0)))
    if spec.get("loop"):
        head += ' "loop": true,'
    out.append(head)
    out.append("\t\t\t\"keys\": [")
    for k in spec["keys"]:
        pose = k.get("pose", {})
        twist = k.get("twist", {})
        parts = []
        for b in sorted(pose):
            x, y, z = pose[b]
            if (x, y, z) == (0, 0, 0) and b not in twist:
                continue
            parts.append('"%s": Vector3(%d, %d, %d)' % (b, round(x), round(y), round(z)))
        tparts = ['"%s": %.1f' % (b, float(twist[b])) for b in sorted(twist)]
        line = '\t\t\t\t{"t": %.2f' % float(k["t"])
        if tparts:
            line += ', "twist": {%s}' % ", ".join(tparts)
        line += ', "pose": {%s}},' % ", ".join(parts)
        out.append(line)
    out.append("\t\t\t],")
    out.append("\t\t},")
    return "\n".join(out)


def find_block(src, name):
    """Byte range of the `{ "name": "<name>" ... },` entry in the specs array."""
    marker = '"name": "%s"' % name
    i = src.find(marker)
    if i == -1:
        return None
    start = src.rfind("\t\t{", 0, i)
    end = src.find("\n\t\t},", i)
    if start == -1 or end == -1:
        return None
    return start, end + len("\n\t\t},")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    check = "--check" in sys.argv[1:]

    if not POSES.is_dir():
        print("no poses directory at %s" % POSES)
        return 0
    files = sorted(POSES.glob("*.json"))
    if args:
        files = [f for f in files if f.stem in args]
    if not files:
        print("nothing to bake")
        return 0

    src = TARGET.read_text()
    changed, stale = [], []
    for f in files:
        spec = json.loads(f.read_text())
        name = spec.get("name")
        span = find_block(src, name)
        if span is None:
            print("  %-14s no matching spec in %s — skipped" % (name, TARGET.name))
            continue
        new = gd_for(spec)
        old = src[span[0]:span[1]]
        if old.strip() == new.strip():
            print("  %-14s already baked" % name)
            continue
        stale.append(name)
        if not check:
            src = src[:span[0]] + new + src[span[1]:]
            changed.append(name)

    if check:
        if stale:
            print("\nOUT OF DATE: %s" % ", ".join(stale))
            print("The game loads these from JSON, so what runs is NOT what "
                  "%s says. Run tools/bake_poses.py." % TARGET.name)
            return 1
        print("\nsource matches the saved poses")
        return 0

    if changed:
        TARGET.write_text(src)
        print("\nbaked into %s: %s" % (TARGET.name, ", ".join(changed)))
    else:
        print("\nnothing to change")
    return 0


if __name__ == "__main__":
    sys.exit(main())
