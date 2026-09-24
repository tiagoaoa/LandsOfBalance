"""Build the thief's head textures by projecting NegoThief.jpg onto the head.

The previous pass painted the face with 3D masks -- flat colour zones for brows,
beard and lips.  That can place a feature correctly but it can never look
photographic, because none of the information in a photograph (pore noise,
specular breakup, the way a beard thins into skin) is in a flat fill.  This
projects the reference photograph itself and derives the normal and roughness
maps from the same pixels, so the shading agrees with the colour.

    python3 posmap.py        # first: position + normal maps from meshdata.npz
    python3 face_project.py

Writes Thief_Body_diffuse.png, Thief_Face_normal.png, Thief_Face_rough.png.
"""
import os
import numpy as np
from PIL import Image

ROOT = "/home/talves/mthings/LandsOfBalance"
HERE = os.path.join(ROOT, "player/character/thief")
SP = os.environ.get("THIEF_TMP", "/tmp/thief")
PHOTO = os.path.join(ROOT, "NegoThief.jpg")
SIZE = 2048

# --- the reference's face, in photo pixels ---------------------------------
# Read off a 8x pixel grid rendered over the crop; see README.
FACE = (509.5, 132.0, 44.0, 62.0)          # sampling ellipse: centre u, v and radii
# The hood throws a hard shadow ring around the face.  Nothing inside that ring
# can be separated from a dark feature by brightness -- the beard is darker than
# the shadowed temple -- so the lit region is declared geometrically instead,
# traced off the pixel grid at y = 84/95/110/130/150/165/180.
LIT = (509.5, 134.0, 36.0, 58.0)
LIT_N = 2.6                                # superellipse: a face is a rounded box
CARD = (440, 60, 580, 220)                 # crop worked at 4x, then sampled
CARD_K = 4

# model (x, z) in metres  ->  photo (u, v) in pixels.  The photo is an AI image
# with close-set eyes on a long lower face, so no single affine fits both the
# eyes and the nose; the warp below is affine + a Gaussian RBF on the residual.
LANDMARKS = np.array([
    (-0.036, 1.665, 492, 105),   # right eye centre
    (+0.036, 1.665, 526, 105),   # left  eye centre
    (-0.020, 1.664, 501, 107),   # right eye inner corner
    (+0.020, 1.664, 517, 107),   # left  eye inner corner
    (-0.052, 1.666, 481, 106),   # right eye outer corner
    (+0.052, 1.666, 537, 106),   # left  eye outer corner
    (-0.036, 1.680, 490,  95),   # right brow
    (+0.036, 1.680, 528,  95),   # left  brow
    (0.000, 1.681, 509,  98),    # glabella
    # No forehead landmark: the model's brow-to-hairline is much taller than the
    # strip of forehead the hood leaves visible, so pinning it bends the warp
    # hard right where the brows are and smears them.  Let the affine carry the
    # forehead up into the inpainted region instead.
    (0.000, 1.618, 509, 134),    # nose base
    (-0.026, 1.622, 488, 131),   # right ala
    (+0.026, 1.622, 530, 131),   # left  ala
    (-0.017, 1.624, 497, 130),   # right nostril
    (+0.017, 1.624, 521, 130),   # left  nostril
    (0.000, 1.596, 509, 152),    # mouth slit
    (-0.030, 1.598, 487, 151),   # right mouth corner
    (+0.030, 1.598, 531, 151),   # left  mouth corner
    (0.000, 1.583, 509, 166),    # bottom of the lower lip
    (0.000, 1.552, 509, 187),    # chin
    (-0.072, 1.632, 467, 133),   # right cheek edge
    (+0.072, 1.632, 551, 133),   # left  cheek edge
    (-0.062, 1.578, 476, 170),   # right jaw
    (+0.062, 1.578, 542, 170),   # left  jaw
], np.float64)
RBF_SIGMA = 0.030


