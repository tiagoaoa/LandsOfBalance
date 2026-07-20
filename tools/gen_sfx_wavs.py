#!/usr/bin/env python3
"""Generate the game's synthetic SFX set.

Same philosophy as gen_footstep_wavs.py: license-clean procedural WAVs,
tiny, swappable later for CC0 recordings (Kenney / Sonniss GDC / freesound)
without touching code. 16-bit mono 44.1kHz into assets/audio/sfx/.

One-shots: sword whooshes (3 combo steps), metal hit, parry ring, block
chip, flesh thud, heavy punch whoosh, bow release twang, arrow impact,
fire ignite, estus drink, roll, Bobba roar, death thud.
Loops (seamless): fire crackle, rain+wind night bed, river babble.

Run once from the repo root:
    python3 tools/gen_sfx_wavs.py
"""

from __future__ import annotations

import math
import os
import random
import struct
import wave

SAMPLE_RATE = 44100
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "sfx")
rng = random.Random(9001)


def _write_wav(path: str, samples: list[float], peak_target: float = 0.85) -> None:
    peak = max(1e-6, max(abs(s) for s in samples))
    scale = peak_target / peak
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s * scale)) * 32767)) for s in samples)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(data)
    print(f"  wrote {os.path.basename(path)} ({len(samples) / SAMPLE_RATE:.2f}s)")


def _n(duration_s: float) -> int:
    return int(SAMPLE_RATE * duration_s)


def _noise(n: int) -> list[float]:
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def _lowpass(samples: list[float], cutoff_hz: float) -> list[float]:
    rc = 1.0 / (2.0 * math.pi * cutoff_hz)
    dt = 1.0 / SAMPLE_RATE
    alpha = dt / (rc + dt)
    out, prev = [], 0.0
    for x in samples:
        prev = prev + alpha * (x - prev)
        out.append(prev)
    return out


def _highpass(samples: list[float], cutoff_hz: float) -> list[float]:
    lp = _lowpass(samples, cutoff_hz)
    return [s - l for s, l in zip(samples, lp)]


def _bandpass(samples: list[float], low_hz: float, high_hz: float) -> list[float]:
    return _highpass(_lowpass(samples, high_hz), low_hz)


def _env_exp(n: int, decay: float, attack_s: float = 0.004) -> list[float]:
    att = max(1, int(SAMPLE_RATE * attack_s))
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        a = min(1.0, i / att)
        out.append(a * math.exp(-decay * t))
    return out


def _mix(*layers: list[float]) -> list[float]:
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for l in layers:
        for i, s in enumerate(l):
            out[i] += s
    return out


def _gain(samples: list[float], g: float) -> list[float]:
    return [s * g for s in samples]


def _sine_partials(n: int, partials: list[tuple[float, float, float]]) -> list[float]:
    """partials: (freq_hz, amplitude, decay_per_s)."""
    out = [0.0] * n
    for freq, amp, decay in partials:
        for i in range(n):
            t = i / SAMPLE_RATE
            out[i] += amp * math.sin(2.0 * math.pi * freq * t) * math.exp(-decay * t)
    return out


def _loopable(samples: list[float], fade_s: float = 0.25) -> list[float]:
    """Crossfade the tail into the head so a forward loop is seamless."""
    f = _n(fade_s)
    n = len(samples)
    out = samples[:]
    for i in range(f):
        w = i / f
        out[i] = samples[i] * w + samples[n - f + i] * (1.0 - w)
    return out[: n - f]


# --- one-shots ---------------------------------------------------------------

def sword_whoosh(step: int) -> list[float]:
    """Air-cutting swing. Later combo steps are longer/deeper."""
    dur = [0.28, 0.30, 0.42][step]
    n = _n(dur)
    noise = _noise(n)
    # Sweeping bandpass: the "shape" of a whoosh is the filter movement.
    out = []
    prev = 0.0
    for i, x in enumerate(noise):
        t = i / n
        # centre sweeps up then down; heavier finisher sweeps lower.
        centre = (900 - step * 150) + math.sin(t * math.pi) * (1400 - step * 250)
        rc = 1.0 / (2.0 * math.pi * max(200.0, centre))
        alpha = (1.0 / SAMPLE_RATE) / (rc + 1.0 / SAMPLE_RATE)
        prev = prev + alpha * (x - prev)
        env = math.sin(t * math.pi) ** 1.6
        out.append(prev * env)
    return _highpass(out, 300)


