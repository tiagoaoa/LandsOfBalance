"""Project the delighted reference photo onto the MakeHuman head's skin texture."""
import sys, json, os, numpy as np
from PIL import Image
from scipy import ndimage
S = sys.argv[1]; name = sys.argv[2]
import glob
D = glob.glob(os.path.expanduser("~/.config/blender/5.2/extensions/.user/blender_org/mpfb/data/skins/" + os.environ.get("SKIN", "young_african_male") + "/*diffuse*.png"))[0]

def srgb2lin(c): return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def lin2srgb(c): c = np.clip(c, 0, 1); return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)
def smooth(a, b, x): t = np.clip((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)
def lum(c): return c @ np.array([0.2126, 0.7152, 0.0722])

pm = np.load(f"{S}/{name}_posmap.npz"); pos, nrm, hit = pm["pos"], pm["nrm"], pm["hit"]
N = hit.shape[0]
photo = srgb2lin(np.asarray(Image.open(f"{S}/photo_crop4x.png").convert("RGB"), np.float64) / 255)
H, W = photo.shape[:2]
lm = np.array(json.load(open(f"{S}/lm_photo.json"))["pts"])[:, :2]
fl = json.load(open(f"{S}/fit_landmarks.json")); vid = np.array(fl["vid"]); w = np.array(fl["w"])
V = np.load(f"{S}/{name}_verts.npy")
mx = V[vid][:, [0, 2]]                                  # model landmarks (x, z)

# --- model (x,z) -> photo (u,v): affine + Gaussian RBF on the residual ---------
use = w > 0
A = np.c_[mx[use], np.ones(use.sum())]
aff, *_ = np.linalg.lstsq(A, lm[use], rcond=None)
res = lm[use] - A @ aff
SIG = 0.02
def K(a, b): return np.exp(-((a[:, None, :] - b[None, :, :]) ** 2).sum(-1) / (2 * SIG ** 2))
coef = np.linalg.solve(K(mx[use], mx[use]) + 0.3 * np.eye(use.sum()), res)
def warp(p):
    out = np.empty((len(p), 2))
    for i in range(0, len(p), 200000):
        q = p[i:i + 200000]
        out[i:i + 200000] = np.c_[q, np.ones(len(q))] @ aff + K(q, mx[use]) @ coef
    return out
chk = np.linalg.norm(warp(mx[use]) - lm[use], axis=1)
print(f"warp residual at landmarks: mean {chk.mean():.2f} px (4x crop)")

# --- photo-space masks from the landmarks -------------------------------------
OVAL = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377,
        152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
LEYE = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
REYE = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
LBROW = [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]; RBROW = [300, 293, 334, 296, 336, 285, 295, 282, 283, 276]
from PIL import ImageDraw
def poly_mask(idx, grow=0):
    im = Image.new("L", (W, H), 0); ImageDraw.Draw(im).polygon([tuple(lm[i]) for i in idx], fill=255)
    m = np.asarray(im) > 0
    return ndimage.binary_dilation(m, iterations=grow) if grow > 0 else m
oval = poly_mask(OVAL)
eye_y = lm[[33, 133, 362, 263], 1].mean(); brow_y = lm[LBROW + RBROW, 1].mean()
nose_base_y = lm[[2, 98, 327], 1].mean(); mouth_y = lm[[13, 14], 1].mean()
hood_y = brow_y - 0.7 * (eye_y - brow_y)
print(f"photo rows: hood {hood_y:.0f} brow {brow_y:.0f} eye {eye_y:.0f} nose {nose_base_y:.0f} mouth {mouth_y:.0f}")
yy, xx = np.mgrid[0:H, 0:W]
eyes = poly_mask(LEYE, 6) | poly_mask(REYE, 6)
brows = poly_mask(LBROW, 5) | poly_mask(RBROW, 5)
skin = oval & (yy > hood_y + 4) & (yy < nose_base_y) & ~eyes & ~brows
# the nose flanks/nostrils are shadowed: drop the darkest 15% of candidate pixels
L = lum(photo)
thr = np.percentile(L[skin], 15); skin &= L > thr
print("skin pixels for the shading fit:", int(skin.sum()))

# --- delight: quadratic log-luminance shading fitted on skin only -----------------
u, v = (xx - W / 2) / W, (yy - H / 2) / H
B = np.stack([np.ones_like(u), u, v, u * u, u * v, v * v], -1)
c, *_ = np.linalg.lstsq(B[skin], np.log(L[skin] + 1e-4), rcond=None)
shade = np.exp(B @ c)
gain = np.clip(np.exp(c[0]) / shade, 0.55, 2.2)          # 1.0 at the centre
delit = np.clip(photo * gain[..., None], 0, 1)
lr = lum(delit)[skin & (xx < W / 2)].mean() / lum(delit)[skin & (xx > W / 2)].mean()
print(f"left/right skin balance after delight: {lr:.2f}")

# usable photo region: inside the oval, below the hood, feathered
dist_in = ndimage.distance_transform_edt(oval & (yy > hood_y))
pmask = smooth(0, 14, dist_in)

# --- sample the photo for every head texel ----------------------------------------
ys, xs = np.where(hit)
P = pos[ys, xs]; Nn = nrm[ys, xs]
facing = -Nn[:, 1]                                          # camera looks along +Y
uv = warp(P[:, [0, 2]])
uvm = warp(np.c_[-P[:, 0], P[:, 2]])                        # mirrored twin
def samp(img, uv):
    return np.stack([ndimage.map_coordinates(img[..., k], [uv[:, 1], uv[:, 0]], order=1, mode="nearest") for k in range(3)], -1)
col = samp(delit, uv); colm = samp(delit, uvm)
inside = ndimage.map_coordinates(pmask, [uv[:, 1], uv[:, 0]], order=1, mode="constant")
insidem = ndimage.map_coordinates(pmask, [uvm[:, 1], uvm[:, 0]], order=1, mode="constant")
# where this side is the darker one, lean on the mirrored side
darker = lum(col) < 0.8 * lum(colm)
mixw = np.where(darker & (insidem > 0.5), 0.6, 0.0)
col = col * (1 - mixw[:, None]) + colm * mixw[:, None]
brow_z = V[vid][LBROW + RBROW, 2].mean(); ear_x = np.abs(V[vid][[234, 454], 0]).mean()
eye_in = poly_mask(LEYE) | poly_mask(REYE)
eye_t = ndimage.map_coordinates(eye_in.astype(float), [uv[:, 1], uv[:, 0]], order=1, mode='constant')
m = inside * smooth(0.45, 0.85, facing) * (1 - smooth(brow_z - 0.004, brow_z + 0.012, P[:, 2])) \
    * (1 - smooth(ear_x * 0.55, ear_x * 0.8, np.abs(P[:, 0]))) * (1 - eye_t)

# --- compose onto the base skin, tone-matched to the photo -----------------------
base = srgb2lin(np.asarray(Image.open(D).convert("RGB").resize((N, N), Image.LANCZOS), np.float64) / 255)
photo_tone = delit[skin].mean(0)
skin_t = ndimage.map_coordinates(skin.astype(float), [uv[:, 1], uv[:, 0]], order=0, mode='constant') > 0.5
sel = skin_t & (m > 0.5)
base_tone = base[ys[sel], xs[sel]].mean(0); photo_tone = col[sel].mean(0)
TONE = os.environ.get("TONE", "base")
if TONE == "base":
    tone_gain = np.clip(base_tone / photo_tone, 0.2, 2.0); body_gain = np.ones(3)
else:
    # hybrid: the base skin's hue (kills the photo's colour cast) at the photo's
    # brightness, lifted by LIFT for an underexposed source; the body follows
    LIFT = float(os.environ.get("LIFT", "1.3"))
    T = base_tone / lum(base_tone) * lum(photo_tone) * LIFT
    if os.environ.get("TARGET"):                      # explicit linear-RGB skin tone
        T = np.array([float(x) for x in os.environ["TARGET"].split(",")])
    tone_gain = np.clip(T / photo_tone, 0.2, 4.0); body_gain = np.clip(T / base_tone, 0.3, 6.0)
print("tone gain face:", tone_gain.round(2), "body:", body_gain.round(2))
col = np.clip(col * tone_gain, 0, 1); out = np.clip(base * body_gain, 0, 1)
proj = np.zeros((N, N, 3)); M = np.zeros((N, N))
proj[ys, xs] = col; M[ys, xs] = m
# dilate colour and mask ~8 texels into the UV gutters so filtering never sees a cliff
has = np.zeros((N, N), bool); has[ys, xs] = True
_, (iy, ix) = ndimage.distance_transform_edt(~has, return_indices=True)
near = ndimage.distance_transform_edt(~has) <= 8
proj[near] = proj[iy[near], ix[near]]; M[near] = M[iy[near], ix[near]]
out = out * (1 - M[..., None]) + proj * M[..., None]
Image.fromarray((lin2srgb(out) * 255 + 0.5).astype(np.uint8)).save(f"{S}/nego_skin_diffuse_4k.png")
Image.fromarray((lin2srgb(out) * 255 + 0.5).astype(np.uint8)).resize((2048, 2048), Image.LANCZOS).save(f"{S}/nego_skin_diffuse.png")
Image.fromarray((lin2srgb(delit) * 255 + 0.5).astype(np.uint8)).save(f"{S}/photo_delit.png")
Image.fromarray((M * 255).astype(np.uint8)).resize((1024, 1024)).save(f"{S}/proj_mask.png")
print("WROTE nego_skin_diffuse.png; projected texels", int((m > 0.5).sum()))
