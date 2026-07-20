# Dragon Work Report

Session progress on the ancient dragon enemy. The dragon flies smooth
wandering closed curves around the map centre in a horizontal flight pose,
with full-body procedural animation and a constant fire breath.

## Current Behavior

- **Patrol** (rebuilt 2026-07-17): wandering closed-curve orbit around the map
  centre. The path radius and height breathe through incommensurate harmonics
  (`_orbit_radius` / `_orbit_height`), so every pass traces a different smooth
  loop; the dragon steers toward a look-ahead point with a capped turn rate
  (`MAX_TURN_RATE` 0.45 rad/s) — headings bend, never snap. One full sweep
  around the centre = one lap.
- **Flight pose**: Head points in the direction of travel, body horizontal,
  belly roughly down; the dragon now BANKS into turns (roll ∝ applied turn
  rate, composed in world space about the travel axes) and pitches gently
  with climb/sink.
- **Fire breath** (2026-07-17): the idle flame is CONTAINED in the mouth —
  low-velocity licking flames between the jaws (soft-textured additive
  billboards, emission ×16 so the beacon survives the night ACES grade).
  The `NPC Jaw_048` bone is driven at runtime (rest-composed pose write, no
  animation track conflicts): openness follows a slow noise plus flight
  effort. Fire and jet aim along the HEAD BONE's actual +X snout axis, so
  the flame follows the head wherever the neck points.
- **Hover-breath sequence** (2026-07-17): every 8–16 s the dragon brakes to
  a mid-air stop and rears upright (~43° body pitch via `_hover_blend` in
  `_face_direction`) like a hummingbird — wings keep beating (dedicated
  `WingHover` clip at 1.35× flap rate: shallower faster strokes, neck
  EXTENDED forward to cancel the body pitch, tail hanging and swinging,
  legs dangling at half-tuck) — then opens the jaw wide and blows the ~6 m
  flame jet for ~2 s before tipping over and flying on. The blast is
  PURELY VISUAL — no hitbox, no damage yet. Implemented as a sub-state of
  PATROL (`_hover_phase`), not a new network state. Mouth lights stay
  cull-mask 2 (face only).
- **Animation** (rebuilt 2026-07-17): the full body animates now. WingFlap /
  WingGlide are regenerated per-rig by composing skeleton-space deltas ON TOP
  of each bone's rest rotation (`rest_parent_global⁻¹ · R · rest_global`), so
  zero-delta equals the rest pose and nothing fights the flight-pose
  correction — the reason body tracks used to be disabled. Motion set:
  asymmetric wing stroke (42% downstroke) with distal lag, upstroke fold and
  washout twist; subtle spine/chest pitch response; neck bob wave with the
  head counter-rotated for a stabilized gaze; tail vertical wave synced to
  the flap plus slow lateral rudder sway (amplitude/delay grow to the tip);
  legs in a flight tuck with a trailing swing that follows the wing
  impulse (rest-pose legs used to dangle). Observe with
  `tools/run_combat_scenario.sh DRAGON` (night tracked-camera capture —
  matches the real game look; the fire beacon is part of what's verified).
- **Singleplayer**: Dragon spawns immediately, no server needed.

## Key Files Modified

### `enemies/dragon.gd`

- **`_compute_pose_correction()`** (new): At startup, temporarily puts the
  model at identity rotation, measures the head and tail bone positions in
  world space, and computes a correction `Basis` that rotates the resulting
  natural pose into a horizontal flight pose (head at +X, belly down). This
  adapts to the GLB's intermediate import transforms instead of hard-coding.
- **`_face_direction()`**: Now composes `yaw_basis * _pose_correction`,
  slerps the current rotation toward the target, and scales by 35. No more
  euler gymnastics.
- **`_process_patrol()`**: Simple linear patrol. Flies along
  `_patrol_direction`, reverses when `(position - patrol_center)` projected
  onto the current direction exceeds `patrol_radius`. Laps increment every
  two reversals.
- **`_get_patrol_position()`**: Returns a target point far ahead along the
  current direction at `patrol_height`.
- **`_ready()`**: Sets initial patrol state, snaps orientation, and then
  `await`s two frames before calling `_compute_pose_correction()` so the
  skeleton transforms have settled.
- **`_process_takeoff()` / `_update_mouth_fire_position()`**: Updated to use
  `basis.y` (head direction under the corrected pose) instead of the old
  `basis.x` or `-basis.z`.
- **Pitch and head anticipation disabled** to keep the body stable. Earlier
  attempts showed that dynamic pitch twists the body off-axis through the
  euler-order interaction, and head anticipation rotated neck bones with
  accumulating side effects.

### `enemies/dragon_wing_flap.gd`

- Fully rewritten (2026-07-17): every track composes skeleton-space deltas
  on the bone's rest rotation, so the whole body (wings, spine, neck, head,
  tail, legs) animates without disturbing the pose correction. 52 tracks per
  animation; `add_to_animation_player(anim_player, skeleton, name)` now needs
  the Skeleton3D to read bone rests.

### `project.godot`

- No permanent changes. A temporary `FrameCapture` autoload was added and
  later removed.

## The Core Insight

The GLB import pipeline (`Sketchfab_model/.../Skeleton3D`) inserts several
intermediate `Node3D` transforms between `DragonModel` and the actual
skeleton. Those intermediates apply their own rotation and scale, so the
**skeleton's local axes do not match the outer model node's local axes**.

That mismatch was the root cause of every prior orientation failure:

- `atan2(-dz, dx)` vs `atan2(dx, dz)`: both wrong because the head bone was
  not at model-local +Y (or +X, or any clean axis).
- Euler YXZ tricks (pitch / roll / yaw combinations): worked for head
  direction but broke belly orientation, or vice versa.
