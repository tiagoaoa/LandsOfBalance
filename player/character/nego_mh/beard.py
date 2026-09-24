"""Beard pass over nego_skin_diffuse_4k.png: moustache, goatee and jaw strap zones
drawn from the photo's landmarks, mapped onto the head with the projection warp,
laid down as stubble (noise-modulated darkening, not a flat fill)."""
import sys, os, json, numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
S = sys.argv[1]; name = sys.argv[2]
STR = float(os.environ.get("BEARD", "0.85"))
def srgb2lin(c): return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def lin2srgb(c): c = np.clip(c, 0, 1); return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)
def smooth(a, b, x): t = np.clip((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)

pm = np.load(f"{S}/{name}_posmap.npz"); pos, nrm, hit = pm["pos"], pm["nrm"], pm["hit"]; N = hit.shape[0]
lm = np.array(json.load(open(f"{S}/lm_photo.json"))["pts"])[:, :2]
W, H = Image.open(f"{S}/photo_crop4x.png").size
fl = json.load(open(f"{S}/fit_landmarks.json")); vid = np.array(fl["vid"]); w = np.array(fl["w"])
V = np.load(f"{S}/{name}_verts.npy"); mx = V[vid][:, [0, 2]]
use = w > 0
A = np.c_[mx[use], np.ones(use.sum())]; aff, *_ = np.linalg.lstsq(A, lm[use], rcond=None)
SIG = 0.02
def K(a, b): return np.exp(-((a[:, None, :] - b[None, :, :]) ** 2).sum(-1) / (2 * SIG ** 2))
coef = np.linalg.solve(K(mx[use], mx[use]) + 0.3 * np.eye(use.sum()), lm[use] - A @ aff)
def warp(p):
    out = np.empty((len(p), 2))
    for i in range(0, len(p), 200000):
        q = p[i:i + 200000]; out[i:i + 200000] = np.c_[q, np.ones(len(q))] @ aff + K(q, mx[use]) @ coef
    return out

# --- zones in photo space ---------------------------------------------------------
def poly(idx):
    im = Image.new("F", (W, H), 0); ImageDraw.Draw(im).polygon([tuple(lm[i]) for i in idx], fill=1.0); return np.asarray(im)
face_w = lm[454, 0] - lm[234, 0]
mous = poly([98, 97, 2, 326, 327, 423, 391, 322, 410, 287, 0, 57, 186, 92, 165, 203])            # nose base -> upper lip
goat = poly([84, 17, 314, 405, 418, 262, 428, 199, 208, 32, 194, 181])                            # under the lower lip
# jaw strap: the oval from ear to ear along the jaw, and a copy shifted up/in to close it
jaw_idx = [132, 58, 172, 136, 150, 149, 176, 148, 152, 377, 400, 378, 379, 365, 397, 288, 361]
pts = lm[jaw_idx]; c = lm[[13, 14]].mean(0)
inner = pts + (c - pts) * 0.42
strap = np.asarray(Image.new("F", (W, H), 0))
im = Image.new("F", (W, H), 0); ImageDraw.Draw(im).polygon([tuple(p) for p in list(pts) + list(inner[::-1])], fill=1.0); strap = np.asarray(im)
# soften each zone; keep the strap lighter (stubble) than the goatee
blur = lambda a, s: ndimage.gaussian_filter(a, s)
zone = np.maximum.reduce([blur(mous, face_w * 0.02) * 1.0, blur(goat, face_w * 0.02) * 1.0, blur(strap, face_w * 0.03) * 0.9])
# no beard on the lips themselves
lips = poly([61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146])
zone *= 1 - blur(lips, face_w * 0.01)

# --- onto the head --------------------------------------------------------------------
ys, xs = np.where(hit); P = pos[ys, xs]; facing = -nrm[ys, xs][:, 1]
uv = warp(P[:, [0, 2]])
z = ndimage.map_coordinates(zone, [uv[:, 1], uv[:, 0]], order=1, mode="constant")
z *= smooth(-0.1, 0.35, facing)                       # wraps under the jaw, not onto the nape
Z = np.zeros((N, N)); Z[ys, xs] = z
rng = np.random.default_rng(7)
noise = blur(rng.random((N, N)), 2.2); noise = (noise - noise.mean()) / noise.std()
stubble = np.clip(0.8 + 0.2 * np.tanh(noise * 1.6), 0, 1)     # hair vs skin between the hairs
cover = np.clip(Z * STR * stubble, 0, 1)
img = srgb2lin(np.asarray(Image.open(f"{S}/nego_skin_diffuse_4k.png").convert("RGB"), np.float64) / 255)
hair = np.array([0.018, 0.013, 0.010])
out = img * (1 - cover[..., None]) + hair * cover[..., None]
Image.fromarray((lin2srgb(out) * 255 + 0.5).astype(np.uint8)).save(f"{S}/nego_skin_diffuse_beard_4k.png")
Image.fromarray((lin2srgb(out) * 255 + 0.5).astype(np.uint8)).resize((2048, 2048), Image.LANCZOS).save(f"{S}/nego_skin_diffuse.png")
Image.fromarray((zone * 255).astype(np.uint8)).save(f"{S}/beard_zone.png")
print("BEARD texels", int((cover > 0.2).sum()))
