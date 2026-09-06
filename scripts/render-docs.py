#!/usr/bin/env python3
"""Render README images from the app icon and the live Touch Bar screenshot."""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DOCS = os.path.join(ROOT, "docs")
SHOT = os.path.join(DOCS, "touchbar-source.jpg")
ICON_CANDIDATES = [
    os.path.join(ROOT, "dist/TokenBar.app/Contents/Resources/AppIcon.icns"),
    "/Applications/TokenBar.app/Contents/Resources/AppIcon.icns",
]


def load_font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    faces = {
        "regular": ("/System/Library/Fonts/HelveticaNeue.ttc", 0),
        "medium": ("/System/Library/Fonts/HelveticaNeue.ttc", 10),
        "demi": ("/System/Library/Fonts/Avenir Next.ttc", 2),
    }
    path, index = faces[weight]
    return ImageFont.truetype(path, size, index=index)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def glow(size: tuple[int, int], color: tuple[int, int, int], radius: int) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = size[0] // 2, size[1] // 2
    draw.ellipse((cx - radius, cy - int(radius * 0.45), cx + radius, cy + int(radius * 0.45)), fill=color + (255,))
    return layer.filter(ImageFilter.GaussianBlur(radius // 3))


def extract_icon(dest: str, pixels: int = 1024) -> Image.Image:
    icns = next((p for p in ICON_CANDIDATES if os.path.isfile(p)), None)
    if icns is None:
        sys.exit("missing AppIcon.icns — build the app first")
    tmp = dest + ".sips.png"
    rc = os.system(f'/usr/bin/sips -s format png -z {pixels} {pixels} "{icns}" --out "{tmp}" >/dev/null')
    if rc != 0:
        sys.exit("sips failed to extract the app icon")
    icon = Image.open(tmp).convert("RGBA")
    os.remove(tmp)
    icon.save(dest)
    return icon


def frame_touchbar(shot: Image.Image, width: int) -> Image.Image:
    scale = width / shot.width
    height = max(1, round(shot.height * scale))
    bar = shot.resize((width, height), Image.Resampling.LANCZOS)
    bar = bar.filter(ImageFilter.UnsharpMask(radius=1.2, percent=80, threshold=2))

    pad_x, pad_y = 10, 10
    inner = (width + pad_x * 2, height + pad_y * 2)
    radius = inner[1] // 2
    bezel = Image.new("RGBA", inner, (22, 22, 24, 255))
    bezel.putalpha(rounded_mask(inner, radius))
    bar_rgba = bar.convert("RGBA")
    bar_rgba.putalpha(rounded_mask(bar.size, max(8, height // 2 - 2)))
    bezel.alpha_composite(bar_rgba, (pad_x, pad_y))

    rim = Image.new("RGBA", inner, (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle(
        (0, 0, inner[0] - 1, inner[1] - 1),
        radius=radius,
        outline=(255, 255, 255, 38),
        width=2,
    )
    bezel.alpha_composite(rim)
    return bezel


def shadow(img: Image.Image, blur: int = 28, offset: tuple[int, int] = (0, 18), alpha: int = 180) -> Image.Image:
    canvas = Image.new("RGBA", (img.width + blur * 4, img.height + blur * 4 + offset[1]), (0, 0, 0, 0))
    sh = Image.new("RGBA", img.size, (0, 0, 0, alpha))
    sh.putalpha(img.split()[-1].point(lambda a: min(alpha, a)))
    canvas.alpha_composite(sh, (blur * 2 + offset[0], blur * 2 + offset[1]))
    canvas = canvas.filter(ImageFilter.GaussianBlur(blur * 0.55))
    canvas.alpha_composite(img, (blur * 2, blur * 2))
    return canvas


def centered(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, y: int, fill, canvas_w: int) -> None:
    box = draw.textbbox((0, 0), text, font=font)
    x = (canvas_w - (box[2] - box[0])) // 2 - box[0]
    draw.text((x, y), text, font=font, fill=fill)


def main() -> None:
    os.makedirs(DOCS, exist_ok=True)
    if not os.path.isfile(SHOT):
        sys.exit(f"missing {SHOT}")

    icon_path = os.path.join(DOCS, "icon.png")
    icon = extract_icon(icon_path, 1024)
    shot = Image.open(SHOT).convert("RGB")

    # Hero / social banner.
    W, H = 2400, 1350
    hero = Image.new("RGBA", (W, H), (7, 11, 9, 255))
    g = glow((W, H), (28, 160, 78), 820)
    g.putalpha(g.split()[-1].point(lambda a: int(a * 0.34)))
    hero.alpha_composite(g, (0, -180))
    g2 = glow((W, H), (12, 40, 22), 1100)
    g2.putalpha(g2.split()[-1].point(lambda a: int(a * 0.5)))
    hero.alpha_composite(g2, (0, 240))

    mark = icon.resize((240, 240), Image.Resampling.LANCZOS)
    radius = int(240 * 0.223)
    mark.putalpha(rounded_mask((240, 240), radius))
    icon_shadow = shadow(mark, blur=26, offset=(0, 16), alpha=90)
    hero.alpha_composite(icon_shadow, ((W - icon_shadow.width) // 2, 128 - 26 * 2))

    draw = ImageDraw.Draw(hero)
    centered(draw, "TokenBar", load_font(92, "demi"), 400, (248, 252, 249, 255), W)
    centered(
        draw,
        "Live AI quota on the MacBook Touch Bar",
        load_font(36, "regular"),
        522,
        (168, 186, 176, 255),
        W,
    )

    hero_bar = frame_touchbar(shot, 2080)
    hero_bar = shadow(hero_bar, blur=32, offset=(0, 22), alpha=170)
    hx = (W - hero_bar.width) // 2
    hero.alpha_composite(hero_bar, (hx, 620))

    centered(
        draw,
        "Requires TokenTracker   ·   macOS 13+   ·   Touch Bar hardware",
        load_font(24, "medium"),
        1228,
        (122, 142, 130, 255),
        W,
    )

    hero.convert("RGB").save(os.path.join(DOCS, "hero.png"), "PNG", optimize=True)
    print("wrote", DOCS)


if __name__ == "__main__":
    main()
