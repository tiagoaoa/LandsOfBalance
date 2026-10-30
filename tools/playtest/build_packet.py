#!/usr/bin/env python3
"""Build a blind playtest packet from recorded boss-arena matches.

    python3 tools/playtest/build_packet.py --matches rec/matches.ndjson \
        --shots rec/shots --out /tmp/pt_packet [--rounds 1 2 3] [--build X]

The packet holds only what a player could perceive: a manual-style README,
per-run timelines in plain language, per-run stats, and contact sheets of
frames with timestamps burned in. No design notes, no tuning, no internal
names, and the two players are just "Player 1" and "Player 2" — the tester
must not know they are bots or that anyone made a decision on purpose.
"""
import argparse
import math
import json
import random
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

README = """PLAYTEST PACKET — "{title}"

Genre: third-person co-op action (souls-like). Two players fight one boss.

THE ARENA
{arena_desc}
Anyone who falls off the platform ends the attempt for BOTH players and the
fight restarts from the beginning. If both players are down, the fight
restarts too.

THE BOSS
{boss_desc} Its health bar is shown at the bottom of the screen. Every so often
it sinks chest-deep and wades through the mist to another side of the
platform. When one of its fists is resting on the platform, a player beside
it can press jump to scramble up the arm onto its shoulder, where its head is
within reach; it tries to shake riders off (a shudder first — crouching holds
on). Dropping onto one of its fists from height (a perch, a tower, a high
jump, its shoulder) with the weapon out is a heavy "plunging" blow.

THE PLAYERS
Player 1 and Player 2 each pick a class:
  KNIGHT (the game calls this class "Paladin") — sword and shield. Light/heavy sword combos, block (raises shield,
           still takes some damage), timed parry (deflects a blow completely),
           dodge-roll (brief invulnerability), jump, crouch. Spell: a
           lightning rite that heals allies standing in it (slow to cast, can't
           start it with an enemy close by). 150 HP.
           Second spell: {pal_spell}
  ARCHER — bow. Hold to draw, release to fire (the arrow arcs with gravity;
           a fully drawn, standing shot flies farthest). Dodge-roll, jump,
           crouch. Spell: a ring of fire. 100 HP.
           Second spell: {arc_spell}
Both carry healing flasks. A downed player can be revived by the other
holding a button beside them for a few seconds. A seized player can
struggle (mash attack/jump) to make the grip last longer, but only the
partner can break it.

WHAT A PLAYER SEES BEFORE EACH BOSS ATTACK (on-screen warnings)
  Fist slam   — a red ring appears on the ground and fills in; the fist lands
                ~1.4 s after the ring appears. The fist then stays on the
                platform for a few seconds, its knuckles glowing. Later in the
                fight the other fist may follow straight away at the other
                player: a second ring, landing ~1.2 s after it appears.
  Arm sweep   — a band lights up across the platform ~1.45 s before the arm
                sweeps across it (the sweep takes ~0.8 s). A RED band on the
                floor is a low sweep; later in the fight an AMBER band at
                chest height is a high one. Afterwards the arm rests on the
                rim for a moment.
  Grab        — a purple ring follows one player for ~0.7 s, then stops; the
                hand closes ~1.35 s after the ring first appeared.
  Eye beam    — the eye brightens for ~2.2 s and a faint aiming line shows,
                then a beam rakes across the platform for ~1.5 s.
  Roar        — the boss rears back for ~1.2 s, then a shockwave.
  Head slam   — its jaw is locked in an iron muzzle. A red ring appears and
                fills in while it rears its helmeted skull back; ~1.65 s
                after the ring appears the skull crashes down onto it, then
                lies on the stone for ~2.6 s before it lifts again.
  Braziers    — fires around the rim are most of the light. Its blows near
                one, a claw dragged through one, or a roar put them out;
                an arrow into a dark bowl lights it again.
  Tail lash   — (big platform) an ORANGE band lights the FAR part of the
                platform ~1.5 s before the tail rakes across it.

FILES
  runs/run_N/timeline.txt  — what happened, second by second, as seen on screen
  runs/run_N/stats.txt     — outcome and totals for the attempt
  runs/run_N/sheet.jpg     — 12 frames across the attempt, timestamps burned in
{extra}
These are consecutive attempts by the same two players on one evening.
"""

