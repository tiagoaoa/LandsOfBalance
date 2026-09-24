#!/usr/bin/env python3
"""Layer the recorded foley and spell beds. Requires numpy and ffmpeg.

python3 tools/build_audio_bank.py
Sources and attribution: assets/audio/sfx/CREDITS.md.
Original recordings stay untouched; outputs go to assets/audio/designed/.
"""

import json
import subprocess
import wave
from functools import lru_cache
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets/audio/source"
OLD = ROOT / "assets/audio/sfx"
OUT = ROOT / "assets/audio/designed"
RATE = 48000
RNG = np.random.default_rng(20260920)
BANK = {}


@lru_cache(maxsize=None)
def read(path):
    raw = subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(RATE),
        "-af", "highpass=f=35,lowpass=f=15000", "-f", "f32le", "-"])
    return np.frombuffer(raw, dtype="<f4").astype(float)


def recorded(name):
    return read(OLD / (name + ".wav"))


def rpg(name):
    return read(SRC / "rpg" / (name + ".wav"))


def impact(name, i):
    return read(SRC / "impact" / (name + "_%03d.ogg" % (i % 5)))


def pitch(x, rate):
    return np.interp(np.arange(0, len(x) - 1, rate), np.arange(len(x)), x)


def mix(*layers):
    n = max(len(x) + int(delay * RATE) for x, gain, delay in layers)
    out = np.zeros(n)
    for x, gain, delay in layers:
        start = int(delay * RATE)
        out[start:start + len(x)] += x * gain
    return out


def low(x, hz):
    freq = np.fft.rfftfreq(len(x), 1 / RATE)
    return np.fft.irfft(np.fft.rfft(x) / (1 + (freq / hz) ** 4), n=len(x))


def body(seconds, frequency=80):
    t = np.arange(int(seconds * RATE)) / RATE
    return np.sin(2 * np.pi * (frequency * t - 18 * t * t)) * np.exp(-14 * t)


def air(seconds, hz=1800):
    x = RNG.normal(0, .2, int(seconds * RATE))
    x = low(x, hz) - low(x, 120)
    return x * np.sin(np.linspace(0, np.pi, len(x))) ** 1.5


