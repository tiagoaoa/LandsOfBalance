# Arena performance

The arena uses baked scenery cards, an upper-body boss mesh, a 60 Hz physics loop, threaded skin sampling and cheaper rendering of fog and stone. Combat timings remain in seconds; continuous arm sweeps, weapon contact checks and scenario collision still run. Other scenes retain their previous physics rate when the arena exits.

The eleven cliff instances previously contained 1,688,192 triangles in total. They are now eleven two-triangle cards. Seven exterior arches and their supporting piers are seven more cards. These use baked lighting, alpha-scissor depth writes, mipmaps and VRAM compression. They are fixed in world space and share meshes/materials for automatic instancing. The foreground platform, ramps, cover and pillars remain geometry. The decorative rim stones use one MultiMesh.

`tools/art/arena_assets.py` bakes the original models in Blender and writes the card sizes alongside the PNGs. It also exports `reptilian_arena.glb`: 175,169 triangles instead of 201,333, with geometry below source Z=-3 removed and capped to keep the skin probe closed. All 21 bones and the existing head/armor materials remain. The complete boss source and GLB are retained for other uses.

The skin probe snapshots bone transforms on the main thread and skins four independent vertex batches through WorkerThreadPool. Each batch owns its output; joining completes before building the spatial grid and checking player contacts. Scene nodes, physics queries and GPU uploads stay on the main thread. A serial fallback is used on small CPUs and can be selected with `LOB_SKIN_THREADS=0`. The occupied-cell nearest search replaces scanning empty grid shells.

Terrain envelopes reuse rigid shapes and cache relative joint poses. A 0.025-model-unit displacement bound permits reuse of small deformations, with the entire bound added to the query margin. Bounds for each bone influence conservatively reject empty space. Detailed deformed hulls and rotational/translation sweeps remain the authority near stone. The arena's simple floors, perches and ramps use primitive cylinder/box collision shapes instead of CSG triangle meshes.

The wet-stone shader skips triplanar projections whose contribution is below 0.001, reducing twelve texture reads to four on axis-aligned faces. The fog froxel buffer is 64×64 in its screen dimensions instead of 128×128, while retaining 64 depth slices, temporal filtering and the local boss fog. The renderer's project defaults are restored when leaving the arena. MSAA, glow, rain, spells and simulated cloth remain enabled.

## Measurement

The repeatable test is `bash tools/profile_arena.sh perf after`. It uses seed 301, a fixed overview camera, idle boss, stationary party, uncapped presentation and wall-clock frame intervals after six seconds of warmup. The viewport is fixed to 1382×720 at 100% 3D scale, matching the baseline capture even if the desktop tiles the window differently. Dynamic resolution is disabled only for this benchmark. Hardware: Radeon 840M integrated graphics, Ryzen AI 5 340, Godot 4.5.1 Forward+ / Vulkan.

The initial log printed the requested 1280×720, but its expanded viewport and saved PNG were actually 1382×720. Later profiling explicitly records and fixes the real viewport. The experimental `cached-hulls.log` used a tall tiled viewport and is not a comparable result. Headless and GPU-feature runs are diagnostic, not gameplay FPS measurements.

| Same overview, 1382×720 | Before | After |
|---|---:|---:|
| Average wall-clock FPS | 10.34 | 36.63 |
| Median frame | 95.05 ms | 29.56 ms |
| 95th percentile frame | 113.94 ms | 36.75 ms |
| GPU frame | 35.69 ms | 13.27 ms |
| Draw calls | 261 | 144 |
| Submitted triangles, including passes | 1,041,421 | 685,243 |

This is a 3.54× throughput improvement in this controlled view, with 63% less GPU time. It is still CPU-limited and does not establish a locked 60 FPS during combat. Logs and captures: [before](presentation/arena-performance/before.log), [after](presentation/arena-performance/after.log), [before image](presentation/arena-performance/before.png), [after image](presentation/arena-performance/after.png).

An isolated skin-probe comparison measured serial updates at 4.38/4.48 ms and parallel updates at 3.28/3.19 ms. Position and normal arrays were identical. Fog-resolution ablation measured approximately 16 ms with the default volume versus 13.3 ms with the smaller volume in that fixed view. These are local measurements, not hardware-independent guarantees.

## Reproduction and checks

```bash
blender --factory-startup -b -t 4 --python-exit-code 1 --python tools/art/arena_assets.py
bash tools/profile_arena.sh import
bash tools/profile_arena.sh perf after
bash tools/profile_arena.sh gpu gpu-features
bash tools/profile_arena.sh skin skin
bash tools/profile_arena.sh animation animation
bash tools/profile_arena.sh terrain terrain-6x
bash tools/profile_arena.sh terrain-small terrain-1x
bash tools/profile_arena.sh bots coop
```

The animation suite checks the upper-body mesh, card counts, body separation, damage zones, mouth interrupts, acid cover, grabs, rescue strikes and attack continuity. Terrain tests sample the visible skin against floor, ramps and pillars through attacks, stagger, repositioning and death, at four arena angles. Skin tests compare threaded/serial outputs and check nearest-point results against a brute-force reference.

Final validation: 98 animation/combat checks passed; 1,224 terrain poses passed at 6× arena area and another 1,224 at 1×, with zero detected penetrations. The co-op bots won a full match in 114.9 simulation seconds, including a rescue, three acid interrupts and four terrain-blocked attacks. Test shutdown still reports ObjectDB/resource-in-use warnings; these assertions do not certify leak-free shutdown. See the logs in `docs/presentation/arena-performance`.

## Architecture and next bottlenecks

[Godot's GPU guide](https://docs.godotengine.org/en/4.5/tutorials/performance/gpu_optimization.html) identifies overdraw, texture reads and memory bandwidth as costs separate from triangle count. That informed the depth-writing cards, compressed/mipmapped textures, reduced fog buffer and conditional triplanar samples. [Godot's instancing guidance](https://docs.godotengine.org/en/4.5/tutorials/performance/optimizing_3d_performance.html) supports shared opaque/cutout meshes and material reuse; the rim uses explicit instancing because every previous stone had its own BoxMesh.

[Godot's threading rules](https://docs.godotengine.org/en/4.5/tutorials/performance/thread_safe_apis.html) informed the isolated CPU batches. Moving same-frame collision skinning onto the GPU would require reading positions back for CPU physics, introducing synchronization. [AMD's RDNA performance guide](https://gpuopen.com/learn/rdna-performance-guide/) describes async compute as useful for particular overlapping workloads, with resource-contention limits. This pass leaves queue scheduling to Godot; it does not claim custom asynchronous GPU compute.

The remaining CPU work is chiefly detailed boss pose/terrain queries and cloth simulation. A native implementation of hull fitting and skin-grid construction is a candidate for a later measured pass. The cards are intended for cameras inside and above the arena, not for freely exploring the exterior ruins. The cut body is specific to this fog-covered arena.