PHRASE = {
    "slam": "the colossus raises a fist over the {target} (red ring)",
    "slam_hit": "  the fist lands on the {victim}",
    "slam_miss": "  the fist lands on empty stone",
    "parry": "  the {by} deflects the falling fist with a shield parry",
    "sweep": "the colossus draws an arm back for a LOW sweep (red band on the platform)",
    "sweep_high": "the colossus draws an arm back for a HIGH sweep (amber band at chest height)",
    "roar_cover": "  the {who} is shielded from the shockwave by a pillar",
    "shift": "the colossus sinks chest-deep and wades through the mist to another side of the platform",
    "climb": "  the {who} leaps onto the pinned fist and scrambles up the arm",
    "mounted": "  the {who} reaches the colossus's shoulder",
    "shake": "the colossus shudders, trying to shake off its rider",
    "clung": "  the {who} crouches and clings on",
    "flung": "  the {who} is flung back down onto the platform",
    "dismount": "  the {who} leaps down from the shoulder",
    "struggle": "  the seized {who} struggles in the claw",
    "head_slam": "the boss rears its muzzled skull back over the {target} (red ring)",
    "head_hit": "  the skull crashes down on the {victim}",
    "head_miss": "  the skull crashes onto empty stone and lies there",
    "brazier_out": "  a brazier goes out ({by})",
    "brazier_lit": "  an arrow lights a dark brazier again",
    "tail": "the boss's tail rises out of the abyss to rake the far side of the platform (orange band)",
    "plunge": "  the {by} drops onto a fist from above with a plunging blow",
    "ignite": "  the hide catches fire where the {by}'s arrow struck",
    "marks": "glowing runes appear on the boss's joints",
    "spell": "  the {who} casts {how}",
    "rider_down": "  the {who} slumps and slides down off the shoulder",
    "dropped": "  the colossus lets the limp {victim} fall back onto the platform",
    "sweep_hit": "  the sweep hits the {victim}",
    "tail_hit": "  the tail hits the {victim}",
    "sweep_cleared": "  the {who} avoids the sweep ({how})",
    "covered": "  the {who} is shielded from the sweep by the {by}'s raised shield",
    "grab": "the colossus reaches for the {target} (purple ring)",
    "grabbed": "  the {victim} is seized and lifted over the abyss; its chest opens",
    "grab_missed": "  the hand closes on nothing",
    "rescued": "  the {victim} breaks free and drops back onto the platform",
    "thrown": "  the {victim} is hurled into the abyss",
    "gaze": "the colossus's eye begins to brighten, fixed on the {target}",
    "eye_interrupt": "  the {by}'s arrows hit the eye — the colossus recoils, chest open",
    "beam_hit": "  the beam burns the {victim}",
    "beam_cover": "  the {who} is behind a pillar as the beam passes",
    "roar": "the colossus rears back and roars",
    "roar_hit": "  the shockwave knocks back the {victim}",
    "roar_braced": "  the {who} crouches and rides out the shockwave",
    "poise_break": "the colossus buckles (struck by the {by})",
    "stagger": "the colossus staggers back, fists braced on the rim, chest-core glowing open",
    "phase2": "the colossus's chains break — it sinks into the mist",
    "party_down": "  the {who} goes down",
    "party_revived": "  the {who} is back on their feet",
    "party_heal": "  the {who} recovers health",
    "flask": "  the {who} drinks a healing flask",
    "downed": "",
    "died": "the colossus collapses and falls into the abyss",
}


BOSS = {
    "dragon": "A huge black dragon in the style of Game of Thrones — a wyvern whose wings are its arms, horned, armoured in scales — clinging to the edge of the platform with its wing-claws while its hind legs grip the cliff below. It strikes across the edge with its wing-claws, its tail and its fire. Fire glows through the scales of its chest and throat.",
    "colossus": "A giant stone-and-bronze colossus standing in the abyss beside the platform, attacking across the edge with its fists. It has a glowing chest-core and a single eye.",
    "lizard": "A giant lizard-king — a scaled, crested saurian warrior with a long armoured snout, a toothed jaw, a heavy tail and clawed hands — standing chest-deep in the abyss beside the platform, attacking across the edge with its claws and its tail. It has a glowing heart-gem in its chest and a glowing third eye on its brow.",
}
SPELLS = {
    "none": "none.",
    "leap": "SKYWARD LEAP — for 7 s the knight jumps more than twice as high (reach ledges, its arms, plunge onto it). 16 s cooldown.",
    "incendiary": "INCENDIARY ARROWS — the next 6 arrows set the boss's hide alight where they hit (damage over time, more on weak spots). 18 s cooldown.",
    "decoy": "SPIRIT HOUNDS — two glowing hounds dart about the platform for 10 s; the boss attacks them as if they were players. 22 s cooldown.",
    "mark": "HUNTER'S MARK — three glowing runes appear on the boss's joints for 9 s; an arrow (or blade) on one is a critical hit that also helps stagger it. 18 s cooldown.",
}


