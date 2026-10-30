#!/usr/bin/env python3
"""Two builds in one blind packet, for "which is more fun / better looking".

    python3 tools/playtest/build_pair.py --x <packet_dir_A> --y <packet_dir_B> --out <dir>

Each input is a packet from build_packet.py. They become "Build X" and
"Build Y" (swap them between raters to cancel position bias — never say
which is newer or which one we prefer).
"""
import argparse
import shutil
from pathlib import Path

HEAD = """PAIRWISE PLAYTEST PACKET

Two builds of the same boss fight, played by the same two players.
Folder "Build X" and folder "Build Y" each hold that build's README.txt,
runs (timelines, stats, frame sheets, full frames) and any solo attempts.
Read both READMEs: they say what differs (for example the platform size or
the players' second spells). Judge each build on its own first, then
compare. Neither is the "new" one.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--x", required=True)
    ap.add_argument("--y", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    shutil.copytree(a.x, out / "Build X")
    shutil.copytree(a.y, out / "Build Y")
    (out / "README.txt").write_text(HEAD)
    print(f"pair packet: {out}")


if __name__ == "__main__":
    main()
