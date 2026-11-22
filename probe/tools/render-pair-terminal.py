#!/usr/bin/env python3
"""Render a captured pairing PTY (ANSI half blocks + SAS) to a PNG with Pillow."""
import math
from pathlib import Path
import re
import sys
from PIL import Image, ImageDraw, ImageFont

source, destination = map(Path, sys.argv[1:3])
font_path = sys.argv[3] if len(sys.argv) > 3 else "/System/Library/Fonts/Menlo.ttc"
font = ImageFont.truetype(font_path, 20)
cjk_path = Path("/System/Library/Fonts/STHeiti Medium.ttc")
cjk = ImageFont.truetype(str(cjk_path), 20) if cjk_path.exists() else font
lines = source.read_text().replace("\r\n", "\n").splitlines()
plain = [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in lines]
cell, height, margin = math.ceil(font.getlength("M")), 24, 24
canvas = Image.new("RGB", (max(map(len, plain)) * cell + margin * 2, len(lines) * height + margin * 2), (18, 22, 28))
draw = ImageDraw.Draw(canvas)
for row, (raw, line) in enumerate(zip(lines, plain)):
    y = margin + row * height
    if raw.startswith("\033[30;107m"):
        for col, char in enumerate(line):
            for half, dark in enumerate({" ": (False, False), "▀": (True, False), "▄": (False, True), "█": (True, True)}[char]):
                x, top = margin + col * cell, y + half * height // 2
                draw.rectangle((x, top, x + cell - 1, top + height // 2 - 1), fill="black" if dark else "white")
    else:
        draw.text((margin, y), line, font=cjk if any(ord(char) > 127 for char in line) else font, fill=(222, 235, 228))
canvas.save(destination)
print(f"Rendered terminal capture: {destination} ({canvas.width}x{canvas.height})")
