#!/usr/bin/env python3
"""Check the rendered audio, not just the synthesis recipe."""

import json
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1] / "assets/audio/designed"


def check(path):
    with wave.open(str(path)) as f:
        assert (f.getnchannels(), f.getsampwidth(), f.getframerate()) == (1, 2, 48000)
        x = np.frombuffer(f.readframes(f.getnframes()), dtype="<i2").astype(float) / 32768
    assert .02 < np.max(abs(x)) < .72, (path.name, "silence or missing headroom")
    assert abs(x.mean()) < .01, (path.name, "DC offset")
    if "_loop_" in path.name:
        limit = max(.02, np.percentile(abs(np.diff(x)), 99) * 2)
        assert abs(x[0] - x[-1]) < limit, (path.name, "loop discontinuity")
    else:
        assert abs(x[0]) + abs(x[-1]) < .0001, (path.name, "unfaded cut")


def main():
    bank = json.loads((ROOT / "bank.json").read_text())
    count = 0
    for files in bank.values():
        data = []
        for name in files:
            check(ROOT / name)
            data.append((ROOT / name).read_bytes())
            count += 1
        assert len(set(data)) == len(data), "duplicate variation"
    print("PASS: %d events, %d recordings; headroom, DC, fades, loops, distinct takes" % (len(bank), count))


if __name__ == "__main__":
    main()
