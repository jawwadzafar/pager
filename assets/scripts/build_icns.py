#!/usr/bin/env python3
"""Build macos/pager.app/Contents/Resources/AppIcon.icns from scratch.

Pure Pillow + stdlib (struct). No SVG conversion, no external tools.

Design: dark rounded-square body + green CRT screen + "PAGER" wordmark
+ row of buttons (only at ≥128px). Echoes assets/logo.svg.

Run from repo root:
    python3 assets/scripts/build-icns.py

Outputs to:
    macos/pager.app/Contents/Resources/AppIcon.icns
"""
import io
import os
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


# ─── visual design ────────────────────────────────────────────────────────
BG_BODY     = (17, 17, 17, 255)        # #111
BG_OUTLINE  = (44, 44, 44, 255)        # #2c2c2c
SCREEN_TOP  = (15, 255, 138, 255)      # #0fff8a — bright phosphor
SCREEN_BOT  = (0, 160, 90, 255)        # #00a05a — deep phosphor
SCREEN_TEXT = (0, 26, 12, 255)         # very dark green
BTN_GREY    = (68, 68, 68, 255)
BTN_RED     = (229, 84, 68, 255)


def _gradient_fill(box, top_color, bot_color, radius):
    """Return an RGBA image of size box filled with a vertical gradient
    inside a rounded rectangle (transparent outside)."""
    w = int(box[2] - box[0])
    h = int(box[3] - box[1])
    grad = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    px = grad.load()
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(top_color[0] * (1 - t) + bot_color[0] * t)
        g = int(top_color[1] * (1 - t) + bot_color[1] * t)
        b = int(top_color[2] * (1 - t) + bot_color[2] * t)
        for x in range(w):
            px[x, y] = (r, g, b, 255)
    # Mask out everything but the rounded rect.
    mask = Image.new('L', (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    grad.putalpha(mask)
    return grad


def _find_bold_mono_font(size_pt):
    """Find a bold monospace font on this system. Falls back to PIL default."""
    candidates = [
        '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf',
        '/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf',
        '/System/Library/Fonts/Menlo.ttc',
        '/Library/Fonts/Menlo.ttc',
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size_pt)
            except Exception:
                continue
    return ImageFont.load_default()


def render_icon(size: int) -> Image.Image:
    """Render the pager app icon at the given pixel size, returning an RGBA PIL Image."""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # ── body: dark rounded square that fills the canvas ──
    radius = int(size * 0.22)  # ~squircle on iOS/macOS
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=BG_BODY)

    # subtle outline at large sizes (lost at small)
    if size >= 128:
        d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius,
                            outline=BG_OUTLINE, width=max(1, int(size * 0.006)))

    # ── screen: bright green CRT rectangle in the upper-mid portion ──
    sm = size * 0.16              # side margin
    s_top = size * 0.18
    s_bot = size * 0.62
    screen_radius = max(2, int(size * 0.04))
    screen_box = [sm, s_top, size - sm, s_bot]
    screen = _gradient_fill(screen_box, SCREEN_TOP, SCREEN_BOT, screen_radius)
    img.alpha_composite(screen, dest=(int(sm), int(s_top)))

    # ── "PAGER" wordmark inside the screen (only legible at ≥64px) ──
    if size >= 64:
        # font size relative to icon
        text = 'PAGER'
        # Try a few sizes until text fits in the screen
        max_w = (size - 2 * sm) * 0.84
        max_h = (s_bot - s_top) * 0.66
        font_pt = int(size * 0.15)
        while font_pt > 6:
            font = _find_bold_mono_font(font_pt)
            bbox = d.textbbox((0, 0), text, font=font)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
            if tw <= max_w and th <= max_h:
                break
            font_pt -= 1
        tx = (size - tw) / 2 - bbox[0]
        ty = (s_top + s_bot) / 2 - th / 2 - bbox[1]
        d.text((tx, ty), text, fill=SCREEN_TEXT, font=font)

    # ── row of buttons below the screen — only useful at ≥128px ──
    if size >= 128:
        btn_y = size * 0.78
        btn_r = max(2, int(size * 0.025))
        # Centered row of 5 buttons; last (rightmost) is red.
        positions = [size * f for f in (0.28, 0.41, 0.54, 0.67, 0.80)]
        for i, x in enumerate(positions):
            color = BTN_RED if i == 4 else BTN_GREY
            d.ellipse([x - btn_r, btn_y - btn_r, x + btn_r, btn_y + btn_r], fill=color)

    return img


# ─── ICNS container ───────────────────────────────────────────────────────
# Modern macOS reads PNG-backed entries. See Apple's icns format spec.
#   Header:  'icns' (4 bytes) + total_size (4 bytes, big-endian)
#   Entries: type_code (4 bytes) + entry_size (4 bytes, BE) + PNG data
ICNS_ENTRIES = [
    # (type_code, pixel_size, description)
    ('ic11', 32,   '16x16  @2x'),
    ('ic12', 64,   '32x32  @2x'),
    ('ic07', 128,  '128x128'),
    ('ic13', 256,  '128x128 @2x'),
    ('ic08', 256,  '256x256'),
    ('ic14', 512,  '256x256 @2x'),
    ('ic09', 512,  '512x512'),
    ('ic10', 1024, '512x512 @2x / 1024x1024'),
]


def build_icns(out_path: Path) -> None:
    body = bytearray()
    print(f"Rendering {len(ICNS_ENTRIES)} icon variants…")
    for type_code, px, label in ICNS_ENTRIES:
        img = render_icon(px)
        buf = io.BytesIO()
        img.save(buf, format='PNG', optimize=True)
        png_data = buf.getvalue()
        entry_size = 8 + len(png_data)
        body += type_code.encode('ascii')
        body += struct.pack('>I', entry_size)
        body += png_data
        print(f"  {type_code}  {px:>4}px  ({label}, {len(png_data):,} bytes)")

    total = 8 + len(body)
    container = b'icns' + struct.pack('>I', total) + bytes(body)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(container)
    print(f"\nWrote {out_path}  ({total:,} bytes)")


def main():
    repo_root = Path(__file__).resolve().parent.parent.parent  # .../assets/scripts/build-icns.py → repo root
    out = repo_root / 'macos' / 'pager.app' / 'Contents' / 'Resources' / 'AppIcon.icns'
    if len(sys.argv) > 1:
        out = Path(sys.argv[1])
    build_icns(out)


if __name__ == '__main__':
    main()
