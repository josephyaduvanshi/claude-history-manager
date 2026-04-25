#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


SIZE = 1024
OUTER_RADIUS = int(round(SIZE * 0.2237))
FRAME_INSET = 145
FRAME_RADIUS = int(round(SIZE * 0.05))
FRAME_WIDTH = int(round(SIZE * 0.0125))
TRACKING = -7

BG_BASE = "#0E0F12"
BG_CORNER = "#1A1C20"
ACCENT = "#FF7A4D"
HIGHLIGHT = "#F5F7FA"

HERE = Path(__file__).resolve().parent
ICONSET_DIR = HERE / "icon.iconset"

FONT_CANDIDATES = [
    Path("/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf"),
    Path("/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"),
    Path("/System/Library/Fonts/Avenir Next Condensed.ttc"),
    Path("/System/Library/Fonts/HelveticaNeue.ttc"),
    Path("/System/Library/Fonts/SFNS.ttf"),
    Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
]


def hex_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def choose_font(size: int) -> tuple[ImageFont.FreeTypeFont, Path | None]:
    for candidate in FONT_CANDIDATES:
        if not candidate.exists():
            continue
        try:
            return ImageFont.truetype(str(candidate), size=size), candidate
        except OSError:
            continue
    return ImageFont.load_default(), None


def rounded_mask() -> Image.Image:
    mask = Image.new("L", (SIZE, SIZE), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=OUTER_RADIUS, fill=255)
    return mask


def background_layer() -> Image.Image:
    base = Image.new("RGBA", (SIZE, SIZE), (*hex_rgb(BG_BASE), 255))
    corner_fill = Image.new("RGBA", (SIZE, SIZE), (*hex_rgb(BG_CORNER), 255))

    radial_mask = Image.new("L", (SIZE, SIZE), 255)
    draw = ImageDraw.Draw(radial_mask)
    inset = int(SIZE * 0.19)
    draw.ellipse((inset, inset, SIZE - inset, SIZE - inset), fill=0)
    radial_mask = radial_mask.filter(ImageFilter.GaussianBlur(radius=170))
    base = Image.composite(corner_fill, base, radial_mask)

    mask = rounded_mask()
    base.putalpha(mask)
    return base


