# Ssethrak, the Chained Lizard-King

The next model is based on the user-supplied *Photorealistic Helmeted Lizard
Turnaround Sheet.png*. Preparation is complete in
`tools/art/source/helmeted_lizard_reference.blend`: packed views and an unbound
21-bone anatomical template. This is a modelling workspace, not a replacement
mesh. The playable asset described below is still current.

`tools/art/prepare_turnaround.py` produces exact panel crops and rebuilds that
workspace. Generation now targets the downloadable Hunyuan3D-2 multiview model
on our own GPU worker. The user prefers paying for compute directly; the earlier
Meshy request is not the active route. No model-service job or GPU rental has
been purchased. The local machine has an integrated Radeon 840M, so the worker
targets a rented NVIDIA GPU with at least 24 GB VRAM.

`tools/art/cloud/pack_job.py` packages only the four views and worker code into
`build/art-models/boss-job.tar.gz`. The worker uses pinned source/model revisions,
50 shape steps, a 512 extraction grid, a retained raw mesh, a 150K-face mesh and
4K diffuse texturing. Normal/roughness/metallic authoring remains Blender work;
this Hunyuan3D paint pipeline does not produce a complete PBR material set.
See [the worker instructions](../tools/art/cloud/README.md).

Validation so far: the four-view preflight passes, dependency versions resolve,
the shell/Python scripts parse, and four local lifecycle tests pass. GPU setup,
inference quality and the returned mesh remain untested until provider access
is configured. The current rental estimate is recorded in
`build/art-models/boss-rental-plan.json`; offers must be refreshed before renting.

After a source mesh is available, inspect its topology in Blender, separate and
hinge the lower jaw, construct the mouth interior, attach the helmet to the head,
and refit/skin the combat bones. The reference's compact skull and upright torso
require new mouth/head offsets and arm contact calibration; retain the existing
terrain envelopes and rerun the animation/collision reviews before switching
the runtime model. The current template has no skin weights or animations.

The full boss source is `assets/characters/reptilian/reptilian_rex.glb`: the supplied reptilian body with a new T-rex skull, articulated mandible, recessed eyes, teeth, and a blackened iron helmet covering approximately 70% of the face. The eyes, nostrils and moving jaw remain open. Crown seams, cheek plates, nicked edges and uneven rivets follow the head bone. The helmet has modeled dents and blade cuts, broken rivet stubs, and 1K albedo, normal, roughness and metallic maps with uneven oxidation. Teeth have individual curvature, spacing, broken tips and stained enamel vertex colors. The original supplied mesh and previous derived asset are retained. C-List's body is CC-BY-4.0; source and attribution are recorded in [the asset notice](../assets/characters/reptilian/NOTICE.md).

The boss now spawns at 60% of its previous size. Its collision, rig and attached effects use the same scale; arena geometry keeps its existing dimensions.

The full derived asset has 201,333 triangles, nine meshes and 21 bones. The arena loads `reptilian_arena.glb`, a 175,169-triangle variant with the submerged lower body removed and capped; the original full model is retained. A combat skeleton drives the spine, neck, jaw, arms and tail. Fine dark scale albedo, normal and roughness maps cover the hide; the iron keeps its own metallic and roughness settings. Head tracking compensates for the hunched torso instead of folding the muzzle into the floor. Arm IK uses the imported limb lengths; the skinned wrists follow the same pivots as the hitboxes. The mouth emitter follows the longer muzzle, and the head hit hull is rebuilt from its skin samples. See [arena performance work](arena_performance.md) for the backdrop, physics, threading and renderer changes.

