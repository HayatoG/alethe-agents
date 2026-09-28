#!/usr/bin/env python3
"""Renders the DMG window background (1x and 2x PNGs) from docs/BRAND.md tokens.

Usage: build/dmg-venv/bin/python Scripts/dmg/make-background.py
Needs Pillow and rsvg-convert. The layout must match Scripts/dmg/settings.py:
a 640x400 window with the app at (170, 190) and Applications at (470, 190).
"""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
MARK_SVG = HERE.parents[2] / "src/assets/alethe-mark.svg"
FONT = "/System/Library/Fonts/SFNS.ttf"  # -apple-system in the --font-sans stack

# docs/BRAND.md, light terminal theme. Finder draws the icon labels in black on a
# picture background, so the window must stay light for them to be readable.
BG = "#fafafa"           # light terminal background
PANEL = "#ffffff"
BORDER = "#e4e4e7"
TEXT_PRIMARY = "#18181b" # light terminal foreground
TEXT_SECONDARY = "#6b6b75"  # --text-quaternary
TEXT_TERTIARY = "#8b8b95"   # --text-tertiary

WIDTH, HEIGHT = 640, 400
APP_X, APPS_X, ICON_Y = 170, 470, 190


def font(size: int, weight: int, scale: int) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(FONT, size * scale)
    # SFNS axes: width, optical size, grade, weight.
    f.set_variation_by_axes([100, max(17, min(size, 96)), 400, weight])
    return f


def render(scale: int, mark: Image.Image) -> Image.Image:
    s = lambda v: round(v * scale)  # noqa: E731
    img = Image.new("RGB", (s(WIDTH), s(HEIGHT)), BG)
    d = ImageDraw.Draw(img)

    # Header: mark + wordmark.
    size = s(22)
    img.paste(mark.resize((size, size), Image.LANCZOS), (s(28), s(26)), mark.resize((size, size), Image.LANCZOS))
    d.text((s(58), s(37)), "Alethe", font=font(15, 600, scale), fill=TEXT_PRIMARY, anchor="lm")

    # Panel behind the two icons.
    d.rounded_rectangle((s(40), s(84), s(600), s(300)), radius=s(14), fill=PANEL, outline=BORDER, width=s(1))

    # Arrow between the icon slots.
    y, x0, x1 = s(ICON_Y), s(APP_X + 88), s(APPS_X - 88)
    d.line((x0, y, x1, y), fill=TEXT_TERTIARY, width=s(2))
    head = s(8)
    d.line((x1 - head, y - head, x1, y, x1 - head, y + head), fill=TEXT_TERTIARY, width=s(2), joint="curve")

    d.text((s(WIDTH / 2), s(340)), "Drag Alethe to Applications to install",
           font=font(13, 500, scale), fill=TEXT_SECONDARY, anchor="mm")
    d.text((s(WIDTH / 2), s(362)), "Preview build · not notarized — see the release notes before the first launch",
           font=font(11, 400, scale), fill=TEXT_TERTIARY, anchor="mm")
    return img


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "mark.png"
        subprocess.run(["rsvg-convert", "-w", "256", "-h", "256", str(MARK_SVG), "-o", str(png)], check=True)
        mark = Image.open(png).convert("RGBA")
    # The mark is drawn in white; recolor it to the primary text color, keeping its alpha.
    mark = Image.merge("RGBA", (*Image.new("RGB", mark.size, TEXT_PRIMARY).split(), mark.getchannel("A")))
    render(1, mark).save(HERE / "background.png")
    render(2, mark).save(HERE / "background@2x.png")
    print("rendered", HERE / "background.png", HERE / "background@2x.png")


if __name__ == "__main__":
    main()