BOSS_WORD = "colossus"
# What the warnings look like on the dragon (same timings, its own body).
DRAGON_WORDS = [
    ("When one of its fists is resting", "When one of its wing-claws is resting"),
    ("scramble up the arm onto its shoulder, where its head is\nwithin reach", "scramble up the wing onto its shoulders, where the base of\nits skull is within reach"),
    ("onto one of its fists from height", "onto one of its wing-claws from height"),
    ("  Fist slam   — a red ring appears on the ground and fills in; the fist lands", "  Claw slam   — a red ring appears on the ground and fills in; the claw lands"),
    ("The fist then stays on the\n                platform for a few seconds, its knuckles glowing.", "The claw then stays on the\n                platform for a few seconds, its wrist glowing."),
    ("Later in the\n                fight the other fist may follow", "Later in the\n                fight the other claw may follow"),
    ("  Arm sweep   — a band", "  Wing sweep  — a band"),
    ("the arm\n                sweeps across it", "the wing-arm\n                sweeps across it"),
    ("Afterwards the arm rests", "Afterwards the claw rests"),
    ("the hand closes ~1.35 s", "the claw closes ~1.35 s"),
    ("  Eye beam    — the eye brightens for ~2.2 s and a faint aiming line shows,\n                then a beam rakes across the platform for ~1.5 s.",
     "  Fire breath — its throat glows brighter for ~2.2 s and a faint aiming line\n                shows, then a stream of fire rakes across the platform for\n                ~1.5 s."),
]


def arena_desc(area):
    r = 6.0 * area ** 0.5
    base = (f"A round stone platform about {2*r:.0f} m across (~{3.1416*r*r:.0f} m²), floating over a\n"
            "bottomless misty abyss at night in the rain.")
    if area <= 1.0:
        return base + (" Two rock pillars at the platform's edge can be climbed by\n"
                       "ramps (about 3.6 m high). A low stump stands at the far side.")
    return base + ("\nTwo low rock perches (3.6 m) and two tall towers (level with the boss's\n"
                   "chest) stand near the edge, each reached by a ramp; ruined pillars and\n"
                   "low stumps are scattered over the open stone.")


def who(x):
    # Decoys and other spawned bodies carry engine names (@CharacterBody3D@839).
    if isinstance(x, str) and x.startswith("@"):
        return "spirit hound"
    return {"paladin": "Knight", "archer": "Archer"}.get(x, x)


def fmt_t(t):
    return f"{int(t)//60:02d}:{t%60:04.1f}"


