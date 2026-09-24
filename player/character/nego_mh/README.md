# Nego — MakeHuman build

The thief's face on a MakeHuman (MPFB2) body, from `NegoThief.jpg`. Unlike the
archer-based thief in `../thief/`, the head *shape* comes from the photo too, not
just the texture.

    ./build.sh /tmp/nego_mh          # ~3 min, all headless

## How it works

1. `mh_base.py` — an African male macro base, rendered front-on with an orthographic
   camera whose parameters are saved beside the image.
2. `lm_photo.py` — MediaPipe Face Landmarker on the photo *and* on that render. Both
   get the same 478 points, so landmark *i* is the same anatomical spot in both.
3. `fit_face.py` — render landmarks become mesh vertices (through the camera); the
   photo's are aligned by a similarity transform; then the 181 face targets under
   cheek/chin/eyebrows/eyes/forehead/head/mouth/nose are solved as one bounded
   least-squares problem, since a target is just an additive vertex offset. Forehead
   points sit on the hood and are dropped; eye rings are down-weighted because the
   reference's eyes are wide open and that is expression, not shape. 5.3 → 3.7 mm.
4. `apply_fit.py` — loads the weights as MPFB shape keys.
5. `dump_uv.py` + `posmap_mh.py` — world-position and normal maps in the skin's UV
   space (`../thief/posmap.py`'s idea, for the MakeHuman atlas).
6. `project_mh.py` — the thief's projection pass, redone: affine + RBF warp pinned on
   the landmarks, delighting from a quadratic fitted on bare skin only, mirrored
   fill for the shadowed side, then composed onto the `young_african_male` skin.
   The photo is toned *to the base skin* (not the base to the photo — that lit the
   whole body up and left the face darker than the neck). Projection stops at the
   brows (hood shadow the delighter cannot lift), at 55–80 % of the ear distance
   (same reason), and skips the eye interiors so the eye asset is not ringed by
   painted whites.
7. `apply_tex.py` — MakeSkin material with the new diffuse, eyes / brows / lashes /
   teeth assets, EEVEE render.

`fit_weights.json` and `nego_skin_diffuse.png` are the outputs checked in.

## Notes

* mediapipe 1.0.x dies with SIGKILL on this machine at the first `detect()`;
  0.10.21 works. `build.sh` expects its venv at `PY=`.
* Vertex indices in `.target` files address the full 19,158-vertex base mesh with
  helpers. The evaluated mesh has helpers masked out, so never read positions from
  it — `render_head.py` sums the shape keys instead.
* Not rigged or in-game yet. Next: `rig.mixamo.json` (52 bones, a strict subset of
  the archer's skeleton, see the Cloud smoke test), a proxy body under the thief's
  clothes, export.

## Grafting onto the thief

    blender -b ../thief/nego_thief.blend --python graft.py -- /tmp/nego_mh ../thief/nego_thief_mh

`mh_head_prep.py` bakes the fitted shape keys, keeps only head+neck body vertices
(`ZCUT`), gives head/eyes/teeth plain Principled materials (the MakeSkin node trees do
not survive glTF), deletes the eyes' cornea shell (its faces map to the blue disc at
UV 0.9,0.1 — with it, the iris renders pink through the blend), and uses
`brown_eye_dark.png`, MPFB's brown eye with the iris darkened, because the stock one
is a red-brown that reads pink under a sun lamp. Eyelashes are dropped: a 250-vert
strip that explodes under weight transfer.

`graft.py` appends that head into the thief file, aligns it to the archer head with a
3-D similarity fit on ten landmarks (8.5 mm mean residual — the two heads simply
disagree in proportion), transfers bone weights from `Thief_Body` by nearest-face
interpolation, then keeps only Head/Neck/Spine2/Spine1 and renormalises. That last
step matters: the archer file is saved in the spread-arm photo pose, and the lowest
ring of the MakeHuman neck picks up Shoulder/Arm weights from the nearest archer faces
and is dragged a metre sideways. The cut is at z = 1.46 with a 4.5 cm band pulled onto
the archer neck, all under the collar (front collar top ≈ 1.52). `Thief_Eyes` is
removed. Output: `../thief/nego_thief_mh.{blend,glb}` — 26.7k tris, 70 bones,
same skeleton as `nego_thief.glb`, so it is a drop-in replacement.

## v2 — the WhatsApp sticker (`v2/reference.png`)

Same pipeline, better source: 300 px sticker, face ~170 px wide (the first photo gave
90). `../thief/nego_thief_mh.{blend,glb}` is built from it; the first photo's version
is kept as `nego_thief_mh_v1.*`. Fit error 5.7 → 3.9 mm.

The sticker is underexposed with a blue cast, and no MPFB skin sits near the subject's
tone (the African skins are lum 0.03 linear, everything else ≥ 0.17), so toning the
photo to a base — what v1 did — gave mud, and toning the base to the photo lit the
body orange. `project_mh.py` now takes `TONE=hybrid TARGET=r,g,b` (linear): the face
is per-channel gained so its mean bare-skin colour hits TARGET (which also cancels the
cast) and the body is gained to the same value. Used `0.13,0.062,0.036`, a medium brown.

    SKIN=young_african_male TONE=hybrid TARGET=0.13,0.062,0.036 python project_mh.py <S> fit1

Inputs the sticker cannot give: the forehead (hard hat, cut at the brows as with the
hood), a neutral mouth (the grimace widened `mouth-scale-horiz` to 0.69 — inner-lip
landmarks are down-weighted but the corners are not), and a calm eye (down-weighted).

## Beard (`beard.py`)

    BEARD=1.0 python beard.py <S> fit1        # after project_mh.py, before apply_tex.py

The projected beard came through faint — the jaw is in shadow and the delighter
flattens it — so the beard is laid down as a separate pass. Three zones drawn from the
photo landmarks (moustache: nose base to upper lip; goatee: under the lower lip; jaw
strap: the face oval from ear to ear, closed by a copy pulled 42 % toward the mouth),
Gaussian-softened, lips masked out, mapped onto the head with the same affine+RBF warp
the projection uses, and allowed to wrap under the jaw (facing > −0.1). Coverage is
not a flat fill: a blurred noise field (σ 2.2 texels at 4k) gates it so hair and the
skin between hairs both survive the 2k downsample. First attempt at σ 1.2 / 55 % base
coverage averaged to a grey tint — the noise has to be coarser than the mip.
