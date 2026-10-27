#!/usr/bin/env python3
"""Draws the app icon (original artwork) and writes the asset catalog PNGs.

The icon follows the macOS icon grid: a rounded-square plate inset in a
1024 px canvas, a dark display with the black island at its top edge and a
soft accent glow — no third-party artwork.

    python3 Scripts/generate_icon.py
"""

import json
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "AlcoveInspired", "Resources", "Assets.xcassets", "AppIcon.appiconset")
SIZE = 1024
SCALE = 4  # supersampling for smooth edges


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def vertical_gradient(size, top, bottom):
    width, height = size
    gradient = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(1, height - 1)
        gradient.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return gradient.resize((width, height))


def draw_icon():
    s = SIZE * SCALE
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    # Plate: 824 px rounded square centered on the 1024 grid.
    inset = 100 * SCALE
    plate_box = (inset, inset, s - inset, s - inset)
    plate_radius = 185 * SCALE

    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (plate_box[0], plate_box[1] + 18 * SCALE, plate_box[2], plate_box[3] + 18 * SCALE),
        radius=plate_radius, fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(28 * SCALE))
    canvas.alpha_composite(shadow)

    plate = vertical_gradient((s, s), (58, 62, 74), (20, 21, 27)).convert("RGBA")
    canvas.paste(plate, (0, 0), rounded_mask((s, s), plate_box, plate_radius))

    # Display glass with a cool gradient.
    screen_inset = 168 * SCALE
    screen_box = (screen_inset, screen_inset + 20 * SCALE, s - screen_inset, s - screen_inset - 40 * SCALE)
    screen = vertical_gradient((s, s), (64, 104, 196), (122, 70, 170)).convert("RGBA")
    canvas.paste(screen, (0, 0), rounded_mask((s, s), screen_box, 70 * SCALE))

    # Soft glow under the island.
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    cx = s // 2
    ImageDraw.Draw(glow).ellipse(
        (cx - 250 * SCALE, screen_box[1] + 40 * SCALE, cx + 250 * SCALE, screen_box[1] + 330 * SCALE),
        fill=(255, 210, 160, 110))
    glow = glow.filter(ImageFilter.GaussianBlur(60 * SCALE))
    clipped = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    clipped.paste(glow, (0, 0), rounded_mask((s, s), screen_box, 70 * SCALE))
    canvas.alpha_composite(clipped)

    # The island: attached to the top edge of the display, expanded state.
    island_w, island_h = 420 * SCALE, 150 * SCALE
    top = screen_box[1]
    island_box = (cx - island_w // 2, top - 40 * SCALE, cx + island_w // 2, top + island_h)
    island = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(island).rounded_rectangle(island_box, radius=62 * SCALE, fill=(4, 4, 6, 255))
    island_mask = Image.new("L", (s, s), 0)
    island_mask.paste(255, (0, 0), rounded_mask((s, s), screen_box, 70 * SCALE))
    clipped_island = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    clipped_island.paste(island, (0, 0), island_mask)
    canvas.alpha_composite(clipped_island)

    # Content inside the island: artwork tile and a progress bar, drawn on an
    # overlay so translucent strokes blend instead of replacing pixels.
    overlay = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    art = (island_box[0] + 46 * SCALE, top + 34 * SCALE, island_box[0] + 120 * SCALE, top + 108 * SCALE)
    art_img = vertical_gradient((s, s), (255, 159, 92), (255, 84, 140)).convert("RGBA")
    canvas.paste(art_img, (0, 0), rounded_mask((s, s), art, 16 * SCALE))
    bar_y = top + 92 * SCALE
    bar_x0 = art[2] + 30 * SCALE
    bar_x1 = island_box[2] - 50 * SCALE
    d.rounded_rectangle((bar_x0, bar_y, bar_x1, bar_y + 14 * SCALE), radius=7 * SCALE, fill=(255, 255, 255, 50))
    d.rounded_rectangle((bar_x0, bar_y, bar_x0 + int((bar_x1 - bar_x0) * 0.58), bar_y + 14 * SCALE),
                        radius=7 * SCALE, fill=(255, 255, 255, 235))
    for i, height in enumerate([30, 52, 38, 60]):
        x = bar_x0 + i * 26 * SCALE
        y_mid = top + 56 * SCALE
        d.rounded_rectangle((x, y_mid - height * SCALE // 2, x + 14 * SCALE, y_mid + height * SCALE // 2),
                            radius=7 * SCALE, fill=(255, 255, 255, 220))
    canvas.alpha_composite(overlay)

    # Subtle rim light on the plate.
    rim = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle(plate_box, radius=plate_radius, outline=(255, 255, 255, 40), width=4 * SCALE)
    canvas.alpha_composite(rim)

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


ENTRIES = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]


def main():
    os.makedirs(ICONSET, exist_ok=True)
    icon = draw_icon()
    images = []
    for size, scale, pixels in ENTRIES:
        name = f"icon_{size}{'' if scale == '1x' else '@2x'}.png"
        icon.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(ICONSET, name))
        images.append({"filename": name, "idiom": "mac", "scale": scale, "size": size})
    with open(os.path.join(ICONSET, "Contents.json"), "w") as handle:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, handle, indent=2)
        handle.write("\n")
    print(f"Wrote {len(images)} icon images to {ICONSET}")


if __name__ == "__main__":
    main()