Build the head and helmet with `blender --factory-startup -b -noaudio -t 6 --python tools/art/trex_helmet.py`, then import resources in Godot. Editable source is `tools/art/source/reptilian_rex.blend`; `tools/art/review_rex.py` renders closed/open jaw studies to `docs/presentation/rex-helmet`. Skull silhouette reference: the [Tyrannosaurus skull atlas](https://iupress.org/tyrannosaurus-rex-the-tyrant-king-chapter-13-multimedia-files/). The new geometry is authored here; reference images are not bundled as assets.

The iron maps now have broader dark brown oxide patches, ochre flakes and deeper pitting. Oxidized areas are rougher and less metallic; the same texture covers the trim and rivets. The procedural noise wraps at the texture edges.

`enemies/colossus/terrain_guard.gd` checks the animated body against the arena's actual floor, columns and ramps. Collision envelopes include the helmet and teeth, and refit blended skin at the joints. Rigid limb cores use translation casts and short rotation steps to catch fast sweeps. Players and the boss's riding ledges are excluded from these world queries. The posture lifts the muzzle and keeps the torso outside the rim; claws account for their real thickness as they land. Obstructed arms stop and recover upward. A hit or grab still needs visible claw contact and a clear line to the player.

Repositioning withdraws from the ledge before descending, circles outside the platform, then rises before approaching again. Death follows the same outward withdrawal. The terrain review samples the visible skin independently against the arena solids, including attacks from four anchor angles: `LOB_ARENA_AREA=6 GODOT_MCP_RUNTIME_ENABLED=0 /home/talves/bin/godot --headless --path . --scene res://tests/boss_arena/terrain_review.tscn -- --singleplayer --spectate --no-mcp-runtime`. The separate `animation_review.tscn` checks weapon contacts, interruption, recovery and rescue behavior.

Rust/collision verification: 96 animation and combat assertions passed. Terrain runs passed 3,068 sampled poses across the 1x arena at 60 Hz and the 6x arena at 30/60 Hz, covering slams, both sweeps, grabs, stagger, shifts, relocation and death. Query shapes bake the boss scale into their vertices; scaled query transforms missed some ramp contacts in the compact arena. Logs and rendered bot-camera captures are under [docs/presentation/rex-helmet](presentation/rex-helmet). The existing shutdown resource warning remains in the animation test.

**Current body: the lizard titan** (2026-10-24). It was generated with Hunyuan3D-2mv (open weights) on a rented vast.ai RTX 4090 from `Ancient lizard titan turnaround sheet.png`. `LOB_BOSS_BODY=rex` brings back the previous T-rex-skulled body. The pipeline:

1. `tools/art/prepare_titan_views.py` cuts the sheet into views in `tools/art/reference/lizard_titan/`, removing the labels and mirroring the side view to make a right view.
2. `tools/art/cloud/` runs on the GPU worker:
   - `run_job.sh` runs Hunyuan.
   - `run_trellis.sh` runs TRELLIS.2, which still needs a Hugging Face login that has accepted the gated DINOv3 licence.
   - `conda_cuda124.sh` gives each model a CUDA 12.4 / PyTorch 2.6 env on images that ship CUDA 13.
   Results land in `tools/art/source/lizard_titan/vast_la/`.
3. `blender -b --python tools/art/build_titan.py` fits the mesh to the 21-bone combat skeleton:
   - It scales the mesh so the head stays in the rex's range and moves every bone onto the new anatomy.
   - It skins a voxel-remeshed proxy, because bone heat fails on the UV-split mesh, and transfers the weights.
   - It decides arm against hip weights by distance to the bones, so the hanging claws don't pull the thigh plates.
4. `tools/art/titan_helmet.py` forges the helmet from the head's own crown and snout:
   - The plates are smoothed, snapped back onto the hide and thickened, with the eyes left open.
   - Two muzzle hoops are fitted to the shut snout's cross-section, with a chin bar, a lock and ember eyes.
5. `tools/art/titan_export.py` writes `assets/characters/reptilian/titan_full.glb` and `titan_arena.glb`:
   - It bakes in a 32° hunch about the hips and lifts the body 3 m.
   - Upright, the titan's belly ground into the platform and the terrain guard pushed it 6 m back; at 25° its shoulders were too high to grab.
   - Measured in the 6x arena: anchor 20.5 m from the centre, shoulders 17.4 m (the rex's figures were 19.9 and 17.4).

`ReptilianRig.BODIES` holds each body's head-local points (muzzle lock, skull underside, nostrils, mouth), its closed-jaw angle and its hull options. The titan's head hull uses head and jaw samples within 3.4 units of the skull centre; its claw hulls use the 70% of samples nearest the wrist. During a head slam the terrain guard raises the skull rather than rotating it, because rotating it swung the lock metres off the ring.

Titan validation (6x): attack review 21/22 and animation review 100/102.
- **Mounted players overlap:** the shoulder seats still need fitting to its wider shoulders.
- **Left claw hull:** 17–20% outside the hide against the 15% limit. The generated left hand's fingers spread wider than the right's, which passes at 11%.
- **Recovery probe:** flaky, as on the rex.

Still open:
- a normal map baked from the raw Hunyuan mesh;
- the TRELLIS.2 comparison;
- a bot-match run.

There is no chest opening, glowing core, chest weak-point collider or low-health core window on this boss, and **no acid**: an iron muzzle locks its jaw shut. Every attack is physical: downward punches, sweeps, grabs, the roar and a head slam. The old eye beam and damaging tail lash are absent from its move selection.

**The muzzle** (`tools/art/muzzle_helmet.py`, built and exported through Blender MCP; `tools/art/muzzle_export.py` writes both GLBs):
- **Parts.** Two forged hoops close round helmet, snout and the shut jaw, each fitted to the measured cross-section of the closed muzzle. A chin bar joins them under the jaw, a heavy lock block with a shackle hangs from it, and riveted cheek straps run back to the helmet's temple guards.
- **Rigging.** Every part is weighted rigidly to the head bone and authored around the closed jaw, the pose the game holds (jaw bone at −30°).
- **In game.** The jaw never opens. A roar only strains it a degree or two against the bands.
- **Breath.** Smoke leaves both nostrils: a slow exhale every few seconds, a steady jet while it strains (roar, head-slam windup, stagger), and a hard snort after every blow. The smoke is lit like any smoke, so it shows in fire-light and vanishes in the dark. The eyes glow faintly amber behind the helmet.

**Head slam.** The boss rears its helmeted skull up and back (about 3.8 m on the 6x field) while a red ring fills on the target. 1.66 s after the ring appears it drives the skull down; the muzzle's lock lands on the stone (0.3 m above it in the review). A player is hit only if the skull's visible underside (lock, chin bar, shut jaw) comes down on them. The skull then lies on the stone for 2.6 s with the punch-recovery multipliers (3.2× blade, 1.8× arrow), and the paladin bot goes for it. If a ramp or tower is under the skull, the terrain guard raises it to rest on that stone rather than pushing the body back. Bots read the head slam as a slam and roll out of the ring.

**Nobody in reach.** Players beyond every claw's reach make it wade round the rim toward them (`SHIFT` toward their side). Sweeps and grabs at empty stone are skipped.

**Fire-lit arena.** The moon, rim and ambient light are cut to a trace. The fog is thick, dark and volumetric (Forward+), so most of the light comes from six braziers near the rim (four on the 1x field), each a 13 m fire light that scatters as a halo in the fog.
- **Knocked out by:** a slam's or head slam's shockwave nearby, a claw dragged through the bowl during a sweep or grab, or the gust of a roar.
- **Relit by:** a burning arrow dropped into a dark bowl. A doused brazier catches arrows on a physics layer only arrows use; a lit one lets shots pass.
- **Embers:** they catch again on their own after 30 s, so a fight without an archer is not dark for good.
- **Bots in the dark** register a boss blow only in its last 0.45 s, so they parry and roll late there. The archer bot's `b_kindle` relights the dead brazier nearest the knight whenever nothing is coming at the archer.

The banners call out the head slam, the grounded skull and the last fire going out.

Downward punches reach from the near rim to the platform's centre, wherever around the rim the boss stands. Players closer than the centre draw punches; players beyond it make it wade toward them. The arm alone reaches about 12 m on the 6x field, but the centre is about 17.5 m from the shoulders. No body pose closes that gap: every lunge, rise and lean that brings a shoulder within arm's length drives the spine and chest through the platform's side, the ramps or a pillar. A far punch therefore combines several parts:
- the body rears up to 3 m, slides in 1.6 m and leans to 28°, while the terrain guard still stops it at the stone;
- the upper arm and forearm lengthen along their bones by up to 40% (the forearm by at most 10%, the claw never);
- the elbow arches straight up, so the blow comes over the towers and ramps instead of through them.

All of this scales with how far past the arm's reach the target is (`plan_slam_reach`). On the small field the centre is barely past the arm, and the punch stays almost unchanged. If a tower or ruin column blocks one arm's arc, the boss swings the other; if both are blocked, that stone is cover, and the claw stops on it.

Two engine traps:
- **Stretched bones and children.** A skeleton stores local poses as position, rotation and scale, so the child of a stretched bone needs shear once the joint bends, and it came back skewed. The visible claw warped, and its terrain hull sank 0.4 m into the floor and froze the blow in the air. The rig now drives the forearm and hand bones without parents (every arm bone is set in skeleton space anyway), and the terrain guard bakes each bone's per-axis scale into its hull.
- **Claw width.** The claw's skin envelope is about 9 m across on the 6x field and 6 m on the 1x field. The 1x field's perches stand 3.4 m from its centre, so punches there often meet a perch.

After impact the boss commits to four seconds of recovery, or 5.2 seconds after a parry, followed by a 0.8-second arm return. Phase two does not cancel this opening into another punch. Both players can climb the grounded hand with **A / Space**. Movement controls the ascent: forward climbs, back retreats, and sideways input adjusts the route. Crouch holds a grip; jump releases it. Separate routes and shoulder positions leave room for two climbers. The standing capsule follows the visible hand, forearm and shoulder while clearing the hide and arena stone. A hand stopped high against scenery cannot be climbed from the floor.

The starting and idle poses extend both arms out to the sides. Attack braces still bring the palms back onto the platform. The boss notices ascending players as well as shoulder riders and warns before rolling its shoulders to shrug them off. Crouching resists the first shakes; a prolonged ride triggers a stronger buck. Released players fall from their current position with an outward impulse.

During punch recovery, sword hits on the punching hand deal 1.25x incoming
damage (arrows 0.65x), and sword hits on the head deal 3.2x (arrows 1.8x).
This makes the grounded hand a useful punish and the shoulder climb a stronger,
more exposed option. Other recovering claws retain their existing multipliers.

Both classes free a grabbed partner by attacking the opposite, braced claw.
Parries and sword hits on recovering hands build poise. A stagger lowers the
head and exposes both hands; the paladin can punish them while the archer
aims at the head. Head hits deal substantial damage even between openings; body and arm hits deal much less. The bots track these moving
targets and prioritize hand rescues and relighting the braziers. HUD prompts match.

The torso, neck and arm capsules block player movement and follow the rig. The skull and claws block through the **visible hide** instead: `enemies/colossus/skin_probe.gd` CPU-skins a sample of the mesh every physics tick and uses a generalized winding number to tell inside from outside. Any player inside the visible model, standing or downed, is pushed out along the surface normal (`_skin_separate`). Their colliders are hit-only convex hulls (`_hull_hitboxes_from_skin`) built from samples that are rigid on that bone (weight ≥ 0.85) and inset 0.2 m along the normal. Boxes can't do this job: the claw is concave, and the fitted boxes were 46–86% outside the mesh, shoving players away from empty air. Mouth and spell targets overlay that body without adding invisible obstacles. Players do not inherit velocity from a moving claw. Recovering hands lift before withdrawing; a descending limb separates an overlapping player along clear floor instead of pushing them below it. The separation checks the arena edge, other bodies and world geometry.

One sword swing damages the boss once, even if it intersects several parts. A blade already inside a part when the swing's damage window opens counts too: `body_entered` only fires on new overlaps, so the window start processes existing ones. The reptilian's shoulder attacks need blade contact, not a timed automatic head hit, and a slam hurts only a player its claw actually touches (`_claw_touches`), not everyone in its ring.

Rescues: while a grab holds, the braced claw stays pinned for the whole hold, including the time the captive's struggling adds. Sword cuts on the gripping claw also count toward the rescue, because a swing that met it first used to be spent on a clink. The paladin bot closes to 1.3 m of a claw's surface before swinging. Standing bots swing where they aim (the camera pivot), not along the last direction they walked. The archer bot shoots the braced claw even when the arrow path ends inside its hull.

Damage is the weapon's incoming HP damage multiplied by the contacted zone. Arrow arrival speed is already included upstream. Poise accumulates separately, so hitting a recovering claw can create an opening without doing much HP damage.

| Contact | HP multiplier | Purpose |
|---|---:|---|
| Body, arm or moving claw | 0.22x | Low damage through the scales |
| Punch recovery, sword on punching hand | 1.25x | 130% raw poise; accessible floor punish |
| Punch recovery, arrow on punching hand | 0.65x | Supporting fire |
| Punch recovery, sword / arrow on head | 3.20x / 1.80x | Strongest head opening; reachable by climbing |
| Other recovering claw, sword | 0.45x | Builds poise at 100% of raw damage |
| Other recovering claw, arrow | 0.30x | Builds poise at 15%; still frees a held partner |
| Head (the muzzled mouth is part of it), sword / arrow | 1.80x / 0.80x | Rewards precision throughout the fight |
| Skull down after a head slam, sword / arrow | 3.20x / 1.80x | Same opening as a grounded punch |
| Head during stagger, sword / arrow | 2.50x / 1.60x | Rewards the opening earned by the party |

Plunges retain their extra impact and poise, but also use the claw's HP multiplier. Spell-created marks and incendiary damage retain their existing special rules.

These are this game's tuning values, not copied multipliers from another title. [PlayStation's God of War Ragnarök combat guide](https://www.playstation.com/en-us/games/god-of-war-ragnarok/god-of-war-combat-refresher-course/) distinguishes HP damage, stun and deliberate attack interrupts. [Bandai Namco's Elden Ring combat guide](https://www.bandainamcoent.com/es_mx/news/elden-ring-introduction-part-4-combat-guide) describes stance breaks exposing enemies to critical attacks, including a marked critical spot on larger targets. The [official Nightreign starter guide, pp. 12–13](https://media-center.bandainamcoent.eu/games/elden-ring-nightreign/ERN_FuturePress_StarterGuide.pdf) also describes boss weaknesses causing both HP and stance damage. The design applied here is low limb damage with useful stagger buildup, then a stronger head punish. The sources do not establish a universal head/arm damage ratio across these games.

Hold **LB** to use the existing crouch/crawl movement; release it to stand. **LT** remains defense and **RT** remains attack or a timed parry. Keyboard crouch remains Ctrl.

A moving fog volume surrounds the boss's lower body, with drifting density
and a soft upper edge. The fighting surface and attack rings remain readable.
This local volumetric effect uses desktop Forward+; other renderers retain
the arena's existing distance/height fog. See [Godot's fog volume documentation](https://docs.godotengine.org/en/4.5/tutorials/3d/volumetric_fog.html).

```bash
LOB_ARENA_AREA=6 bash tools/run_boss_arena.sh --paladin
```

This gives you the paladin and an archer bot. Omit `--paladin` to play the
archer with a paladin bot; use `--watch` to watch both bots.

Rebuild through Blender MCP with `tools/art/blender_mcp.py execute_blender_code
tools/art/prepare_reptilian.py` in the MCP Python environment. Editable source:
`tools/art/source/reptilian_dark.blend`. `tools/art/inspect_reptilian.py` inspects
the original asset; `tools/art/review_reptilian.py` renders a neutral sculpt
study. Godot's `tools/review_dragon.tscn` supports `idle`, `slam_impact`,
`head_slam_windup`, `head_slam_down` and `stagger` captures via `REVIEW_ONLY`.

Validation (2026-10-23, muzzle/head slam/braziers): `animation_review` 102/102 at 6x and 94/97 at 1x, `attack_review` 22/22 at both sizes, `terrain_review` 0 failures at both sizes (head slams from four anchors included), `combat_feel` 54/0 and `souls_combat` 0 failures. The animation review now drives a real head slam (rear 3.8 m, lock 0.3 m over the stone, the player in the ring hit, the skull down, a nearby brazier out, the head back up) and a real arrow into a dead brazier. At 1x three checks fail: two grab checks that already failed before these changes, and the recovery-probe distance check, which straddles its 1.0 m limit from run to run (1.00–1.24 m on identical code). A 24-match bot run was stopped by memory pressure after 4 matches (2 wins, 1 wipe, 1 fall; braziers knocked out 6.0 and relit 5.8 times a match) — too few to judge balance.

Validation (2026-10-07): 78 arena checks pass at 6x area and 77 at 1x (`tests/boss_arena/animation_review.tscn`, `LOB_ARENA_AREA=6|1`). They cover both players' movement against boss parts, hull fit against the hide in four poses (≤15% outside), HP/poise differences, one hit per sword swing, lower-face mouth interrupts, slam contact, a real sword swing landing rescue damage on the braced claw from both sides, moving-limb contact, attack transitions, jaw/acid behaviour and rig alignment. The player combat suites pass (`combat_feel` 54/0, `souls_combat` 0 failures; both need `-- --singleplayer --character-class=paladin`).

Containment and balance, 30 bot matches at 6x (`LOB_CONTACT_PROBE=1 bash tools/run_boss_sims.sh`, then `tools/contact_report.py` and `tools/boss_report.py`):

| Run | Inside visible hide | Inside a collider | Win | Falls | Rescues |
|---|---|---|---:|---:|---:|
| before (boxes as blockers) | 219 s | 39.6 s | 60% | — | 5/12 |
| after (skin separation, hulls) | 20.0 s (0.32%), longest 0.8 s | 5.9 s | 83% | 10% | 17/21 |

What remains inside the hide is mostly a claw passing through a bystander for 0.3–0.4 s during a grab's reach, about 0.4 m deep, until separation clears them. The three remaining falls are all the archer thrown after being grabbed while drinking. Damage share is 63% archer, 37% paladin; acid is interrupted 1.9 times per match. No script errors occurred. These checks establish functionality, not human combat feel.

## Legacy colossus development notes

The notes below describe the original stone colossus (`LOB_BOSS_MODEL=colossus`).
Chest-core and gaze mechanics do not apply to the current reptilian boss.

A God of War–scale, Dark Souls–rules boss fight for the AI co-op mode: one
human (archer or paladin) and one bot of the other class, or two bots to
watch. Built so that **neither class can win alone**, and measured that way.

```bash
tools/run_boss_arena.sh            # you: archer, bot: paladin
tools/run_boss_arena.sh --paladin  # you: paladin, bot: archer
tools/run_boss_arena.sh --watch    # two bots, spectator camera
tools/run_boss_sims.sh             # headless batches -> tools/boss_report.py
```

## The arena

`tests/boss_arena/boss_arena.gd` — a round stone platform, radius 6 m
(~113 m²), floating over a fog-drowned abyss on the main game's rainy
full-moon night (it reuses `LightingManager` and `Moon`, then lifts the abyss
into a moonlit mist so the colossus reads as a silhouette).

- **Falling restarts the match** for both — knocked off, thrown, or a bad roll.
  So does a party wipe; a kill shows the result and restarts.
- **Two perches** (3.6 m rock columns at the rim, reached by ramps): level with
  the colossus's chest-core, above its sweeps, cover from its gaze.
- **A stump** (0.6 m hop-up) at the far side: standing on it clears a sweep.
- Each match appends a JSON report (outcome, duration, damage by class, every
  mechanic that fired, a player-perceivable timeline, and — on a fall — who,
  what hit them last, and a 3 s position trace) to `LOB_BOSS_LOG`.

## The colossus

`enemies/colossus/colossus.gd` + `colossus_part.gd`; model built by
`tools/build_colossus.py` (headless Blender → `assets/characters/colossus/`):
12 rigid parts pivoted at their joints, posed with an analytic two-bone IK, so
a slam lands exactly on the ring it telegraphed at exactly the time it told
the AI it would.

| Move | Telegraph | Answer |
|---|---|---|
| **Slam** | red ring fills ~1.4 s | roll, or a paladin **parry** (builds poise). The fist then stays **pinned** ~3 s, knuckle-embers bare |
| **Sweep** | red band lights the platform ~1.45 s | roll, hop it, stand high — or crouch behind the paladin's **raised shield** (covers both) |
| **Grab** | purple ring tracks, locks 0.35 s before | roll it; if caught, *the partner* must break it (below) or the victim is thrown into the abyss |
| **Gaze** (phase 2) | eye brightens 2.2 s | one solid **arrow in the eye** interrupts it; the perch columns block the beam |
| **Roar** | rears back 1.2 s | **crouch** to brace, or cover behind a column |
| **Double slam** (phase 2) | second ring at the OTHER player, ~1.2 s | as slam — two fists down is a big punish window |
| **High sweep** (phase 2) | amber band at chest height | **crouch** under it — a hop or a perch does not help |
| **Wade** (every 20–30 s) | it sinks chest-deep and pushes through the mist | it rises on another side: the perches, the safe spots and every angle change |
| **Shake** (when ridden) | shoulders shudder 0.9 s | **crouch** to cling, or be flung back down (15 dmg) |

After a sweep the arm drags to rest on the rim for ~1.8 s, bare — every
sweep owes the players a punish.

**Damage model — why it needs both:**
- Stone and bronze take **8%** of anything.
- A **pinned fist** takes the sword at 45% and, more importantly, only a
  blade builds real **poise** (arrows give 15%). ~5 sword hits (or a parry +
  hits) → **stagger**.
- **Stagger**: it reels back, fists braced on the rim (still bare — the
  knight keeps working), **chest-core open**. The core sits in a socket whose
  bronze lip turns shots from the floor; from a perch, level with it, arrows
  hit for **250%**. The archer converts the paladin's windows into damage.
- **Grab rescue**: grab the paladin → the core opens, the archer shoots him
  free; grab the archer → the other fist braces on the platform, the paladin
  hacks it. Freeing the victim also makes the colossus recoil (a free stagger).
- **Climbing it** (any class): beside a pinned fist, press **jump** to
  grip the hand, then use movement to scramble over the arm onto a
  **shoulder ledge** that carries you through its movements. From there the **head** is in sword reach
  (100% damage + poise). It shakes riders (crouch to cling); it grabs riders
  first; walking off the ledge is the abyss. A bot rider drops down when its
  partner is seized — the braced fist is the only place a grip breaks from.
- Grabs: the victim is held out to the SIDE and the chest gapes (the lip stops
  guarding), so a rescue arrow works from the floor too. Never a grab while a
  player is down (nobody could answer it); a 2.5 s breath after a player drops.
- Phase 2 at 60%: it roars, sinks into the mist and rises on another side of
  the platform (the chains snap), adds the high sweep and double slams, and
  sometimes comes out of a stagger roaring. The gaze can come in phase 1 too
  (rarer) — the archer's own opener: one arrow in the eye interrupts it.

## The bots (co-op AI)

Class knowledge stays in the class files, as the rest of the co-op AI does:
- `player/ai/ai_role.gd` (class-neutral): finds the boss/arena, reads
  `strike_eta_for()` for every move, answers instantaneous hits at the right
  frame (parry live 0.05–0.22 s after press, roll i-frames 0.09–0.34 s, a hop
  over a sweep), a **ledge guard** and a **rim fence**, and **human-like
  reactions** (`LOB_BOT_SKILL`, default 0.7: timing error and the odd
  missed read — frame-perfect bots parried everything and the fight looked trivial).
- `paladin_role.gd` `b_*` tactics: rescue (hack the braced fist, dropping off
  the shoulder if he is up there), break pinned fists — from their INNER side,
  because a sword chain lunges and a knight facing the abyss at the rim walks
  himself off it — **climb** a pinned fist and **ride** (sword on the head,
  crouch through the shake), **cover** the archer from a sweep, heal rite on
  the far side, hold the anvil. `LOB_BOSS_CLIMB` 0/1/2 = never / about half
  the chances (default) / always.
- `archer_role.gd` `b_*` tactics: climb a perch (detouring around columns),
  shoot the open core / the eye / pinned fists, shelter behind the shield.
- `LOB_BOSS_AI=naive` switches the co-op plays off; `LOB_BOSS_SOLO=paladin|archer`
  puts one class alone on the platform. These are the control groups.

## Evaluation

Simulations (`tools/run_boss_sims.sh`, headless, time ×2) and blind outside
testers (`tools/playtest/`): a packet of player-perceivable timelines, stats
and contact sheets from windowed recordings (`LOB_BOSS_SHOTS`), judged by two
Claude Code instances and one Codex instance that run outside the repo with
file-read-only tools and no project context (see `run_testers.sh` for the
isolation flags and why each is there). The rubric (R1–R11) follows MDA,
GameFlow, Lazzaro's Four Keys, the PLAY heuristics and souls-like readability
practice; testers must name the worst moments before scoring and cite a
timestamp or frame for every claim.

## Results (final build, 2026-10-03)

Headless bot-vs-boss batches, `LOB_BOT_SKILL=0.7`, time ×2:

| Party | Matches | Win rate | Notes |
|---|---|---|---|
| Co-op bots, mixed strategy (default) | 30 | **67%** | median 2:39; 6/20 wins close; rescues 76/91 (84%); damage 58% paladin / 42% archer |
| Co-op bots, never climb | 15 | 67% | ground game: fist → stagger → core |
| Co-op bots, always climb | 15 | 40% | viable, riskier: riders get grabbed; paladin does 58% via the head |
| Same bots, co-op plays off (`naive`) | 12 | **0%** | rescues 1/7; archer chips armour (57 glances a match) |
| Paladin alone | 4 | **0%** | grabbed and thrown — nobody to free him |
| Archer alone | 4 | **0%** | cannot stagger it; plucked off the perch |

A weaker pair (`LOB_BOT_SKILL=0.5`, earlier build) won ~25%, mostly close.

Blind tester panel (2 × Claude Code, 1 × Codex, no project context; medians,
1–5): five rounds, each recorded and judged on the build of the moment.

| Round | Fun /10 | Co-op need | Counterplay | Memorable | Bugs (5 = none) | Biggest complaint that round → fix |
|---|---|---|---|---|---|---|
| 1 | 5, 5 | 3.5 | 3.5 | 3 | 1.5 | sweep unanswerable (jump too low), beam one-shot, camera clipping |
| 2 | 5, 5, 4 | 4 | 3 | 3 | 1 | 0-HP player never "down", chained slams 1.1 s, eye un-hittable |
| 3 | 5, 6, 6 | 4 | 4 | 3 | 2 | high ground beat 39/47 sweeps → high sweep; dead air → sweep rest window |
| 4 | 6, 6, 6 | 4 | 4 | 4 | 2 | sword lunges off the rim; shield label on the archer |
| 5 (climbing, wading) | 6, 5, 6 | 4 | 4 | 4 | 2 | slams hitting riders, downed rider unreachable, "0%" alive (fixed after) |

Every rater in every round named the rescue and the stagger → core loop as
the best moments, and judged co-operation required ("yes"/"partly").
Their recurring wish we did NOT take: let a fall be recoverable — the spec is
that a fall restarts the match.


## Earlier dragon variant (development override)

This earlier variant is a Game-of-Thrones-style **wyvern** — the wings are its arms,
it clings to the rim with its wing-claws while its hind legs grip the cliff
below, and it fights with claws, wings, tail and fire. The fight's rules and
timings are unchanged. It is no longer the stage's default body. `LOB_BOSS_MODEL=dragon` selects it; `LOB_BOSS_MODEL=colossus` selects the original stone body.

**Model** — `tools/build_dragon.py` (headless Blender, ~6 min). No asset store
was available (no Rodin credits, no Sketchfab key), so it is built:
metaball anatomy remeshed into one watertight skin and auto-weighted by bone
heat (49 bones); crisp horn crown, dorsal spines, claws and teeth; wing
membranes as Coons patches between the finger bones; scales from tileable
textures on skeleton-cylindrical UVs (scale rows follow every limb, the seam
hides under the spines); AO and colour zones baked into vertex colour; glow
masks packed in UV2. Marker bones (`fist.*`, `core`, `mouth`, `snout`,
`f*t.*`, `tailtip`) carry every point the game needs.

**Rig** — `enemies/colossus/dragon_rig.gd` builds the colossus's gameplay
pivots *from* the skeleton (arm lengths are the bones'), then drives the
bones every frame: pivot bones copy their pivot exactly (what you see is what
hits you), the spine shares the lean, the neck is a curve into the skull, the
tail a sprung rope (lag, whip, settle), the wing fingers fold along the
forearm or flare (roar, stagger, wade).

**Arm motion** (the user's "awkward arms"):
- the elbow pole is a wyvern's (elbows high over the back), and the elbow
  plane *rotates* toward it around the arm axis — it used to be kept
  "continuous" by flipping, which locked an elbow inverted for good;
- wrists step instead of sliding (they lift on the way and set down);
- the slam arcs over and down, and the body rides the impact down;
- the head reaches for what it watches, never lays its chin on the stone,
  and rears up out of the way while it holds someone or reels open.

**Fire** — the gaze is a fire breath (throat glows through the scale seams,
flame stream, scorched stone), the spit a fireball with burning ground, the
core a furnace showing through the chest scutes (`dragon_skin.gdshader`);
membranes glow red when backlit and ripple (`dragon_membrane.gdshader`).

**Arena** — Poly Haven CC0 scans (slate floor, castle wall) through
`tests/boss_arena/wet_stone.gdshader`: rain-darkened stone with standing
puddles that mirror fire and moon; bloom on the fire.

**Review** — `tools/review_dragon.tscn`: stills per act from the player's eye,
the side and close (`REVIEW_STUDIO=1` neutral light), filmstrips of each act
(`REVIEW_BURST=1`), and a joint dump (`REVIEW_DEBUG=1`). `reach_short` events
in the match log flag any claw the logic thinks is on the stone while the IK
left it hanging short.

### Dragon results (6× field, knight: Skyward Leap, archer: Incendiary Arrows)

The spell kit is the blind testers' pick: three raters (two Claude, one Codex,
build order swapped) ranked incendiary arrows over hunter's mark and spirit
hounds — the only kit where both players do comparable damage.

Headless bot batches (`LOB_BOT_SKILL` 0.7, ×2 time):

| Build | Matches | Win | Fall | Wipe | Rescues | Notes |
|---|---|---|---|---|---|---|
| first dragon | 24 | 12% | 50% | 38% | 6/19 | claws hung short of the stone; brace reached across the chest |
| + full lean, brace on own side, detour around ruins, smaller skull box | 24 | 42% | 8% | 50% | 13/21 | a fallen capital pinned the knight in place for whole grabs |
| + fewer fireballs, incendiary kit | 30 | 63% | 13% | 23% | 26/33 | damage 59/41 |
| + plunge cooldown, phase at threshold, non-lethal grip | 30 | 57% | 23% | 20% | 21/30 | |
| + exposed chest below 18%, slam mercy | 30 | 53% | 37% | 10% | 37/45 | last 15% now ~8 s (was up to 85 s) |
| + claw that hit you can't be climbed, short wade | 30 | 60% | 13% | 27% | 42/47 | damage 49/51 |
| + rides end after ~8 s, wade throws riders | 30 | 63% | 20% | 17% | 34/41 | damage 46/54 |
| + no flask mid-air, fireball spacing, ruins kit | 30 | 63% | 3% | 33% | 46/52 | damage 50/50 |
| + archer leaves a burning tower by its ramp | 30 | 43% | 30% | 27% | 42/46 | worse: she still dropped off the side |
| + burning ground only on the floor | 30 | 63% | 3% | 33% | 49/51 | damage 53/47 |
| + it pants after a breath (chest open), riders can't be grabbed, wrist arrows count 2× | 30 | 87% | 0% | 13% | 38/48 | too easy |
| + shorter pant, wrist arrows 1.5× | 30 | 67% | 0% | 33% | 35/42 | |
| + one arrow in the mouth always chokes the breath (and still opened the chest) | 30 | 77% | 7% | 17% | 31/36 | too easy |
| **final**: the choke stops the fire, no free opening | 30 | **60%** | 3% | 37% | 47/48 | damage 52/48 |

Control groups on the dragon (same bots): co-op plays off (`naive`) **0/12**,
knight alone **0/6**, archer alone **0/6**.

Lizard on the same code for reference: 54% (24 matches).

Blind panel, per round (fun /10 from the three game testers; overall look /10
from the art critics):

| Round | Fun | Look | Their top complaint → what changed |
|---|---|---|---|
| 1 | 5, 5, 6 | 4 | plunge spam, unanswered grabs, fire pools → caps, rescue fixes |
| 2 | 7, 6, 6 | 5, 4 | endgame drag, slam pile-ons → exposed chest, mercy |
| 3 | 6, 6, 6 | 4, 4 | eating slams is optimal, fire is "the worst asset" → pin rules, breath |
| 4 | 7, 6, 6 | 4, 4 | 15 s rides, T-pose death, camera in the wing → ride limit, collapse |
| 5 | 6, 6, 6 | 5, 4 | a 1-HP captive read as "0% but up", fireball camping → display, spacing |
| 6 | 6, 6, 6 | 5, 4 | riders seized off its shoulder, cover that failed mid-breath, kill-cam in the floor → fixed |
| 7 | 6, 6, 6 | 4, 5 | seized while climbing, one-arrow choke inconsistent, camera in rock → fixed |

What the art critics still ask for, every round: volumetric fire, wings that
read as membrane when folded, designed ruins instead of kit pieces, a richer
backdrop. Those want hand-made art (a sculpted, hand-textured dragon; flipbook
fire) more than another procedural pass.

**Frame rate.** The art pass cost frames: 16.8 fps in the arena on the dev
laptop's Radeon 840M. `--perf-probe --perf-gpu` blamed SSAO (23.7 ms) and 4×
anisotropic filtering (13.7 ms); the arena now turns SSAO off (the dragon's
contact shadows are baked) and runs its viewport at 2× anisotropy: 40 fps,
no frame over 33 ms.

The acid vomit described in the 2026-10-22 notes below was removed on
2026-10-23 (the boss is muzzled; see the top of this page). Its module and
shaders are gone; those notes are history.

Attack regression and rendered captures:

```bash
bash tools/profile_arena.sh attack forward-attack
bash tools/profile_arena.sh attack-visual forward-visual
```

Validation for the forward vomit and punch update (2026-10-22): 31 focused
attack checks and 98 animation checks passed. Terrain checks passed 3,696
sampled poses across the 1x and 6x arenas, including the entire vomit and punch
recovery. A bot match completed in 112.6 simulation seconds with ten downward
punches and three acid windups; both characters survived. This is functional
validation, not a claim about human difficulty or balance. The animation test
still reports its existing shutdown resource warning.

Final logs are in `docs/presentation/arena-performance/forward-preview.log`,
`forward-animation-final.log`, `forward-terrain-final.log`, and
`forward-terrain-small.log`. See the [vomit preview](presentation/arena-performance/forward-preview-vomit-trail.png)
and [two-player climb preview](presentation/arena-performance/forward-preview-climbers.png).


The idle and climbing review (2026-10-28) passed for Titan and Trellis: 35 climbing checks, 41 attack checks, 135 animation checks and 2,268 terrain poses per model. The climbing review covers both arms with two players, input control, capsule clearance, continuous movement, shoulder spacing, shrug warnings, clinging and release. Rendered captures are in [climb-review](presentation/climb-review/); the corresponding logs are in `docs/presentation/arena-performance/natural-*`.

```bash
LOB_BOSS_BODY=titan bash tools/profile_arena.sh climb climb-titan
LOB_BOSS_BODY=trellis bash tools/profile_arena.sh climb-visual climb-trellis
```
