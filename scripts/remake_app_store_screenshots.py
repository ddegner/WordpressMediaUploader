#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "output" / "app-store-screenshots" / "raw"
APP_STORE_DIR = ROOT / "screenshots" / "app-store" / "macos"
ITERATIONS_DIR = ROOT / "output" / "app-store-screenshots" / "iterations"

FONT_HEAVY = Path("/Library/Fonts/SF-Pro-Text-Bold.otf")
FONT_REGULAR = Path("/Library/Fonts/SF-Pro-Text-Regular.otf")
FONT_SEMIBOLD = Path("/Library/Fonts/SF-Pro-Text-Semibold.otf")

TARGET_SIZES = ((1280, 800), (2560, 1600), (2880, 1800))

SLIDES = (
    {
        "slug": "01-overview",
        "raw": "01-overview-both-closed.png",
        "title": "Reliable Uploads,\nZero Friction",
        "subtitle": "Works the way you work: drop files on the Dock icon,\ndrag into the window, or stay keyboard-first.",
        "bullets": ("Dock icon file intake", "Drag-and-drop queueing", "Keyboard shortcuts when speed matters"),
    },
    {
        "slug": "02-queued-files",
        "raw": "02-uploading-activejob.png",
        "title": "Bulk Queue,\nLive Progress",
        "subtitle": "Run larger batches with active-job visibility,\nclear progress metrics, and reliable throughput.",
        "bullets": ("Large queues stay organized", "Real-time job telemetry", "Predictable batch processing"),
        "focus": (0.30, 0.0, 1.0, 1.0),
    },
    {
        "slug": "03-profile-editor",
        "raw": "03-uploading-terminal.png",
        "title": "Terminal Clarity,\nNo Guesswork",
        "subtitle": "Live command output keeps every run transparent,\nso you always know what is happening.",
        "bullets": ("Built-in terminal stream", "Detailed status feedback", "Fast diagnostics when needed"),
        "focus": (0.32, 0.0, 1.0, 1.0),
    },
)

VARIANTS = (
    "v3_split_clean",
    "v4_diagonal",
    "v5_dark_glow",
    "v6_card_stack",
    "v7_ribbon_light",
    "v8_glass_diagonal",
    "v9_midnight_orbit",
    "v10_sunrise_stack",
    "v11_lumen_arc",
    "v12_skyline_ribbon",
    "v13_ice_glass",
    "v14_sunbeam_split",
)


