#!/usr/bin/env python3
"""Compose the README cover from public, fictional SwiftUI preview screenshots.

Requires macOS and Pillow. Uses the repository's existing fonts and images,
plus the system Chinese font; no network, simulator, private configuration,
or running service is accessed.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
IMAGES = ROOT / "docs/images"
FONTS = ROOT / "CodexMobile/CodexMobile/Fonts"
SIZE = (1800, 1000)
GREEN = "#A6E3A1"


def font(size: int, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / f"Geist-{weight}.ttf"), size)


def chinese_font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", size)


def screenshot_card(canvas: Image.Image, name: str, xy: tuple[int, int], label: str, chinese: bool) -> None:
    x, y = xy
    screenshot = Image.open(IMAGES / name).convert("RGB")
    width = 352
    height = round(screenshot.height * width / screenshot.width)
    screenshot = screenshot.resize((width, height), Image.Resampling.LANCZOS)
    box = (x - 12, y - 12, x + width + 12, y + height + 12)

    shadow = Image.new("RGBA", SIZE)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + 16, box[2], box[3] + 16), radius=30, fill=(0, 0, 0, 150)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(24)))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(box, radius=30, fill="#242424", outline="#505050", width=2)
    # Keep the full source image, including its offline-demo banner.
    canvas.paste(screenshot, (x, y))
    draw.text((x, y - 58), label, font=chinese_font(20) if chinese else font(20, "Medium"), fill=GREEN)


def render(chinese: bool = False) -> None:
    canvas = Image.new("RGBA", SIZE, "#111111")
    draw = ImageDraw.Draw(canvas)

    # Quiet graphite grid; all emphasis uses the project's green accent.
    for x in range(800, SIZE[0], 56):
        draw.line((x, 0, x, SIZE[1]), fill="#191919", width=1)
    for y in range(0, SIZE[1], 56):
        draw.line((800, y, SIZE[0], y), fill="#191919", width=1)

    draw.rounded_rectangle((96, 106, 104, 138), radius=4, fill=GREEN)
    draw.text((124, 104), "MAC  /  IPHONE", font=font(24, "Medium"), fill="#B7B7B7")
    draw.text((90, 218), "离开书桌，" if chinese else "Keep your", font=chinese_font(80) if chinese else font(88, "SemiBold"), fill="#F5F5F5")
    draw.text((90, 318), "会话仍在手边。" if chinese else "session close.", font=chinese_font(80) if chinese else font(88, "SemiBold"), fill=GREEN)
    draw.text((96, 476), "Codex CLI + Claude Code.", font=font(30), fill="#EEEEEE")
    draw.text((96, 526), "一个原生 iPhone App。" if chinese else "One native iPhone companion.", font=chinese_font(30) if chinese else font(30), fill="#B7B7B7")

    draw.line((96, 654, 658, 654), fill="#383838", width=2)
    steps = [(96, "01", "Mac 上运行" if chinese else "Run on Mac"), (300, "02", "私网配对" if chinese else "Pair privately"), (504, "03", "手机接着聊" if chinese else "Stay in touch")]
    for x, number, label in steps:
        draw.text((x, 692), number, font=font(20, "Medium"), fill=GREEN)
        draw.text((x, 732), label, font=chinese_font(22) if chinese else font(22, "Medium"), fill="#E5E5E5")

    draw.text((96, 894), "离线界面预览" if chinese else "OFFLINE UI PREVIEWS", font=chinese_font(18) if chinese else font(18, "Medium"), fill="#A0A0A0")
    draw.text((96, 925), "虚构数据 · 真实 SwiftUI 界面" if chinese else "Fictional data. Actual SwiftUI views.", font=chinese_font(18) if chinese else font(18), fill="#A0A0A0")

    screenshot_card(canvas, "session-queue.png", (866, 120), "CODEX  /  指引与排队" if chinese else "CODEX  /  STEER & QUEUE", chinese)
    screenshot_card(canvas, "claude-approval.png", (1308, 164), "CLAUDE  /  消息与审批" if chinese else "CLAUDE  /  MESSAGES & REQUESTS", chinese)

    destination = IMAGES / ("readme-showcase.zh-CN.png" if chinese else "readme-showcase.png")
    canvas.convert("RGB").save(destination, optimize=True)
    print(f"Wrote {destination.relative_to(ROOT)} ({destination.stat().st_size:,} bytes)")


if __name__ == "__main__":
    render()
    render(chinese=True)
