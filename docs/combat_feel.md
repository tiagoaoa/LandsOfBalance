# Combat revision

The controller now buffers one recent action, gives dodges priority over an earlier combo press, and accepts attacks during the end of a roll or hit reaction. Light sword clips take 0.68, 0.74 and 0.92 seconds. Their recovery tails allow movement, guard or a paid dodge. Heavy attacks use a separate 1.08 second clip, cost 32 stamina, deal 170 base damage and apply 85 posture damage. Paladin light attack, dodge, parry and sprint costs remain unchanged; the archer still pays 40% of those costs.

Sword contact sweeps the blade between physics poses and records targets per swing. A cleave can hit several enemies once each, excludes allies, checks walls, and only confirms accepted damage. Free movement turns the paladin toward the stick; lock-on and guard retain strafing. Sprint requires Shift or L3. R3 locks, and a right-stick flick changes targets. The camera continues following the target while the player recoils.

Bobba commits his heading before contact, alternates the axe with a two-hit fist chain, and adds the third fist attack below half health. His windup timing is stable. He stays within reach during recovery, cannot guard while attacking, and no longer reads the player's animation clock to evade. Guard only covers his front, heavy blows can break it, and posture breaks open a critical attack. Ordinary hits cannot erase his armored windup. He no longer flees or regenerates while engaged. His four attacks deal 34, 28, 48 and 55 damage, with reduced displacement.

Skeletons commit to a facing, require line of sight at contact, and cancel interrupted attacks completely. They can be parried and critically struck. At most two skeletons attack the same target simultaneously, with staggered starts. Hit reactions now have a short torso/head recoil animation. Weapon trails only accompany the weapon that is actually attacking. The target HUD shows posture and OPEN windows.

The existing no-hitstop/no-camera-shake combat behavior is preserved. The opt-in cinematic hitstop helper now uses a real-time deadline, fixing the twentyfold duration stretch at 5% time scale.

## Verification

130 focused checks pass: 50 combat behavior checks, 51 existing combat regressions and 29 archer aim checks. The [recorded review](presentation/combat-review.mp4) shows the scripted encounter; the [controls table](../README.md#controls) lists the updated bindings.

Run the focused checks from the repository root with Godot 4.5.1:

```bash
GODOT_MCP_RUNTIME_ENABLED=0 /home/talves/bin/godot --headless --path . --scene res://tests/combat_feel.tscn -- --singleplayer --character-class=paladin --no-mcp-runtime
GODOT_MCP_RUNTIME_ENABLED=0 /home/talves/bin/godot --headless --path . --scene res://tests/souls_combat.tscn -- --singleplayer --character-class=paladin --no-mcp-runtime
GODOT_MCP_RUNTIME_ENABLED=0 /home/talves/bin/godot --headless --path . --scene res://tests/archer_aim.tscn -- --singleplayer --character-class=archer --no-mcp-runtime
```

`tests/combat_review.tscn` runs a scripted dodge-and-counter encounter, showing the fight from the side for 12 seconds and then through the player's camera. It never submits a human fun rating. `tests/combat_arena/arena.tscn` remains the interactive practice arena.

The full-world SOULS scenario used five parries, four critical hits and three healing flasks to defeat Bobba in 37.6 simulated seconds. This scripted controller reads attack timing and is an integration check, not evidence of human difficulty or enjoyment. The rendered review checks weapon motion, readable recovery, dodge direction, lock-on framing and effects. Human combat feel still needs judgment on the controller.
