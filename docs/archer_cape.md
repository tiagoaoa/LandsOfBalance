# Archer cape

The archer now wears a simulated, gathered cape with a woven matte surface and stitched hem. Gravity, air drag and movement inertia deform 187 cloth points; stretch, shear and bending constraints keep the fabric together. The collar follows the final chest pose after bow aiming. Body capsules and a sampled floor plane keep the cloth clear of the wearer and ground.

[Movement preview](presentation/archer-cape.mp4) · [Resting drape](presentation/archer-cape.png)

`player/cape.gd` installs the same solver on local, companion and remote characters. The paladin wears a wider burgundy cut fitted below the pauldrons, in both armed and unarmed modes. His old wool surface is discarded independently of the cuirass and pauldrons, which share the imported mesh. The archer's original mantle stays hidden. Both preserve their imported skin bindings. Simulation uses 120 Hz substeps, pauses for hidden characters, resets after teleports, and uses the authored drape beyond 30 metres. `player/cape.gdshader` samples the simulated positions and shades the weave; the mesh stays allocated instead of being rebuilt each frame.

Run `tests/cape.tscn` with `--singleplayer --no-mcp-runtime` for movement, attachment, body/floor clearance, teleport and remote-player checks. Add `--paladin-cape` for the paladin, and `--capture-cape` in a graphical run to save idle, run, turn and settled PNGs under `/tmp/lob-<class>-cape-*.png`. The preview shows idle, running, turning and stopping. The test also exercises a low horizontal pose; the existing archer aim scenario checks held draw, pitch tracking and release recovery.

The paladin passed 14 cloth checks in headless and graphical runs. [Paladin cape](presentation/paladin-cape.png).

Validation on Godot 4.5.1: 13 cloth checks and 29 archer aiming checks passed, with no script or shader errors. Simulation plus texture upload measured 2.12 ms median and 2.94 ms at the 95th percentile during a 60 FPS movie capture on this machine. This is the cape's CPU cost, not a whole-game frame-rate benchmark.

Collision approximates the torso, hips, thighs, neck, shoulders and long tunic. It does not simulate cloth self-collision or contact with arbitrary world walls. A live multiplayer session and mobile performance were not tested.
