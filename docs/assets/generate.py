#!/usr/bin/env python3
"""Regenerate bilingual heroes from the committed, real simulator captures (Pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
FONT = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def font(size, bold=False):
    return ImageFont.truetype(BOLD if bold else FONT, size)


def phone(canvas, path, x, y, height):
    source = Image.open(path).convert("RGB")
    width = round(height * source.width / source.height)
    screen = source.resize((width, height), Image.Resampling.LANCZOS)
    mask = Image.new("L", screen.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width, height), 48, fill=255)
    shadow = Image.new("RGBA", canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x-15, y-10, x+width+15, y+height+25), 65, fill=(0, 0, 0, 180))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(24)))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x-13, y-13, x+width+13, y+height+13), 62, fill="#080b0f", outline="#58616a", width=3)
    canvas.paste(screen, (x, y), mask)


def hero(language):
    en = language == "en"
    canvas = Image.new("RGBA", (2400, 1200))
    draw = ImageDraw.Draw(canvas)
    for y in range(1200):
        for x in range(2400):
            glow = max(0, 1 - ((x-1650)**2/1900**2 + (y-300)**2/1300**2))
            canvas.putpixel((x, y), (round(12+9*glow), round(15+16*glow), round(21+19*glow), 255))
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((1150, -600, 2700, 1300), outline="#25353b", width=2)
    draw.ellipse((1010, -740, 2840, 1440), outline="#1d2a31", width=2)
    icon = Image.open(ROOT / "design/icon.png").convert("RGBA").resize((144, 144), Image.Resampling.LANCZOS)
    icon_mask = Image.new("L", icon.size)
    ImageDraw.Draw(icon_mask).rounded_rectangle((0, 0, 143, 143), 32, fill=255)
    icon.putalpha(icon_mask)
    canvas.alpha_composite(icon, (110, 224))
    draw.text((110, 398), "NodePulse", font=font(104, True), fill="#f3f5f7")
    tagline = ["Small probe. Complete control.", "Your infrastructure, in your pocket."] if en else ["轻量探针，掌握每一次脉动。", "从路由器到云端，尽在掌中。"]
    for index, line in enumerate(tagline):
        draw.text((114, 555+index*64), line, font=font(39 if en else 42), fill="#c0c9cf")
    features = ["Direct & opaque E2E relay", "Terminal, files & two-sided SAS pairing", "English / 简体中文 · Default / Grayscale"] if en else ["直连 / 不透明端到端共享中继", "终端与文件管理 / 双端 SAS 核对", "中文 / English · 默认 / 灰阶主题"]
    for index, line in enumerate(features):
        top = 740 + index*60
        draw.ellipse((116, top+17, 126, top+27), fill="#50b6aa")
        draw.text((148, top), line, font=font(29), fill="#b0bdc5")
    draw.rounded_rectangle((112, 970, 900, 1070), 22, fill="#182329", outline="#30434a", width=2)
    draw.text((144, 994), "C / static musl    ·    7 architectures    ·    lite < 200 KB", font=font(27), fill="#9dd6cc")
    phone(canvas, HERE / f"dashboard-{language}.png", 1115, 230, 870)
    phone(canvas, HERE / f"pairing-{language}.png", 1810, 240, 860)
    phone(canvas, HERE / f"detail-{language}.png", 1450, 120, 1020)
    destination = HERE / ("hero-en.png" if en else "hero.png")
    canvas.convert("RGB").quantize(colors=192, method=Image.Quantize.MEDIANCUT).save(destination, optimize=True)
    print(f"{destination.name}: 2400x1200, {destination.stat().st_size} bytes")


if __name__ == "__main__":
    for language in ("zh", "en"):
        hero(language)
