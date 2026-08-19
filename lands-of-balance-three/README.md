# Lands of Balance — Three.js port

A browser port of the Godot 4 game in the repository root ("Douglass The
Keeper"). It reimplements the souls-like combat loop, the rainy-night world
and the gothic HUD on Three.js + TypeScript, reusing the original's art and
audio through an offline asset-bake step.

This is a **new, separate port**. The older `../lands-of-balance-web/`
directory is a January multiplayer-client experiment and predates the combat
systems (lock-on, roll, parry/riposte, backstab, estus, combo chains,
skeletons, the night world); nothing here depends on it.

## Running

```bash
npm install
npm run dev            # http://127.0.0.1:5273
npm run build          # typecheck + production bundle into dist/
```

Assets under `public/assets/` are committed pre-baked, so a fresh clone runs
without Blender. To regenerate them from the Godot project:

```bash
npm run bake           # requires Blender 5.x on PATH
```

### Headless check

With `npm run dev` already serving, `npm run check` boots the game in
Playwright's Chromium, picks a class, drives a scripted sequence (walk, lock
on, combo, roll, parry, estus, jump) and reports any console error plus a
state dump. `npm run probe:bow` is a narrower probe that watches the archer's
draw → hold → loose → ground-fire chain.

One caveat when reading those runs: headless Chromium renders through
SwiftShader at a few frames per second, and the fixed-step loop deliberately
clamps how many physics steps one frame may replay. **Game** time therefore
advances slower than wall-clock time, so held-key durations in the scripts are
generous on purpose — a 600 ms hold can be under the 0.3 s a bow draw needs.

## Controls

| Key | Action |
| --- | --- |
| `WASD` | move (camera-relative) |
| `Shift` | run |
| `Ctrl` | crouch — braced stance, −25% damage taken |
| `Space` | jump; with a direction held it becomes a leaping dodge |
| `LMB` / `F` | attack. As the Archer, **hold** to draw and release to loose |
| `RMB` | block — chips damage down, never cancels it |
| `G` | parry — the only thing that cancels a hit outright |
| `X` | dodge roll (i-frames) |
| `H` | estus flask |
| `T` | lock on / off |
| `C` | cast the rite |
| `L` | toggle the Nordic day / rainy night |
| `M` | minimap · `F1` controls card · `R` return to spawn · `Esc` release mouse |

A gamepad works too (left stick moves, right stick looks, A jump, X attack,
LB roll, RB parry, RT block, R3 lock-on, d-pad down estus).

## What was ported

Every gameplay constant lives in [`src/core/tuning.ts`](src/core/tuning.ts),
grouped by the GDScript file it came from, so the two builds can be diffed by
eye. The rules the Godot build cares about are carried across intact:

- **Golden rule — damage only on visible contact.** The sword hitbox is the
  blade capsule hanging off the right-hand bone, and the slash ribbon is drawn
  *exactly* while that capsule can hurt.
- **Blocks chip, parries cancel.** A held shield reduces a clean weapon strike
  to 15% and blunt force to 30%; only a parry inside its 0.05–0.38 s window
  negates a hit and opens the riposte.
- **Roll i-frames** start at 0.06 s and end at 0.40 s of a 0.5 s roll, so
  startup and recovery stay punishable.
- **Combo chain** — three swings, chained only by clicks inside a 0.5 s
  window, cancelling into each other at 60% progress, with a recovery cancel
  that lets you walk out of the finisher's long tail.
- **Jumping is flight, not offense**: the airborne Paladin cannot swing and
  takes half damage.
- **Night perception.** Living AI is blind in the dark: Bobba smells you
  inside 10 m, reads silhouettes inside the moon's 25 m, and sees you from
  90 m if a fire lit you up. Skeletons have dark vision and ignore all of it.
- **Fire is a weapon, not decoration.** Arrows do a flat 1 damage to Bobba but
  leave a 30 s ground fire that burns for 5%/s, reveals characters, panics
  Bobba and sets skeletons alight.
- **Bobba** roams, chases, blocks on a 40%/1.5 s roll, staggers on poise, is
  opened by a parry, and flees below 22% HP while regenerating 3%/s.
- **The skeleton crew** rises as a pack of five, crowds you on individually
  drifting bearings with separation, swerves around fire, and rises again
  20 s after each death.

Source layout mirrors the Godot project: `src/player/`, `src/enemies/`,
`src/combat/`, `src/world/`, `src/fx/`, `src/ui/`.

## Asset pipeline

`scripts/bake_characters.py` is a Blender script that solves the port's
biggest problem: the Godot build ships rigged GLBs with **no** clips and loads
~25 Mixamo animation FBXs per character at runtime, retargeting by bone name.
A browser can't afford that, so the bake does it once, offline:

1. Import the character GLB (bones named `mixamorig_Hips`).
2. Import each animation FBX (bones named `mixamorig:Hips`, and a different
   bone roll from a different importer).
