# Nego Thief

A hooded rogue built from `NegoThief.jpg`, sharing the archer's base mesh and rig so
every animation already in `player/character/archer/` retargets to him unchanged.

* `nego_thief_base.blend` — the pristine source. **The build never writes to it.**
* `nego_thief.blend` — the built result (Blender 5.0)
* `nego_thief.glb` — export, 19,808 tris, mixamorig skeleton, 70 bones
* `Thief_Body_diffuse.png` `Thief_Face_normal.png` `Thief_Face_rough.png`
  `Thief_Face_spec.png` — the head maps, all generated
* `Thief_Clothes_diffuse.png` — the garment atlas
* `face_sheet.png`, `reference_sheet.png` — reference beside the renders

## Build

    blender -b nego_thief_base.blend --python build_face.py -- /tmp/thief

Sculpt → dump mesh → `posmap.py` → `face_project.py` → `apply_face.py` → save + export.
Because it always starts from the base, it is repeatable; running it twice gives the
same result rather than sculpting the sculpt.

## The face is projected, not painted

An earlier pass painted the face with 3D masks — flat colour zones for brows, beard
and lips. That can put a feature in the right place but it can never look
photographic, because none of what makes skin read as skin (pore noise, specular
breakup, the way a beard thins into stubble) exists in a flat fill.

`face_project.py` projects the reference photograph itself onto the head and derives
the normal and roughness maps from the same pixels, so the shading agrees with the
colour. The steps that matter:

**Delighting.** The reference is lit hard from one side and the hood throws a shadow
ring around the face, and neither can be baked into an albedo. The shading estimate is
a polynomial in (u, v) — cubic vertically, because the hood brim darkens the forehead
from above and no quadratic follows that — fitted to **bare skin only**. Merely
down-weighting the dark pixels is not enough: the beard is a large dark region low in
the frame, so it bends the fit down there, and dividing that out then brightens the
beard back to cheek tone. Fitted on skin, brow-to-forehead contrast lands at 0.42
against the photograph's 0.50.

**The lit region is declared geometrically.** Nothing inside the hood's shadow ring can
be separated from a dark feature by brightness — the beard is darker than the shadowed
temple. So the usable area is a superellipse (a face is a rounded box, not an oval)
traced off a pixel grid, with an explicit horizontal cut where the hood brim crosses
the forehead. Everything outside is replaced by diffusion inpainting with the trusted
region as a Dirichlet boundary.

**Symmetry.** The key light leaves one cheek 2.2x the other and the gain clip cannot
close that, so wherever the local half is the darker one the mirrored half is blended
in. Left/right balance ends at 1.00.

**Position maps.** `posmap.py` rasterises each mesh's UV triangles into world position
and world normal maps. The archer's UV islands line up with nothing anatomical, so
every decision downstream asks "where on the head does this texel sit?" and reads the
answer out of these. It also carries a mouth-interior flag (see below).

**Dilate into the gutter.** Blender filters across UV island borders. A map that falls
off a cliff at the mask edge shows the island outlines — as dark fringes in the albedo
and, because the gradient there is enormous, as bright rectangles in the normal map.

## Two traps worth remembering

**Roughness must describe what the surface is, not where the photograph shone.**
Deriving gloss from the reference's highlights baked that shoot's key light in as fixed
low-roughness patches, which rendered as translucent panes lying across the nose and
cheek — the single most confusing artefact in this whole pass, and it survived several
rounds because a flat-shaded geometry render cannot show it. Roughness now comes from
skin / beard / lip masks.

**Fit the shading on skin, not on the face.** Same failure in a different costume: any
estimator that can see a feature will fit it and then remove it.

## Landmarks — measure them, don't guess

Histogram probes of the painted art are not reliable (the archer's hairline outweighs
her brows, and her skin reads "red" almost everywhere). Render a labelled pixel grid
over the reference and a world-millimetre grid over an orthographic head render, and
read both off directly.

    reference (px)              model (world mm)
    eye centres  (492,105) (526,105)   eye 1665, x +-36
    brows        y 95.5               brow ridge 1680
    nose base    y 134                nose base 1618
    mouth slit   y 152                mouth 1596
    lower lip    y 166                lower lip 1583
    chin         y 189                chin tip 1552

The photograph is an AI image with close-set eyes on a long lower face, so no single
affine fits both the eyes and the nose. `LANDMARKS` in `face_project.py` drives an
affine plus a Gaussian RBF on the residual — smooth, and it decays to pure affine away
from the face. There is deliberately **no forehead landmark**: the model's
brow-to-hairline is far taller than the strip the hood leaves visible, and pinning it
bends the warp hard right where the brows are and smears them.

**Re-run everything after any sculpt.** Masks built against stale position maps slide
off by a centimetre and the moustache ends up on the nose. `build_face.py` does this in
the right order.

## Geometry: repair first

The head arrived damaged from earlier passes, and no texture hides either fault:

* a hard crease running from the outer eye corner down across the cheek to the jaw
* lips squashed into a flat letterbox slit, with a hard quad ledge across the chin

`head_sculpt.py` relaxes the surface first (masked Laplacian, protecting only nose,
eyes and ears — the mouth is deliberately *not* protected, since the lips are rebuilt
afterwards), then sculpts:

* nose broadened ~30%, with tip, alae and nostril creases as Gaussian blobs
* lips rebuilt as Gaussian lobes — smoothstep bands build a rectangular shelf here,
  because a mouth is lobes
* chin pulled back 8 mm; it jutted further forward than the nose tip
* eyeballs scaled to 0.82 (they were 36.6 mm across, half again life size) and the lid
  aperture closed mostly from below, so the iris sits up against the top lid
* a lash line painted at the lid margin, which the photograph has none of because at
  that scale it is under a pixel

All of it is world-space vertex movement; the rest pose and vertex groups are
untouched, which is why the Mixamo rig still matches. Every weight is gated on x AND y
AND z at once — a weight banded only in z has twice silently scaled this character's
whole torso. `head_sculpt.py` asserts nothing moved outside the face box.

**The lips do not quite meet**, and rather than force the geometry shut, the mouth
interior is flagged per-vertex (teeth and the inner bag are small separate shells up
inside the head), carried through the position map and painted near-black. Teeth
catching the light through a 1 mm parting is the worst thing a head can do.

## What this does not fix

The reference face is about 90 px across in a 1024 px jpeg and it lands on roughly 700
atlas texels, so the albedo is an 8x upscale and the result is soft. Brows read as
smudges rather than hair, and the nose has less definition than the reference. Getting
past that needs either a higher-resolution reference or hand-sculpted detail; it is not
reachable from these pixels.

The head has no modelled eyelid fold or ear detail, and the hood opening is a narrower,
deeper cowl than the reference's, so it crops the temples and jaw that the reference
shows.

## Leftovers from an earlier pass

`detail_pass.py`, `build_realistic_thief.py`, `build_realistic_relief_thief.py` and
their outputs (`nego_thief_realistic*.blend/glb`, `front_camera_match.png`,
`NegoThief_relief_cutout.png`) built a "camera match" by putting the reference photo on
a plane in front of the character and setting `hide_render` on all three real meshes.
That is a photograph, not a character. The flags are cleared in `apply_face.py`; the
files are still here but nothing in the build uses them.

`raster.py` is superseded by `posmap.py` (which also does normals and the mouth flag)
and `body_recolor.py` by `face_project.py`. `recolor.py` still generates
`Thief_Clothes_diffuse.png` and is run by hand; `face_dbg.py` and `probe2.py` are
landmark debugging aids.
