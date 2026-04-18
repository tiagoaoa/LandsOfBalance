# Lands of Balance — Project Lingo

Shared vocabulary we use when discussing this project, extracted from the
chat history so future sessions (and other collaborators) can echo the
same terms instead of re-negotiating them.

Using these words consistently shortens specs — saying "use the GRASS
showcase" is one word instead of three sentences describing what to run.

---

## Game-world vocabulary

| Term              | Meaning                                                        |
| ----------------- | -------------------------------------------------------------- |
| **Douglass**      | The player character (the Keeper). Paladin or Archer class.    |
| **Paladin**       | Sword + shield class. HP 150, 100-damage knight sword.          |
| **Archer**        | Bow + spell class. HP 100, percent-based arrow damage.          |
| **Bobba**         | The mutant NPC enemy at the village. HP 1000, 40-dmg punch.     |
| **Dragon**        | Patrolling boss-class NPC. HP 500.                              |
| **Combatant**     | Any living entity with HP (player, Bobba, Dragon).              |
| **Village of Eights**, **Realm of Hudson**, **Tower of Hakutnas**, **The Burning Peaks**, **The Hills** | Named regions on MainGround. Use these names instead of coordinates. |
| **MainGround**    | The 1070×1145 m flat CSGBox3D that defines the playable area. |
| **The Moon**      | The night-time directional light source; carves god rays      |
|                   | through volumetric fog in the NIGHT lighting preset.          |

---

## Combat vocabulary

| Term                | Meaning                                                    |
| ------------------- | ---------------------------------------------------------- |
| **Golden rule**     | A non-negotiable spec. Currently: *"An attack only causes damage when it visually collides with the target."* |
| **Visual collision**| The hit volume must match the rendered weapon's shape — a sword is a thin capsule along the blade, a fist is a small sphere at the hand bone. No generous spheres. |
| **Hurtbox**         | The target's own body volume — Paladin uses the existing CapsuleShape3D. |
| **Fully blockable** | Attack that's negated entirely on a successful block (sword, arrow). Non-fully-blockable hits (Bobba punches, DoT auras) only get damage reduced 70% on block. |
| **Poise**           | A second HP pool; depleted by heavy hits and, when emptied, triggers a stagger. See `combat/poise_component.gd`. |
| **Stagger**         | Longer hit-stun triggered by poise break — Bobba plays the Roar animation. |
| **Unstoppable**     | 2-second immunity to further poise damage granted after 3 rapid staggers — so the player can't chain-lock the enemy. |
| **Hitstop**         | Engine.time_scale drop on impact (60 ms at 5% speed for heavy hits). `CombatFX.on_hit(weight)`. |
| **Stamina**         | Resource consumed by Paladin sword swings (25 per swing). Regen pauses 0.6 s after any spend; blocking halves regen. |
| **Damage buff**     | 0 – 50% multiplier on knight sword damage, charged by the Archer's buff aura. Shown as the bottom-right "ᛋ" rune counter (0-50). |
| **Attack data**     | A Godot `Resource` bundling damage / poise damage / knockback / hit-window / stamina cost. Replaces hardcoded per-attack constants. `combat/attack_data.gd`. |
| **Combat effect**   | Base class for post-hit chainables (DoT tick, knockback variant). `combat/combat_effect.gd`. |
| **Hit window**      | The `[start, end]` normalized animation range (e.g. 0.15–0.95) during which the attack's hitbox is active. |

---

## Scene & rendering vocabulary