3. Constrain the target bones to the source bones in **world space** and bake
   — roll- and rest-pose-independent, which matching local rotations is not.
4. Strip hips XZ so every clip plays in place (world movement comes from
   velocity, as in Godot).
5. Export one GLB per character with each clip named after its Godot key.

Result: `paladin.glb` (23 clips, 4.0 MB), `archer.glb` (28 clips, 5.8 MB),
`skeleton_axe.glb` (mesh only — the draugr is animated procedurally).

The Block-while-moving clips are composed at load time in the browser
([`src/player/block_stance.ts`](src/player/block_stance.ts)), the same way
`player/block_stance_anim.gd` does it in Godot: locomotion footwork plus the
Block clip's guard pose grafted over arms, shoulders and weapon joints.

The draugr's five clips are generated in code
([`src/enemies/skeleton_anim.ts`](src/enemies/skeleton_anim.ts)), a direct
port of `enemies/skeleton_anim.gd` including its sign conventions.

## Graphics

The renderer is three's node-based `WebGPURenderer`: WebGPU where the browser
has it, an automatic WebGL2 backend where it doesn't, with the same TSL graph
running on both. `?webgl=1` forces the fallback.

| | |
|---|---|
| **Post chain** | scene → GTAO (half-res) → exposure → night grade → threshold bloom → Khronos PBR Neutral tonemap → SMAA |
| **Sky** | TSL dome: Rayleigh-ish gradient, sun/moon disc and halo, two drifting cloud layers, ~2500 hashed point stars, Milky Way band. Doubles as the PMREM environment map, so materials get real sky lighting |
| **Terrain** | fbm-displaced 620 m mesh with a flat pad under the village, a carved river channel, two-scale albedo blending against noise to defeat tiling, and roads painted into the material |
| **Grass** | ~105k instanced tufts of tapered blades, two-frequency wind, per-blade AO and tint variation, and the field **recentres on the player** in chunks so it is never bare where you are standing |
| **Scatter** | ~900 trees across two species, 700 displaced-icosahedron boulders, 1400 bushes; canopy shares the grass wind |
| **Water** | TSL surface with two crossing ripple trains, fresnel rim and depth-faded banks, sitting in the carved channel |
| **Shadows** | Single 2048 map over a tight 60 m box that follows the player (~34 texels/m) |

Roughly 40–50 fps at 1600×900 on a GTX 1650 — a low-end card — so there is
headroom on anything current. Quality is URL-switchable for bisecting or for
weaker hardware: `?post=0`, `?ao=0`, `?bloom=0`, `?aa=0`, `?scale=0.5`,
`?hud=0`, `?labels=0`.

### Things deliberately not done

- **Cascaded shadows.** `CSMShadowNode` is the node renderer's CSM, and it is
  the right answer — but it is documented WebGPU-only and throws during graph
  construction on the WebGL2 backend, which is the path every browser without
  WebGPU takes. A shipped crash beats a softer distant shadow, so the single
  map was tightened instead.
- **Volumetric light shafts.** Moonbeams and firelight shafts are the one
  planned item still outstanding. WebGL2 has no compute, so it would be a
  fragment raymarch; the night currently gets its mood from the scotopic
  grade and fog instead.
- **Scatter is not solid.** `MeshBVH` builds from a geometry plus one world
  matrix, so an `InstancedMesh` would register a single collider at the
  origin — a phantom tree in an empty field. Trees and rocks are therefore
  walk-through.

## Differences from the Godot build

These are deliberate, and worth knowing before comparing the two:

- **No multiplayer.** The UDP protocol, the C server, remote players and the
  co-op AI companion are not ported; this is the singleplayer loop.
- **No UNARMED mode.** The bake ships the Paladin's *armed* clip set only, so
  the Tab sheathe/draw toggle is gone rather than leaving the player in a
  state with no attack. (`Tab` is still listed in the Godot InputMap.)
- **Physics is a custom kinematic controller** on `three-mesh-bvh`
  ([`src/core/physics.ts`](src/core/physics.ts)) rather than Godot's
  `move_and_slide`. Slope and wall behaviour is equivalent, not identical.
- **The Paladin's lightning rite** is a heal with the correct gating rules
  (no casting in combat, broken by a hit) but not the full particle/bolt VFX
  stack from `player.gd`.
- **The dragon, the castle builder and the village decorator** are not ported.
  The castle is already skipped in the Godot build (its Quaternius assets are
  absent from the repo).
- Godot's `SimpleGrassTextured` is replaced by the instanced, wind-animated,
  player-following field described above.
- **The world is no longer a flat slab.** The Godot scene's 1070 m ground box,
  road slabs and river boxes are replaced by displaced terrain with a carved
  river and painted roads, so the landmark coordinates still line up but the
  ground beneath them does not match the original exactly.

## Credits

Art, audio and design are the parent project's — see the repository root
`README.md`, `assets/skeleton/CREDITS.md` and `assets/audio/sfx/CREDITS.md`.
