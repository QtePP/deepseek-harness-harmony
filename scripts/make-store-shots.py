#!/usr/bin/env python3
"""Compose AGC store screenshots (9:16, 1080x1920) from raw device captures.

AGC 应用介绍截图 requirements: 3-10 images, >=720x1280, aspect 9:16,
PNG/JPG <=5MB. Raw captures are 1320x2848 (phone) so they are cropped to drop
the status bar (personal notification icons) and then framed with the brand
header. Source PNGs live in .build/shots/ and are gitignored.

Usage:
    python3 scripts/make-store-shots.py
Outputs to .build/store-shots/; copy the keepers into store-assets/screenshots/.
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1080, 1920
OUT = ".build/store-shots"
os.makedirs(OUT, exist_ok=True)

CN_BOLD = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 1, index=2)
CN_REG  = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 1, index=0)
EN_DEMI = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 1, index=2)

def f(base, size):
    return base.font_variant(size=size)

BRAND = (77, 107, 254)
INK   = (18, 20, 26)
SUB   = (107, 114, 128)

def mark(size):
    im = Image.open("AppScope/resources/base/media/foreground.png").convert("L")
    # dark strokes on white -> alpha = 255 - luminance
    alpha = im.point(lambda v: 255 - v)
    rgba = Image.new("RGBA", im.size, (18, 20, 26, 0))
    rgba.putalpha(alpha)
    return rgba.resize((size, size), Image.LANCZOS)

def background():
    base = Image.new("RGB", (W, H), (255, 255, 255))
    d = ImageDraw.Draw(base)
    for y in range(H):
        t = y / H
        r = int(246 - 14 * t); g = int(248 - 10 * t); b = int(255 - 4 * t)
        d.line([(0, y), (W, y)], fill=(r, g, b))
    # soft brand glow, top right
    glow = Image.new("L", (W, H), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W - 420, -320, W + 260, 340], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    tint = Image.new("RGB", (W, H), (196, 208, 255))
    base = Image.composite(tint, base, glow)
    return base

def shadow_card(size, radius, blur=42, alpha=64, dy=26):
    w, h = size
    pad = blur * 3
    layer = Image.new("L", (w + pad * 2, h + pad * 2), 0)
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([pad, pad + dy, pad + w, pad + h + dy], radius=radius, fill=alpha)
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    return layer, pad

def compose(src, out, headline, sub, card_zoom=1.0, crop_bottom=0):
    bg = background()
    draw = ImageDraw.Draw(bg)

    # brand row
    m = mark(58)
    bg.paste(m, (96, 92), m)
    draw.text((96 + 58 + 22, 92 + 29), "TA Harness", font=f(EN_DEMI, 34), fill=INK, anchor="lm")

    # headline
    hf = f(CN_BOLD, 66)
    y = 210
    for line in headline:
        draw.text((96, y), line, font=hf, fill=INK)
        y += 92
    draw.text((96, y + 8), sub, font=f(CN_REG, 33), fill=SUB)
    y += 8 + 33 + 54

    shot = Image.open(src).convert("RGB")
    if crop_bottom:
        shot = shot.crop((0, 0, shot.width, shot.height - crop_bottom))
    sw, sh = shot.size
    aspect = sw / sh

    card_top = y
    card_h = H - card_top - 56
    card_w = int(round(card_h * aspect))
    if card_w > 986:
        card_w = 986
        card_h = int(round(card_w / aspect))
        # centre the card in the space under the copy instead of pinning it
        # to the bottom, so a cropped source does not leave a hole up top
        card_top = y + (H - 56 - card_h - y) // 2
    if card_zoom != 1.0:
        card_h = int(card_h * card_zoom)
        card_w = int(round(card_h * aspect))
        card_top = y + (H - 56 - card_h - y) // 2
    card_x = (W - card_w) // 2
    radius = 46

    sh_layer, pad = shadow_card((card_w, card_h), radius)
    bg.paste(Image.new("RGB", sh_layer.size, (24, 32, 64)), (card_x - pad, card_top - pad), sh_layer)

    card = shot.resize((card_w, card_h), Image.LANCZOS)
    mask = Image.new("L", (card_w, card_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, card_w - 1, card_h - 1], radius=radius, fill=255)
    bg.paste(card, (card_x, card_top), mask)

    d2 = ImageDraw.Draw(bg)
    d2.rounded_rectangle([card_x, card_top, card_x + card_w - 1, card_top + card_h - 1],
                         radius=radius, outline=(214, 220, 234), width=2)
    bg.save(out, "PNG", optimize=True)
    print("wrote", out, bg.size, os.path.getsize(out) // 1024, "KB")

SHOTS = [
    ("q_answer",  ["看得懂照片，", "也写得出文件"], "识别晚餐照片、算营养、落盘 Markdown 与网页",
     "01-chat.png", 0),
    ("q_trace",   ["每一步工具调用", "都摊开给你看"], "思考、grep、read、edit、todo，逐条可展开",
     "02-trace.png", 0),
    ("q_files",   ["产物就在", "你自己的目录里"], "Markdown、HTML、代码，点开即预览",
     "03-files.png", 0),
    ("q_sessions_final", ["按项目分开的会话"], "每个项目一个工作目录，历史随时接着聊",
     "04-sessions.png", 0),
    ("r4",        ["密钥、模型、权限", "都归你管"], "权限三档 + 能力开关，密钥只存本机沙箱",
     "05-settings.png", 0),
]

for src, head, sub, name, cut in SHOTS:
    path = f".build/shots/sheet/{src}.png"
    if not os.path.exists(path):
        path = f".build/shots/crop/{src}.png"
    if not os.path.exists(path):
        print("MISSING", path); continue
    compose(path, os.path.join(OUT, name), head, sub, crop_bottom=cut)