| Term                | Meaning                                                      |
| ------------------- | ------------------------------------------------------------ |
| **Open terrain**    | Any MainGround area **not** inside an exclusion zone. Grass goes here. |
| **Exclusion zone**  | Rectangular region flagged "no grass" — village, castle, training grounds, tower, roads, rivers. Defined in `stage/realistic_grass_placer.gd::_setup_exclusion_zones()`. |
| **Blade field**     | The uniform dense grass carpet on open terrain. 6 blades/m², cornfield-sparse (roots 30-50 cm apart), Paladin-shoulder tall. |
| **Cornfield rule**  | Tall grass must look like a shorter, more sparse corn field — individual blades visible, not bushy clumps. |
| **SGT**             | Shorthand for `SimpleGrassTextured` (the addon + its `MultiMeshInstance3D` node). |
| **Performance mode**| `--performance-mode` CLI flag; disables shadows, halves grass density. `test_full_game.sh` uses this. |
| **DAY / NIGHT**     | `LightingManager` presets. Default is NIGHT. Only the GRASS showcase scenario force-switches to DAY. |
| **Gothic HUD**      | The dark-fantasy / Elder-Scrolls-style UI language: wooden-textured frames, bronze rims, corner gold gems, parchment-tinted text. `ui/gothic_hud.gd`. |
| **Wood frame**      | A panel backing drawn by `ui/woodgrain_frame.gdshader` — grain + bevel + carved inner border. Replaces flat StyleBoxFlat. |
| **26 style**        | The visual-fidelity bar for this project. It is 2026 — we have the GPU and CPU headroom of a mid-range modern machine, and anything we ship should read as **better than a PS4-era early souls-like** (Dark Souls 3, Bloodborne, Dragon's Dogma). Plan for shaders, textures, volumetric light, dense instancing, per-instance variation — not flat StyleBox/ColorRect work. If a draft looks 8- or 16-bit or reads as "Godot defaults," it's not 26 style. |

---

## Test-harness vocabulary

| Term                      | Meaning                                        |
| ------------------------- | ---------------------------------------------- |
| **Scenario A**            | Auto-driven Paladin *wins* combat vs Bobba. `./tools/run_combat_scenario.sh A` |
| **Scenario B**            | Auto-driven Paladin *loses* combat but lands hits. `./tools/run_combat_scenario.sh B` |
| **GRASS showcase**        | Teleports Paladin to open grass, forces DAY lighting, disables interactive bending. Verifies only the grass visual, *not* gameplay conditions. `./tools/run_combat_scenario.sh GRASS` |
| **`test_full_game.sh`**   | The real-game launch — two windows, multiplayer, NIGHT, performance-mode. *This is the definition of "done" for anything visual.* |
| **`run_local.sh`**        | Local game-server + single client loop for UDP testing. |
| **Showcase vs. gameplay** | A visual that works in the GRASS scenario but fails in `test_full_game.sh` is **not done**. Always validate in the real launch before claiming success. |

---

## Workflow & tooling vocabulary

| Term                       | Meaning                                                    |
| -------------------------- | ---------------------------------------------------------- |
| **Round-trip (asset)**     | Edit an asset in Blender → export → Godot re-imports. `./tools/edit_asset.sh <asset>` → `./tools/sync_from_blender.sh <blend>`. |
| **v6100 FBX**              | Ancient binary FBX format. Blender refuses it; we detour via Godot → GLB → Blender. Happens automatically in `edit_asset.sh`. |
| **Blender 4.5 LTS**        | Installed at `/home/talves/.local/blender-4.5/blender`. Used for editing; system Blender 5.0 has broken FBX import/export operators. |
| **Godot re-import**        | After an asset changes on disk, focus the Godot editor or run `godot --headless --import` to regenerate `.import` files. |
| **Audio procedural**       | Footstep + jump WAVs are synthesized by `tools/gen_footstep_wavs.py` — license-clean placeholders. Swap for CC0 recordings later by overwriting the same filenames. |

---

## User-facing communication shorthand

Phrases from earlier sessions that have acquired consistent meaning —
worth re-using to keep specs short.

| Phrase                                | Binding                                    |
| ------------------------------------- | ------------------------------------------ |
| **"Golden rule: …"**                  | Non-negotiable spec. Echo back in one sentence before acting. |
| **"Hideous"**                         | Reject. Stop. Re-examine assumptions; probably hand-rolled something when the repo already has the right asset. |
| **"Almost acceptable"**               | Near-target but at least one visible flaw left. Do a specific fix pass, not a rewrite. |
| **"Visual consequences"**             | Must be *seen* in game (knockback, flash, stun), not merely stat-tracked. |
| **"Research for …"**                  | License-check first (CC0 / CC-BY). If external download is flaky, fall back to procedural. Declare the choice. |
| **"Go for it"**                       | Autonomous execution permitted on this scope. No further prompting unless something ambiguous blocks progress. |
| **"Make this a rule"**                | Same as "golden rule" — persist the rule in code + this doc. |
| **"26 style"** / **"this is 2026"**   | The fidelity bar — better than PS4-era early souls-likes. See the scene & rendering table. Flat ColorRect / StyleBoxFlat work is a failure mode; reach for shaders, textures, lighting, and per-instance variation. |

---

## Component / script index

| Path                                         | Responsibility                                  |
| -------------------------------------------- | ----------------------------------------------- |
| `combat/health_component.gd`                 | Shared HP pool (players and NPCs).              |
| `combat/stamina_component.gd`                | Regen-with-delay stamina pool.                  |
| `combat/poise_component.gd`                  | Stagger pool + unstoppable grant.               |
| `combat/attack_data.gd`                      | Resource-based attack definition.               |
| `combat/combat_effect.gd`                    | Base for post-hit effects.                      |
| `combat/damage_aura_area.gd`                 | DoT aura (ground fire).                         |
| `combat/heal_aura_area.gd`                   | Heal aura (Paladin spell).                      |
| `combat/buff_aura_area.gd`                   | Damage-buff aura (Archer spell).                |
| `combat/combat_fx.gd`                        | Hitstop + camera shake autoload.                |
| `stage/realistic_grass_placer.gd`            | Populates SGT with the blade field.             |
| `stage/lighting_manager.gd`                  | DAY / NIGHT preset.                             |
| `ui/gothic_hud.gd`                           | Full gothic HUD (emblem, bars, slots, buff).    |
| `ui/woodgrain_frame.gdshader`                | Wood-grain + bevel + carved-border panel shader.|
| `ui/combat_hud.gd`                           | Enemy HP row builder (lives inside gothic HUD). |
| `enemies/combat_test.gd`                     | Auto-driver for A / B / GRASS scenarios.        |
| `tools/run_combat_scenario.sh`               | Launches the selected scenario headlessly.      |
| `tools/edit_asset.sh`                        | Open an FBX / GLB in Blender.                   |
| `tools/sync_from_blender.sh`                 | Re-export a `.blend` back to the project.       |
| `tools/blender_import.py`                    | Blender startup script (import + stash source). |
| `tools/blender_export.py`                    | Headless Blender export driver.                 |
| `tools/godot_fbx_to_glb.gd`                  | Godot-side FBX → GLB converter for old FBX.     |
| `tools/gen_footstep_wavs.py`                 | Regenerate footstep / jump WAV placeholders.    |

---

## Committed rules (from this conversation)

1. **Visual collision rule.** An attack causes damage only when its weapon volume visually intersects the target. Hitboxes must match the rendered weapon shape.
2. **Real-game launch is the bar for "done"** on visual features. `test_full_game.sh`, not a showcase scenario.
3. **Bobba's block must look protective.** Both arms raised X-guard + head tuck + spine hunch (procedural over the Mixamo rig).
4. **Blocked hits still push.** Shield eats damage, not momentum.
5. **Cornfield grass spec.** Blades roughly Paladin shoulder-height (1.5 m), roots 30-50 cm apart, individual stalks visible, dark desaturated green, lit bevel when moonlight hits the top.
6. **Tall-grass exclusion.** Grass only on open natural terrain; never on village, castle, roads, training grounds, tower, realm fields, burning peaks.
7. **26-style fidelity bar.** Every visual pass should aim above PS4-era early souls-likes. If the first draft looks retro or uses Godot default styling, it needs another pass before it ships.
