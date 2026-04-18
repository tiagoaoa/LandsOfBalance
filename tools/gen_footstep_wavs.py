#!/usr/bin/env python3
"""Generate placeholder footstep + jump WAV files.

Writes three 16-bit mono 44.1kHz WAV files to
assets/audio/footsteps/. These are synthetic — short percussive
thumps built out of an exponentially-damped low-frequency sine with
some filtered noise on top. They're not AAA footage, but they're
license-clean, tiny, and can be swapped for CC0 recordings (Kenney,
freesound, Sonniss GDC bundles) later without code changes.

Run once from the repo root:
    python3 tools/gen_footstep_wavs.py
"""

from __future__ import annotations

import math
import os
import random
import struct
import wave

SAMPLE_RATE = 44100
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "footsteps")


def _write_wav(path: str, samples: list[float]) -> None:
    peak = max(1e-6, max(abs(s) for s in samples))
    scale = 0.85 / peak  # normalize and leave headroom
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s * scale)) * 32767)) for s in samples)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(data)


def _lowpass(samples: list[float], cutoff_hz: float) -> list[float]:
    # Single-pole IIR low-pass; cheap but good enough for colouring noise.
    rc = 1.0 / (2.0 * math.pi * cutoff_hz)
    dt = 1.0 / SAMPLE_RATE
    alpha = dt / (rc + dt)
    out = [0.0] * len(samples)
    prev = 0.0
    for i, x in enumerate(samples):
        prev = prev + alpha * (x - prev)
        out[i] = prev
    return out


def _thump(duration_s: float, freq_hz: float, decay: float, noise_amount: float,
           noise_cutoff_hz: float, click_db: float = -6.0) -> list[float]:
    """Percussive element: damped sine at freq_hz + noise burst."""
    n = int(SAMPLE_RATE * duration_s)
    tone = []
    noise = []
    for i in range(n):
        t = i / SAMPLE_RATE
        env = math.exp(-decay * t)
        tone.append(math.sin(2.0 * math.pi * freq_hz * t) * env)
        noise.append((random.random() * 2.0 - 1.0) * env)
    noise = _lowpass(noise, noise_cutoff_hz)
    click_scale = 10.0 ** (click_db / 20.0)
    # 5 ms attack envelope to avoid a crackly onset
    attack = int(SAMPLE_RATE * 0.005)
    samples = []
    for i in range(n):
        a = min(1.0, i / max(1, attack))
        samples.append(a * (tone[i] + noise[i] * noise_amount * click_scale))
    return samples


def gen_walk() -> list[float]:
    # Soft low thump, fairly muted. 90 ms.
    return _thump(duration_s=0.090, freq_hz=130.0, decay=45.0,
                  noise_amount=0.6, noise_cutoff_hz=2200.0, click_db=-4.0)


def gen_run() -> list[float]:
    # Harder, shorter, a touch brighter. 70 ms.
    return _thump(duration_s=0.070, freq_hz=180.0, decay=60.0,
                  noise_amount=0.9, noise_cutoff_hz=3800.0, click_db=-2.0)


def gen_jump() -> list[float]:
    # Two-layer: a "takeoff" chirp (pitch falls) + subtle wind.
    n = int(SAMPLE_RATE * 0.180)
    out = [0.0] * n
    # Descending pitch 220 -> 90 Hz over ~120 ms
    for i in range(n):
        t = i / SAMPLE_RATE
        pitch = 220.0 - (220.0 - 90.0) * min(1.0, t / 0.120)
        env = math.exp(-12.0 * t)
        out[i] += math.sin(2.0 * math.pi * pitch * t) * env
    # Add mid-freq filtered noise "whoosh"
    whoosh = []
    for i in range(n):
        t = i / SAMPLE_RATE
        env = math.sin(math.pi * min(1.0, t / 0.180)) ** 2
        whoosh.append((random.random() * 2.0 - 1.0) * env)
    whoosh = _lowpass(whoosh, 1800.0)
    for i in range(n):
        out[i] += whoosh[i] * 0.35
    # Short attack to kill click
    attack = int(SAMPLE_RATE * 0.005)
    for i in range(attack):
        out[i] *= i / attack
    return out


def main() -> int:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    random.seed(1337)
    _write_wav(os.path.join(OUTPUT_DIR, "walk.wav"), gen_walk())
    random.seed(2025)
    _write_wav(os.path.join(OUTPUT_DIR, "run.wav"), gen_run())
    random.seed(42)
    _write_wav(os.path.join(OUTPUT_DIR, "jump.wav"), gen_jump())
    print("Wrote footstep WAVs to", os.path.abspath(OUTPUT_DIR))
    for f in ("walk.wav", "run.wav", "jump.wav"):
        p = os.path.join(OUTPUT_DIR, f)
        print(f"  {f}: {os.path.getsize(p)} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