def timeline_text(m):
    out = []
    hits = []   # aggregate weak-point hits into bursts

    def flush():
        if not hits:
            return
        parts = {}
        for h in hits:
            k = (who(h.get("by", "?")), h.get("part"))
            parts[k] = parts.get(k, 0) + 1
        names = {"hand": "glowing fist", "mark": "rune mark", "core": "heart-gem/core",
                 "plunge": "fist (plunging blow)", "head": "head", "eye": "third eye"}
        desc = ", ".join(f"{b} lands {n} hit{'s' if n > 1 else ''} on the {names.get(p, p)}"
                         for (b, p), n in parts.items())
        out.append(f"{fmt_t(hits[0]['t'])}  {desc}")
        hits.clear()

    for e in m.get("timeline", []):
        if e["e"] == "hit":
            if hits and e["t"] - hits[-1]["t"] > 2.5:
                flush()
            hits.append(e)
            continue
        flush()
        tmpl = PHRASE.get(e["e"])
        if not tmpl:
            continue
        fields = {k: who(v) for k, v in e.items() if isinstance(v, str)}
        fields.setdefault("how", "")
        if e["e"] == "sweep_cleared":
            fields["how"] = {"high": "standing high / airborne", "evaded": "dodge",
                             "ducked": "crouched under it"}.get(e.get("how"), "")
        try:
            line = tmpl.format(**fields)
        except KeyError:
            line = tmpl
        if e["e"] in ("slam_hit", "sweep_hit") and e.get("blocked"):
            line += " (on a raised shield — reduced damage)"
        if e["e"] == "beam_hit":
            line = line.replace("burns", "burns and briefly staggers")
        bars = f"   [boss {int(e.get('boss', 0)*100)}%  Knight {int(e.get('paladin', 0)*100)}%  Archer {int(e.get('archer', 0)*100)}%]"
        out.append(f"{fmt_t(e['t'])}  {line}{bars}")
    flush()
    end = {"WIN": "THE COLOSSUS IS DEFEATED", "FALL": f"THE {who(m.get('who','')).upper()} FALLS INTO THE ABYSS — attempt over",
           "WIPE": "BOTH PLAYERS ARE DOWN — attempt over", "TIMEOUT": "time limit reached"}[m["outcome"]]
    out.append(f"{fmt_t(m['duration'])}  {end}")
    text = "\n".join(out) + "\n"
    if BOSS_WORD == "dragon":
        for x, y in DRAGON_TIMELINE:
            text = text.replace(x, y)
    if BOSS_WORD != "colossus":
        text = text.replace("colossus", BOSS_WORD).replace("COLOSSUS", BOSS_WORD.upper())
    return text


DRAGON_TIMELINE = [
    ("raises a fist", "raises a wing-claw"), ("the fist lands", "the claw lands"),
    ("the falling fist", "the falling claw"), ("draws an arm back", "draws a wing back"),
    ("onto the pinned fist and scrambles up the arm", "onto the pinned claw and scrambles up the wing"),
    ("onto a fist from above", "onto a claw from above"), ("glowing fist", "glowing wrist"),
    ("fist (plunging blow)", "claw (plunging blow)"), ("heart-gem/core", "glowing chest"),
    ("third eye", "open mouth"),
    ("'s eye begins to brighten, fixed on the", "'s throat begins to glow, its head fixed on the"),
    ("arrows hit the eye", "arrows hit its open mouth"),
    ("the beam burns", "the fire burns"), ("as the beam passes", "as the fire passes"),
    ("fists braced on the rim, chest-core glowing open", "claws braced on the rim, chest glowing open"),
    ("the hand closes on nothing", "the claw closes on nothing"),
    ("'s chains break — it sinks into the mist", "'s chains break — it drops into the mist"),
]


def stats_text(m):
    ev = m["events"]
    lines = [
        f"outcome: {m['outcome']}",
        f"duration: {fmt_t(m['duration'])}",
        f"boss health left: {math.ceil(m['boss_hp_frac']*100)}%",
        f"Knight health at end: {int(m.get('hp_paladin', 0)*100)}%   Archer: {int(m.get('hp_archer', 0)*100)}%",
        f"boss attacks: slams {ev.get('slam',0)}, sweeps {ev.get('sweep',0)}, grabs {ev.get('grab',0)}, "
        f"{'fire breaths' if BOSS_WORD == 'dragon' else 'eye beams'} {ev.get('gaze',0)}, roars {ev.get('roar',0)}",
        f"slams that hit someone: {ev.get('slam_hit',0)}   parried: {ev.get('parry',0)}",
        f"sweeps that hit someone: {ev.get('sweep_hit',0)}   avoided: {ev.get('sweep_cleared',0)}   shielded: {ev.get('covered',0)}",
        f"players seized: {ev.get('grabbed',0)}   freed: {ev.get('rescued',0)}   thrown: {ev.get('thrown',0)}",
        f"times the boss staggered: {ev.get('stagger',0)}",
        f"players downed: {ev.get('party_down',0)}   revived: {ev.get('party_revived',0)}",
    ]
    dealt = m.get("dealt", {})
    tot = sum(dealt.values()) or 1
    lines.append("share of boss damage: " + ", ".join(f"{who(k)} {100*v/tot:.0f}%" for k, v in dealt.items()))
    return "\n".join(lines) + "\n"


