"""Repair and reshape the head toward NegoThief.jpg.

Run inside Blender:  blender -b nego_thief.blend --python head_sculpt.py

Earlier passes left the head damaged: a hard crease running from the outer eye
corner down across the cheek to the jaw, and lips squashed into a flat letterbox
slit with no vermilion at all.  No texture can hide either, so this smooths the
surface first and then rebuilds the features it needs.

All of it is world-space vertex movement on Thief_Body.  The rest pose and the
vertex groups are untouched, so the Mixamo rig keeps matching.  Every weight is
gated on x AND y AND z at once -- a weight banded only in z has twice silently
scaled this character's whole torso.
"""
import bmesh
import bpy
import numpy as np
from mathutils import Vector

EYE_C = np.array([0.0361, -0.0777, 1.6629])   # eyeball centre, mirrored in x
EYE_R = 0.0183
EYE_SHRINK = 0.82

# measured landmarks, world mm (see README)
# eye 1665   brow 1680   nose base 1618   mouth 1596   chin tip 1552


def ss(a, b, t):
    """smoothstep from a to b evaluated at t; works when a > b (descending)."""
    u = np.clip((t - a) / (b - a), 0.0, 1.0)
    return u * u * (3.0 - 2.0 * u)


def smooth_weight(co):
    """1 where the surface should be relaxed, 0 on features worth keeping."""
    x, y, z = co[:, 0], co[:, 1], co[:, 2]
    ax = np.abs(x)
    w = ss(1.500, 1.530, z) * ss(1.790, 1.740, z)

    # keep the nose
    nose = ss(1.600, 1.614, z) * ss(1.672, 1.652, z) * ss(0.036, 0.020, ax) * ss(-0.086, -0.104, y)
    # The mouth is NOT protected.  It arrived as a flat letterbox slit with a
    # hard quad ledge across the chin, and the lips are rebuilt analytically
    # below, so it is cheaper to relax the whole thing flat first.
    # keep the eye openings
    eye = np.zeros_like(z)
    for s in (-1.0, 1.0):
        d = np.linalg.norm(co - np.array([s * EYE_C[0], EYE_C[1], EYE_C[2]]), axis=1)
        eye = np.maximum(eye, ss(0.030, 0.016, d))
    # keep the ears
    ear = ss(0.070, 0.082, ax) * ss(1.600, 1.620, z) * ss(1.700, 1.680, z)
    return np.clip(w * (1.0 - np.maximum.reduce([nose, eye, ear])), 0.0, 1.0)


def relax(ob, iters=16, factor=0.60):
    """Masked Laplacian smoothing -- this is what removes the cheek crease."""
    me = ob.data
    M = np.array(ob.matrix_world)
    R, t = M[:3, :3], M[:3, 3]
    Rinv = np.linalg.inv(R)

    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    co = np.array([v.co for v in bm.verts], np.float64)
    world = co @ R.T + t
    w = smooth_weight(world) * factor

    nbr = [[e.other_vert(v).index for e in v.link_edges] for v in bm.verts]
    for _ in range(iters):
        avg = np.array([world[n].mean(0) if n else world[i]
                        for i, n in enumerate(nbr)])
        world = world + (avg - world) * w[:, None]
    print(f"  relax: {int((w > 0).sum())} verts touched")

    co = (world - t) @ Rinv.T
    for v, c in zip(bm.verts, co):
        v.co = Vector(c)
    bm.to_mesh(me)
    bm.free()
    me.update()


