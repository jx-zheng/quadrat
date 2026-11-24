#!/usr/bin/env python3
"""Draw Quadrat's macOS AppIcon in the house style (see satchel-icon/HOUSE-STYLE.md).

Same kit as make_satchel_icon.py (Pith's grid: 1024 canvas, 824 n=5 squircle,
4x supersampled master, cream glyph, hairline, margin shadow; 16/32 redrawn
on a 16-unit pixel grid). Requires Pillow and numpy.

    python3 make_quadrat_icon.py                 # every concept + sheets
    python3 make_quadrat_icon.py --concept A --iconset App/Assets.xcassets/AppIcon.appiconset
"""
# ---------------------------------------------------------------------------
# House icon kit. Same grid and finishing as Pith's scripts/make_app_icon.py:
# 1024 canvas, 824 squircle (n=5, 100 px margin), vertical two-stop tile
# gradient with a white sheen over the top half, a cream glyph with a soft
# contact shadow, a 10% white 2 px hairline, and a drop shadow in the margin.
# Small slots (16, 32) are redrawn on a 16-unit pixel grid, no sheen/shadow.
# ---------------------------------------------------------------------------
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

CANVAS = 1024
BODY = 824
SQUIRCLE_N = 5.0
SCALE = 4            # supersample factor for the 1024 master
SHEEN = 0.18         # white wash, top half only
GLYPH_SHADOW_DY = 6.0
GLYPH_SHADOW_BLUR = 10.0
GLYPH_SHADOW_ALPHA = 0.22
ICON_SHADOW_DY = 10.0
ICON_SHADOW_BLUR = 12.0
ICON_SHADOW_ALPHA = 0.28
HAIRLINE_WIDTH = 2.0
HAIRLINE_ALPHA = 0.10
SMALL_PIXELS = (16, 32)

CREAM_TOP = (255, 252, 246)     # #FFFCF6 (Pith pith)
CREAM_BOTTOM = (247, 235, 220)  # #F7EBDC

SLOTS = (
    ("icon_16x16.png", "16x16", "1x", 16),
    ("icon_16x16@2x.png", "16x16", "2x", 32),
    ("icon_32x32.png", "32x32", "1x", 32),
    ("icon_32x32@2x.png", "32x32", "2x", 64),
    ("icon_128x128.png", "128x128", "1x", 128),
    ("icon_128x128@2x.png", "128x128", "2x", 256),
    ("icon_256x256.png", "256x256", "1x", 256),
    ("icon_256x256@2x.png", "256x256", "2x", 512),
    ("icon_512x512.png", "512x512", "1x", 512),
    ("icon_512x512@2x.png", "512x512", "2x", 1024),
)


def hexrgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def superellipse(cx, cy, radius, steps):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        pts.append((cx + radius * math.copysign(abs(ct) ** (2 / SQUIRCLE_N), ct),
                    cy + radius * math.copysign(abs(st) ** (2 / SQUIRCLE_N), st)))
    return pts