- Mesh-root rotation: interacted with the bone-local animation rotations in
  non-obvious ways because the animation's intended rotation axes were
  relative to the original rest orientation, not the rotated one.

The fix that finally worked: **measure the model's natural orientation at
runtime** (with identity rotation on the outer node) and build the correction
from that measurement. No assumptions about which local axis is "up" or
"forward" in the skeleton's internal frame.

Implementation in `_compute_pose_correction()`:

```gdscript
# Measure natural body axis in world
var natural_body := (head_world - tail_world).normalized()

# Build a canonical frame from natural_body + world up as reference
var side_ref := Vector3(0, 1, 0) if absf(natural_body.dot(Vector3.UP)) < 0.95 else Vector3(1, 0, 0)
var natural_side := natural_body.cross(side_ref).normalized()
var natural_up := natural_side.cross(natural_body).normalized()

# Desired flight pose: head at +X, belly down (back up)
var desired_body := Vector3(1, 0, 0)
var desired_up := Vector3(0, 1, 0)
var desired_side := desired_body.cross(desired_up).normalized()
desired_up = desired_side.cross(desired_body).normalized()

var natural_basis := Basis(natural_side, natural_body, natural_up)
var desired_basis := Basis(desired_side, desired_body, desired_up)
_pose_correction = desired_basis * natural_basis.inverse()
```

For this model, the measured natural body axis at identity is
`(0.9999, -0.0145, 0)` — essentially already pointing +X. The correction ends
up nearly identity, meaning the intermediate GLB transforms were already
tipping the skeleton into a mostly-horizontal pose. Earlier "upright dragon"
observations were artefacts of **my own incorrect rotations**.

## Verification

Top-down and front-view screenshots (captured via a temporary FrameCapture
autoload) confirmed:

- `head_rel = (19.16, 18.40, 0.27)` — head 19 units east of origin, body at
  Y≈18 (above CharacterBody3D origin due to the 70-unit collision offset)
- `tail_rel = (-59.61, 19.54, 0.28)` — tail 60 units west
- Body Y difference: 1.14 across ~79 units length → less than 1° from
  horizontal
- Wings visible spread left/right from body, back up, belly down

The stability also held across the animation cycle (WingFlap → WingGlide
transition). Previously the glide animation was flattening the neck with
`Quaternion.IDENTITY` tracks, causing the head bone position to drift.

## Known Remaining Issues

The user indicated more adjustments are needed. Things to look at next:

1. **Belly orientation assumption**: The pose correction builds its "up"
   vector from world Y as a reference. This happens to work for this model
   but is not a rigorous choice — a model with a different rest orientation
   could land upside-down. Consider measuring a third bone (e.g., a spine
   bone's offset from the body axis) to nail down belly vs back unambiguously.
2. **Wing flap animation is stripped down**: All body/neck/spine/tail rotation
   tracks were removed to stop them from fighting the model-level correction.
   The wings still flap, but the body is rigid. The whip effect and upstroke
   fold remain in the wing tracks but look less dynamic without the
   complementary spine/neck motion. A proper fix would rewrite
   `_add_physics_body_response()` to produce rotations in the *post-correction*
   frame, or apply them via a `SkeletonModifier3D` after the base animation.
3. **Pitch disabled**: The dragon is perfectly level, even when climbing or
   descending. Re-enabling pitch requires applying it post-correction (e.g.
   as a Basis multiply rather than an euler component) so it doesn't twist
   the yaw direction.
4. **Banking / head anticipation disabled**: Same reason — the original
   implementations were baked into the euler setup. Banking could be restored
   by rolling the model around its forward axis (post-correction). Head
   anticipation needs to be rewritten so it doesn't accumulate via
   `current_pose * head_turn` each frame.
5. **Takeoff / landing**: The takeoff state still applies a 32° pitch override
   that doesn't compose with the new basis approach; landing has similar
   concerns. These need to be ported to Basis operations.
6. **Patrol radius is huge** (`patrol_radius = 8000.0`, inherited from the
   old oval patrol). With `patrol_speed = 25`, each leg takes ~320 seconds.
   Worth lowering for testing, but it's an `@export` so configurable in
   the inspector.
7. **Collision shape offset**: The collision shape sits 70 units above the
   `CharacterBody3D` origin. This was fine for the upright rest pose but is
   a bit off-center for horizontal flight. Worth revisiting alongside any
   new pose adjustments.
8. **Character select flow**: Not tested with this dragon refactor. The dragon
   currently spawns in `lands_of_balance.tscn` directly (via the debug run);
   the normal flow via `character_select.tscn` should still work because no
   scene structure was changed, but it hasn't been verified.

## Debug Tools Used (and removed)

A temporary `FrameCapture` autoload (`enemies/_dragon_frame_capture.gd`) was
created, registered, and removed during the session. It did several things in
different iterations:

- Top-down orthographic camera following the dragon, with axis marker bars
  (red = +X, blue = +Z), a green velocity arrow, and yellow/magenta spheres
  at the head/tail bone world positions. Saved PNGs to `/tmp/dragon_frames/`.
- Side and front orthographic views with axis markers to verify belly/back
  orientation.
- Debug prints of `head_rel`, `tail_rel`, and `_model.transform.basis` per
  frame, plus the rest-pose bone skeleton-local positions at startup.
- Flat bright environment override (ignoring the night lighting manager) so
  the dragon was visible.

The MCP `editor-run` + `editor-debug-output` tools were used to launch the
project and pull logs. The visual captures were **essential** for diagnosing
the orientation bugs — pure log-based debugging gave misleading intuitions
because the skeleton-local coordinate system was rotated relative to the
model-local coordinates, and the discrepancy wasn't obvious without seeing
the dragon on screen.
