# River channel

The river follows a continuous bend from the north edge to the south edge of MainGround, spanning its full 1,144.983-metre extent. Its central bed sits 1.4 metres below the mean water surface; submerged banks slope up to the shore. Water rests 18 cm below the field, with small travelling waves. Characters walk on the bed and can climb either bank.

`stage/river_builder.gd` replaces the old ground slab and disconnected river boxes with matching terrain, channel and collision meshes in 64-metre sections. Grass exclusions follow the same river profile. A timber bridge and approach ramps carry NorthRoad over the channel; the buried road collision is removed from the crossing. Reeds and spatial water audio extend along the whole river.

`stage/river_water.gdshader` carries two ripple scales, broken shoreline foam and foam streaks downstream in the channel's UVs. Shallow transparency reveals the sloping bed, and a small sky reflection keeps the surface visible under the night exposure.

[Daylight](presentation/river-day.png) · [Night](presentation/river-night.png)

Run `tests/river.tscn` with `--singleplayer --no-mcp-runtime`. Eight checks cover removal of the old slab, 65 depth probes through both map endpoints, dry-bank continuity, submerged slopes, bridge collision, grass exclusion and a character walking out of the water. Add `--capture-river` in a graphical run for day, moving-water and night images under `/tmp/lob-river-*.png`. All eight checks passed headless and with Vulkan rendering; the full-game headless RIVER scenario also completed without script errors. A graphical full-game run was inspected but reached its 45-second wall-clock limit before completing; whole-game performance has not been benchmarked in this pass.