# --------------------------------------------------------------------------
def srgb2lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin2srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def blur(a, sigma):
    """Separable Gaussian; a is (h, w) or (h, w, c)."""
    if sigma <= 0:
        return a.copy()
    r = int(max(1, round(sigma * 3)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    single = a.ndim == 2
    x = a[..., None] if single else a
    out = np.empty_like(x, np.float64)
    pad = np.pad(x, ((r, r), (0, 0), (0, 0)), mode="edge")
    acc = np.zeros_like(x, np.float64)
    for i, w in enumerate(k):
        acc += w * pad[i:i + x.shape[0]]
    pad = np.pad(acc, ((0, 0), (r, r), (0, 0)), mode="edge")
    out[:] = 0
    for i, w in enumerate(k):
        out += w * pad[:, i:i + x.shape[1]]
    return out[..., 0] if single else out


def ss(a, b, t):
    u = np.clip((t - a) / (b - a), 0.0, 1.0)
    return u * u * (3.0 - 2.0 * u)


def noise3(P, freq, seed, res=96):
    """Trilinear value noise sampled at world positions P*freq. Seamless in the
    atlas because it is a function of position, not of uv."""
    rng = np.random.default_rng(seed)
    g = rng.random((res, res, res)).astype(np.float32)
    q = P * freq
    i = np.floor(q).astype(np.int64)
    f = q - i
    f = f * f * (3 - 2 * f)
    i %= res
    i1 = (i + 1) % res
    ix, iy, iz = i[..., 0], i[..., 1], i[..., 2]
    jx, jy, jz = i1[..., 0], i1[..., 1], i1[..., 2]
    fx, fy, fz = f[..., 0], f[..., 1], f[..., 2]

    def L(a, b, t):
        return a + (b - a) * t
    c00 = L(g[ix, iy, iz], g[jx, iy, iz], fx)
    c10 = L(g[ix, jy, iz], g[jx, jy, iz], fx)
    c01 = L(g[ix, iy, jz], g[jx, iy, jz], fx)
    c11 = L(g[ix, jy, jz], g[jx, jy, jz], fx)
    return L(L(c00, c10, fy), L(c01, c11, fy), fz)


# --------------------------------------------------------------------------
def build_warp(L):
    """(x, z) metres -> (u, v) photo pixels."""
    S, T = L[:, :2], L[:, 2:]
    A = np.column_stack([S, np.ones(len(S))])
    coef, *_ = np.linalg.lstsq(A, T, rcond=None)
    res = T - A @ coef
    D2 = ((S[:, None, :] - S[None, :, :]) ** 2).sum(2)
    K = np.exp(-D2 / (2 * RBF_SIGMA ** 2))
    W = np.linalg.solve(K + 1e-3 * np.eye(len(S)), res)
    print(f"  warp: affine px/m = {coef[0,0]:.1f} (x), {coef[1,1]:.1f} (z);"
          f" residual max {np.abs(res).max():.1f} px")
    if os.environ.get("THIEF_VERBOSE"):
        for i, r in enumerate(res):
            print(f"    lm{i:02d} ({L[i,0]:+.3f},{L[i,1]:.3f}) -> ({L[i,2]:.0f},{L[i,3]:.0f})"
                  f"  residual ({r[0]:+6.1f},{r[1]:+6.1f})")

    def warp(x, z):
        u = x * coef[0, 0] + z * coef[1, 0] + coef[2, 0]
        v = x * coef[0, 1] + z * coef[1, 1] + coef[2, 1]
        for i in range(len(S)):
            g = np.exp(-((x - S[i, 0]) ** 2 + (z - S[i, 1]) ** 2) / (2 * RBF_SIGMA ** 2))
            u += g * W[i, 0]
            v += g * W[i, 1]
        return u, v
    return warp


def prepare_photo():
    """Delight the reference face and inpaint the hood shadow.

    Returns (albedo, detail) as 4x "face cards" in linear light, plus the
    card->photo mapping.  Working at 4x matters: the face is only ~90 px across
    in the source and lands on ~700 atlas texels, so anything sampled bilinearly
    straight off the jpeg arrives as mush.
    """
    full = np.asarray(Image.open(PHOTO).convert("RGB")).astype(np.float64) / 255.0
    x0, y0, x1, y1 = CARD
    K = CARD_K
    card = Image.fromarray((full[y0:y1, x0:x1] * 255).astype(np.uint8)).resize(
        ((x1 - x0) * K, (y1 - y0) * K), Image.LANCZOS)
    img = srgb2lin(np.asarray(card).astype(np.float64) / 255.0)
    h, w = img.shape[:2]

    vv, uu = np.mgrid[0:h, 0:w].astype(np.float64)
    pu, pv = x0 + uu / K, y0 + vv / K            # card px -> photo px

    cu, cv, rx, ry = LIT
    er = (np.abs((pu - cu) / rx) ** LIT_N + np.abs((pv - cv) / ry) ** LIT_N) ** (1.0 / LIT_N)
    # the hood brim cuts a hard horizontal line across the forehead; a smooth
    # superellipse cannot express that, so cut it explicitly
    trust = ss(1.06, 0.92, er) * ss(78.0, 88.0, pv)

    lum = img @ np.array([0.2126, 0.7152, 0.0722])

    # Shading is the smooth part: a quadratic in (u, v) fitted to log luminance
    # over the trusted skin.  A blur would fit the beard and the brows too and
    # then divide them straight back out again.
    # Fit on bare skin only.  Merely down-weighting the beard is not enough:
    # it is a large dark region low in the frame, so it bends the quadratic down
    # there, and dividing that out then brightens the beard back to cheek tone.
    lit = trust > 0.55
    m = lit & (lum > 0.45 * np.percentile(lum[lit], 65))
    su = (pu[m] - cu) / rx
    sv = (pv[m] - cv) / ry
    # cubic in v, quadratic in u: the hood brim darkens the forehead from above,
    # which is a vertical falloff no quadratic can follow.  The brows sit inside
    # that falloff, and they survive because the fit only sees bare skin.
    def basis(u_, v_):
        return np.column_stack([np.ones_like(u_), u_, v_, u_ * u_, u_ * v_, v_ * v_,
                                v_ ** 3, u_ * v_ * v_, u_ * u_ * v_])
    tgt = np.log(np.maximum(lum[m], 3e-4))
    coef, *_ = np.linalg.lstsq(basis(su, sv), tgt, rcond=None)
    au = np.clip((pu - cu) / rx, -1.15, 1.15)     # a cubic must not extrapolate far
    av = np.clip((pv - cv) / ry, -1.15, 1.15)
    sh = np.exp((basis(au.ravel(), av.ravel()) @ coef).reshape(au.shape))
    ref = np.exp(coef[0])
    gain = np.clip((ref / np.maximum(sh, 1e-4)) ** 1.0, 0.32, 3.2)
    alb = img * gain[..., None]

    # The key light is well off to one side, so one cheek is 2.2x the other and
    # the gain clip cannot close that.  The face is near-symmetric, so take the
    # better-lit half wherever the local half was the darker one.
    mid = int(round((509.5 - CARD[0]) * K))
    idx = np.clip(2 * mid - np.arange(w), 0, w - 1)
    shm, albm = sh[:, idx], alb[:, idx]
    ratio = sh / np.maximum(sh + shm, 1e-6)
    mw = ss(0.50, 0.33, ratio)[..., None]
    alb = alb * (1.0 - mw) + albm * mw

    skin = m
    med = np.median(alb[skin], axis=0)
    alb *= (np.array([0.082, 0.038, 0.023]) / np.maximum(med, 1e-4))[None, None, :]
    alb = np.clip(alb, 0.0, 1.0)

    # Push trusted colour outward so the shadow ring is replaced, not sampled.
    # Diffusion with the trusted region as a Dirichlet boundary -- an earlier
    # np.maximum() version biased the fill bright and left the skull paler than
    # the face, with a visible oval seam where the two met.
    keep = ss(0.40, 0.78, trust)[..., None]
    seed = np.median(alb[skin], axis=0)
    cur = alb * keep + seed[None, None, :] * (1.0 - keep)
    for sg in (48.0, 24.0, 12.0, 6.0, 3.0):
        for _ in range(3):
            cur = alb * keep + blur(cur, sg) * (1.0 - keep)
    alb = cur

    alb = np.clip(alb + 0.85 * (alb - blur(alb, 2.6)), 0.0, 1.0)   # undo jpeg softness

    # deepen features: a delit jpeg of a dark-skinned face is low-contrast, and
    # the reference's beard is ~7% of cheek luminance, not 77%
    al0 = alb @ np.array([0.2126, 0.7152, 0.0722])
    ml = np.median(al0[skin])
    alb *= ((np.maximum(al0, 1e-5) / ml) ** 0.20)[..., None]
    alb = np.clip(alb, 0.0, 1.0)

    al = alb @ np.array([0.2126, 0.7152, 0.0722])
    detail = al - blur(al, 5.0)
    return alb, detail


def card_uv(u, v):
    """photo px -> face-card px"""
    x0, y0, _, _ = CARD
    return (u - x0) * CARD_K, (v - y0) * CARD_K


def dilate(img, mask, iters=10):
    """Grow the atlas outward into the gutter.

    Blender filters across UV island borders, and a map that falls off a cliff
    at the mask edge shows the island outlines: as dark fringes in the albedo,
    and -- because the gradient there is enormous -- as bright rectangles in
    the normal map.
    """
    out = img.astype(np.float64).copy()
    m = mask.astype(np.float64)
    single = out.ndim == 2
    if single:
        out = out[..., None]
    for _ in range(iters):
        acc = np.zeros_like(out)
        cnt = np.zeros_like(m)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            acc += np.roll(np.roll(out * m[..., None], dy, 0), dx, 1)
            cnt += np.roll(np.roll(m, dy, 0), dx, 1)
        grow = (cnt > 0) & (m < 0.5)
        out[grow] = (acc[grow] / cnt[grow][..., None])
        m = np.where(grow, 1.0, m)
    return out[..., 0] if single else out


def sample(img, u, v):
    h, w = img.shape[:2]
    u = np.clip(u, 0, w - 1.001)
    v = np.clip(v, 0, h - 1.001)
    u0, v0 = np.floor(u).astype(np.int64), np.floor(v).astype(np.int64)
    fu, fv = (u - u0)[..., None], (v - v0)[..., None]
    if img.ndim == 2:
        fu, fv = fu[..., 0], fv[..., 0]
    a = img[v0, u0] * (1 - fu) + img[v0, u0 + 1] * fu
    b = img[v0 + 1, u0] * (1 - fu) + img[v0 + 1, u0 + 1] * fu
    return a * (1 - fv) + b * fv


# --------------------------------------------------------------------------
def main():
    dat = np.load(os.path.join(SP, "Thief_Body_pos.npz"))
    P, N, M = dat["P"].astype(np.float64), dat["N"].astype(np.float64), dat["M"].astype(bool)
    INNER = dat["I"].astype(np.float64) if "I" in dat else np.zeros((SIZE, SIZE))
    eye = np.load(os.path.join(SP, "Thief_Eyes_pos.npz"))
    PE, ME = eye["P"].astype(np.float64), eye["M"].astype(bool)

    alb, detail = prepare_photo()
    warp = build_warp(LANDMARKS)

    x, y, z = P[..., 0], P[..., 1], P[..., 2]
    ny = N[..., 1]

    out = np.zeros((SIZE, SIZE, 3))
    height = np.zeros((SIZE, SIZE))
    rough = np.full((SIZE, SIZE), 0.58)

    sel = M & ~ME
    u, v = warp(x[sel], z[sel])

    # clamp outside the face ellipse: the cheek colour continues around the head
    cu, cv, rx, ry = FACE
    du, dv = (u - cu) / rx, (v - cv) / ry
    r = (np.abs(du) ** LIT_N + np.abs(dv) ** LIT_N) ** (1.0 / LIT_N)
    k = np.where(r > 0.94, 0.94 / np.maximum(r, 1e-6), 1.0)
    uc, vc = cu + du * rx * k, cv + dv * ry * k

    ku, kv = card_uv(uc, vc)
    c = sample(alb, ku, kv)
    d = sample(detail, ku, kv)

    # how much of the photo to believe here: front-facing, and inside the ellipse
    face = ss(0.10, -0.50, ny[sel]) * ss(1.04, 0.76, r)
    # surfaces turning away lose light in life too
    turn = 0.55 + 0.45 * ss(0.55, -0.30, ny[sel])
    shade = turn * (0.70 + 0.30 * ss(1.500, 1.560, z[sel]))   # under the jaw is darker

    body = c * shade[..., None]
    body *= (1.0 + 0.85 * (d * face)[..., None])              # keep detail only where real

    # skin grain everywhere, so the clamped surround is not a flat fill.
    # Keep it quiet: at 2048 over a 0.28 m head these frequencies are only a few
    # texels wide, and any real amplitude turns the face into brain coral.
    pores = (noise3(P[sel], 1400.0, 7) - 0.5) * 2.0
    meso = (noise3(P[sel], 260.0, 3) - 0.5) * 2.0
    body *= (1.0 + 0.022 * pores + 0.020 * meso)[..., None]

    out[sel] = np.clip(body, 0.0, 1.0)
    height[sel] = 0.85 * (d * face) + 0.030 * pores + 0.016 * meso
    # Roughness describes what the surface IS, not where the photograph happened
    # to shine.  Deriving it from the reference's highlights baked that shoot's
    # key light in as fixed glossy patches, which read in-render as translucent
    # panes lying across the nose and cheek.
    dark = ss(0.30, 0.08, (c @ np.array([0.2126, 0.7152, 0.0722])) / 0.082)
    zz, xx = z[sel], np.abs(x[sel])
    lip = (ss(1.5775, 1.5835, zz) * ss(1.6135, 1.6075, zz) * ss(0.030, 0.018, xx))
    rough[sel] = np.clip(0.60 + 0.20 * dark * face - 0.24 * lip
                         + 0.05 * meso, 0.30, 0.82)

    # ---- eyes -------------------------------------------------------------
    if ME.any():
        side = np.sign(PE[ME][:, 0])
        side[side == 0] = 1.0
        ctr = np.stack([0.0361 * side,
                        np.full(side.shape, -0.0777),
                        np.full(side.shape, 1.6629)], 1)
        d3 = PE[ME] - ctr
        d3 /= np.linalg.norm(d3, axis=1, keepdims=True) + 1e-9
        fwd = np.stack([0.13 * side, np.full(side.shape, -1.0), np.zeros_like(side)], 1)
        fwd /= np.linalg.norm(fwd, axis=1, keepdims=True)
        ang = np.degrees(np.arccos(np.clip((d3 * fwd).sum(1), -1, 1)))

        SCLERA = np.array([0.205, 0.178, 0.163])   # warm off-white, never 1.0
        IRIS = np.array([0.026, 0.013, 0.006])
        LIMBAL = np.array([0.008, 0.006, 0.005])
        PUPIL = np.array([0.003, 0.003, 0.003])
        col = np.tile(SCLERA, (len(ang), 1))
        # veined, and shadowed under the upper lid
        vn = noise3(PE[ME], 1600.0, 11)[..., None]
        col = col * (0.88 + 0.24 * vn)
        top = ss(1.652, 1.680, PE[ME][:, 2])
        col *= (1.0 - 0.72 * top)[..., None]   # the upper lid shades the globe
        for lo, hi, c2 in ((26.5, 30.0, LIMBAL), (9.0, 26.5, IRIS), (-1.0, 9.0, PUPIL)):
            m = (ang > lo) & (ang <= hi)
            col[m] = c2
        m = (ang > 9.0) & (ang <= 26.5)          # iris fibre
        col[m] *= (0.65 + 0.9 * noise3(PE[ME][m], 2600.0, 13))[..., None]
        out[ME] = np.clip(col, 0, 1)
        rough[ME] = 0.06   # a wet eye has a small hard highlight, not a broad wash
        height[ME] = 0.0

    # The lips do not quite meet, and rather than force the geometry shut, let
    # the gap read as the dark line a closed mouth has.  Teeth catching the light
    # through a 1 mm parting is the single most artificial thing a head can do.
    inn = ss(0.15, 0.60, INNER)
    out[M] = out[M] * (1.0 - 0.94 * inn[M])[..., None]
    rough[M] = rough[M] * (1.0 - inn[M]) + 0.45 * inn[M]

    # lash line: the lid margin is the darkest part of an eye and the photo has
    # none of it, because at this scale it is under a pixel
    for sgn in (-1.0, 1.0):
        ec = np.array([sgn * 0.0361, -0.0777, 1.6629])
        dv = P[M] - ec
        rr = np.linalg.norm(dv, axis=1)
        lash = ss(0.0230, 0.0180, rr) * ss(0.0135, 0.0175, rr) * ss(-0.055, -0.070, P[M][:, 1])
        idx = np.zeros(M.shape, bool)
        idx[M] = lash > 0.01
        w2 = np.zeros(M.shape)
        w2[M] = lash
        out[idx] = out[idx] * (1.0 - 0.72 * w2[idx])[..., None]

    # ---- write ------------------------------------------------------------
    filled = M | ME
    out = dilate(out, filled)
    height = dilate(height, filled)
    rough = dilate(rough, filled)

    Image.fromarray((lin2srgb(out) * 255).round().astype(np.uint8)).save(
        os.path.join(HERE, "Thief_Body_diffuse.png"))

    hb = blur(height, 0.8)
    gu = np.gradient(hb, axis=1)
    gv = np.gradient(hb, axis=0)
    STR = 22.0
    nx, ny_, nz = -gu * STR, gv * STR, np.ones_like(hb)
    ln = np.sqrt(nx * nx + ny_ * ny_ + nz * nz)
    nm = np.stack([nx / ln, ny_ / ln, nz / ln], -1) * 0.5 + 0.5

    Image.fromarray((nm * 255).round().astype(np.uint8)).save(
        os.path.join(HERE, "Thief_Face_normal.png"))

    Image.fromarray((np.clip(rough, 0, 1) * 255).round().astype(np.uint8)).save(
        os.path.join(HERE, "Thief_Face_rough.png"))

    # Hair is not skin.  Leaving beard texels at skin specular puts a broad grey
    # sheen over black albedo, which is exactly what "plastic" looks like.
    spec_map = np.full((SIZE, SIZE), 0.45)
    spec_map[sel] = np.clip(0.45 - 0.30 * dark * face, 0.1, 0.45)
    spec_map[ME] = 0.6
    spec_map = dilate(spec_map, filled)
    Image.fromarray((spec_map * 255).round().astype(np.uint8)).save(
        os.path.join(HERE, "Thief_Face_spec.png"))
    print(f"  atlas: {sel.sum()} skin texels, {ME.sum()} eye texels")


if __name__ == "__main__":
    main()