def sculpt(co):
    x, y, z = co[:, 0], co[:, 1], co[:, 2]
    ax = np.abs(x)
    d = np.zeros_like(co)

    # 1. the nose.  Broaden it, then give it a tip and alae -- it arrived as a
    #    smooth wedge, and a wedge under a photographic texture reads as a blob.
    w = (ss(1.604, 1.616, z) * ss(1.652, 1.640, z)
         * ss(-0.088, -0.104, y)
         * ss(0.034, 0.020, ax))
    d[:, 0] += x * 0.30 * w
    front_n = ss(-0.090, -0.106, y)

    def blob(cx, cz, sx, sz, amp):
        return amp * np.exp(-0.5 * (((ax - cx) / sx) ** 2 + ((z - cz) / sz) ** 2))

    d[:, 1] += -(blob(0.000, 1.6285, 0.0105, 0.0075, 0.0030)     # tip bulb
                 + blob(0.0195, 1.6240, 0.0070, 0.0058, 0.0024)  # alae
                 - blob(0.0105, 1.6205, 0.0042, 0.0034, 0.0026)  # nostril crease
                 - blob(0.000, 1.6165, 0.0075, 0.0030, 0.0012)   # under the septum
                 ) * front_n
    d[:, 0] += np.sign(x) * blob(0.0195, 1.6240, 0.0070, 0.0058, 0.0016) * front_n

    # 2. lips.  The mouth is a flat slit; give it vermilion.  Smoothstep bands
    #    build a rectangular shelf here -- a mouth is lobes, so use Gaussians.
    def lobe(cz, sx, sz, amp, bow=0.0):
        g = np.exp(-0.5 * ((x / sx) ** 2 + ((z - cz) / sz) ** 2))
        return amp * g * (1.0 - bow * np.exp(-0.5 * (x / 0.007) ** 2))

    front = ss(-0.082, -0.096, y)
    bulge = (lobe(1.6045, 0.0205, 0.0050, 0.0042, bow=0.32)    # upper vermilion
             + lobe(1.5860, 0.0195, 0.0058, 0.0058)            # lower, the fuller one
             - lobe(1.5960, 0.0230, 0.0023, 0.0010)            # the slit; deeper than
             #   this and the lips part and the teeth show through
             - lobe(1.5745, 0.0230, 0.0055, 0.0022))           # mentolabial crease
    d[:, 1] += -bulge * front

    # 3. chin: it juts further forward than the nose tip, which is wrong
    w = (ss(1.528, 1.542, z) * ss(1.580, 1.566, z)
         * ss(-0.100, -0.112, y) * ss(0.050, 0.034, ax))
    d[:, 1] += 0.0080 * w

    # 4. eyelids: the aperture is a wide round hole, so sclera shows all round
    #    the iris and he reads as a startled doll.  Close it from below mostly --
    #    the reference's eyes ARE wide, but the iris sits up against the top lid.
    for sgn in (-1.0, 1.0):
        c = np.array([sgn * EYE_C[0], EYE_C[1], EYE_C[2]])
        r = np.linalg.norm(co - c, axis=1)
        w = ss(0.031, 0.015, r) * ss(-0.052, -0.066, y)
        below = z < EYE_C[2]
        d[:, 2] += np.where(below, (EYE_C[2] - z) * 0.34, -(z - EYE_C[2]) * 0.16) * w

    # 5. the mouth sits ~5 mm high
    w = (ss(1.588, 1.596, z) * ss(1.616, 1.606, z)
         * ss(-0.092, -0.102, y) * ss(0.042, 0.028, ax))
    d[:, 2] += -0.0035 * w
    return d


def shrink_eyes(ob):
    """The eyeballs are 36.6 mm across -- half again the size of a real one --
    so they bulge past the lids and the face reads as a startled doll.  Shrink
    them about their own centres; the lid opening is left alone."""
    me = ob.data
    M = np.array(ob.matrix_world)
    R, t = M[:3, :3], M[:3, 3]
    Rinv = np.linalg.inv(R)
    n = len(me.vertices)
    loc = np.empty(n * 3, np.float32)
    me.vertices.foreach_get("co", loc)
    world = loc.reshape(n, 3).astype(np.float64) @ R.T + t
    for s_ in (-1.0, 1.0):
        c = np.array([s_ * EYE_C[0], EYE_C[1], EYE_C[2]])
        sel = np.sign(world[:, 0]) == s_
        world[sel] = c + (world[sel] - c) * EYE_SHRINK
    me.vertices.foreach_set("co", ((world - t) @ Rinv.T).astype(np.float32).ravel())
    me.update()
    print(f"  eyes scaled {EYE_SHRINK:.2f} -> radius {EYE_R*EYE_SHRINK*1000:.1f} mm")


def main():
    shrink_eyes(bpy.data.objects["Thief_Eyes"])
    ob = bpy.data.objects["Thief_Body"]
    relax(ob)

    me = ob.data
    M = np.array(ob.matrix_world)
    R, t = M[:3, :3], M[:3, 3]
    Rinv = np.linalg.inv(R)

    n = len(me.vertices)
    loc = np.empty(n * 3, np.float32)
    me.vertices.foreach_get("co", loc)
    world = loc.reshape(n, 3).astype(np.float64) @ R.T + t

    d = sculpt(world)

    box = (world[:, 2] > 1.50) & (world[:, 2] < 1.72) & (np.abs(world[:, 0]) < 0.075)
    moved = np.linalg.norm(d, axis=1) > 1e-9
    stray = moved & ~box
    assert not stray.any(), f"{stray.sum()} verts moved outside the face box"
    print(f"  sculpt: moved {moved.sum()} / {n} verts, max {np.linalg.norm(d, axis=1).max()*1000:.2f} mm")

    me.vertices.foreach_set("co", ((world + d - t) @ Rinv.T).astype(np.float32).ravel())
    me.update()


if __name__ == "__main__":
    main()
