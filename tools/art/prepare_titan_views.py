"""Cut the lizard-titan turnaround into the views the 3D generators take.

Source: 'Ancient lizard titan turnaround sheet.png' (2x2: front, left side,
back, three-quarter on flat grey). Each panel is cropped, its corner label is
painted over with the panel's own background, and it is padded to a square.
Hunyuan3D-2mv also wants a right view: the left side, mirrored.
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'tools/art/reference/lizard_titan'
SHEET = OUT / 'turnaround.png'
PANELS = {   # x0, y0, x1, y1 inside the sheet; label box is panel-local
    'front': ((0, 0, 766, 498), (0, 0, 140, 42)),
    'left': ((770, 0, 1536, 498), (0, 0, 140, 42)),
    'back': ((0, 502, 766, 1024), (0, 0, 140, 42)),
    'three_quarter': ((770, 502, 1536, 1024), (0, 0, 200, 42)),
}


def square(image, bg):
    side = max(image.size)
    canvas = Image.new('RGB', (side, side), bg)
    canvas.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    return canvas


def cutout(path, tolerance=34):
    """The view with its flat grey backdrop made transparent: a flood fill
    from the border over everything near the backdrop's colour, so the
    creature's own greys survive. TRELLIS.2 then skips its background
    remover (briaai/RMBG-2.0 is gated and non-commercial)."""
    from PIL import ImageFilter
    rgb = Image.open(path).convert('RGB')
    w, h = rgb.size
    mask = rgb.copy()
    key = (255, 0, 255)
    #Seeds all round the border: the square padding's grey differs a little
    #from the panel's own.
    seeds = [(x, y) for x in range(0, w, 16) for y in (0, h - 1)] + \
            [(x, y) for y in range(0, h, 16) for x in (0, w - 1)]
    for seed in seeds:
        if mask.getpixel(seed) != key:
            ImageDraw.floodfill(mask, seed, key, thresh=tolerance)
    px = mask.load()
    alpha = Image.new('L', (w, h), 255)
    ap = alpha.load()
    for y in range(h):
        for x in range(w):
            if px[x, y] == key:
                ap[x, y] = 0
    #Keep the creature: the largest opaque island. Floor shadow strips and
    #padding seams left over read as a slab under its feet.
    import numpy as np
    from collections import deque
    a = np.array(alpha) > 0
    seen = np.zeros_like(a)
    best = None
    for y0, x0 in zip(*np.nonzero(a)):
        if seen[y0, x0]:
            continue
        q = deque([(y0, x0)])
        seen[y0, x0] = True
        comp = []
        while q:
            y, x = q.popleft()
            comp.append((y, x))
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and a[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    q.append((ny, nx))
        if best is None or len(comp) > len(best):
            best = comp
    keep = np.zeros_like(a)
    for y, x in best:
        keep[y, x] = True
    #The floor shadow clings to the feet: near the bottom of the figure, pale
    #grey is shadow, the creature's hide there is darker.
    ys = np.nonzero(keep.any(axis=1))[0]
    floor = ys.max() - int((ys.max() - ys.min()) * 0.12)
    px_rgb = np.array(rgb).astype(int)
    lum = px_rgb.mean(axis=2)
    sat = px_rgb.max(axis=2) - px_rgb.min(axis=2)
    shadow = (lum > 100) & (sat < 14)
    shadow[:floor] = False
    keep &= ~shadow
    #Backdrop enclosed by the body (between the legs, inside the tail's curve)
    #is out of the border flood's reach: clear any large flat patch of the
    #backdrop's colour. The hide is textured, so it never makes one.
    back = np.array(rgb.getpixel((2, 2)), dtype=int)
    near = (np.abs(px_rgb - back).max(axis=2) < 16) & keep
    seen = np.zeros_like(near)
    for y0, x0 in zip(*np.nonzero(near)):
        if seen[y0, x0]:
            continue
        q = deque([(y0, x0)])
        seen[y0, x0] = True
        comp = []
        while q:
            y, x = q.popleft()
            comp.append((y, x))
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and near[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    q.append((ny, nx))
        if len(comp) > 1500:
            for y, x in comp:
                keep[y, x] = False
    alpha = Image.fromarray((keep * 255).astype(np.uint8))
    alpha = alpha.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.2))
    out = rgb.convert('RGBA')
    out.putalpha(alpha)
    return out


def main():
    sheet = Image.open(SHEET).convert('RGB')
    meta = {}
    for name, (box, label) in PANELS.items():
        panel = sheet.crop(box)
        bg = panel.getpixel((panel.width - 6, panel.height // 2))
        ImageDraw.Draw(panel).rectangle(label, fill=bg)
        out = square(panel, bg)
        out.save(OUT / (name + '.png'))
        meta[name] = {'box': box, 'label_painted': label, 'background': bg}
    right = ImageOps.mirror(Image.open(OUT / 'left.png'))
    right.save(OUT / 'right.png')
    for name in list(PANELS) + ['right']:
        cutout(OUT / (name + '.png')).save(OUT / (name + '_rgba.png'))
    meta['right'] = 'left.png mirrored (the sheet has no right side view)'
    (OUT / 'views.json').write_text(json.dumps(meta, indent=2) + '\n')
    print('VIEWS', sorted(p.name for p in OUT.glob('*.png')))


if __name__ == '__main__':
    main()