def seam(x, seconds=.25):
    n = min(int(seconds * RATE), len(x) // 4)
    out = x[:-n].copy()
    blend = np.linspace(0, 1, n)
    out[:n] = x[-n:] * (1 - blend) + x[:n] * blend
    return out


def save(event, x, peak=-4.0, loop=False):
    x = x - x.mean()
    if loop:
        x = seam(x)
    else:
        #Preserve the transient, remove dead air and silence the cut edges.
        live = np.flatnonzero(abs(x) > max(abs(x).max() * .008, .0001))
        x = x[max(0, live[0] - 96):min(len(x), live[-1] + 1200)]
        n = min(96, len(x) // 8)
        x[:n] *= np.linspace(0, 1, n)
        n = min(1200, len(x) // 5)
        x[-n:] *= np.linspace(1, 0, n)
    x *= 10 ** (peak / 20) / max(abs(x).max(), 1e-9)
    files = BANK.setdefault(event, [])
    name = "%s_%d.wav" % (event, len(files) + 1)
    with wave.open(str(OUT / name), "wb") as f:
        f.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        f.writeframes(np.round(x * 32767).astype("<i2").tobytes())
    files.append(name)


def weapons():
    cloth = rpg("inventory/cloth-heavy")
    ring = rpg("inventory/metal-ringing")
    for i in range(3):
        rate = .94 + i * .055
        hit = impact("impactPunch_heavy", i)
        plate = impact("impactPlate_medium", i)
        wood = impact("impactWood_medium", i)
        for step in range(1, 4):
            swish = pitch(recorded("sword_whoosh_%d" % step), rate)
            save("sword_whoosh_%d" % step, mix((swish, 1, 0),
                 (air(.22 + step * .025), .7, 0), (cloth, .13, .02)))
        save("punch_whoosh", mix((pitch(recorded("punch_whoosh"), rate), 1, 0),
             (air(.3, 850), 1.2, 0), (cloth, .15, .025)))
        save("hit_metal", mix((pitch(recorded("hit_metal"), rate), .8, 0),
             (plate, .45, .008), (body(.3), .14, 0)))
        save("hit_flesh", mix((pitch(recorded("hit_flesh"), rate), .8, 0),
             (hit, .6, 0), (cloth, .2, .03)))
        save("block_chip", mix((plate, .9, 0), (wood, .3, .015),
             (body(.3, 110), .13, 0)), -5)
        save("parry_ring", mix((recorded("parry_ring"), .7, 0),
             (pitch(ring, .88 + i * .04), .5, .025), (plate, .6, 0)), -3)
        save("bow_release", mix((pitch(recorded("bow_release"), rate), 1, 0),
             (air(.22, 4000), .2, .02), (wood, .10, 0)))
        save("bow_draw", mix((pitch(cloth, .7 + i * .05), .7, 0),
             (low(wood, 1600), .2, .12)), -9)
        for surface, layer in [("wood", wood), ("stone", plate), ("flesh", hit)]:
            save("arrow_impact_" + surface,
                 mix((pitch(recorded("arrow_impact"), rate), .7, 0),
                     (layer, .65, .008), (body(.18, 140), .08, 0)), -5)
        save("arrow_impact", mix((recorded("arrow_impact"), .8, 0), (wood, .5, 0)), -5)


def foley():
    cloth = rpg("inventory/cloth-heavy")
    for i in range(5):
        for surface in ["grass", "concrete", "wood"]:
            step = impact("footstep_" + surface, i)
            save("step_" + surface, mix((step, 1, 0), (cloth, .07, .02)), -6)
        mail = rpg("inventory/chainmail%d" % (i % 2 + 1))
        save("armor_step", pitch(mail, .88 + i * .06), -12)
    for i in range(3):
        soft = impact("impactSoft_heavy", i)
        save("roll", mix((pitch(cloth, .8 + i * .08), 1, 0),
             (soft, .4, .13)), -6)
        save("jump", mix((air(.22, 900), .5, 0), (cloth, .7, 0)), -8)
        save("land", mix((soft, 1, 0), (body(.28, 65), .18, 0),
             (cloth, .35, .025)), -5)
        save("death_thud", mix((pitch(recorded("death_thud"), .8 + i * .06), .8, 0),
             (soft, .65, .04), (cloth, .3, .06)), -4)
        bubbles = rpg("inventory/bubble" + (str(i + 1) if i else ""))
        save("estus_drink", mix((rpg("inventory/bottle"), .7, 0),
             (bubbles, .3, .17), (cloth, .1, .03)), -6)
        save("coin", rpg("inventory/coin" + (str(i + 1) if i else "")), -8)
        growl = rpg("NPC/giant/giant%d" % (i + 1))
        save("bobba_roar", pitch(growl, .72 + i * .035), -4)
        save("dragon_roar", mix((pitch(growl, .52 + i * .02), 1, 0),
             (low(pitch(growl, .45), 350), .35, .025)), -4)


def spells():
    fire = recorded("fire_crackle_loop")
    magic = rpg("battle/magic1")
    ring = rpg("inventory/metal-ringing")
    for i in range(3):
        burst = air(1.15, 2300)
        rumble = low(air(1.7, 400), 260)
        flare = pitch(recorded("fire_ignite"), 1.3 + i * .06)[:RATE]
        save("fire_ignite", mix((flare[:int(RATE * .65)], .6, 0),
             (burst, .8, 0), (rumble, 1.5, 0)), -6)
        save("spell_fire_start", mix((flare, .7, 0), (burst, 1.5, 0),
             (rumble, 2.4, .015)), -4)
        save("spell_lightning_start", mix((pitch(magic, .8 + i * .04), .6, 0),
             (body(.5, 100), .16, 0), (ring, .3, .03), (air(.4, 7000), .5, 0)), -4)
        save("spell_lightning_end", mix((low(air(1.2, 800), 700), 2, 0),
             (pitch(ring, .65), .4, .03), (body(.5, 65), .15, 0)), -5)
        save("spell_fire_end", mix((air(.7, 1300), 1, 0),
             (low(flare, 650), .45, 0)), -8)
    t = np.arange(RATE * 6) / RATE
    noise = RNG.normal(0, .2, len(t))
    crackle = (noise - low(noise, 3000)) * (np.sin(t * 2 * np.pi * 13) ** 18)
    hum = .05 * np.sin(2 * np.pi * 55 * t) + .025 * np.sin(2 * np.pi * 110 * t)
    save("spell_lightning_loop", crackle * .22 + hum * (.7 + .3 * np.sin(t * 2)), -10, True)
    save("spell_fire_loop", fire[:RATE * 6] + low(fire[:RATE * 6], 450) * .9, -9, True)
    for name in ["fire_crackle_loop", "night_rain_loop", "river_loop"]:
        save(name, recorded(name), -8, True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    weapons()
    foley()
    spells()
    (OUT / "bank.json").write_text(json.dumps(BANK, indent=2) + "\n")
    lines = ["extends RefCounted", "", "#Generated by tools/build_audio_bank.py", "const FILES := {"]
    for event, files in BANK.items():
        refs = ['preload("res://assets/audio/designed/%s")' % name for name in files]
        lines.append('\t"%s": [%s],' % (event, ", ".join(refs)))
    (OUT / "bank.gd").write_text("\n".join(lines + ["}", ""]))
    print("Built %d events / %d recordings" % (len(BANK), sum(map(len, BANK.values()))))


if __name__ == "__main__":
    main()
