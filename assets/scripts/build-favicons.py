#!/usr/bin/env python3
"""Build docs/ favicons + og-image from the same render as build-icns.py.

Outputs (all under docs/):
    favicon.ico              — multi-resolution Windows-style icon (16/32/48)
    favicon-32.png           — explicit 32×32 PNG (modern browsers prefer)
    favicon-16.png           — explicit 16×16 PNG
    apple-touch-icon.png     — 180×180, used by iOS home-screen + macOS Safari
    icon.svg                 — vector square version (favicon for retina/SVG-capable browsers)
    og-image.png             — 1200×630 social-share card (Open Graph / Twitter)

Run from repo root:
    python3 assets/scripts/build-favicons.py
"""
import io
import sys
from pathlib import Path

# Re-use the icon renderer from build-icns.py
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_icns import render_icon  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402


DOCS = Path(__file__).resolve().parent.parent.parent / 'docs'


def write_png(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, format='PNG', optimize=True)
    print(f"  {path.relative_to(DOCS.parent)}  ({img.size[0]}×{img.size[1]}, {path.stat().st_size:,} bytes)")


def build_favicon_ico() -> None:
    """Multi-resolution .ico containing 16, 32, 48 px PNG variants."""
    images = [render_icon(s) for s in (16, 32, 48)]
    out = DOCS / 'favicon.ico'
    images[0].save(out, format='ICO', sizes=[(16, 16), (32, 32), (48, 48)], append_images=images[1:])
    print(f"  {out.relative_to(DOCS.parent)}  (16+32+48 px, {out.stat().st_size:,} bytes)")


def build_apple_touch_icon() -> None:
    """180×180 PNG that iOS uses for Home Screen + macOS Safari tab icon."""
    write_png(render_icon(180), DOCS / 'apple-touch-icon.png')


def build_png_favicons() -> None:
    """Plain PNG favicons — modern browsers pick these via <link rel='icon' sizes='…'>."""
    write_png(render_icon(16), DOCS / 'favicon-16.png')
    write_png(render_icon(32), DOCS / 'favicon-32.png')


def build_icon_svg() -> None:
    """Square SVG version of the pager icon — modern browsers prefer SVG favicons.

    Mirrors the Pillow render visually using SVG shapes, so a vector copy is
    available and matches the bitmap variants.
    """
    out = DOCS / 'icon.svg'
    svg = '''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">
  <defs>
    <linearGradient id="screen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#0fff8a"/>
      <stop offset="100%" stop-color="#00a05a"/>
    </linearGradient>
  </defs>
  <!-- body -->
  <rect x="0" y="0" width="100" height="100" rx="22" fill="#111" stroke="#2c2c2c" stroke-width="0.8"/>
  <!-- CRT screen -->
  <rect x="16" y="18" width="68" height="44" rx="4" fill="url(#screen)"/>
  <!-- wordmark -->
  <text x="50" y="46" font-size="11" font-weight="800" fill="#001a0c" text-anchor="middle" letter-spacing="0.5">PAGER</text>
  <!-- buttons -->
  <g fill="#444">
    <circle cx="28" cy="78" r="2.5"/>
    <circle cx="41" cy="78" r="2.5"/>
    <circle cx="54" cy="78" r="2.5"/>
    <circle cx="67" cy="78" r="2.5"/>
  </g>
  <circle cx="80" cy="78" r="2.5" fill="#e54"/>
</svg>
'''
    out.write_text(svg)
    print(f"  {out.relative_to(DOCS.parent)}  ({out.stat().st_size:,} bytes)")


def build_og_image() -> None:
    """1200×630 Open Graph card with the icon, wordmark, and tagline."""
    W, H = 1200, 630
    bg = (11, 15, 13, 255)  # var(--bg) from style.css
    img = Image.new('RGBA', (W, H), bg)
    d = ImageDraw.Draw(img)

    # The pager icon, large, left side
    ICON_PX = 360
    icon = render_icon(ICON_PX)
    icon_x = 110
    icon_y = (H - ICON_PX) // 2
    img.alpha_composite(icon, dest=(icon_x, icon_y))

    # Wordmark + tagline to the right of the icon
    text_x = icon_x + ICON_PX + 60
    fg = (231, 239, 233, 255)        # var(--fg)
    fg_dim = (154, 168, 160, 255)    # var(--fg-dim)
    accent = (15, 255, 138, 255)      # var(--green)

    # Wordmark — small, lowercase, top-left of the text column
    try:
        wm_font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf', 36)
    except Exception:
        wm_font = ImageFont.load_default()
    d.text((text_x, 90), 'pager', font=wm_font, fill=accent)

    # Hero headline — the wow line
    try:
        hl_font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 64)
    except Exception:
        hl_font = ImageFont.load_default()
    d.text((text_x, 150), 'Claude Code', font=hl_font, fill=fg)
    d.text((text_x, 222), 'that never sleeps.', font=hl_font, fill=fg)

    # Subtitle — the proof points
    try:
        st_font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 26)
    except Exception:
        st_font = ImageFont.load_default()
    d.text((text_x, 320), 'No timeouts. No "session expired."', font=st_font, fill=fg_dim)
    d.text((text_x, 354), 'Persistent claude --remote-control,', font=st_font, fill=fg_dim)
    d.text((text_x, 388), 'driven from your phone.', font=st_font, fill=fg_dim)

    # OS line — chip-style
    try:
        os_font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf', 22)
    except Exception:
        os_font = ImageFont.load_default()
    d.text((text_x, 462), 'Linux  +  macOS  •  one-line install  •  MIT', font=os_font, fill=accent)

    write_png(img, DOCS / 'og-image.png')


def main():
    if not DOCS.exists():
        print(f"ERROR: docs/ not found at {DOCS}", file=sys.stderr)
        sys.exit(1)
    print(f"Writing favicons to {DOCS}/")
    build_png_favicons()
    build_apple_touch_icon()
    build_icon_svg()
    build_favicon_ico()
    build_og_image()
    print('\nDone.')


if __name__ == '__main__':
    main()
