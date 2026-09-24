#!/usr/bin/env python3
"""[MARK_ONEBIT]: how a logo becomes one bit, as a sheet to pick from.

    extensions/launch_world/onebit_sheet.py

An orb's mark is one bit on three of the room's surfaces -- a hole in a
glowing orb's emission, a patch of a mirror that stops being metal, an
etch in a white sphere's roughness -- and how a *logo* becomes that bit
is the pick this sheet is for. No engine: the transforms are here, over
the logos this tree ships, and the sheet is a picture.

Rows are the logos, the first column is the original and each further
column is a method. **Judged at the size the sphere gives it**: the
mark is about 64 texels on an orb, so every method is applied to a
64-pixel version rather than to the original -- a logo that thresholds
well at 512 can be mush at 64.

**Polarity is the trap.** A logo may be white lines on transparency or
black ink on white, and a mark needs the *shape* to be the ink either
way. The buildat logo is luminance 1 everywhere it is drawn, which is
what made it vanish under a luminance threshold. Every method here says
how it decides, and a method that gets it backwards shows as an
inverted tile rather than as a quiet mistake.

Writes local/options_for_LAUNCH_WORLD_mark_onebit/sheet.png.
"""
import os
import sys
import glob

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "local", "options_for_LAUNCH_WORLD_mark_onebit")
SIZE = 64          # the size a mark gets on an orb
TILE = 128         # how big a tile is drawn on the sheet

LOGOS = [
    "client/data/buildat_logo.png",
    "builtin/luanti/launcher/luanti.png",
    "games/vanilla/launcher/luanti.png",
    "extensions/luanti_client/res/icon.png",
    "extensions/__menu/res/icon_local.png",
    "extensions/__menu/res/icon_network.png",
    "extensions/__menu/res/icon_preferences.png",
    "extensions/launch_menu/launcher/local.png",
    "extensions/launch_menu/launcher/network.png",
]


def load(path):
    im = Image.open(path).convert("RGBA")
    # **Down first, then decide.** Every method is judged at the size
    # the sphere gives it, so the resize is part of the input rather
    # than of any one method.
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def parts(im):
    a = np.asarray(im, dtype=np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3]
    lum = rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114
    return lum, alpha


def as_tile(mask, name):
    """A mask is True where the mark is; the mark is drawn black."""
    px = np.where(mask, 0, 255).astype(np.uint8)
    return Image.fromarray(px, mode="L").convert("RGB"), name


def ink_share(mask):
    return float(mask.mean())


# ---- the methods ---------------------------------------------------

def m_alpha(lum, alpha):
    """The shape is the cut-out. What most icons want, and it says
    nothing about colour -- so polarity cannot go wrong."""
    return alpha >= 0.5


def m_luminance(lum, alpha):
    """A fixed cut at 0.5, the room's rule before this round. Dark ink
    on light ground only: a white logo on transparency vanishes."""
    return (lum < 0.5) & (alpha >= 0.5)


def otsu(values):
    hist, edges = np.histogram(values, bins=64, range=(0.0, 1.0))
    total = values.size
    if total == 0:
        return 0.5
    w0 = np.cumsum(hist)
    w1 = total - w0
    mids = (edges[:-1] + edges[1:]) / 2.0
    s0 = np.cumsum(hist * mids)
    s1 = s0[-1] - s0
    with np.errstate(invalid="ignore", divide="ignore"):
        m0 = np.where(w0 > 0, s0 / np.maximum(w0, 1), 0)
        m1 = np.where(w1 > 0, s1 / np.maximum(w1, 1), 0)
        between = w0 * w1 * (m0 - m1) ** 2
    return float(mids[int(np.argmax(between))])


def m_otsu(lum, alpha):
    """The threshold out of the histogram, so no magic number -- and
    the polarity from which side has less of the picture, since a mark
    is the smaller part."""
    drawn = alpha >= 0.5
    vals = lum[drawn]
    if vals.size == 0:
        return np.zeros_like(lum, dtype=bool)
    t = otsu(vals)
    dark = (lum < t) & drawn
    light = (lum >= t) & drawn
    return dark if dark.sum() <= light.sum() else light


def m_darkest_fifth(lum, alpha):
    """A percentile -- what the room does today. Same polarity trap as
    the fixed cut."""
    drawn = alpha >= 0.5
    vals = lum[drawn]
    if vals.size == 0:
        return np.zeros_like(lum, dtype=bool)
    t = float(np.percentile(vals, 20.0))
    return (lum <= t) & drawn


def m_adaptive(lum, alpha):
    """The mean of a neighbourhood, which keeps detail in an unevenly
    lit picture. A box blur by summed area, radius four."""
    r = 4
    pad = np.pad(lum, r, mode="edge")
    acc = pad.cumsum(0).cumsum(1)
    acc = np.pad(acc, ((1, 0), (1, 0)))
    n = 2 * r + 1
    y, x = np.mgrid[0:lum.shape[0], 0:lum.shape[1]]
    y0, x0 = y, x
    y1, x1 = y + n, x + n
    local = (acc[y1, x1] - acc[y0, x1] - acc[y1, x0] + acc[y0, x0]) / (n * n)
    return (lum < local - 0.02) & (alpha >= 0.5)


