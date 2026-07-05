# App icon — "Code Spark"

The Pocket Artifacts app icon: rounded `< >` code brackets hugging a
four-point spark, on a cyan→blue glass gradient. It reads as *code / HTML*
(what the app builds) plus the *generation* spark, and stays legible at the
smallest home-screen sizes.

## iOS 26 appearance variants

iOS 26 renders app icons through the **Liquid Glass** system: you supply a
flat, full-bleed 1024×1024 image (no rounded corners, no alpha) and the OS
applies the squircle mask, specular highlights, and refraction. Each icon
provides up to three appearance variants, wired up in
`ios/Sources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

| File | Appearance | Design |
| --- | --- | --- |
| `icon-light.png` | default / light | cyan→blue gradient, white glyph |
| `icon-dark.png` | `luminosity: dark` | deep-navy gradient, white glyph |
| `icon-tinted.png` | `luminosity: tinted` | grayscale luminance map (dark bg, light glyph) — the system multiplies the user's tint over it |

## Regenerating

The PNGs are generated from vector art so they stay editable:

```sh
pip install cairosvg pillow
python3 design/appicon/generate_appicon.py
```

Edit palettes/geometry in `generate_appicon.py` and re-run; it overwrites the
three PNGs in the asset catalog in place.