def add_frame(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    rect = (
        FRAME_INSET,
        FRAME_INSET,
        SIZE - FRAME_INSET,
        SIZE - FRAME_INSET,
    )
    draw.rounded_rectangle(
        rect,
        radius=FRAME_RADIUS,
        outline=hex_rgb(ACCENT),
        width=FRAME_WIDTH,
    )


def lettermark_image() -> tuple[Image.Image, str]:
    font_size = 440
    font, font_path = choose_font(font_size)

    while font_size > 280:
        bbox_c = font.getbbox("C")
        bbox_l = font.getbbox("L")
        width_c = bbox_c[2] - bbox_c[0]
        width_l = bbox_l[2] - bbox_l[0]
        total_width = width_c + width_l + TRACKING
        total_height = max(bbox_c[3] - bbox_c[1], bbox_l[3] - bbox_l[1])
        if total_width <= 430 and total_height <= 340:
            break
        font_size -= 8
        font, font_path = choose_font(font_size)

    bbox_c = font.getbbox("C")
    bbox_l = font.getbbox("L")
    width_c = bbox_c[2] - bbox_c[0]
    width_l = bbox_l[2] - bbox_l[0]
    height = max(bbox_c[3] - bbox_c[1], bbox_l[3] - bbox_l[1])
    canvas = Image.new("RGBA", (width_c + width_l + abs(TRACKING) + 32, height + 32), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    y_c = 16 - bbox_c[1]
    y_l = 16 - bbox_l[1]
    x_c = 16
    x_l = 16 + width_c + TRACKING
    fill = (*hex_rgb(ACCENT), 255)
    draw.text((x_c, y_c), "C", font=font, fill=fill)
    draw.text((x_l, y_l), "L", font=font, fill=fill)
    crop = canvas.getbbox()
    assert crop is not None
    return canvas.crop(crop), str(font_path) if font_path else "Pillow default bitmap font"


def add_lettermark(image: Image.Image) -> str:
    mark, font_used = lettermark_image()
    x = (SIZE - mark.width) // 2
    y = (SIZE - mark.height) // 2 - 10
    image.alpha_composite(mark, (x, y))
    return font_used


def add_scanlines(image: Image.Image) -> None:
    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    light = (*hex_rgb("#FFFFFF"), 10)
    dark = (*hex_rgb("#000000"), 8)
    for y in range(0, SIZE, 12):
        draw.line((0, y, SIZE, y), fill=light, width=1)
        if y + 1 < SIZE:
            draw.line((0, y + 1, SIZE, y + 1), fill=dark, width=1)
    overlay.putalpha(ImageChops.multiply(overlay.getchannel("A"), rounded_mask()))
    image.alpha_composite(overlay)


def add_edge_highlight(image: Image.Image) -> None:
    stroke = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(stroke)
    inset = 3
    draw.rounded_rectangle(
        (inset, inset, SIZE - inset - 1, SIZE - inset - 1),
        radius=OUTER_RADIUS,
        outline=(*hex_rgb(HIGHLIGHT), 46),
        width=8,
    )
    stroke = stroke.filter(ImageFilter.GaussianBlur(radius=4))

    glow_mask = Image.new("L", (SIZE, SIZE), 0)
    gdraw = ImageDraw.Draw(glow_mask)
    gdraw.ellipse((-260, -260, 620, 620), fill=255)
    glow_mask = glow_mask.filter(ImageFilter.GaussianBlur(radius=120))

    alpha = stroke.getchannel("A")
    alpha = ImageChops.multiply(alpha, glow_mask)
    stroke.putalpha(alpha)
    image.alpha_composite(stroke)


def render_variant(filename: str, texture: bool = False, highlight: bool = False) -> str:
    image = background_layer()
    add_frame(image)
    font_used = add_lettermark(image)
    if texture:
        add_scanlines(image)
    if highlight:
        add_edge_highlight(image)
    image.save(HERE / filename, "PNG")
    return font_used


def assert_png(path: Path) -> None:
    with Image.open(path) as image:
        if image.format != "PNG":
            raise ValueError(f"{path.name} is not a PNG")
        if image.size != (SIZE, SIZE):
            raise ValueError(f"{path.name} has size {image.size}, expected {(SIZE, SIZE)}")


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def build_iconset(source: Path) -> bool:
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)
    for entry in ICONSET_DIR.iterdir():
        if entry.is_file():
            entry.unlink()

    entries = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for pixel_size, filename in entries:
        run(
            [
                "sips",
                "-z",
                str(pixel_size),
                str(pixel_size),
                str(source),
                "--out",
                str(ICONSET_DIR / filename),
            ]
        )

    try:
        run(["iconutil", "-c", "icns", str(ICONSET_DIR), "-o", str(HERE / "icon.icns")])
        return True
    except subprocess.CalledProcessError:
        return False


def build_icns_fallback(source: Path) -> None:
    with Image.open(source) as image:
        image.save(HERE / "icon.icns")


def assert_icns(path: Path) -> None:
    if not path.exists() or path.stat().st_size == 0:
        raise ValueError("icon.icns was not produced")
    with Image.open(path) as image:
        if image.format != "ICNS":
            raise ValueError(f"{path.name} is not an ICNS file")
        if image.size != (SIZE, SIZE):
            raise ValueError(f"{path.name} has size {image.size}, expected {(SIZE, SIZE)}")


def main() -> None:
    font_used = render_variant("icon-1024-v1.png", texture=False, highlight=False)
    render_variant("icon-1024-v2.png", texture=True, highlight=False)
    render_variant("icon-1024-v3.png", texture=False, highlight=True)

    for name in ("icon-1024-v1.png", "icon-1024-v2.png", "icon-1024-v3.png"):
        assert_png(HERE / name)

    used_iconutil = build_iconset(HERE / "icon-1024-v2.png")
    if not used_iconutil:
        build_icns_fallback(HERE / "icon-1024-v2.png")
    assert_icns(HERE / "icon.icns")

    builder = "iconutil" if used_iconutil else "Pillow fallback"
    print(f"Generated Chronicle icon set with font: {font_used} ({builder})")


if __name__ == "__main__":
    main()
