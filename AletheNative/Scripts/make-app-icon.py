#!/usr/bin/env python3
"""Regenerates Alethe/Assets.xcassets/AppIcon.appiconset from the Tauri icon, on Apple's macOS grid.

Usage: build/dmg-venv/bin/python Scripts/make-app-icon.py   (needs Pillow and iconutil)

The Tauri artwork fills its whole 1024 canvas, so as-is it looked ~24% larger than other apps in
the Dock and Finder. Apple's template draws the rounded square at 824x824, centered, leaving the
margin for the drop shadow.
"""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ICNS = ROOT.parent / "src-tauri/icons/icon.icns"
OUT = ROOT / "Alethe/Assets.xcassets/AppIcon.appiconset"

CANVAS, ART = 1024, 824
SHADOW_OFFSET, SHADOW_BLUR, SHADOW_ALPHA = 10, 12, 0.30


def master() -> Image.Image:
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "src.iconset"
        subprocess.run(["iconutil", "-c", "iconset", "-o", str(iconset), str(SOURCE_ICNS)], check=True)
        art = Image.open(iconset / "icon_512x512@2x.png").convert("RGBA")
    art = art.resize((ART, ART), Image.LANCZOS)
    origin = ((CANVAS - ART) // 2, (CANVAS - ART) // 2)

    alpha = Image.new("L", (CANVAS, CANVAS), 0)
    alpha.paste(art.getchannel("A"), (origin[0], origin[1] + SHADOW_OFFSET))
    alpha = alpha.filter(ImageFilter.GaussianBlur(SHADOW_BLUR)).point(lambda a: int(a * SHADOW_ALPHA))
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.putalpha(alpha)

    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.alpha_composite(shadow)
    icon.alpha_composite(art, origin)
    return icon


def main() -> None:
    icon = master()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            px = size * scale
            (icon if px == CANVAS else icon.resize((px, px), Image.LANCZOS)).save(OUT / name)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