def squircle_mask(px: int, supersample: int = 8) -> Image.Image:
    big = px * supersample
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(superellipse(big / 2, big / 2, BODY / CANVAS * big / 2, max(720, big // 2)), fill=255)
    return mask.resize((px, px), Image.Resampling.BOX)


def gaussian_blur(image: np.ndarray, sigma: float) -> np.ndarray:
    """Separable Gaussian truncated at 3 sigma (as in Pith)."""
    if sigma < 0.25:
        return image
    radius = max(1, int(math.ceil(sigma * 3.0)))
    x = np.arange(-radius, radius + 1, dtype=np.float32)
    k = np.exp(-0.5 * (x / np.float32(sigma)) ** 2)
    k /= k.sum()

    def conv(src, axis):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (radius, radius)
        win = np.lib.stride_tricks.sliding_window_view(np.pad(src, pad), k.size, axis=axis)
        return np.tensordot(win, k, axes=([-1], [0])).astype(np.float32)

    return conv(conv(image.astype(np.float32), 1), 0)


def shift_y(image: np.ndarray, dy: float) -> np.ndarray:
    out = np.zeros_like(image)
    d = int(round(dy))
    if d <= 0:
        return image
    out[d:] = image[:-d]
    return out


# ----- glyph drawing: shapes are given in 1024-grid (or 16-unit) coordinates ---

class Pen:
    """Draws antialiased masks. `unit` maps design coordinates to pixels."""

    def __init__(self, px: int, unit: float):
        self.px = px
        self.u = unit
        self.ops: list[tuple] = []

    def _new(self):
        m = Image.new("L", (self.px, self.px), 0)
        return m, ImageDraw.Draw(m)

    def _p(self, pts):
        return [(x * self.u, y * self.u) for x, y in pts]

    # primitive masks -------------------------------------------------------
    def rrect(self, x0, y0, x1, y1, r):
        m, d = self._new()
        d.rounded_rectangle([x0 * self.u, y0 * self.u, x1 * self.u - 1, y1 * self.u - 1], radius=max(0, r * self.u), fill=255)
        return m

    def ellipse(self, cx, cy, rx, ry=None):
        ry = rx if ry is None else ry
        m, d = self._new()
        d.ellipse([(cx - rx) * self.u, (cy - ry) * self.u, (cx + rx) * self.u - 1, (cy + ry) * self.u - 1], fill=255)
        return m

    def poly(self, pts):
        m, d = self._new()
        d.polygon(self._p(pts), fill=255)
        return m

    def stroke(self, pts, width, closed=False):
        """Round-capped polyline."""
        m, d = self._new()
        p = self._p(pts + ([pts[0]] if closed else []))
        w = width * self.u
        d.line(p, fill=255, width=max(1, int(round(w))), joint="curve")
        for x, y in (p if not closed else p):
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
        return m

    def ring(self, cx, cy, r_out, r_in, a0=None, a1=None):
        """Annulus, optionally a sector [a0, a1] degrees clockwise from 12 o'clock."""
        m, d = self._new()
        if a0 is None:
            d.ellipse([(cx - r_out) * self.u, (cy - r_out) * self.u, (cx + r_out) * self.u, (cy + r_out) * self.u], fill=255)
        else:
            d.pieslice([(cx - r_out) * self.u, (cy - r_out) * self.u, (cx + r_out) * self.u, (cy + r_out) * self.u],
                       a0 - 90, a1 - 90, fill=255)
        d.ellipse([(cx - r_in) * self.u, (cy - r_in) * self.u, (cx + r_in) * self.u, (cy + r_in) * self.u], fill=0)
        return m

    def rotated(self, mask: Image.Image, degrees: float, cx: float, cy: float):
        return mask.rotate(-degrees, resample=Image.Resampling.BICUBIC, center=(cx * self.u, cy * self.u))

    # ops -------------------------------------------------------------------
    def fill(self, mask, top=CREAM_TOP, bottom=None, y0=None, y1=None):
        bottom = top if bottom is None else bottom
        top = hexrgb(top) if isinstance(top, str) else top
        bottom = hexrgb(bottom) if isinstance(bottom, str) else bottom
        self.ops.append(("fill", mask, top, bottom, y0, y1))

    def cut(self, mask):
        self.ops.append(("cut", mask))


def union(*masks):
    out = np.zeros(np.asarray(masks[0]).shape, np.uint8)
    for m in masks:
        out = np.maximum(out, np.asarray(m))
    return Image.fromarray(out, "L")


def minus(a, b):
    return Image.fromarray(np.clip(np.asarray(a).astype(np.int16) - np.asarray(b), 0, 255).astype(np.uint8), "L")


def _vgrad(px, top, bottom, y0, y1):
    rows = (np.arange(px, dtype=np.float32) + 0.5)
    t = np.clip((rows - y0) / max(y1 - y0, 1e-6), 0, 1)[:, None]
    return (np.array(top, np.float32) * (1 - t) + np.array(bottom, np.float32) * t)[:, None, :]


def paint(px: int, ops, bg: np.ndarray, glyph_shadow: bool):
    """Apply fill/cut ops over the tile. Returns rgb float array (0..255)."""
    rgb = bg.copy()
    cover = np.zeros((px, px), np.float32)
    layers = []
    for op in ops:
        a = np.asarray(op[1], dtype=np.float32) / 255.0
        if op[0] == "fill":
            _, _, top, bottom, y0, y1 = op
            y0 = 0 if y0 is None else y0
            y1 = px if y1 is None else y1
            col = np.broadcast_to(_vgrad(px, top, bottom, y0, y1), (px, px, 3))
            layers.append(("fill", a, col))
            cover = np.maximum(cover, a)
        else:
            layers.append(("cut", a, None))
            cover = cover * (1 - a)
    if glyph_shadow:
        small = Image.fromarray(cover, "F").resize((CANVAS, CANVAS), Image.Resampling.BOX)
        sh = shift_y(gaussian_blur(np.asarray(small), GLYPH_SHADOW_BLUR), GLYPH_SHADOW_DY) * GLYPH_SHADOW_ALPHA
        sh = np.asarray(Image.fromarray(sh, "F").resize((px, px), Image.Resampling.BILINEAR))
        rgb *= (1 - np.clip(sh, 0, 1))[..., None]
    shaded = rgb.copy()
    for kind, a, col in layers:
        a3 = a[..., None]
        if kind == "fill":
            rgb = rgb * (1 - a3) + col * a3
        else:
            rgb = rgb * (1 - a3) + shaded * a3
    return rgb


def tile_wash(px: int, top, bottom, sheen: float, margin=True):
    t0 = (CANVAS - BODY) / 2 / CANVAS * px if margin else 0
    rows = np.arange(px, dtype=np.float32) + 0.5
    t = np.clip((rows - t0) / (px - 2 * t0), 0, 1)
    s = np.clip(1 - t / 0.5, 0, 1) * sheen
    col = np.array(top, np.float32) * (1 - t[:, None]) + np.array(bottom, np.float32) * t[:, None]
    col = col * (1 - s[:, None]) + 255 * s[:, None]
    return np.broadcast_to(col[:, None, :], (px, px, 3)).copy()


def resize_rgba(im: Image.Image, size: int) -> Image.Image:
    ch = np.asarray(im).astype(np.float32) / 255.0
    prem = np.dstack([ch[..., :3] * ch[..., 3:4], ch[..., 3]])
    planes = [np.asarray(Image.fromarray(prem[..., i], "F").resize((size, size), Image.Resampling.LANCZOS)) for i in range(4)]
    st = np.stack(planes, -1)
    a = st[..., 3:4]
    rgb = np.zeros_like(st[..., :3])
    np.divide(st[..., :3], np.maximum(a, 1e-6), out=rgb, where=a > 1e-4)
    cov = np.asarray(squircle_mask(size), np.float32)[..., None] / 255.0
    a = np.clip(a * cov, 0, 1)
    return Image.fromarray((np.dstack([np.clip(rgb, 0, 1), a]) * 255 + 0.5).astype(np.uint8), "RGBA")


def _composite(dst, src):
    sa, da = src[..., 3:4], dst[..., 3:4]
    oa = sa + da * (1 - sa)
    orgb = src[..., :3] * sa + dst[..., :3] * da * (1 - sa)
    np.divide(orgb, np.maximum(oa, 1e-6), out=orgb, where=oa > 1e-6)
    return np.dstack([orgb, oa[..., 0]])


def outer_shadow(size):
    m = np.asarray(squircle_mask(size), np.float32) / 255.0
    a = shift_y(gaussian_blur(m, ICON_SHADOW_BLUR * size / CANVAS), ICON_SHADOW_DY * size / CANVAS) * ICON_SHADOW_ALPHA
    return np.dstack([np.zeros((size, size, 3), np.float32), a])


def hairline(size):
    ss = 4
    big = size * ss
    mask = Image.new("L", (big, big), 0)
    pts = superellipse(big / 2, big / 2, BODY / CANVAS * big / 2, max(720, big // 2))
    ImageDraw.Draw(mask).line(pts + [pts[0]], fill=255, width=max(1, int(round(HAIRLINE_WIDTH * ss * size / CANVAS))), joint="curve")
    cov = np.asarray(mask, np.float32).reshape(size, ss, size, ss).mean(axis=(1, 3)) / 255.0
    return np.dstack([np.ones((size, size, 3), np.float32), cov * HAIRLINE_ALPHA])


class Concept:
    key = "x"
    title = ""
    blurb = ""
    tile = ("#888888", "#444444")       # full-size tile gradient top, bottom
    small_tile = None                   # deeper, no sheen; defaults to tile

    def glyph(self, pen: Pen):          # 1024-grid coordinates
        raise NotImplementedError

    def small(self, pen: Pen, px: int):  # 16-unit grid coordinates
        raise NotImplementedError


def render_body(c: Concept, scale: int = SCALE) -> Image.Image:
    px = CANVAS * scale
    pen = Pen(px, scale)
    c.glyph(pen)
    bg = tile_wash(px, hexrgb(c.tile[0]), hexrgb(c.tile[1]), SHEEN)
    rgb = paint(px, pen.ops, bg, glyph_shadow=True)
    alpha = np.asarray(squircle_mask(px, 1))
    return Image.fromarray(np.dstack([np.clip(rgb + 0.5, 0, 255).astype(np.uint8), alpha]), "RGBA")


def full_icon(size: int, body: Image.Image) -> Image.Image:
    scaled = np.asarray(resize_rgba(body, size)).astype(np.float32) / 255.0
    img = _composite(_composite(outer_shadow(size), scaled), hairline(size))
    return Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def small_icon(c: Concept, px: int, ss: int = 16) -> Image.Image:
    """Redrawn mark on the 16-unit grid. Whole units land on whole pixels at 16."""
    big = px * ss
    pen = Pen(big, big / 16.0)
    c.small(pen, px)
    top, bottom = c.small_tile or c.tile
    bg = tile_wash(big, hexrgb(top), hexrgb(bottom), 0.0)
    rgb = paint(big, pen.ops, bg, glyph_shadow=False)
    planes = [np.asarray(Image.fromarray(np.ascontiguousarray(rgb[..., i]), "F").resize((px, px), Image.Resampling.BOX)) for i in range(3)]
    alpha = np.asarray(squircle_mask(px), np.float32)
    out = np.dstack(planes + [alpha])
    return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGBA")


def build_images(c: Concept) -> dict[int, Image.Image]:
    body = render_body(c)
    imgs = {}
    for _, _, _, p in SLOTS:
        if p not in imgs:
            imgs[p] = small_icon(c, p) if p in SMALL_PIXELS else full_icon(p, body)
    return imgs


def write_catalog(imgs, iconset: Path):
    iconset.mkdir(parents=True, exist_ok=True)
    entries = []
    for name, size, scale, p in SLOTS:
        imgs[p].save(iconset / name, optimize=True)
        entries.append({"filename": name, "idiom": "mac", "scale": scale, "size": size})
    (iconset / "Contents.json").write_text(json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


# ----- presentation sheets -------------------------------------------------

FONT = "/usr/share/fonts/truetype/sand-box/google/Inter/Inter-VariableFont_opsz,wght.ttf"


def font(size, weight="SemiBold"):
    try:
        f = ImageFont.truetype(FONT, size)
        try:
            f.set_variation_by_name(weight)
        except Exception:
            pass
        return f
    except OSError:
        return ImageFont.load_default()


def dock_mock(house: list[tuple[str, Image.Image]], icon: Image.Image, name: str, dark: bool) -> Image.Image:
    """A macOS-like Dock: house icons then the concept, 128 px, on a wallpaper."""
    n = len(house) + 1
    tile, gap, pad = 128, 14, 18
    W = n * tile + (n - 1) * gap + 2 * pad + 160
    H = 330
    y = np.linspace(0, 1, H)[:, None, None]
    x = np.linspace(0, 1, W)[None, :, None]
    if dark:
        a, b, cc = np.array([28, 30, 48]), np.array([58, 40, 72]), np.array([16, 18, 26])
    else:
        a, b, cc = np.array([196, 218, 246]), np.array([246, 222, 214]), np.array([232, 236, 244])
    wall = a * (1 - x) * (1 - y) + b * x * (1 - y) + cc * y
    img = Image.fromarray(wall.astype(np.uint8), "RGB").convert("RGBA")
    dw = n * tile + (n - 1) * gap + 2 * pad
    dx0 = (W - dw) // 2
    dy0 = H - 40 - tile - 2 * 12
    dock = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(dock)
    box = [dx0, dy0, dx0 + dw, dy0 + tile + 24]
    d.rounded_rectangle(box, radius=30, fill=(255, 255, 255, 70) if not dark else (60, 60, 70, 140),
                        outline=(255, 255, 255, 120) if not dark else (255, 255, 255, 40), width=2)
    blurred = img.filter(ImageFilter.GaussianBlur(20))
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=30, fill=255)
    img.paste(blurred, (0, 0), m)
    img.alpha_composite(dock)
    d = ImageDraw.Draw(img)
    items = house + [(name, icon)]
    hover = len(items) - 1
    fx = dx0 + pad
    for i, (label, im) in enumerate(items):
        ic = im.resize((tile, tile), Image.Resampling.LANCZOS)
        img.alpha_composite(ic, (fx, dy0 + 12))
        if i == hover:
            d.ellipse([fx + tile // 2 - 3, dy0 + tile + 16, fx + tile // 2 + 3, dy0 + tile + 22], fill=(30, 30, 30) if not dark else (235, 235, 235))
            f = font(20)
            tw = d.textlength(label, font=f)
            bx = [fx + tile // 2 - tw / 2 - 14, dy0 - 52, fx + tile // 2 + tw / 2 + 14, dy0 - 18]
            d.rounded_rectangle(bx, radius=8, fill=(236, 236, 238, 235) if not dark else (50, 50, 56, 235))
            d.text((bx[0] + 14, bx[1] + 6), label, font=f, fill=(20, 20, 24) if not dark else (240, 240, 244))
        fx += tile + gap
    return img.convert("RGB")


def concept_card(c: Concept, imgs, name) -> Image.Image:
    """1024 at 384, then 128, 64, 32 and 16 at 1x, plus 16/32 blown up 6x."""
    W, H = 1560, 560
    card = Image.new("RGBA", (W, H), (244, 243, 240, 255))
    d = ImageDraw.Draw(card)
    d.text((32, 22), f"{name} {c.key}: {c.title}", font=font(30, "Bold"), fill=(24, 24, 28))
    d.text((32, 62), c.blurb, font=font(18, "Regular"), fill=(88, 88, 96))
    big = imgs[1024].resize((384, 384), Image.Resampling.LANCZOS)
    card.alpha_composite(big, (24, 110))
    x = 440
    for p in (256, 128, 64, 32, 16):
        im = imgs[p] if p != 256 else imgs[256].resize((192, 192), Image.Resampling.LANCZOS)
        card.alpha_composite(im, (x, 300 - im.height // 2))
        d.text((x, 420), f"{p}" if p != 256 else "256 (shown 192)", font=font(15, "Medium"), fill=(110, 110, 118))
        x += im.width + 30
    # pixel blow-ups on light and dark
    for j, bgc in enumerate(((244, 243, 240), (30, 30, 34))):
        ox = 1200
        oy = 110 + j * 200
        pane = Image.new("RGBA", (320, 190), bgc + (255,))
        a = imgs[16].resize((96, 96), Image.Resampling.NEAREST)
        b = imgs[32].resize((160, 160), Image.Resampling.NEAREST)
        pane.alpha_composite(a, (14, 47))
        pane.alpha_composite(b, (140, 15))
        card.alpha_composite(pane, (ox, oy))
    d.text((1200, 512), "16 and 32, nearest-neighbour zoom", font=font(15, "Medium"), fill=(110, 110, 118))
    return card.convert("RGB")


def overview(concepts, all_imgs, name, house) -> Image.Image:
    cols = len(concepts)
    W = 60 + cols * 420
    H = 900
    sheet = Image.new("RGBA", (W, H), (242, 241, 238, 255))
    d = ImageDraw.Draw(sheet)
    d.text((30, 20), f"{name}: house-style icon concepts", font=font(34, "Bold"), fill=(24, 24, 28))
    for i, c in enumerate(concepts):
        imgs = all_imgs[c.key]
        x0 = 30 + i * 420
        big = imgs[1024].resize((380, 380), Image.Resampling.LANCZOS)
        sheet.alpha_composite(big, (x0, 80))
        d.text((x0 + 10, 470), f"{c.key}  {c.title}", font=font(24, "Bold"), fill=(24, 24, 28))
        import textwrap
        for k, line in enumerate(textwrap.wrap(c.blurb, 44)):
            d.text((x0 + 10, 504 + k * 20), line, font=font(16, "Regular"), fill=(88, 88, 96))
        sheet.alpha_composite(imgs[128], (x0 + 10, 570))
        sheet.alpha_composite(imgs[64], (x0 + 160, 602))
        sheet.alpha_composite(imgs[32], (x0 + 246, 618))
        sheet.alpha_composite(imgs[16], (x0 + 300, 626))
        dark = Image.new("RGBA", (380, 150), (30, 30, 34, 255))
        dark.alpha_composite(imgs[128], (10, 11))
        dark.alpha_composite(imgs[64], (160, 43))
        dark.alpha_composite(imgs[32], (246, 59))
        dark.alpha_composite(imgs[16], (300, 67))
        sheet.alpha_composite(dark, (x0, 720))
    return sheet.convert("RGB")


def load_house(ref_dir: Path) -> list[tuple[str, Image.Image]]:
    names = [("Pith", "pith"), ("Fetch", "fetch"), ("MenuBarUsage", "menubar-usage"), ("Gamepad Keymapper", "gamepad-keymapper")]
    out = []
    for label, stem in names:
        p = ref_dir / f"{stem}-1024.png"
        if p.exists():
            out.append((label, Image.open(p).convert("RGBA")))
    return out


def run(concepts, name, default_out: Path, default_ref: Path, argv=None):
    ap = argparse.ArgumentParser(description=f"Draw {name}'s macOS AppIcon (house style).")
    ap.add_argument("--concept", default=None, help="one concept key (default: all)")
    ap.add_argument("--out", type=Path, default=default_out, help="where concept PNGs go")
    ap.add_argument("--house-ref", type=Path, default=default_ref, help="folder of house icons for the Dock mock")
    ap.add_argument("--iconset", type=Path, default=None, help="write this concept into an AppIcon.appiconset")
    args = ap.parse_args(argv)
    chosen = [c for c in concepts if args.concept in (None, c.key)]
    if args.iconset:
        if len(chosen) != 1:
            raise SystemExit("--iconset needs --concept")
        write_catalog(build_images(chosen[0]), args.iconset)
        print(f"wrote {args.iconset}")
        return
    args.out.mkdir(parents=True, exist_ok=True)
    house = load_house(args.house_ref)
    all_imgs = {}
    for c in chosen:
        imgs = build_images(c)
        all_imgs[c.key] = imgs
        base = args.out / f"concept-{c.key}"
        imgs[1024].save(f"{base}-1024.png", optimize=True)
        imgs[32].save(f"{base}-32.png")
        imgs[16].save(f"{base}-16.png")
        concept_card(c, imgs, name).save(f"{base}-sizes.png", optimize=True)
        for dark in (False, True):
            dock_mock(house, imgs[1024], name, dark).save(f"{base}-dock-{'dark' if dark else 'light'}.png", optimize=True)
        print(f"wrote {base}-*")
    if len(chosen) > 1:
        overview(chosen, all_imgs, name, house).save(args.out / "concepts-overview.png", optimize=True)
        print(f"wrote {args.out / 'concepts-overview.png'}")
# ----- Quadrat (disk-usage visualizer) concepts ------------------------------

CREAM = ("#FFFCF6", "#F7EBDC")
CREAM_DEEP = ("#F2E2CC", "#E6D0B4")
AMBER = ("#FFC861", "#FF9F2E")       # the "hot spot": the biggest consumer


def np_min(a, b):
    return Image.fromarray(np.minimum(np.asarray(a), np.asarray(b)), "L")


class QuadA(Concept):
    key = "A"
    title = "Treemap"
    blurb = "Squarified treemap tiles; the biggest block is lit amber."
    tile = ("#5D6CF2", "#2B2FAE")
    small_tile = ("#4E5BE6", "#23279A")

    def glyph(self, pen):
        g = 30
        x0, y0, x1, y1 = 236, 236, 788, 788
        xm = 560
        tiles = [
            (x0, y0, xm, y1, AMBER),
            (xm + g, y0, x1, 480, CREAM),
            (xm + g, 480 + g, x1, 650, CREAM),
            (xm + g, 650 + g, 694, y1, CREAM_DEEP),
            (694 + g, 650 + g, x1, y1, CREAM_DEEP),
        ]
        for a, b, c, d, col in tiles:
            pen.fill(pen.rrect(a, b, c, d, 44 if (c - a) > 120 else 30), *col, y0=y0 * pen.u, y1=y1 * pen.u)

    def small(self, pen, px):
        if px <= 16:
            spec = [(3, 3, 8, 13, AMBER), (9, 3, 13, 7, CREAM), (9, 8, 13, 10, CREAM), (9, 11, 11, 13, CREAM_DEEP), (12, 11, 13, 13, CREAM_DEEP)]
            r = 1
        else:
            spec = [(3, 3, 8, 13, AMBER), (8.5, 3, 13, 7.5, CREAM), (8.5, 8, 13, 10.5, CREAM),
                    (8.5, 11, 10.5, 13, CREAM_DEEP), (11, 11, 13, 13, CREAM_DEEP)]
            r = 1
        for a, b, c, d, col in spec:
            pen.fill(pen.rrect(a, b, c, d, r), *col)


class QuadB(Concept):
    key = "B"
    title = "Sunburst"
    blurb = "Two-ring sunburst: depth is a ring, share is an angle; the largest wedge is amber."
    tile = ("#FF6A8E", "#C81E5A")
    small_tile = ("#F2557C", "#B01650")

    # (start, end) degrees clockwise from 12 o'clock. Outer arcs sit inside their parent.
    INNER = [(0, 160, AMBER), (160, 270, CREAM), (270, 360, CREAM)]
    OUTER = [(0, 100, AMBER), (100, 160, AMBER), (160, 230, CREAM_DEEP), (270, 330, CREAM_DEEP)]

    def _rings(self, pen, c, r0, r1, r2, r3, gap):
        for a0, a1, col in self.INNER:
            pen.fill(pen.ring(c, c, r1, r0, a0, a1), *col, y0=(c - r3) * pen.u, y1=(c + r3) * pen.u)
        for a0, a1, col in self.OUTER:
            pen.fill(pen.ring(c, c, r3, r2, a0, a1), *col, y0=(c - r3) * pen.u, y1=(c + r3) * pen.u)

        def spoke(a, ra, rb):
            t = math.radians(a)
            return pen.rotated(pen.rrect(c - gap / 2, c - rb, c + gap / 2, c - ra, 0), a, c, c)

        for a0, _, _ in self.INNER:
            pen.cut(spoke(a0, 0, r3 + gap))
        for a0, a1, _ in self.OUTER:
            for a in (a0, a1):
                pen.cut(spoke(a, r2 - gap, r3 + gap))

    def glyph(self, pen):
        self._rings(pen, 512, 104, 222, 246, 330, 26)

    def small(self, pen, px):
        if px <= 16:
            pen.fill(pen.ring(8, 8, 4.5, 1.7, 0, 180), *AMBER)
            pen.fill(pen.ring(8, 8, 4.5, 1.7, 180, 360), *CREAM)
            pen.fill(pen.ring(8, 8, 6.6, 5.4, 20, 160), *AMBER)
        else:
            self._rings(pen, 8, 1.7, 3.9, 4.6, 6.3, 0.6)


class QuadC(Concept):
    key = "C"
    title = "Lens on a treemap"
    blurb = "A magnifier whose lens holds a treemap; the biggest block is amber."
    tile = ("#2FB7D8", "#0B6FA6")
    small_tile = ("#1EA6CC", "#095F92")

    def glyph(self, pen):
        cx, cy, r = 466, 466, 214
        handle = pen.rotated(pen.rrect(cx - 44, cy + r + 10, cx + 44, cy + r + 236, 44), -45, cx, cy)
        pen.fill(minus(pen.ellipse(cx, cy, r + 52), pen.ellipse(cx, cy, r)), *CREAM, y0=(cy - r) * pen.u, y1=(cy + r) * pen.u)
        pen.fill(handle, *CREAM, y0=cy * pen.u, y1=830 * pen.u)
        inside = pen.ellipse(cx, cy, r - 30)
        g = 22
        for a, b, c, d, col in ((cx - 190, cy - 190, cx + 10, cy + 190, AMBER),
                                (cx + 10 + g, cy - 190, cx + 190, cy + 20, CREAM),
                                (cx + 10 + g, cy + 20 + g, cx + 190, cy + 190, CREAM_DEEP)):
            pen.fill(np_min(inside, pen.rrect(a, b, c, d, 26)), *col)

    def small(self, pen, px):
        if px <= 16:
            pen.fill(minus(pen.ellipse(7, 7, 5), pen.ellipse(7, 7, 3.5)), *CREAM)
            pen.fill(pen.rotated(pen.rrect(6, 10.5, 8, 15, 1), -45, 7, 7), *CREAM)
            pen.fill(pen.rrect(5, 5, 9, 9, 1), *AMBER)
        else:
            pen.fill(minus(pen.ellipse(7, 7, 5.25), pen.ellipse(7, 7, 3.75)), *CREAM)
            pen.fill(pen.rotated(pen.rrect(6.1, 11, 7.9, 15, 0.9), -45, 7, 7), *CREAM)
            inside = pen.ellipse(7, 7, 3.1)
            pen.fill(np_min(inside, pen.rrect(3.5, 3.5, 7, 10.5, 0.4)), *AMBER)
            pen.fill(np_min(inside, pen.rrect(7.5, 3.5, 10.5, 6.75, 0.4)), *CREAM)
            pen.fill(np_min(inside, pen.rrect(7.5, 7.25, 10.5, 10.5, 0.4)), *CREAM_DEEP)


CONCEPTS = [QuadA(), QuadB(), QuadC()]

if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    run(CONCEPTS, "Quadrat", here, Path("/workspace/satchel-icon/house-ref"))
