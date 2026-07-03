#!/usr/bin/env python3
"""
Generate the TopStats macOS app icon.

Selected direction from the 5-option logo exploration: a simple three-bar
metric mark. No text, no labels, and no tiny detail so it survives at 16 px.
"""

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw


PROJECT_DIR = Path(__file__).parent
ICONSET_DIR = PROJECT_DIR / "TopStats.iconset"
ICNS_PATH = PROJECT_DIR / "TopStats.icns"
SVG_PATH = PROJECT_DIR / "TopStats_icon_simple.svg"
SVG_ALIAS_PATH = PROJECT_DIR / "TopStats_icon.svg"

ICON_FILES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def mix(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t))


def rounded_gradient(img: Image.Image, box: tuple[int, int, int, int], radius: int,
                     top: tuple[int, int, int], bottom: tuple[int, int, int]) -> None:
    x1, y1, x2, y2 = box
    height = max(1, y2 - y1)
    mask = Image.new("L", (x2 - x1, y2 - y1), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle((0, 0, x2 - x1, y2 - y1), radius=radius, fill=255)

    gradient = Image.new("RGBA", (x2 - x1, y2 - y1), (0, 0, 0, 0))
    gradient_draw = ImageDraw.Draw(gradient)
    for y in range(y2 - y1):
        t = y / height
        color = mix(top, bottom, t)
        gradient_draw.line((0, y, x2 - x1, y), fill=(*color, 255))

    img.paste(gradient, (x1, y1), mask)


def draw_icon(size: int) -> Image.Image:
    scale = 4
    canvas_size = size * scale
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s = canvas_size / 1024

    def px(value: float) -> int:
        return round(value * s)

    # macOS-style rounded square with a restrained purple-black background.
    bg_box = (px(54), px(54), px(970), px(970))
    rounded_gradient(img, bg_box, px(196), (34, 16, 58), (10, 20, 42))

    # Gentle inner sheen and border, visible at large sizes but quiet at small sizes.
    draw.rounded_rectangle(
        (px(86), px(86), px(938), px(938)),
        radius=px(164),
        outline=(255, 255, 255, 28),
        width=max(1, px(4)),
    )

    bars = [
        (318, 438, 238, (104, 96, 255), (63, 117, 255)),
        (452, 350, 326, (86, 139, 255), (64, 199, 255)),
        (586, 256, 420, (43, 224, 226), (93, 255, 209)),
    ]

    for x, y, height, top_color, bottom_color in bars:
        box = (px(x), px(y), px(x + 104), px(y + height))
        radius = px(34)
        rounded_gradient(img, box, radius, top_color, bottom_color)
        draw.rounded_rectangle(box, radius=radius, outline=(255, 255, 255, 34), width=max(1, px(3)))

    # One small live-status dot; simple enough to survive small icon sizes.
    dot_center = (px(724), px(290))
    dot_radius = px(28)
    draw.ellipse(
        (
            dot_center[0] - dot_radius,
            dot_center[1] - dot_radius,
            dot_center[0] + dot_radius,
            dot_center[1] + dot_radius,
        ),
        fill=(82, 255, 212, 255),
        outline=(255, 255, 255, 36),
        width=max(1, px(3)),
    )

    if size == canvas_size:
        return img

    return img.resize((size, size), Image.Resampling.LANCZOS)


def write_svg() -> None:
    svg = """<?xml version="1.0" encoding="UTF-8"?>
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="15%" y1="0%" x2="85%" y2="100%">
      <stop offset="0%" stop-color="#22103a"/>
      <stop offset="100%" stop-color="#0a142a"/>
    </linearGradient>
    <linearGradient id="bar1" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#6860ff"/>
      <stop offset="100%" stop-color="#3f75ff"/>
    </linearGradient>
    <linearGradient id="bar2" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#568bff"/>
      <stop offset="100%" stop-color="#40c7ff"/>
    </linearGradient>
    <linearGradient id="bar3" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#2be0e2"/>
      <stop offset="100%" stop-color="#5dffd1"/>
    </linearGradient>
  </defs>
  <rect x="54" y="54" width="916" height="916" rx="196" fill="url(#bg)"/>
  <rect x="86" y="86" width="852" height="852" rx="164" fill="none" stroke="#ffffff" stroke-opacity="0.11" stroke-width="4"/>
  <rect x="318" y="438" width="104" height="238" rx="34" fill="url(#bar1)" stroke="#ffffff" stroke-opacity="0.13" stroke-width="3"/>
  <rect x="452" y="350" width="104" height="326" rx="34" fill="url(#bar2)" stroke="#ffffff" stroke-opacity="0.13" stroke-width="3"/>
  <rect x="586" y="256" width="104" height="420" rx="34" fill="url(#bar3)" stroke="#ffffff" stroke-opacity="0.13" stroke-width="3"/>
  <circle cx="724" cy="290" r="28" fill="#52ffd4" stroke="#ffffff" stroke-opacity="0.14" stroke-width="3"/>
</svg>
"""
    SVG_PATH.write_text(svg)
    SVG_ALIAS_PATH.write_text(svg)


def main() -> None:
    if ICONSET_DIR.exists():
        shutil.rmtree(ICONSET_DIR)
    ICONSET_DIR.mkdir()

    write_svg()

    for filename, size in ICON_FILES:
        out = ICONSET_DIR / filename
        draw_icon(size).save(out, "PNG")
        print(f"created {out.relative_to(PROJECT_DIR)}")

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET_DIR), "-o", str(ICNS_PATH)], check=True)
    print(f"created {ICNS_PATH.relative_to(PROJECT_DIR)}")


if __name__ == "__main__":
    main()
