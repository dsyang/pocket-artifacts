#!/usr/bin/env python3
"""Regenerate the Pocket Artifacts "Code Spark" app icon.

Emits the three iOS 26 appearance variants into
`ios/Sources/Assets.xcassets/AppIcon.appiconset/`:

  - icon-light.png   default / light appearance  (cyan -> blue)
  - icon-dark.png    dark appearance             (deep navy)
  - icon-tinted.png  tinted appearance           (grayscale luminance map)

Each is a full-bleed 1024x1024 PNG with NO rounded corners and NO alpha
channel — the system applies the squircle mask + Liquid Glass treatment,
and App Store icons must be opaque.

Usage:
    pip install cairosvg pillow
    python3 design/appicon/generate_appicon.py
"""
import io
import os
import cairosvg
from PIL import Image

S = 1024
OUT = os.path.join(
    os.path.dirname(__file__), "..", "..",
    "ios", "Sources", "Assets.xcassets", "AppIcon.appiconset",
)


def sparkle_path(cx, cy, r, waist=0.34):
    """Four-point sparkle (concave diamond)."""
    w = r * waist
    return (
        f"M {cx:.1f} {cy-r:.1f} "
        f"C {cx+w:.1f} {cy-w:.1f} {cx+w:.1f} {cy-w:.1f} {cx+r:.1f} {cy:.1f} "
        f"C {cx+w:.1f} {cy+w:.1f} {cx+w:.1f} {cy+w:.1f} {cx:.1f} {cy+r:.1f} "
        f"C {cx-w:.1f} {cy+w:.1f} {cx-w:.1f} {cy+w:.1f} {cx-r:.1f} {cy:.1f} "
        f"C {cx-w:.1f} {cy-w:.1f} {cx-w:.1f} {cy-w:.1f} {cx:.1f} {cy-r:.1f} Z"
    )


def build_svg(bg_stops, ink_top, ink_bot, shadow_hex, shadow_op, sheen_op):
    cx = cy = S / 2
    stops = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in bg_stops)
    lw = 62
    ltop, lbot = 320, 704
    lx1, lx2 = 384, 250
    left = f"M {lx1} {ltop} L {lx2} {cy:.0f} L {lx1} {lbot}"
    right = f"M {S-lx1} {ltop} L {S-lx2} {cy:.0f} L {S-lx1} {lbot}"
    sp = sparkle_path(cx, cy, 132)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">{stops}</linearGradient>
    <linearGradient id="ink" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{ink_top}"/>
      <stop offset="1" stop-color="{ink_bot}"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.32" cy="0.26" r="0.9">
      <stop offset="0" stop-color="#ffffff" stop-opacity="{0.45*sheen_op:.3f}"/>
      <stop offset="0.4" stop-color="#ffffff" stop-opacity="{0.08*sheen_op:.3f}"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="{0.55*sheen_op:.3f}"/>
      <stop offset="0.28" stop-color="#ffffff" stop-opacity="{0.14*sheen_op:.3f}"/>
      <stop offset="0.55" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="{S}" height="{S}" fill="url(#bg)"/>
  <g fill="none" stroke="{shadow_hex}" stroke-opacity="{shadow_op}" stroke-width="{lw}" stroke-linecap="round" stroke-linejoin="round" transform="translate(0,12)">
    <path d="{left}"/><path d="{right}"/>
  </g>
  <g fill="none" stroke="url(#ink)" stroke-width="{lw}" stroke-linecap="round" stroke-linejoin="round">
    <path d="{left}"/><path d="{right}"/>
  </g>
  <path d="{sp}" fill="url(#ink)"/>
  <rect x="0" y="0" width="{S}" height="{S}" fill="url(#glow)"/>
  <rect x="0" y="0" width="{S}" height="{S/2}" fill="url(#sheen)"/>
</svg>"""


VARIANTS = {
    "light": dict(
        bg_stops=[(0, "#2FE6D6"), (0.5, "#1FA8F0"), (1, "#1462D6")],
        ink_top="#ffffff", ink_bot="#EAF6FF",
        shadow_hex="#0A3B7A", shadow_op=0.28, sheen_op=1.0),
    "dark": dict(
        bg_stops=[(0, "#1D3E74"), (0.5, "#122B54"), (1, "#08152E")],
        ink_top="#ffffff", ink_bot="#DCEBFF",
        shadow_hex="#000000", shadow_op=0.35, sheen_op=0.7),
    "tinted": dict(
        bg_stops=[(0, "#3A3A3A"), (0.5, "#202020"), (1, "#0E0E0E")],
        ink_top="#FFFFFF", ink_bot="#D8D8D8",
        shadow_hex="#000000", shadow_op=0.4, sheen_op=0.5),
}


def main():
    for name, kw in VARIANTS.items():
        svg = build_svg(**kw)
        png = cairosvg.svg2png(bytestring=svg.encode(), output_width=S, output_height=S)
        img = Image.open(io.BytesIO(png)).convert("RGBA")
        flat = Image.new("RGB", (S, S), (0, 0, 0))
        flat.paste(img, mask=img.split()[3])
        path = os.path.join(OUT, f"icon-{name}.png")
        flat.save(path, format="PNG")
        print(f"wrote {os.path.normpath(path)}  mode={flat.mode} size={flat.size}")


if __name__ == "__main__":
    main()
