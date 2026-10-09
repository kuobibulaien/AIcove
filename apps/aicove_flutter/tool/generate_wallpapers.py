"""Generate the global wallpaper sets in assets/wallpapers (light + dark).

Usage: python3 tool/generate_wallpapers.py assets/wallpapers  (needs pillow, numpy, scipy)
"""
import sys
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

OUT = sys.argv[1]
W = H = 1600
LW = LH = 400  # paint at low res, upscale -> perfectly smooth fields


def hexc(h):
    h = h.lstrip('#')
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.float64) / 255


SETS = {
    'mist': {
        'light': dict(top='#F3F6F8', bottom='#E6ECF1',
                      blobs=['#BFD1E3', '#CFDCCF', '#DAD3E8', '#C7DAE3'],
                      silk='#FFFFFF', shadow='#C9D3DD'),
        'dark': dict(top='#161B21', bottom='#10141A',
                     blobs=['#2B3D52', '#2A3B33', '#383249', '#26404A'],
                     silk='#3A4A5C', shadow='#0B0E12'),
    },
    'apricot': {
        'light': dict(top='#F8F3EC', bottom='#F1E8DD',
                      blobs=['#F2D5BF', '#EDCFCD', '#E8DEC6', '#F0DCCB'],
                      silk='#FFFDF9', shadow='#E2D2C1'),
        'dark': dict(top='#1C1815', bottom='#15110F',
                     blobs=['#4B3628', '#47302F', '#3F392A', '#4A3A2E'],
                     silk='#4E3F34', shadow='#0E0B09'),
    },
}

# slot -> (blobs: (x, y, radius, color index, strength), silk: (y0, amp, freq, phase, tilt, width, strength))
LAYOUTS = {
    1: dict(blobs=[(0.15, 0.12, 0.45, 0, 0.85), (0.9, 0.85, 0.5, 1, 0.8), (0.75, 0.3, 0.3, 2, 0.5)],
            folds=[(0.55, 0.06, 0.8, 0.4, -0.2, 0.02, 0.7), (0.75, 0.05, 1.0, 2.0, -0.15, 0.025, 0.55)]),
    2: dict(blobs=[(0.85, 0.05, 0.4, 3, 0.55), (0.1, 0.95, 0.45, 2, 0.55)],
            folds=[(0.86, 0.035, 0.7, 1.6, -0.08, 0.025, 0.45)]),
    3: dict(blobs=[(0.92, 0.1, 0.5, 1, 0.75), (0.05, 0.55, 0.38, 0, 0.55), (0.6, 1.0, 0.45, 3, 0.6)],
            folds=[(0.3, 0.05, 0.9, 2.4, 0.18, 0.02, 0.6), (0.68, 0.04, 0.7, 4.0, 0.1, 0.03, 0.45)]),
    4: dict(blobs=[(0.5, 0.45, 0.55, 2, 0.6), (0.1, 0.1, 0.35, 0, 0.55), (0.95, 0.9, 0.4, 1, 0.65)],
            folds=[(0.42, 0.08, 0.75, 0.0, -0.3, 0.022, 0.7), (0.62, 0.06, 0.85, 1.3, -0.25, 0.028, 0.6),
                   (0.8, 0.04, 0.9, 2.6, -0.2, 0.035, 0.45)]),
}


def render(palette, layout, seed):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:LH, 0:LW] / np.array([LH, LW]).reshape(2, 1, 1)[:, :, :]
    top, bottom = hexc(palette['top']), hexc(palette['bottom'])
    img = top[None, None] * (1 - y[..., None]) + bottom[None, None] * y[..., None]
    for bx, by, r, ci, k in layout['blobs']:
        d2 = (x - bx) ** 2 + (y - by) ** 2
        a = k * np.exp(-d2 / (2 * (r * 0.55) ** 2))
        c = hexc(palette['blobs'][ci])
        img = img * (1 - a[..., None]) + c[None, None] * a[..., None]
    silk = hexc(palette['silk'])
    shadow = hexc(palette['shadow'])
    for y0, amp, freq, ph, tilt, soft, k in layout['folds']:
        center = y0 + tilt * (x - 0.5) + amp * np.sin(2 * np.pi * freq * x + ph)
        t = (y - center) / soft
        # below the fold: a faint shadowed layer; right at the edge: a soft sheen
        below = 1 / (1 + np.exp(-t))
        sheen = np.exp(-((t + 1.2) / 1.6) ** 2)
        a = k * 0.45 * below * np.exp(-np.clip(t, 0, None) / 6)
        img = img * (1 - a[..., None]) + shadow[None, None] * a[..., None]
        a = k * sheen
        img = img * (1 - a[..., None]) + silk[None, None] * a[..., None]
    img = np.stack([gaussian_filter(img[..., i], 2.5) for i in range(3)], -1)
    chans = []
    for i in range(3):
        ch = Image.fromarray((np.clip(img[..., i], 0, 1) * 255).astype(np.float32), 'F')
        chans.append(np.asarray(ch.resize((W, H), Image.BICUBIC)))
    hi = np.stack(chans, -1)
    hi += rng.normal(0, 1.1, hi.shape[:2])[..., None]  # fine grain against banding
    return Image.fromarray(np.clip(hi, 0, 255).astype(np.uint8), 'RGB')


for name, modes in SETS.items():
    for mode, palette in modes.items():
        for slot, layout in LAYOUTS.items():
            im = render(palette, layout, seed=slot)
            im.save(f'{OUT}/{name}_{slot}_{mode}.webp', quality=82, method=6)
print('ok')
