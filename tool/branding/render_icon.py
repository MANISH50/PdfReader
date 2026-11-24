#!/usr/bin/env python3
"""Render the PdfReader icon PNGs from the same geometry as assets/branding/icon.svg.

Dev tool only (needs Pillow: `pip install pillow`). Usage, from the repo root:

    python3 tool/branding/render_icon.py
    dart run flutter_launcher_icons
    dart run flutter_native_splash:create

Outputs (assets/branding/):
  icon_ios.png              1024x1024 full-bleed, opaque (iOS masks the corners)
  icon_android_legacy.png   1024x1024 rounded square on transparent (pre-Android 8)
  icon_foreground.png       432x432 adaptive-icon foreground, mark in the 66% safe zone
  icon_background.png       432x432 adaptive-icon background gradient
  icon_monochrome.png       432x432 themed-icon (Android 13+) silhouette, white on transparent
  splash.png                768x768 splash logo (rounded tile, transparent outside)
  splash_android12.png      1152x1152 Android 12+ splash icon: mark inside the 768px circle
"""
from __future__ import annotations

import os

from PIL import Image, ImageDraw

SS = 4  # supersampling factor for antialiasing
OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'assets', 'branding')

# Brand gradient (keep in sync with Brand.gradientColors in tokens.dart).
BG_STOPS = [(0x3B, 0x5B, 0xDB), (0x7C, 0x3A, 0xED), (0xDB, 0x27, 0x77)]
PAPER = (255, 255, 255, 255)
FOLD = (0xDC, 0xE3, 0xFB, 255)
LINE = (0xC5, 0xCE, 0xF2, 255)
GLASS = (0xFF, 0xF4, 0xDE, 255)
ACCENT = (0xFF, 0xB5, 0x47, 255)

# Geometry in 1024 units (keep in sync with icon.svg and app_logo.dart).
L, T, R, B, CORNER, FOLD_SIZE = 254, 182, 678, 786, 44, 132
LENS_C, LENS_R, LENS_W = (554, 626), 112, 40
HANDLE = ((648, 720), (744, 816))
HANDLE_W, LINE_W = 52, 34
LINES = [(340, 334, 520), (420, 334, 598), (500, 334, 470)]


def gradient(size: int) -> Image.Image:
    """Diagonal top-left -> bottom-right gradient."""
    small = Image.new('RGB', (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510 * (len(BG_STOPS) - 1)
            i = min(int(t), len(BG_STOPS) - 2)
            f = t - i
            a, b = BG_STOPS[i], BG_STOPS[i + 1]
            px[x, y] = tuple(round(u + (v - u) * f) for u, v in zip(a, b))
    return small.resize((size, size), Image.BICUBIC).convert('RGBA')


def round_line(d: ImageDraw.ImageDraw, p0, p1, w, fill, k):
    (x0, y0), (x1, y1) = p0, p1
    d.line([(x0 * k, y0 * k), (x1 * k, y1 * k)], fill=fill, width=round(w * k))
    r = w * k / 2
    for x, y in (p0, p1):
        d.ellipse([x * k - r, y * k - r, x * k + r, y * k + r], fill=fill)


def sheet_mask(k: float, size: int) -> Image.Image:
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([L * k, T * k, R * k, B * k], radius=CORNER * k, fill=255)
    d.polygon([((R - FOLD_SIZE) * k, T * k - 2), (R * k + 2, T * k - 2), (R * k + 2, (T + FOLD_SIZE) * k)], fill=0)
    return m


def draw_mark(img: Image.Image, k: float, mono: bool = False) -> None:
    """Draws the mark scaled by k (pixels per 1024 unit) onto RGBA img."""
    size = img.size[0]
    paper = Image.new('RGBA', img.size, PAPER)
    img.alpha_composite(Image.composite(paper, Image.new('RGBA', img.size, (0, 0, 0, 0)), sheet_mask(k, size)))
    d = ImageDraw.Draw(img)
    clear = (0, 0, 0, 0)
    fx = R - FOLD_SIZE
    d.polygon([(fx * k, T * k), (fx * k, (T + FOLD_SIZE) * k), (R * k, (T + FOLD_SIZE) * k)],
              fill=clear if mono else FOLD)
    for y, x0, x1 in LINES:
        round_line(d, (x0, y), (x1, y), LINE_W, clear if mono else LINE, k)
    cx, cy = LENS_C
    if mono:
        # Cut a gap around the lens so it reads as a separate shape.
        gap = 22
        rr = LENS_R + LENS_W / 2 + gap
        d.ellipse([(cx - rr) * k, (cy - rr) * k, (cx + rr) * k, (cy + rr) * k], fill=clear)
        round_line(d, HANDLE[0], HANDLE[1], HANDLE_W + 2 * gap, clear, k)
        fill = PAPER
    else:
        d.ellipse([(cx - LENS_R) * k, (cy - LENS_R) * k, (cx + LENS_R) * k, (cy + LENS_R) * k], fill=GLASS)
        fill = ACCENT
    round_line(d, HANDLE[0], HANDLE[1], HANDLE_W, fill, k)
    ro, ri = LENS_R + LENS_W / 2, LENS_R - LENS_W / 2
    d.ellipse([(cx - ro) * k, (cy - ro) * k, (cx + ro) * k, (cy + ro) * k], fill=fill)
    d.ellipse([(cx - ri) * k, (cy - ri) * k, (cx + ri) * k, (cy + ri) * k], fill=clear if mono else GLASS)


def render(size: int, *, background: str | None, mark_scale: float = 1.0, mono: bool = False) -> Image.Image:
    """background: None | 'square' | 'rounded'. mark_scale shrinks the mark about the centre."""
    big = size * SS
    img = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    if background:
        g = gradient(big)
        if background == 'square':
            img = g
        else:
            m = Image.new('L', (big, big), 0)
            ImageDraw.Draw(m).rounded_rectangle([0, 0, big - 1, big - 1], radius=230 / 1024 * big, fill=255)
            img.paste(g, (0, 0), m)
    if mark_scale <= 0:
        return img.resize((size, size), Image.LANCZOS)
    k = big / 1024 * mark_scale
    layer = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    draw_mark(layer, k, mono=mono)
    off = round((big - 1024 * k) / 2)
    shifted = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    shifted.paste(layer, (off, off))
    img.alpha_composite(shifted)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)

    def save(img: Image.Image, name: str) -> None:
        path = os.path.join(OUT, name)
        img.save(path, optimize=True)
        print('wrote', os.path.normpath(path), img.size)

    save(render(1024, background='square').convert('RGB'), 'icon_ios.png')
    save(render(1024, background='rounded'), 'icon_android_legacy.png')
    # Adaptive icon: flutter_launcher_icons wraps the foreground in a 16% inset
    # (content scaled to 68%), which already puts the mark (~660 units tall)
    # inside the 66dp safe circle: 0.68 * 660 * 1.414 / 1024 = 0.62 < 0.667.
    # So the mark is drawn at full scale here.
    save(render(432, background=None, mark_scale=1.0), 'icon_foreground.png')
    save(render(432, background='square', mark_scale=0.0), 'icon_background.png')
    save(render(432, background=None, mark_scale=1.0, mono=True), 'icon_monochrome.png')
    save(render(768, background='rounded'), 'splash.png')
    # Android 12: 1152px image, only the centre 768px circle is visible.
    # The mark must fit in that circle: 1152/1024 * s * 660 * 1.414 <= 768 -> s ~= 0.73
    save(render(1152, background=None, mark_scale=0.68), 'splash_android12.png')


if __name__ == '__main__':
    main()
