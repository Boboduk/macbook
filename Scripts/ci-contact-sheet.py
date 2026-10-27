#!/usr/bin/env python3
"""Builds a contact sheet of the island screenshots taken by ci-smoke-test.sh.

Crops the top-center area of every screenshot (where the island lives),
stacks them with labels into one JPEG, and optionally prints it base64
encoded between markers so it can be recovered from the CI log.

    python3 Scripts/ci-contact-sheet.py build/screenshots [--print-base64]
"""

import base64
import glob
import os
import sys

from PIL import Image, ImageDraw

CROP_WIDTH = 900   # points of the top-center area to keep (at 1x)
CROP_HEIGHT = 300
SCALE = 0.7


def main() -> None:
    folder = sys.argv[1]
    shots = sorted(glob.glob(os.path.join(folder, "*.png")))
    tiles = []
    for path in sorted(glob.glob(os.path.join(folder, "window", "*.png"))):
        # The island panel alone, composited on gray so the black shape and
        # its corners are visible.
        window = Image.open(path).convert("RGBA")
        backdrop = Image.new("RGBA", window.size, (150, 150, 155, 255))
        backdrop.alpha_composite(window)
        factor = 2 if window.width >= 1100 else 1
        size = (int(window.width / factor * SCALE), int(window.height / factor * SCALE))
        tiles.append(("island: " + os.path.splitext(os.path.basename(path))[0], backdrop.convert("RGB").resize(size, Image.LANCZOS)))
    for path in shots:
        image = Image.open(path).convert("RGB")
        # Retina screenshots are 2x; normalize to points.
        factor = 2 if image.width >= 2560 else 1
        width, height = CROP_WIDTH * factor, CROP_HEIGHT * factor
        left = max(0, (image.width - width) // 2)
        crop = image.crop((left, 0, left + width, min(height, image.height)))
        crop = crop.resize((int(CROP_WIDTH * SCALE), int(CROP_HEIGHT * SCALE)), Image.LANCZOS)
        tiles.append((os.path.splitext(os.path.basename(path))[0], crop))

    if not tiles:
        print("No screenshots found")
        return

    label_height = 18
    tile_width = max(tile.width for _, tile in tiles)
    sheet = Image.new("RGB", (tile_width, sum(t.height + label_height for _, t in tiles)), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    y = 0
    for name, tile in tiles:
        draw.text((6, y + 3), name, fill=(200, 0, 0))
        sheet.paste(tile, (0, y + label_height))
        y += tile.height + label_height

    out = os.path.join(folder, "contact-sheet.jpg")
    sheet.save(out, quality=62, optimize=True)
    print(f"Contact sheet: {out} ({os.path.getsize(out)} bytes, {len(tiles)} states)")

    if "--print-base64" in sys.argv:
        print("=====BEGIN CONTACT SHEET=====")
        encoded = base64.b64encode(open(out, "rb").read()).decode()
        for index in range(0, len(encoded), 4000):
            print(encoded[index:index + 4000])
        print("=====END CONTACT SHEET=====")


if __name__ == "__main__":
    main()