def sheet(frames, out):
    if not frames:
        return False
    pick = [frames[round(i * (len(frames) - 1) / 11)] for i in range(12)] if len(frames) >= 12 else frames
    w, h = 480, 300
    canvas = Image.new("RGB", (w * 4, h * 3), "black")
    font = ImageFont.load_default()
    for i, (t, f) in enumerate(pick):
        im = Image.open(f).convert("RGB").resize((w, h))
        d = ImageDraw.Draw(im)
        d.rectangle([0, 0, 92, 18], fill="black")
        d.text((4, 3), f"F{i+1:02d} {fmt_t(t)}", fill="white", font=font)
        canvas.paste(im, ((i % 4) * w, (i // 4) * h))
    canvas.save(out, quality=82)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--matches", nargs="+", required=True)
    ap.add_argument("--shots", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rounds", nargs="*", type=int)
    ap.add_argument("--title", default="The Chained Colossus")
    ap.add_argument("--build", default="")
    ap.add_argument("--boss", default="dragon", choices=list(BOSS))
    ap.add_argument("--area", type=float, default=1.0, help="platform area factor (1 = ~113 m2)")
    ap.add_argument("--pal-spell", default="leap", choices=list(SPELLS))
    ap.add_argument("--arc-spell", default="mark", choices=list(SPELLS))
    ap.add_argument("--solo", nargs="*", default=[],
                    help="match files from single-player attempts (timeline+stats only)")
    ap.add_argument("--solo-count", type=int, default=2)
    a = ap.parse_args()
    global BOSS_WORD
    BOSS_WORD = {"lizard": "lizard-king", "dragon": "dragon"}.get(a.boss, "colossus")
    ms = []
    for f in a.matches:
        ms += [json.loads(l) for l in Path(f).read_text().splitlines() if l.strip()]
    if a.rounds:
        ms = [m for m in ms if m["round"] in a.rounds]
    out = Path(a.out)
    if out.exists():
        shutil.rmtree(out)
    (out / "runs").mkdir(parents=True)
    shots = Path(a.shots)
    for n, m in enumerate(ms, 1):
        rd = out / "runs" / f"run_{n}"
        rd.mkdir()
        (rd / "timeline.txt").write_text(timeline_text(m))
        (rd / "stats.txt").write_text(stats_text(m))
        frames = []
        for f in sorted(shots.glob(f"a{m['round']:02d}_t*.jpg")):
            t = float(f.stem.split("_t")[1].split("_")[0])
            frames.append((t, f))
        frames.sort()
        sheet(frames, rd / "sheet.jpg")
        # A handful of full-size frames for the visual critic.
        if frames:
            fd = rd / "frames"
            fd.mkdir()
            for k in range(6):
                t, f = frames[round(k * (len(frames) - 1) / 5)]
                shutil.copy(f, fd / f"f{k+1}_{fmt_t(t).replace(':', 'm')}.jpg")
    solo_n = 0
    for f in a.solo:
        sm = [json.loads(l) for l in Path(f).read_text().splitlines() if l.strip()][:a.solo_count]
        for m in sm:
            solo_n += 1
            rd = out / "solo" / f"solo_{solo_n}"
            rd.mkdir(parents=True)
            cls = "Knight" if "paladin" in m.get("ai_mode", "") else "Archer"
            (rd / "who.txt").write_text(f"A single player, playing the {cls} alone (no partner on the platform).\n")
            (rd / "timeline.txt").write_text(timeline_text(m))
            (rd / "stats.txt").write_text(stats_text(m))
    extra = ""
    if solo_n:
        extra += ("\n  solo/solo_N/         — attempts by ONE player alone (no partner), timeline\n"
                  "                         and stats only, for comparison\n")
    if a.build:
        extra += f"\nThis packet is BUILD {a.build}.\n"
    readme = README
    if a.boss == "dragon":
        for x, y in DRAGON_WORDS:
            readme = readme.replace(x, y)
    (out / "README.txt").write_text(readme.format(title=a.title, extra=extra,
        arena_desc=arena_desc(a.area), boss_desc=BOSS[a.boss],
        pal_spell=SPELLS[a.pal_spell], arc_spell=SPELLS[a.arc_spell]))
    print(f"packet: {out} ({len(ms)} runs)")


if __name__ == "__main__":
    random.seed(1)
    main()