def punch_whoosh() -> list[float]:
    n = _n(0.34)
    body = _bandpass(_noise(n), 120, 900)
    env = [math.sin((i / n) * math.pi) ** 2 for i in range(n)]
    return [b * e for b, e in zip(body, env)]


def hit_metal() -> list[float]:
    n = _n(0.5)
    ring = _sine_partials(n, [(620, 0.9, 9.0), (1080, 0.6, 11.0), (1750, 0.45, 14.0), (2600, 0.3, 18.0)])
    clank = _gain(_highpass(_noise(_n(0.03)), 2000), 0.8)
    thud = _gain(_lowpass(_noise(_n(0.08)), 200), 1.2)
    return _mix(ring, clank, thud)


def parry_ring() -> list[float]:
    n = _n(0.9)
    ring = _sine_partials(n, [(880, 1.0, 4.5), (1320, 0.7, 5.5), (1980, 0.5, 7.0), (2960, 0.35, 9.0)])
    shimmer = _gain(_bandpass(_noise(n), 3000, 8000), 0.12)
    env = _env_exp(n, 5.0)
    return _mix(ring, [s * e for s, e in zip(shimmer, env)])


def block_chip() -> list[float]:
    n = _n(0.3)
    ring = _sine_partials(n, [(520, 0.7, 16.0), (940, 0.5, 20.0), (1500, 0.3, 26.0)])
    thud = _gain(_lowpass(_noise(_n(0.09)), 260), 1.4)
    return _mix(ring, thud)


def hit_flesh() -> list[float]:
    n = _n(0.22)
    thud = _sine_partials(n, [(95, 1.2, 22.0), (60, 0.8, 16.0)])
    smack = _gain(_bandpass(_noise(_n(0.05)), 400, 2200), 0.7)
    return _mix(thud, smack)


def bow_release() -> list[float]:
    n = _n(0.5)
    # Plucked-string twang + immediate arrow hiss.
    twang = _sine_partials(n, [(190, 1.0, 12.0), (380, 0.55, 15.0), (570, 0.3, 20.0), (760, 0.2, 26.0)])
    hiss_n = _n(0.35)
    hiss = _bandpass(_noise(hiss_n), 1200, 6000)
    hiss = [h * math.exp(-9.0 * i / hiss_n) * 0.35 for i, h in enumerate(hiss)]
    return _mix(twang, hiss)


def arrow_impact() -> list[float]:
    n = _n(0.25)
    thunk = _sine_partials(n, [(140, 1.0, 26.0), (85, 0.7, 18.0)])
    crack = _gain(_highpass(_noise(_n(0.03)), 1500), 0.6)
    return _mix(thunk, crack)


def fire_ignite() -> list[float]:
    n = _n(0.7)
    burst = _lowpass(_noise(n), 3000)
    env = [math.exp(-5.0 * i / n) * (0.4 + 0.6 * math.sin((i / n) * math.pi)) for i in range(n)]
    body = [b * e for b, e in zip(burst, env)]
    woof = _sine_partials(_n(0.3), [(70, 0.9, 12.0)])
    return _mix(body, woof)


def estus_drink() -> list[float]:
    n = _n(0.8)
    out = [0.0] * n
    # Three descending glugs.
    for k, start in enumerate([0.0, 0.22, 0.46]):
        s0 = _n(start)
        gn = _n(0.16)
        f0 = 300 - k * 60
        for i in range(gn):
            if s0 + i >= n:
                break
            t = i / SAMPLE_RATE
            f = f0 - 250 * (i / gn)
            out[s0 + i] += math.sin(2.0 * math.pi * f * t) * math.exp(-14.0 * t)
    return _lowpass(out, 900)


def roll_thud() -> list[float]:
    n = _n(0.35)
    cloth = _gain(_bandpass(_noise(n), 300, 1400), 0.5)
    env = [math.sin((i / n) * math.pi) ** 2 for i in range(n)]
    cloth = [c * e for c, e in zip(cloth, env)]
    thud = _sine_partials(_n(0.15), [(80, 0.9, 20.0)])
    return _mix(cloth, thud)


