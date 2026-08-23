# Nego Thief

A hooded rogue built from `NegoThief.jpg`, sharing the archer's base mesh and rig so
every animation already in `player/character/archer/` retargets to him unchanged.

* `nego_thief.blend` — working file (Blender 5.0)
* `nego_thief.glb`   — export, ~20k tris, mixamorig skeleton, 70 bones
* `Thief_Clothes_diffuse.png`, `Thief_Body_diffuse.png` — the two rewritten atlases
* `face_sheet.png` — reference face beside the model, hooded and bare
* `reference_sheet.png` — reference photo beside front / 3-4 / side / back / head renders

## How the textures are made

The archer's atlases are laid out in UV islands that do not line up with garments or
with anything on the face, so nothing here is painted in 2D. `raster.py` rasterises
each mesh's UV triangles into a *position map* — the world-space XYZ of whatever the
texel sits on — and the recolour scripts then work in 3D: a texel is sleeve or bracer
or moustache because of where it lives on the body, not where it lands in the atlas.

    python3 raster.py          # needs meshdata*.npz, dumped from Blender
    python3 recolor.py         # clothes atlas: zones -> leather / linen palette
    python3 body_recolor.py    # skin, beard, brows, lips, eyes

Every threshold is in metres up the T-posed character (he is 1.79 m tall).

### Face landmarks — measure them, don't guess

Beard and brow masks are placed to the millimetre, and histogram probes of the painted
art are not reliable enough to find them (the archer's hairline outweighs her brows,
and her skin reads "red" almost everywhere). `face_dbg.py` writes a striped ruler
texture — 10 mm bands in flat colours — that you render on the head and simply read off:

    z 1.5955  mouth slit          z 1.6180  nose base
    z 1.5820  lower lip bottom    z 1.6630  eye centres (x = ±0.0342)
    z 1.6080  upper lip top       z 1.6880  brows
    z 1.6080-1.6180  philtrum, i.e. where the moustache goes

**Re-run the ruler after any sculpt that moves the face**, and re-rasterise the position
maps first — masks built against stale geometry slide off by a centimetre and the
moustache ends up painted on the nose. `probe2.py` gives a second opinion.

The beard is bounded by two curves that must not converge, or it collapses into a
painted stripe: `JAW` (the mandible) and `TOP = JAW + GAP`, with GAP widening from
11 mm at the ear to 38 mm at the chin. Its edge is dithered against noise rather than
blurred — a blurred mask reads as an airbrushed shadow, a dithered one reads as hair.

## Geometry changes off the archer

Erika Archer is a slim woman; he is a broad man. All of it is vertex moves in world
space, applied to the mesh only — the rest pose and the vertex groups are untouched,
which is why the Mixamo rig still matches exactly.

* body: broader shoulders, flattened bust, thicker neck and arms, narrower hips
* head: wider skull and cheeks, shorter and squarer jaw, heavier brow ridge, broad
  nose with wide alae, smaller mouth, and eyelids opened up — the wide-eyed look is
  the single strongest cue from the reference
* the philtrum had to be re-lengthened by 6.5 mm after the face was shortened, or
  there was no room between nose and lip for a moustache
* deleted: quiver, arrows, and the archer's blonde fringe (15 loose parts hanging in
  front of the face — they read as bangs on a bald man)

## Remaining polish

The rigged source model still uses the archer's skeleton and retargetable vertex groups.
The active camera match is handled by a 2.5D image plane, so any future fully-volumetric
pass should preserve the Mixamo bone names and rebuild the boots, dagger, pouches, and
leather vest as properly skinned geometry.

## Detail pass

`detail_pass.py` creates the active front-camera match. It keeps the rigged stylized
thief source in the scene, then adds an opaque 2.5D camera-match layer from
`NegoThief.jpg` so the required camera angle reads as close to the source photo as
possible. It exports `nego_thief.glb` and writes `front_camera_match.png` plus the
two-panel `reference_sheet.png` comparison.
