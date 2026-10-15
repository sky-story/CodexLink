#!/usr/bin/env python3
"""Render a labeled notification illustration, never a claimed device screenshot.

Requires Pillow and macOS fonts. Only public, pinned artwork is downloaded;
this script never reads Bark configuration or sends a notification.
"""
import hashlib
import urllib.request
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / '.build/docs-artwork'
OUT = ROOT / 'docs/images'
ARTWORK = {
    'claude': (
        'https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/51/61/43/51614377-8976-4277-5f5e-90c614b04913/AppIcon-0-0-1x_U007epad-0-1-85-220.png/512x512bb.jpg',
        'f09be3bc8dce0094a6bcbe4a20ae16f077f86f723e825f65ed4e24d02bd04aaa',
    ),
    'bark': (
        'https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/fa/34/e6/fa34e6bd-879d-9cc3-eae6-95cfab8c3720/AppIcon-0-0-1x_U007epad-0-0-0-1-0-0-85-220.png/512x512bb.jpg',
        'd51181848d9417347efd12888761dbf609e430cbc525622fa6b571403b9d4b57',
    ),
}


def artwork(name):
    url, digest = ARTWORK[name]
    file = CACHE / f'{name}.jpg'
    if not file.exists():
        with urllib.request.urlopen(url, timeout=20) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f'{name}: artwork changed; review before updating the digest')
        file.write_bytes(data)
    if hashlib.sha256(file.read_bytes()).hexdigest() != digest:
        raise ValueError(f'{name}: cached artwork checksum mismatch')
    return Image.open(file).convert('RGBA')


def font(size, bold=False):
    weight = 'Medium' if bold else 'Light'
    return ImageFont.truetype(f'/System/Library/Fonts/STHeiti {weight}.ttc', size)


def paste_icon(canvas, source, xy, size, radius):
    # Render masks at higher resolution for smooth small notification badges.
    mask = Image.new('L', (size * 4, size * 4))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=radius * 4, fill=255)
    mask = mask.resize((size, size), Image.Resampling.LANCZOS)
    icon = source.resize((size, size), Image.Resampling.LANCZOS)
    canvas.paste(icon, xy, mask)


def render(language, codex, claude, bark):
    canvas = Image.new('RGBA', (1200, 760), '#f2f4fb')
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((64, 42, 110, 49), radius=3, fill='#6665e8')
    if language == 'zh':
        title, subtitle = '离开电脑，也能收到提醒', 'Codex + Claude · 通过 Bark 推送'
        badge, bottom = '通知示意 · 示例文字', '不同来源，一眼识别。'
        foot = '右下角的 Bark 小图标由 iOS 显示，用于标明通知来源。'
    else:
        title, subtitle = 'Updates, even away from your Mac', 'Codex + Claude · Lock-screen alerts via Bark'
        badge, bottom = 'Illustration · Sample text', 'Distinct icons. Clear session labels.'
        foot = 'iOS keeps the small Bark badge to identify the app delivering the notification.'
    draw.text((64, 76), title, font=font(42, True), fill='#1e2741')
    draw.text((64, 137), subtitle, font=font(24), fill='#626e88')
    draw.text((1136, 165), badge, font=font(20), fill='#626e88', anchor='rt')

    for y, icon, title, label in [
        (208, codex, 'Codex · 任务已完成', '示例：待办 App · a1b2c3d4'),
        (420, claude, 'Claude · 本轮已回复', '示例：网站改版 · 8e2a9f10'),
    ]:
        shadow = Image.new('RGBA', canvas.size)
        ImageDraw.Draw(shadow).rounded_rectangle((64, y + 8, 1136, y + 196), radius=28, fill=(39, 51, 89, 17))
        canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
        draw = ImageDraw.Draw(canvas)
        draw.rounded_rectangle((64, y, 1136, y + 188), radius=28, fill='#ffffff', outline='#e1e5f0', width=1)
        paste_icon(canvas, icon, (104, y + 46), 96, 48)
        draw.rounded_rectangle((170, y + 110, 211, y + 151), radius=12, fill='white')
        paste_icon(canvas, bark, (173, y + 113), 35, 9)
        draw.text((240, y + 45), title, font=font(36, True), fill='#192237')
        draw.text((240, y + 103), label, font=font(29), fill='#5c687f')
        draw.text((1094, y + 49), '现在', font=font(24), fill='#8791a3', anchor='rt')

    draw.text((64, 651), bottom, font=font(28, True), fill='#2f3b55')
    draw.text((64, 700), foot, font=font(22), fill='#626e88')
    name = 'notifications-preview.png' if language == 'zh' else 'notifications-preview-en.png'
    canvas.convert('RGB').save(OUT / name, optimize=True)


if __name__ == '__main__':
    CACHE.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    codex = Image.open(ROOT / 'CodexMobile/CodexMobile/Assets.xcassets/AppLogo.imageset/CodexRemote-iOS-Default-1024x1024.png').convert('RGBA')
    claude, bark = artwork('claude'), artwork('bark')
    for language in ['zh', 'en']:
        render(language, codex, claude, bark)
    print('Rendered two labeled notification illustrations. Review before publication.')
