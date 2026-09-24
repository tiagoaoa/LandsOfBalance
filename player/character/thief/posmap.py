"""Rasterise UV triangles into world position + world normal maps.

The archer's UV islands line up with nothing anatomical, so no mask in this
folder is painted in 2D.  Everything downstream asks "where on the body does
this texel sit?" and these maps are the answer.
"""
import os
import numpy as np

SP = os.environ.get("THIEF_TMP", "/tmp/thief")


def rasterise(d, name, size=2048):
    co = d[name + "_co"].astype(np.float64)
    no = d[name + "_no"].astype(np.float64)
    uv = d[name + "_uv"]
    tl = d[name + "_tl"]
    tv = d[name + "_tv"]

    inner = d[name + "_in"] if (name + "_in") in d else np.zeros(len(co), np.float32)
    P = np.zeros((size, size, 3), np.float32)
    N = np.zeros((size, size, 3), np.float32)
    I = np.zeros((size, size), np.float32)
    M = np.zeros((size, size), np.uint8)

    tuv = uv[tl]
    px = tuv[:, :, 0] * size
    py = (1.0 - tuv[:, :, 1]) * size
    tco = co[tv]
    tno = no[tv]
    tin = inner[tv]

    for i in range(len(tl)):
        x0, x1, x2 = px[i]
        y0, y1, y2 = py[i]
        xmin = int(max(0, np.floor(min(x0, x1, x2)) - 1))
        xmax = int(min(size - 1, np.ceil(max(x0, x1, x2)) + 1))
        ymin = int(max(0, np.floor(min(y0, y1, y2)) - 1))
        ymax = int(min(size - 1, np.ceil(max(y0, y1, y2)) + 1))
        if xmax < xmin or ymax < ymin:
            continue
        X, Y = np.meshgrid(np.arange(xmin, xmax + 1) + 0.5,
                           np.arange(ymin, ymax + 1) + 0.5)
        den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
        if abs(den) < 1e-12:
            continue
        a = ((y1 - y2) * (X - x2) + (x2 - x1) * (Y - y2)) / den
        b = ((y2 - y0) * (X - x2) + (x0 - x2) * (Y - y2)) / den
        c = 1.0 - a - b
        m = (a >= -0.02) & (b >= -0.02) & (c >= -0.02)
        if not m.any():
            continue
        pos = a[..., None] * tco[i, 0] + b[..., None] * tco[i, 1] + c[..., None] * tco[i, 2]
        nor = a[..., None] * tno[i, 0] + b[..., None] * tno[i, 1] + c[..., None] * tno[i, 2]
        inn = a * tin[i, 0] + b * tin[i, 1] + c * tin[i, 2]
        P[ymin:ymax + 1, xmin:xmax + 1][m] = pos[m]
        N[ymin:ymax + 1, xmin:xmax + 1][m] = nor[m]
        I[ymin:ymax + 1, xmin:xmax + 1][m] = inn[m]
        M[ymin:ymax + 1, xmin:xmax + 1][m] = 1

    N /= np.linalg.norm(N, axis=2, keepdims=True) + 1e-9
    return P, N, I, M


def main():
    d = np.load(os.path.join(SP, "meshdata.npz"))
    for name, size in (("Thief_Body", 2048), ("Thief_Eyes", 2048), ("Thief_Clothes", 2048)):
        P, N, I, M = rasterise(d, name, size)
        np.savez_compressed(os.path.join(SP, name + "_pos.npz"), P=P, N=N, I=I, M=M)
        print(f"{name}: coverage {M.mean():.3f}")


if __name__ == "__main__":
    main()
