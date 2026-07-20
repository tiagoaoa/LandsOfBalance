#!/usr/bin/env python3
"""Build the game's SFX set from recorded CC0/CC-BY sources.

Replaces the earlier synthetic set with real recorded audio, keeping the
exact slot filenames the Sfx autoload expects. Every output is 16-bit
mono 44.1 kHz WAV (sfx.gd computes loop points as data.size()/2, which
assumes exactly that format).

Sources (see assets/audio/sfx/CREDITS.md):
  - RPG Sound Pack (artisticdude, CC0)         -> swings, growls, foley
  - Sword/clash packs (StarNinjas, CC0)        -> metal impacts
  - Fleshy fight sounds (OGA-BY 3.0)           -> flesh/pierce/thud hits
  - Fireplace loop (CC0), rain+thunder (CC-BY) -> ambience beds
  - Stream sounds (CC-BY 3.0)                  -> river
  - Archers shooting (CC-BY 3.0)               -> bow release

Usage: tools/import_sfx_recorded.py <sources_dir>
  where <sources_dir> holds rpg_pack/, sword_pack/, clash_pack/,
  flesh_pack/, stream_pack/, fire.wav, rain_thunder_loop.wav,
  Archers-shooting.flac (as downloaded/extracted).
"""

import math
import os
import struct
import subprocess
import sys
import tempfile
import wave

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "sfx")
RATE = 44100


def _decode(src: str, filters: str = "") -> list:
    """ffmpeg-decode any source to 16-bit mono 44.1k samples."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
        tmp = tf.name
    cmd = ["ffmpeg", "-y", "-v", "error", "-i", src,
           "-ac", "1", "-ar", str(RATE), "-sample_fmt", "s16"]
    if filters:
        cmd += ["-af", filters]
    cmd.append(tmp)
    subprocess.run(cmd, check=True)
    with wave.open(tmp, "rb") as w:
        raw = w.readframes(w.getnframes())
    os.unlink(tmp)
    return list(struct.unpack("<%dh" % (len(raw) // 2), raw))


def _normalize(samples: list, peak_db: float) -> list:
    peak = max(1, max(abs(s) for s in samples))
    gain = (10 ** (peak_db / 20.0)) * 32767.0 / peak
    return [max(-32768, min(32767, int(s * gain))) for s in samples]


def _trim_silence(samples: list, thresh: int = 160) -> list:
    """Drop leading/trailing silence so one-shots hit instantly."""
    start, end = 0, len(samples)
    while start < end and abs(samples[start]) < thresh:
        start += 1
    while end > start and abs(samples[end - 1]) < thresh:
        end -= 1
    start = max(0, start - RATE // 200)  # keep 5 ms of attack ramp
    return samples[start:end]


def _loop_condition(samples: list, fade_s: float = 0.8) -> list:
    """Equal-power crossfade of the tail into the head -> seamless loop."""
    n = int(RATE * fade_s)
    if len(samples) <= 2 * n:
        return samples
    body = samples[:-n]
    tail = samples[-n:]
    for i in range(n):
        t = i / n
        a = math.cos(t * math.pi / 2.0)
        b = math.sin(t * math.pi / 2.0)
        body[i] = int(tail[i] * a + body[i] * b)
    return body


def _write(name: str, samples: list) -> None:
    path = os.path.join(OUT_DIR, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))
    print("  %-22s %5.2fs" % (name, len(samples) / RATE))


def main() -> None:
    src = sys.argv[1]
    rpg = os.path.join(src, "rpg_pack", "RPG Sound Pack")

    def p(*parts):
        return os.path.join(src, *parts)

    # slot -> (source path, ffmpeg filter, peak dB, is_loop)
    plan = {
        # Paladin sword combo whooshes (real recorded swings, CC0).
        "sword_whoosh_1": (os.path.join(rpg, "battle", "swing.wav"), "", -2.0, False),
        "sword_whoosh_2": (os.path.join(rpg, "battle", "swing2.wav"), "", -2.0, False),
        "sword_whoosh_3": (os.path.join(rpg, "battle", "swing3.wav"), "", -1.0, False),
        # Bobba's heavy arm swing: same swing slowed/deepened.
        "punch_whoosh": (os.path.join(rpg, "battle", "swing3.wav"),
                         "asetrate=%d*0.72,aresample=%d" % (RATE, RATE), -2.0, False),
        # Sword-on-armor / clash impacts (StarNinjas, CC0).
        "hit_metal": (p("clash_pack", "sword_clash.3.ogg"), "", -1.5, False),
        "block_chip": (p("clash_pack", "sword_clash.6.ogg"), "volume=0.75", -4.0, False),
        # Flesh hits and thuds (fleshy fight sounds, OGA-BY).
        "hit_flesh": (p("flesh_pack", "sword-1a.wav"), "", -1.5, False),
        "arrow_impact": (p("flesh_pack", "piercing-1a.wav"), "", -2.0, False),
        "death_thud": (p("flesh_pack", "hammer-1a.wav"),
                       "asetrate=%d*0.9,aresample=%d" % (RATE, RATE), -2.0, False),
        # Bow release (real archery recording).
        "bow_release": (p("Archers-shooting.flac"), "", -2.0, False),
        # Fire ignition: spell whoosh-flare from the RPG pack.
        "fire_ignite": (os.path.join(rpg, "battle", "spell.wav"),
                        "asetrate=%d*0.92,aresample=%d" % (RATE, RATE), -2.5, False),
        # Foley (RPG pack, CC0).
        "estus_drink": (os.path.join(rpg, "inventory", "bottle.wav"), "", -4.0, False),
        "roll": (os.path.join(rpg, "inventory", "cloth-heavy.wav"), "", -6.0, False),
        # Bobba: giant growl, pitched for bulk.
        "bobba_roar": (os.path.join(rpg, "NPC", "giant", "giant1.wav"),
                       "asetrate=%d*0.85,aresample=%d" % (RATE, RATE), -1.5, False),
        # Ambience loops.
        "fire_crackle_loop": (p("fire.wav"), "atrim=2:15", -6.0, True),
        "night_rain_loop": (p("rain_thunder_loop.wav"), "", -6.0, True),
        "river_loop": (p("stream_pack", "stream-waterfall", "stream2.ogg"),
                       "atrim=0:14", -6.0, True),
    }

    print("Importing recorded SFX -> %s" % os.path.normpath(OUT_DIR))
    for slot, (path, filters, peak_db, is_loop) in plan.items():
        samples = _decode(path, filters)
        if is_loop:
            samples = _loop_condition(samples)
        else:
            samples = _trim_silence(samples)
        _write(slot, _normalize(samples, peak_db))

    # parry_ring: clash layered with a long metal ring tail.
    clash = _decode(p("clash_pack", "sword_clash.1.ogg"))
    ring = _decode(os.path.join(rpg, "inventory", "metal-ringing.wav"))
    delay = int(RATE * 0.03)
    mixed = clash + [0] * max(0, delay + len(ring) - len(clash))
    for i, s in enumerate(ring):
        mixed[delay + i] += int(s * 0.55)
    _write("parry_ring", _normalize(_trim_silence(mixed), -1.0))

    print("Done: %d slots" % (len(plan) + 1))


if __name__ == "__main__":
    main()