def m_outline(lum, alpha):
    """A morphological gradient: any logo becomes a line drawing, which
    is the most *etched* of the lot and does not care whether the ink
    is light or dark."""
    v = np.where(alpha >= 0.5, lum, 0.0)
    pad = np.pad(v, 1, mode="edge")
    hi = np.maximum.reduce([pad[:-2, 1:-1], pad[2:, 1:-1],
            pad[1:-1, :-2], pad[1:-1, 2:], v])
    lo = np.minimum.reduce([pad[:-2, 1:-1], pad[2:, 1:-1],
            pad[1:-1, :-2], pad[1:-1, 2:], v])
    edge = hi - lo
    a = np.pad(alpha, 1, mode="edge")
    ahi = np.maximum.reduce([a[:-2, 1:-1], a[2:, 1:-1], a[1:-1, :-2],
            a[1:-1, 2:], alpha])
    alo = np.minimum.reduce([a[:-2, 1:-1], a[2:, 1:-1], a[1:-1, :-2],
            a[1:-1, 2:], alpha])
    return (edge > 0.15) | ((ahi - alo) > 0.5)


def m_alpha_or_otsu(lum, alpha):
    """Alpha where there is any, else Otsu -- the room's current rule
    stated properly."""
    if float(alpha.min()) < 0.5:
        return m_alpha(lum, alpha)
    return m_otsu(lum, alpha)


def m_dither(lum, alpha):
    """Floyd-Steinberg, to rule out: it keeps apparent tone and should
    be noise at this size."""
    v = np.where(alpha >= 0.5, lum, 1.0).astype(np.float32).copy()
    h, w = v.shape
    for y in range(h):
        for x in range(w):
            old = v[y, x]
            new = 1.0 if old >= 0.5 else 0.0
            v[y, x] = new
            err = old - new
            if x + 1 < w:
                v[y, x + 1] += err * 7 / 16
            if y + 1 < h:
                if x > 0:
                    v[y + 1, x - 1] += err * 3 / 16
                v[y + 1, x] += err * 5 / 16
                if x + 1 < w:
                    v[y + 1, x + 1] += err * 1 / 16
    return (v < 0.5) & (alpha >= 0.5)


METHODS = [
    ("alpha", m_alpha),
    ("luminance 0.5", m_luminance),
    ("Otsu", m_otsu),
    ("darkest fifth", m_darkest_fifth),
    ("adaptive", m_adaptive),
    ("outline", m_outline),
    ("alpha or Otsu", m_alpha_or_otsu),
    ("dither", m_dither),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    paths = [os.path.join(ROOT, p) for p in LOGOS]
    paths = [p for p in paths if os.path.exists(p)]
    # **A game's own icon is what a mark usually is**, and those follow
    # none of this tree's conventions -- so a few off ContentDB, by
    # size rather than by name, since the cache is hashes.
    thumbs = []
    for p in sorted(glob.glob(os.path.join(ROOT, "cache", "tmp", "*.png")))[:400]:
        try:
            im = Image.open(p)
            if im.size[0] >= 96 and im.size[0] == im.size[1]:
                thumbs.append(p)
        except Exception:
            pass
        if len(thumbs) >= 3:
            break
    paths += thumbs
    if not paths:
        print("no logos found")
        return 1
    try:
        font = ImageFont.truetype(
                "/usr/share/fonts/liberation-mono/LiberationMono-Bold.ttf", 18)
    except Exception:
        font = ImageFont.load_default()
    cols = 1 + len(METHODS)
    sheet = Image.new("RGB", (cols * (TILE + 6) + 6,
            (len(paths) + 1) * (TILE + 6) + 6), (18, 18, 20))
    d = ImageDraw.Draw(sheet)
    for i, (name, _) in enumerate([("original", None)] + METHODS):
        d.text((6 + (i + 0) * (TILE + 6) + 4, 8), name, fill=(255, 220, 120),
                font=font)
    print("%-34s %s" % ("logo", "  ".join("%-9s" % n for n, _ in METHODS)))
    for r, p in enumerate(paths):
        im = load(p)
        lum, alpha = parts(im)
        y = 6 + (r + 1) * (TILE + 6)
        flat = Image.new("RGB", im.size, (255, 255, 255))
        flat.paste(im, (0, 0), im)
        sheet.paste(flat.resize((TILE, TILE), Image.NEAREST), (6, y))
        shares = []
        for c, (name, fn) in enumerate(METHODS):
            mask = fn(lum, alpha)
            shares.append(ink_share(mask))
            tile, _ = as_tile(mask, name)
            sheet.paste(tile.resize((TILE, TILE), Image.NEAREST),
                    (6 + (c + 1) * (TILE + 6), y))
        short = os.path.relpath(p, ROOT)
        if short.startswith("cache/"):
            short = "contentdb/" + os.path.basename(p)[:8]
        print("%-34s %s" % (short[-34:],
                "  ".join("%8.1f%%" % (s * 100) for s in shares)))
        d.text((10, y + TILE - 22), short[-16:], fill=(200, 200, 200),
                font=font)
    sheet.save(os.path.join(OUT, "sheet.png"))
    print("\nthe sheet: %s/sheet.png -- the original first, a method a "
            "column; the mark is the black" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