def bobba_roar() -> list[float]:
    n = _n(1.1)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SAMPLE_RATE
        # Growly sawtooth around 70-95Hz with vibrato and grit.
        f = 82 + 14 * math.sin(2.0 * math.pi * 3.1 * t) + 8 * math.sin(2.0 * math.pi * 0.9 * t)
        phase += f / SAMPLE_RATE
        saw = 2.0 * (phase - math.floor(phase + 0.5))
        grit = rng.uniform(-1.0, 1.0) * 0.35
        env = math.sin(min(1.0, t / 0.15) * math.pi / 2.0) * math.exp(-1.6 * max(0.0, t - 0.55))
        out.append((saw * 0.8 + grit) * env)
    return _lowpass(out, 700)


def death_thud() -> list[float]:
    n = _n(0.6)
    body = _sine_partials(n, [(55, 1.2, 7.0), (110, 0.5, 10.0)])
    dirt = _gain(_lowpass(_noise(_n(0.2)), 500), 0.5)
    return _mix(body, dirt)


# --- loops -------------------------------------------------------------------

def fire_crackle_loop() -> list[float]:
    n = _n(4.0)
    bed = _gain(_lowpass(_noise(n), 500), 0.5)
    out = bed[:]
    # Random pops: tiny high-passed clicks with fast decay.
    for _ in range(90):
        p = rng.randrange(0, n - _n(0.04))
        pn = _n(rng.uniform(0.008, 0.03))
        for i in range(pn):
            t = i / SAMPLE_RATE
            out[p + i] += rng.uniform(-1.0, 1.0) * math.exp(-300.0 * t) * rng.uniform(0.5, 1.2)
    return _loopable(_highpass(out, 60))


def night_rain_loop() -> list[float]:
    n = _n(6.0)
    rain = _gain(_bandpass(_noise(n), 900, 7000), 0.35)
    wind_src = _lowpass(_noise(n), 220)
    # Slow wind swells.
    wind = [w * (0.5 + 0.5 * math.sin(2.0 * math.pi * (i / n) * 2.0 + 1.3)) * 0.9 for i, w in enumerate(wind_src)]
    return _loopable(_mix(rain, wind), 0.5)


def river_loop() -> list[float]:
    n = _n(5.0)
    rush = _gain(_bandpass(_noise(n), 400, 3200), 0.6)
    # Babble: amplitude wobble at a few Hz.
    out = [r * (0.7 + 0.3 * math.sin(2.0 * math.pi * 4.7 * (i / SAMPLE_RATE)) *
			math.sin(2.0 * math.pi * 0.6 * (i / SAMPLE_RATE))) for i, r in enumerate(rush)]
    return _loopable(out, 0.4)


def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print("Generating SFX into", os.path.relpath(OUTPUT_DIR))
    one_shots = {
        "sword_whoosh_1.wav": sword_whoosh(0),
        "sword_whoosh_2.wav": sword_whoosh(1),
        "sword_whoosh_3.wav": sword_whoosh(2),
        "punch_whoosh.wav": punch_whoosh(),
        "hit_metal.wav": hit_metal(),
        "parry_ring.wav": parry_ring(),
        "block_chip.wav": block_chip(),
        "hit_flesh.wav": hit_flesh(),
        "bow_release.wav": bow_release(),
        "arrow_impact.wav": arrow_impact(),
        "fire_ignite.wav": fire_ignite(),
        "estus_drink.wav": estus_drink(),
        "roll.wav": roll_thud(),
        "bobba_roar.wav": bobba_roar(),
        "death_thud.wav": death_thud(),
    }
    for name, samples in one_shots.items():
        _write_wav(os.path.join(OUTPUT_DIR, name), samples)
    loops = {
        "fire_crackle_loop.wav": fire_crackle_loop(),
        "night_rain_loop.wav": night_rain_loop(),
        "river_loop.wav": river_loop(),
    }
    for name, samples in loops.items():
        _write_wav(os.path.join(OUTPUT_DIR, name), samples, peak_target=0.55)
    print("Done. Loops must be imported with loop_mode=forward (see sfx.gd,")
    print("which forces looping at runtime regardless of import settings).")


if __name__ == "__main__":
    main()
