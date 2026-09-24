# Spell and sound pass

Fire rings now have twelve rising emitters with 44 particles each, plus 96
embers. Lightning has seven branched arcs reaching 2.4–4.6 metres above the
caster, with denser upward sparks. Local and remote casters share these effects.
Flame cards use animated noise to break up their silhouette; arrow ground fires
also have more flames, smoke and embers. Damage areas remain unchanged.

[Spell preview](presentation/spells.png) · [In-game sound demo](presentation/sound-demo.ogg)

The demo plays armoured footsteps, three sword contacts ending in a parry, a bow
draw/release/impact, then lightning and fire channels. It was captured from the
Godot master bus. The 11.11-second WAV measured a peak of -10.38 dBFS, RMS of
-32.49 dBFS and zero clipped samples before encoding this review copy as Ogg.
This checks the signal, not subjective loudness on different playback systems.

The new sound bank contains 36 events and 106 recordings. Recorded cloth,
chainmail, footfalls and impacts are layered with the existing effects and
procedural air, rumble and electrical beds. Spell casting now has start, sustain
and release sounds; the previous spell players had no streams. Bow drawing,
landing, coins and dragon casting also have cues. Attribution and processing
details are in [SFX credits](../assets/audio/sfx/CREDITS.md).

Footsteps choose grass, wood or concrete from the contacted floor and follow
movement speed. Set `audio_surface` metadata to `grass`, `wood` or `concrete` on a
collision body when its node name does not describe the material. Arrow impacts
distinguish flesh, wood and hard surfaces. Enemy swing cues occur at the strike,
and player-owned hit/block audio avoids duplicate flesh impacts. Remote players
play movement and sword cues from their replicated motion and animation.

The mixer separates Combat, Magic, Foley and Ambience, with light magic reverb,
combat compression and a master limiter. A 32-voice pool gives critical cues
priority over movement sounds; variations avoid immediate repeats. Environmental
and spell loops have conditioned seams and fades. Authored WAVs retain headroom.

Rebuild and audit the bank with Python, NumPy and FFmpeg installed:

```bash
python3 tools/build_audio_bank.py
python3 tools/check_audio_bank.py
GODOT_MCP_RUNTIME_ENABLED=0 /home/talves/bin/godot --headless --path . --import -- --no-mcp-runtime
```

The generated `bank.gd` preloads every recording so exported builds retain the
audio. Selected source recordings are under `assets/audio/source/`, excluded
from Godot's import scan.

Validation on Godot 4.5.1: all 106 WAVs passed format, peak, DC offset, variation
and seam checks. The rendered presentation test passed 18 checks, including
playable resources, mixer setup, voice priority, audible local/remote casting,
effect height/density and cleanup. The existing archer aim, trajectory and combat
scenarios passed another 103 checks. No script or shader errors appeared in
these runs; existing UI anchor warnings remain.

```bash
GODOT_MCP_RUNTIME_ENABLED=0 /home/talves/bin/godot --path . \
  --scene res://tests/presentation.tscn --resolution 1280x800 -- \
  --singleplayer --no-mcp-runtime --capture-presentation
```

This writes the PNG and WAV to `/tmp/lob-presentation-spells.png` and
`/tmp/lob-audio-demo.wav`. Without `--capture-presentation`, the scene also runs
headless and skips the render/audio capture check. A live multiplayer session,
mobile particle performance and listening tests on speakers/headphones were not
validated in this pass.
