# Soulslike pass

The subsequent [spell and sound pass](presentation_pass.md) increases effect
height/density and replaces the sound bank and playback mix.

This pass changes the paladin and archer presentation, sword timing, defensive
combat, terrain shading, lighting and casting effects. It extends the existing
models and animation library. It does not replace the base characters with new
sculpts or motion capture.

- Paladin: fitted breastplate, layered shoulder plates, brass detail and a skinned
  mantle. Archer: skinned mantle and corrected cloth roughness/metal response.
  Both local and remote players load the new GLBs.
- Sword attacks: three trimmed clips, with damage confined to the blade sweep.
  Windup and contact commit the player; recovery permits a paid dodge or one
  recently buffered follow-up. Facing stays committed during the swing.
  Footstep animation rates follow movement speed.
- Defense: front-facing guard spends stamina, rear attacks bypass it, and a guard
  break empties stamina and leaves a 1.1 second punish window. Roll invulnerability
  lasts from 0.09 to 0.34 seconds; parry contact lasts from 0.05 to 0.22 seconds.
  Sprinting spends stamina, and committed actions pause regeneration.
- Targeting and impact: lock-on includes skeletons and dragons and rejects walls.
  Authored poise damage reaches Bobba, so finishers stagger more effectively.
  Removed impact scaling that distorted bodies and generated Jolt warnings.
- Ground: world-space soil detail at two scales, broad soil/moss variation and
  localized wet patches. Grass blades are narrower. Lighting uses lower daylight
  fill, readable night fill and less bloom. Day/night brightness now interpolates.
- Casting: thin animated sigils, tapered flames and short lightning arcs. The
  paladin aura preserves the character materials. The same sigils and fire shader
  are used by remote players.

The Blender sources are in `assets/characters/source/`. Rebuild the three models
from the repository root with:

```bash
blender -b --factory-startup -P tools/build_souls_characters.py
timeout 60 /home/talves/bin/godot --headless --path . --import -- --no-mcp-runtime
```

Validation on Godot 4.5.1:

- 33 focused checks pass: guard direction/cost, guard breaks, damage windows,
  input expiry, recovery cancellation, dodge vulnerability, stamina, actual
  movement speeds, lock occlusion, remote finisher timing, poise and lighting.
- Automated paladin/Bobba duel: paladin wins in 32.7 seconds, with six parries,
  six ripostes and 30 HP remaining. No physics errors in that run.
- Rendered both characters, casting, and the actual world in day/night modes.
  UI anchor warnings remain in the test scenes; no script or rendering errors.

```bash
GODOT_MCP_RUNTIME_ENABLED=0 /home/talves/bin/godot --headless --path . \
  --scene res://tests/souls_combat.tscn -- \
  --singleplayer --character-class=paladin --no-mcp-runtime
bash tools/run_combat_scenario.sh SOULS 45
/home/talves/bin/godot --path . --scene res://tests/souls_showcase.tscn \
  -- --singleplayer --no-mcp-runtime
```

The showcase writes PNGs to `/tmp/lob-souls-*.png` and exits. Review captures:
[characters](souls_pass/characters.png), [casting](souls_pass/spells.png),
[mantles](souls_pass/mantles.png), [day](souls_pass/world-day.png),
[night](souls_pass/world-night.png).

Further art work is still needed for faces, cloth deformation, bespoke attack
poses, terrain composition and foliage. Both characters now have [simulated fabric capes](archer_cape.md), and the [river has a continuous physical channel](river.md). Fire remains stylized. Remote rigs and clip rates were checked
locally; a full multiplayer session, server combat balance and mobile performance
were not validated in this pass.

Archer aimed shots now use hold/release on either LT or right mouse: hold to
zoom and draw, release after the draw completes to shoot. Early release cancels.
RB retains the automatic quick shot. The held arrow reuses the projectile mesh,
and the split bowstring follows the drawing hand. Run `tests/archer_aim.tscn`
with `--singleplayer --character-class=archer --no-mcp-runtime` to check trigger
motion, release, early cancellation, quick shots and mouse input. Add
`--capture-aim` on a graphical run to save `/tmp/lob-archer-draw.png`.

Player arrows now leave the held arrow position pointing toward the crosshair's
world target. There is no automatic upward correction; gravity still bends the
flight, so distant shots require aiming higher. The AI retains its ballistic
solution. `tests/archer_trajectory.tscn` checks near, distant, elevated and sky
shots, including initial mesh orientation and the release position.

The aiming pose now bends the waist and chest toward the sight, carrying the
arms, bow and nocked arrow together while leaving the feet planted. A separate
0.8-second recovery starts at the held pose and eases into idle. The camera and
crosshair remain in aim view for 0.45 seconds after release, then the camera
eases back over 0.8 seconds.

Sighted shots launch at 75 m/s (50% above the quick shot's 50 m/s). Gravity acts
on the vertical component and horizontal velocity stays constant. Direct-hit
damage scales with incoming speed: 52.5 HP at 75 m/s, versus 35 HP at 50 m/s,
before defensive modifiers. Climbing exchanges vertical speed for height;
falling restores it. Moving shots still halve launch speed. Network spawn
vectors carry that multiplier in their magnitude, and hit messages carry the
same damage used locally. Peers need the updated client to reproduce the speed.

Archer validation covers sight alignment at three pitches, planted feet, hand
continuity during recovery, camera hold/return, held input, early cancellation,
velocity components, impact damage, thin-target collisions and network packet
round trips. Render captures include [upward aim](souls_pass/archer-aim-up.png),
[downward aim](souls_pass/archer-aim-down.png) and
[recovered arms](souls_pass/archer-recovery.png). These are local checks; a live
multiplayer session was not run for this change.
