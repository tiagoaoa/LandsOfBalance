"""Rasterise the head's UV triangles into world-position and world-normal maps."""
import sys, numpy as np
S = sys.argv[1]; name = sys.argv[2]; N = int(sys.argv[3])
V = np.load(f"{S}/{name}_verts.npy")
d = np.load(f"{S}/uvmesh.npz"); tris, uvs = d["tris"], d["uvs"]
body = np.load(f"{S}/body_mask.npy")
# per-vertex normals from the fitted mesh (area weighted)
fn = np.cross(V[tris[:, 1]] - V[tris[:, 0]], V[tris[:, 2]] - V[tris[:, 0]])
VN = np.zeros_like(V)
for k in range(3): np.add.at(VN, tris[:, k], fn)
VN /= np.linalg.norm(VN, axis=1, keepdims=True) + 1e-12
keep = body[tris].all(1) & (V[tris][:, :, 2].min(1) > 1.40)
pos = np.zeros((N, N, 3)); nrm = np.zeros((N, N, 3)); hit = np.zeros((N, N), bool)
for t, uv in zip(tris[keep], uvs[keep]):
    p = uv * N; p[:, 1] = N - p[:, 1]                      # image rows go down
    x0, y0 = np.floor(p.min(0)).astype(int); x1, y1 = np.ceil(p.max(0)).astype(int)
    x0, y0 = max(x0, 0), max(y0, 0); x1, y1 = min(x1, N - 1), min(y1, N - 1)
    if x1 < x0 or y1 < y0: continue
    xs, ys = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
    (ax, ay), (bx, by), (cx, cy) = p
    det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
    if abs(det) < 1e-12: continue
    l1 = ((bx - ax) * (ys - ay) - (by - ay) * (xs - ax)) / det   # weight of c
    l2 = ((xs - ax) * (cy - ay) - (cx - ax) * (ys - ay)) / det   # weight of b
    l0 = 1 - l1 - l2
    m = (l0 >= -0.002) & (l1 >= -0.002) & (l2 >= -0.002)
    if not m.any(): continue
    w = np.stack([l0, l2, l1], -1)[m]
    pos[ys[m].astype(int), xs[m].astype(int)] = w @ V[t]
    nrm[ys[m].astype(int), xs[m].astype(int)] = w @ VN[t]
    hit[ys[m].astype(int), xs[m].astype(int)] = True
np.savez_compressed(f"{S}/{name}_posmap.npz", pos=pos.astype(np.float32), nrm=nrm.astype(np.float32), hit=hit)
ys, xs = np.where(hit)
print("HEAD texels", hit.sum(), "uv bbox x", xs.min(), xs.max(), "y", ys.min(), ys.max())