def load_font(path: Path, size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    if path.exists():
        return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def wrap_lines(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont, max_width: int) -> list[str]:
    lines: list[str] = []
    for paragraph in text.splitlines():
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        current = words[0]
        for word in words[1:]:
            candidate = f"{current} {word}"
            if draw.textbbox((0, 0), candidate, font=font)[2] <= max_width:
                current = candidate
            else:
                lines.append(current)
                current = word
        lines.append(current)
    return lines


def gradient(canvas: Image.Image, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> None:
    w, h = canvas.size
    draw = ImageDraw.Draw(canvas, "RGBA")
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        draw.line((0, y, w, y), fill=(r, g, b, 255))


def trim_black_border(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    mask = rgb.convert("L").point(lambda px: 255 if px > 10 else 0)
    bbox = mask.getbbox()
    if bbox is None:
        return image
    return image.crop(bbox)


def apply_focus_crop(image: Image.Image, focus: tuple[float, float, float, float] | None) -> Image.Image:
    if focus is None:
        return image

    x1f, y1f, x2f, y2f = focus
    x1f = max(0.0, min(1.0, x1f))
    y1f = max(0.0, min(1.0, y1f))
    x2f = max(0.0, min(1.0, x2f))
    y2f = max(0.0, min(1.0, y2f))
    if x2f <= x1f or y2f <= y1f:
        return image

    w, h = image.size
    x1 = int(w * x1f)
    y1 = int(h * y1f)
    x2 = int(w * x2f)
    y2 = int(h * y2f)
    return image.crop((x1, y1, x2, y2))


def place_card(
    canvas: Image.Image,
    screenshot: Image.Image,
    x1: int,
    y1: int,
    x2: int,
    y2: int,
    radius: int,
    border: tuple[int, int, int, int],
    shadow: tuple[int, int, int, int],
) -> None:
    w = x2 - x1
    h = y2 - y1
    scale = min(w / screenshot.width, h / screenshot.height)
    target_w = max(1, int(screenshot.width * scale))
    target_h = max(1, int(screenshot.height * scale))
    shot = screenshot.resize((target_w, target_h), Image.Resampling.LANCZOS)

    px = x1 + (w - target_w) // 2
    py = y1 + (h - target_h) // 2
    rect = (px, py, px + target_w, py + target_h)

    shadow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow_layer, "RGBA")
    sd.rounded_rectangle(
        (rect[0], rect[1] + max(8, radius // 3), rect[2], rect[3] + max(8, radius // 3)),
        radius=radius,
        fill=shadow,
    )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=max(10, radius // 2)))
    canvas.alpha_composite(shadow_layer)

    card_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    cd = ImageDraw.Draw(card_layer, "RGBA")
    cd.rounded_rectangle(rect, radius=radius, fill=(255, 255, 255, 255), outline=border, width=2)
    canvas.alpha_composite(card_layer)

    inset = 3
    inner = shot.resize((target_w - inset * 2, target_h - inset * 2), Image.Resampling.LANCZOS)
    mask = Image.new("L", (target_w - inset * 2, target_h - inset * 2), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, target_w - inset * 2, target_h - inset * 2), radius=max(8, radius - 4), fill=255)
    canvas.paste(inner, (px + inset, py + inset), mask)


def draw_copy_block(
    canvas: Image.Image,
    title: str,
    subtitle: str,
    bullets: Iterable[str],
    block: tuple[int, int, int, int],
    title_color: tuple[int, int, int, int],
    subtitle_color: tuple[int, int, int, int],
    bullet_color: tuple[int, int, int, int],
    panel: tuple[int, int, int, int] | None = None,
) -> None:
    x1, y1, x2, y2 = block
    draw = ImageDraw.Draw(canvas, "RGBA")
    w, h = canvas.size

    if panel is not None:
        draw.rounded_rectangle((x1, y1, x2, y2), radius=max(24, w // 80), fill=panel, outline=(168, 193, 236, 180), width=2)

    margin_x = x1 + int(w * 0.024)
    content_w = (x2 - x1) - int(w * 0.048)
    y = y1 + int(h * 0.06)

    title_font = load_font(FONT_HEAVY, int(w * 0.029))
    subtitle_font = load_font(FONT_REGULAR, int(w * 0.0132))
    bullet_font = load_font(FONT_SEMIBOLD, int(w * 0.0124))
    meta_font = load_font(FONT_REGULAR, int(w * 0.0106))

    for line in wrap_lines(draw, title, title_font, content_w):
        draw.text((margin_x, y), line, font=title_font, fill=title_color)
        y += draw.textbbox((0, 0), line, font=title_font)[3] + int(h * 0.010)

    y += int(h * 0.01)
    for line in wrap_lines(draw, subtitle, subtitle_font, content_w):
        draw.text((margin_x, y), line, font=subtitle_font, fill=subtitle_color)
        y += draw.textbbox((0, 0), line, font=subtitle_font)[3] + int(h * 0.008)

    y += int(h * 0.02)
    dot_r = max(5, w // 950)
    for item in bullets:
        dot_x = margin_x + dot_r
        dot_y = y + dot_r + 1
        draw.ellipse((dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r), fill=(79, 137, 241, 255))
        draw.text((margin_x + int(w * 0.015), y - 2), item, font=bullet_font, fill=bullet_color)
        y += int(h * 0.046)

    draw.text((margin_x, y2 - int(h * 0.045)), "SSH  •  rsync  •  WP-CLI", font=meta_font, fill=(92, 119, 159, 235))


def render_variant(variant: str, size: tuple[int, int], slide: dict[str, object]) -> Image.Image:
    w, h = size
    shot = trim_black_border(Image.open(RAW_DIR / str(slide["raw"])).convert("RGBA"))
    focus = slide.get("focus")
    if isinstance(focus, (tuple, list)) and len(focus) == 4:
        shot = apply_focus_crop(shot, (float(focus[0]), float(focus[1]), float(focus[2]), float(focus[3])))
    canvas = Image.new("RGBA", (w, h), (240, 246, 255, 255))
    draw = ImageDraw.Draw(canvas, "RGBA")

    if variant == "v3_split_clean":
        gradient(canvas, (247, 251, 255), (220, 232, 250))
        draw.ellipse((int(w * 0.60), -int(h * 0.18), int(w * 1.07), int(h * 0.42)), fill=(126, 176, 255, 70))
        draw.ellipse((int(w * 0.50), int(h * 0.62), int(w * 1.02), int(h * 1.20)), fill=(110, 154, 235, 56))
        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.12), int(w * 0.43), int(h * 0.88)),
            title_color=(21, 35, 56, 255),
            subtitle_color=(51, 76, 108, 245),
            bullet_color=(35, 55, 85, 255),
            panel=(255, 255, 255, 218),
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.47),
            y1=int(h * 0.08),
            x2=int(w * 0.95),
            y2=int(h * 0.92),
            radius=max(20, w // 150),
            border=(174, 199, 236, 220),
            shadow=(20, 34, 57, 96),
        )
        return canvas.convert("RGB")

    if variant == "v4_diagonal":
        gradient(canvas, (18, 34, 62), (37, 71, 128))
        draw.polygon(
            [
                (0, int(h * 0.72)),
                (int(w * 0.52), 0),
                (w, 0),
                (w, int(h * 0.34)),
                (int(w * 0.46), h),
                (0, h),
            ],
            fill=(56, 108, 190, 110),
        )
        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.10), int(w * 0.40), int(h * 0.90)),
            title_color=(246, 251, 255, 255),
            subtitle_color=(209, 226, 252, 245),
            bullet_color=(225, 236, 255, 255),
            panel=(12, 28, 52, 175),
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.45),
            y1=int(h * 0.10),
            x2=int(w * 0.95),
            y2=int(h * 0.90),
            radius=max(22, w // 140),
            border=(185, 212, 252, 210),
            shadow=(6, 14, 28, 140),
        )
        return canvas.convert("RGB")

    if variant == "v5_dark_glow":
        gradient(canvas, (12, 20, 36), (18, 30, 54))
        glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow, "RGBA")
        gd.ellipse((int(w * 0.50), int(h * 0.02), int(w * 1.02), int(h * 0.64)), fill=(67, 128, 255, 88))
        gd.ellipse((-int(w * 0.20), int(h * 0.58), int(w * 0.38), int(h * 1.18)), fill=(84, 149, 255, 60))
        glow = glow.filter(ImageFilter.GaussianBlur(radius=max(20, w // 50)))
        canvas.alpha_composite(glow)
        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.11), int(w * 0.42), int(h * 0.89)),
            title_color=(247, 250, 255, 255),
            subtitle_color=(206, 221, 247, 245),
            bullet_color=(230, 239, 255, 255),
            panel=(11, 22, 40, 190),
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.46),
            y1=int(h * 0.08),
            x2=int(w * 0.95),
            y2=int(h * 0.92),
            radius=max(20, w // 150),
            border=(160, 197, 255, 220),
            shadow=(0, 0, 0, 165),
        )
        return canvas.convert("RGB")

    if variant == "v6_card_stack":
        gradient(canvas, (247, 251, 255), (226, 236, 252))
        draw.ellipse((int(w * 0.64), -int(h * 0.20), int(w * 1.12), int(h * 0.38)), fill=(123, 176, 255, 84))
        draw.rectangle((int(w * 0.43), int(h * 0.05), int(w * 0.46), int(h * 0.95)), fill=(179, 207, 247, 110))

        deco = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        dd = ImageDraw.Draw(deco, "RGBA")
        dd.rounded_rectangle(
            (int(w * 0.49), int(h * 0.13), int(w * 0.90), int(h * 0.78)),
            radius=max(20, w // 130),
            fill=(236, 244, 255, 200),
            outline=(183, 204, 238, 190),
            width=2,
        )
        deco = deco.filter(ImageFilter.GaussianBlur(radius=max(5, w // 300)))
        canvas.alpha_composite(deco)

        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.47),
            y1=int(h * 0.14),
            x2=int(w * 0.93),
            y2=int(h * 0.91),
            radius=max(20, w // 150),
            border=(168, 196, 239, 220),
            shadow=(20, 40, 68, 98),
        )
        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.12), int(w * 0.41), int(h * 0.88)),
            title_color=(20, 36, 60, 255),
            subtitle_color=(54, 80, 115, 245),
            bullet_color=(34, 54, 83, 255),
            panel=(255, 255, 255, 226),
        )
        return canvas.convert("RGB")

    if variant == "v7_ribbon_light":
        gradient(canvas, (246, 251, 255), (224, 237, 255))
        draw.polygon(
            [
                (int(w * 0.38), 0),
                (w, 0),
                (w, int(h * 0.36)),
                (int(w * 0.56), int(h * 0.72)),
                (int(w * 0.33), int(h * 0.42)),
            ],
            fill=(111, 165, 250, 78),
        )
        draw.ellipse((int(w * 0.64), -int(h * 0.24), int(w * 1.06), int(h * 0.26)), fill=(86, 151, 255, 78))
        draw.ellipse((int(w * 0.58), int(h * 0.64), int(w * 1.10), int(h * 1.26)), fill=(126, 179, 255, 64))

        ribbon = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        rd = ImageDraw.Draw(ribbon, "RGBA")
        rd.rounded_rectangle(
            (int(w * 0.48), int(h * 0.06), int(w * 0.95), int(h * 0.94)),
            radius=max(24, w // 120),
            outline=(152, 191, 245, 165),
            width=max(4, w // 420),
            fill=(255, 255, 255, 35),
        )
        ribbon = ribbon.filter(ImageFilter.GaussianBlur(radius=max(6, w // 260)))
        canvas.alpha_composite(ribbon)

        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.10), int(w * 0.41), int(h * 0.90)),
            title_color=(20, 38, 63, 255),
            subtitle_color=(53, 82, 118, 245),
            bullet_color=(33, 56, 89, 255),
            panel=(255, 255, 255, 225),
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.46),
            y1=int(h * 0.10),
            x2=int(w * 0.95),
            y2=int(h * 0.90),
            radius=max(22, w // 140),
            border=(170, 201, 241, 220),
            shadow=(24, 41, 67, 108),
        )
        return canvas.convert("RGB")

    if variant == "v8_glass_diagonal":
        gradient(canvas, (227, 239, 255), (201, 224, 255))
        draw.polygon(
            [
                (0, int(h * 0.82)),
                (int(w * 0.58), 0),
                (w, 0),
                (w, int(h * 0.28)),
                (int(w * 0.42), h),
                (0, h),
            ],
            fill=(46, 104, 189, 92),
        )

        glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow, "RGBA")
        gd.ellipse((int(w * 0.62), -int(h * 0.12), int(w * 1.12), int(h * 0.45)), fill=(122, 178, 255, 92))
        gd.ellipse((-int(w * 0.20), int(h * 0.56), int(w * 0.30), int(h * 1.20)), fill=(107, 167, 255, 72))
        glow = glow.filter(ImageFilter.GaussianBlur(radius=max(16, w // 70)))
        canvas.alpha_composite(glow)

        panel_layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        pd = ImageDraw.Draw(panel_layer, "RGBA")
        pd.rounded_rectangle(
            (int(w * 0.04), int(h * 0.08), int(w * 0.42), int(h * 0.92)),
            radius=max(26, w // 110),
            fill=(241, 248, 255, 170),
            outline=(166, 198, 241, 190),
            width=2,
        )
        panel_layer = panel_layer.filter(ImageFilter.GaussianBlur(radius=max(2, w // 600)))
        canvas.alpha_composite(panel_layer)

        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.10), int(w * 0.41), int(h * 0.90)),
            title_color=(17, 34, 57, 255),
            subtitle_color=(44, 72, 108, 245),
            bullet_color=(26, 50, 84, 255),
            panel=None,
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.45),
            y1=int(h * 0.09),
            x2=int(w * 0.95),
            y2=int(h * 0.91),
            radius=max(24, w // 135),
            border=(170, 204, 247, 220),
            shadow=(16, 34, 58, 120),
        )
        return canvas.convert("RGB")

    if variant == "v9_midnight_orbit":
        gradient(canvas, (8, 20, 44), (24, 48, 90))
        draw.polygon(
            [
                (0, int(h * 0.66)),
                (int(w * 0.44), int(h * 0.14)),
                (w, int(h * 0.02)),
                (w, int(h * 0.36)),
                (int(w * 0.58), h),
                (0, h),
            ],
            fill=(44, 97, 184, 98),
        )

        orbits = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        od = ImageDraw.Draw(orbits, "RGBA")
        od.ellipse((int(w * 0.56), -int(h * 0.28), int(w * 1.02), int(h * 0.32)), outline=(109, 168, 255, 88), width=max(2, w // 720))
        od.ellipse((int(w * 0.52), -int(h * 0.34), int(w * 1.10), int(h * 0.40)), outline=(91, 149, 236, 70), width=max(2, w // 760))
        od.ellipse((-int(w * 0.22), int(h * 0.56), int(w * 0.30), int(h * 1.18)), outline=(112, 174, 255, 78), width=max(2, w // 760))
        orbits = orbits.filter(ImageFilter.GaussianBlur(radius=max(2, w // 900)))
        canvas.alpha_composite(orbits)

        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.10), int(w * 0.41), int(h * 0.90)),
            title_color=(245, 249, 255, 255),
            subtitle_color=(208, 222, 247, 245),
            bullet_color=(229, 238, 255, 255),
            panel=(8, 24, 47, 178),
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.46),
            y1=int(h * 0.08),
            x2=int(w * 0.95),
            y2=int(h * 0.92),
            radius=max(22, w // 140),
            border=(165, 201, 255, 218),
            shadow=(0, 4, 18, 178),
        )
        return canvas.convert("RGB")

    if variant == "v10_sunrise_stack":
        gradient(canvas, (255, 246, 236), (229, 239, 255))
        draw.ellipse((-int(w * 0.12), -int(h * 0.34), int(w * 0.42), int(h * 0.38)), fill=(255, 186, 123, 70))
        draw.ellipse((int(w * 0.66), int(h * 0.52), int(w * 1.12), int(h * 1.20)), fill=(127, 173, 248, 92))
        draw.polygon(
            [
                (int(w * 0.34), 0),
                (w, 0),
                (w, int(h * 0.18)),
                (int(w * 0.46), int(h * 0.60)),
                (int(w * 0.26), int(h * 0.34)),
            ],
            fill=(242, 204, 162, 66),
        )

        deck = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        dd = ImageDraw.Draw(deck, "RGBA")
        dd.rounded_rectangle(
            (int(w * 0.08), int(h * 0.12), int(w * 0.56), int(h * 0.88)),
            radius=max(26, w // 120),
            fill=(255, 255, 255, 150),
            outline=(224, 197, 171, 150),
            width=2,
        )
        deck = deck.filter(ImageFilter.GaussianBlur(radius=max(4, w // 360)))
        canvas.alpha_composite(deck)

        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.10),
            y1=int(h * 0.14),
            x2=int(w * 0.58),
            y2=int(h * 0.90),
            radius=max(22, w // 140),
            border=(224, 200, 174, 215),
            shadow=(55, 42, 36, 100),
        )
        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.61), int(h * 0.10), int(w * 0.95), int(h * 0.90)),
            title_color=(58, 40, 26, 255),
            subtitle_color=(98, 72, 49, 245),
            bullet_color=(76, 53, 31, 255),
            panel=(255, 251, 244, 208),
        )
        return canvas.convert("RGB")

    if variant == "v11_lumen_arc":
        gradient(canvas, (255, 251, 242), (228, 241, 255))
        draw.ellipse((-int(w * 0.16), -int(h * 0.30), int(w * 0.44), int(h * 0.36)), fill=(255, 185, 118, 72))
        draw.ellipse((int(w * 0.52), int(h * 0.56), int(w * 1.08), int(h * 1.22)), fill=(128, 178, 255, 86))
        draw.polygon(
            [
                (int(w * 0.30), 0),
                (w, 0),
                (w, int(h * 0.30)),
                (int(w * 0.56), int(h * 0.70)),
                (int(w * 0.26), int(h * 0.40)),
            ],
            fill=(250, 208, 162, 78),
        )

        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.10), int(w * 0.41), int(h * 0.90)),
            title_color=(52, 38, 28, 255),
            subtitle_color=(88, 67, 47, 245),
            bullet_color=(70, 50, 33, 255),
            panel=(255, 252, 246, 220),
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.45),
            y1=int(h * 0.10),
            x2=int(w * 0.95),
            y2=int(h * 0.90),
            radius=max(22, w // 140),
            border=(219, 198, 172, 220),
            shadow=(64, 50, 39, 100),
        )
        return canvas.convert("RGB")

    if variant == "v12_skyline_ribbon":
        gradient(canvas, (239, 248, 255), (222, 238, 255))
        draw.polygon(
            [
                (0, int(h * 0.82)),
                (int(w * 0.54), 0),
                (w, 0),
                (w, int(h * 0.34)),
                (int(w * 0.48), h),
                (0, h),
            ],
            fill=(90, 146, 236, 95),
        )
        draw.ellipse((int(w * 0.68), -int(h * 0.22), int(w * 1.08), int(h * 0.24)), fill=(129, 186, 255, 96))
        draw.rectangle((int(w * 0.60), int(h * 0.08), int(w * 0.62), int(h * 0.92)), fill=(170, 204, 246, 110))

        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.06),
            y1=int(h * 0.12),
            x2=int(w * 0.56),
            y2=int(h * 0.90),
            radius=max(22, w // 140),
            border=(170, 204, 245, 218),
            shadow=(20, 44, 80, 108),
        )
        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.61), int(h * 0.10), int(w * 0.95), int(h * 0.90)),
            title_color=(20, 38, 62, 255),
            subtitle_color=(49, 76, 110, 245),
            bullet_color=(30, 53, 86, 255),
            panel=(247, 251, 255, 208),
        )
        return canvas.convert("RGB")

    if variant == "v13_ice_glass":
        gradient(canvas, (248, 252, 255), (228, 243, 255))
        draw.ellipse((-int(w * 0.22), int(h * 0.56), int(w * 0.30), int(h * 1.20)), fill=(141, 192, 255, 64))
        draw.ellipse((int(w * 0.62), -int(h * 0.18), int(w * 1.10), int(h * 0.32)), fill=(158, 205, 255, 84))

        frost = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        fd = ImageDraw.Draw(frost, "RGBA")
        fd.rounded_rectangle(
            (int(w * 0.04), int(h * 0.08), int(w * 0.42), int(h * 0.92)),
            radius=max(28, w // 100),
            fill=(246, 251, 255, 165),
            outline=(174, 205, 246, 192),
            width=2,
        )
        frost = frost.filter(ImageFilter.GaussianBlur(radius=max(3, w // 540)))
        canvas.alpha_composite(frost)

        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.10), int(w * 0.41), int(h * 0.90)),
            title_color=(15, 36, 62, 255),
            subtitle_color=(44, 73, 109, 245),
            bullet_color=(27, 53, 86, 255),
            panel=None,
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.45),
            y1=int(h * 0.08),
            x2=int(w * 0.95),
            y2=int(h * 0.92),
            radius=max(24, w // 132),
            border=(166, 204, 248, 220),
            shadow=(16, 37, 67, 112),
        )
        return canvas.convert("RGB")

    if variant == "v14_sunbeam_split":
        gradient(canvas, (255, 247, 233), (234, 243, 255))
        draw.polygon(
            [
                (0, int(h * 0.72)),
                (int(w * 0.48), int(h * 0.02)),
                (w, 0),
                (w, int(h * 0.42)),
                (int(w * 0.58), h),
                (0, h),
            ],
            fill=(110, 165, 244, 84),
        )
        draw.ellipse((-int(w * 0.18), -int(h * 0.26), int(w * 0.40), int(h * 0.34)), fill=(255, 178, 111, 80))
        draw.ellipse((int(w * 0.62), int(h * 0.58), int(w * 1.14), int(h * 1.22)), fill=(126, 178, 255, 88))

        draw_copy_block(
            canvas=canvas,
            title=str(slide["title"]),
            subtitle=str(slide["subtitle"]),
            bullets=tuple(slide["bullets"]),  # type: ignore[arg-type]
            block=(int(w * 0.05), int(h * 0.11), int(w * 0.41), int(h * 0.89)),
            title_color=(55, 37, 22, 255),
            subtitle_color=(96, 69, 45, 245),
            bullet_color=(74, 50, 28, 255),
            panel=(255, 252, 244, 216),
        )
        place_card(
            canvas=canvas,
            screenshot=shot,
            x1=int(w * 0.45),
            y1=int(h * 0.10),
            x2=int(w * 0.95),
            y2=int(h * 0.90),
            radius=max(22, w // 140),
            border=(216, 194, 170, 215),
            shadow=(58, 45, 34, 104),
        )
        return canvas.convert("RGB")

    raise ValueError(f"Unknown variant: {variant}")


def generate_variant(variant: str) -> Path:
    output_dir = ITERATIONS_DIR / variant
    output_dir.mkdir(parents=True, exist_ok=True)
    for w, h in TARGET_SIZES:
        for slide in SLIDES:
            out = output_dir / f"{slide['slug']}-{w}x{h}.png"
            image = render_variant(variant, (w, h), slide)
            image.save(out, "PNG", optimize=True)
            print(out)
    return output_dir


def promote_variant(output_dir: Path) -> None:
    APP_STORE_DIR.mkdir(parents=True, exist_ok=True)
    for png in sorted(output_dir.glob("*.png")):
        shutil.copy2(png, APP_STORE_DIR / png.name)
        print(APP_STORE_DIR / png.name)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate dynamic App Store screenshot variants.")
    parser.add_argument("--variant", choices=list(VARIANTS), help="Generate one variant only.")
    parser.add_argument("--promote", choices=list(VARIANTS), help="Copy selected variant into screenshots/app-store/macos.")
    args = parser.parse_args()

    if args.variant:
        generate_variant(args.variant)
    else:
        for variant in VARIANTS:
            generate_variant(variant)

    if args.promote:
        promote_variant(ITERATIONS_DIR / args.promote)


if __name__ == "__main__":
    main()
