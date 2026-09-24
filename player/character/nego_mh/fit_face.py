"""Fit MPFB face targets so the MakeHuman head's landmarks match the photo's.

Both images were run through the same landmarker, so landmark i on the render and
landmark i on the photo are the same anatomical point.  Render landmarks are mapped
to mesh vertices through the orthographic camera; the photo's are aligned to the
model by a similarity transform; then the target weights are a bounded linear least
squares problem, because every target is an additive vertex offset.
"""
import sys, os, json, gzip, glob, numpy as np
from scipy.optimize import lsq_linear
S = sys.argv[1]
T = os.path.expanduser("~/.config/blender/5.2/extensions/blender_org/mpfb/data/targets")
SCALE = 0.1
CATS = ["cheek", "chin", "eyebrows", "eyes", "forehead", "head", "mouth", "nose"]
SKIP = ("age", "bag", "eye-height", "temple")         # expression-like or hidden by the hood
RIDGE = float(os.environ.get("RIDGE", "0.02"))

cam = json.load(open(f"{S}/base_cam.json"))
V = np.load(f"{S}/base_verts.npy")                     # evaluated base, metres
lm_r = np.array(json.load(open(f"{S}/lm_base.json"))["pts"])[:, :2]
lm_p = np.array(json.load(open(f"{S}/lm_photo.json"))["pts"])[:, :2]

# --- render pixel -> model (x, z), then nearest front-facing vertex --------
res, os_ = cam["res"], cam["ortho"]
xz = np.stack([(lm_r[:, 0] / res - 0.5) * os_, cam["cz"] - (lm_r[:, 1] / res - 0.5) * os_], 1)
head = np.where(V[:, 2] > 1.45)[0]
Vh = V[head]
vid = np.empty(len(xz), int)
for i, (x, z) in enumerate(xz):
    d = np.hypot(Vh[:, 0] - x, Vh[:, 2] - z)
    cand = np.where(d < 0.006)[0]
    if len(cand) == 0:
        cand = np.argsort(d)[:6]
    vid[i] = head[cand[np.argmin(Vh[cand, 1])]]      # frontmost (-Y is forward)

# --- which landmarks to trust ---------------------------------------------
LEYE = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
REYE = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
INNER_LIP = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191]
brow_y = lm_p[[70, 63, 105, 66, 107, 336, 296, 334, 293, 300], 1].mean()
w = np.ones(478)
w[468:] = 0                                            # irises
w[LEYE + REYE] = 0.15                                  # wide-open eyes are expression
w[[33, 133, 362, 263]] = 1.0                           # ...but corners are shape
w[INNER_LIP] = 0.2
w[lm_p[:, 1] < brow_y - 0.06 * (lm_p[:, 1].max() - lm_p[:, 1].min())] = 0   # under the hood
use = w > 0

# --- targets as a linear system ---------------------------------------------
names, cols = [], []
for c in CATS:
    for f in sorted(glob.glob(f"{T}/{c}/*.target.gz")):
        n = os.path.basename(f)[:-len(".target.gz")]
        if any(s in n for s in SKIP) or n.startswith(("l-", "r-")) and False:
            continue
        D = np.zeros((len(V), 3))
        for line in gzip.open(f, "rt"):
            p = line.split()
            if len(p) == 4 and not line.startswith("#"):
                D[int(p[0])] = (float(p[1]), -float(p[3]), float(p[2]))
        D *= SCALE
        col = D[vid][:, [0, 2]]                        # landmark vertices' (x, z) shift
        if np.abs(col).max() > 1e-5:
            names.append(n); cols.append(col)
A = np.stack(cols, -1)                                 # (478, 2, n)
print("targets", len(names))

# --- alternate: align photo to model, solve weights ---------------------------
def procrustes(src, dst, wt):
    m = wt > 0
    s, d = src[m], dst[m]
    sc, dc = s.mean(0), d.mean(0)
    s0, d0 = s - sc, d - dc
    U, _, Vt = np.linalg.svd(s0.T @ d0)
    R = U @ Vt
    if np.linalg.det(R) < 0:
        Vt[-1] *= -1; R = U @ Vt
    k = (s0 @ R * d0).sum() / (s0 ** 2).sum()
    return lambda p: (p - sc) @ R * k + dc

P0 = V[vid][:, [0, 2]]
ph = lm_p * [1, -1]                                    # image y down -> model z up
x = np.zeros(len(names))
for it in range(4):
    cur = P0 + np.einsum("ijk,k->ij", A, x)
    tf = procrustes(ph, cur, w)
    tgt = tf(ph)
    r = (tgt - P0)[use].ravel()
    M = A[use].reshape(-1, len(names))
    sw = np.repeat(np.sqrt(w[use]), 2)
    Mr = np.vstack([M * sw[:, None], RIDGE * np.eye(len(names))])
    rr = np.concatenate([r * sw, np.zeros(len(names))])
    x = lsq_linear(Mr, rr, bounds=(0, 1), lsmr_tol="auto").x
    fit = P0 + np.einsum("ijk,k->ij", A, x)
    err = np.linalg.norm((fit - tgt)[use], axis=1)
    print(f"iter {it}: mean err {err.mean()*1000:.2f} mm, max {err.max()*1000:.1f} mm, "
          f"active {int((x > 0.01).sum())}, sum |w| {x.sum():.1f}")
base_err = np.linalg.norm((P0 - tgt)[use], axis=1).mean() * 1000
print(f"baseline err {base_err:.2f} mm")
out = {n: float(v) for n, v in zip(names, x) if v > 0.01}
json.dump(out, open(f"{S}/fit_weights.json", "w"), indent=1)
json.dump({"vid": vid.tolist(), "w": w.tolist(), "tgt": tgt.tolist()}, open(f"{S}/fit_landmarks.json", "w"))
for n, v in sorted(out.items(), key=lambda kv: -kv[1])[:25]:
    print(f"  {v:.2f} {n}")
