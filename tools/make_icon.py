#!/usr/bin/env python3
"""產生「愛車記錄」App 圖示的全部尺寸（需要 Pillow：pip install pillow）。

圖案：深青綠底，白色的小車側面剪影 + 橘色油滴徽章（加油 / 保養車輛）。
和 Mido筆記 的圖示在顏色與圖形上都明顯不同。

輸出到 branding/（已提交進倉庫，CI 不需要 Pillow，只負責複製）：
  branding/icon_1024.png                      預覽用
  branding/android/res/mipmap-*/ic_launcher.png            舊版（含背景）
  branding/android/res/mipmap-*/ic_launcher_foreground.png 自適應圖示前景
  branding/android/res/mipmap-anydpi-v26/ic_launcher.xml   自適應圖示
  branding/android/res/values/garage_icon_colors.xml       自適應圖示背景色
  branding/windows/app_icon.ico

重新產生：python3 tools/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

BG_TOP = (18, 94, 107)      # 深青綠
BG_BOTTOM = (8, 52, 68)     # 更深
CAR = (255, 255, 255)
GLASS = (18, 94, 107)
ACCENT = (255, 138, 0)      # 橘色油滴
SS = 4                      # 超取樣倍率（抗鋸齒）

OUT = Path("branding")


def gradient(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        c = tuple(round(BG_TOP[i] * (1 - t) + BG_BOTTOM[i] * t) for i in range(3))
        for x in range(size):
            px[x, y] = c
    return img


def draw_art(size: int, scale: float = 1.0) -> Image.Image:
    """透明底的前景圖案。scale<1 時縮小（自適應圖示的安全區）。"""
    big = size * SS
    art = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)

    def P(x, y):  # 0..100 座標 → 像素，並套用縮放（以中心為基準）
        cx = cy = 50
        x = cx + (x - cx) * scale
        y = cy + (y + 7 - cy) * scale
        return (x / 100 * big, y / 100 * big)

    def poly(points, fill):
        d.polygon([P(x, y) for x, y in points], fill=fill)

    # 車身（側面）：底盤 + 車頂的圓滑多邊形
    poly([(14, 62), (14, 52), (24, 48), (33, 36), (45, 31), (60, 31),
          (70, 37), (78, 48), (88, 52), (90, 62), (90, 66), (14, 66)], CAR)
    # 車窗
    poly([(36, 47), (41, 37), (49, 36), (49, 47)], GLASS)
    poly([(53, 47), (53, 36), (60, 36), (68, 47)], GLASS)
    # 輪子：深色外圈（壓在車身底部，形成輪拱）+ 白色輪框
    for cx in (31, 73):
        d.ellipse([*P(cx - 11.5, 55.5), *P(cx + 11.5, 78.5)], fill=BG_BOTTOM)
        d.ellipse([*P(cx - 7.5, 59.5), *P(cx + 7.5, 74.5)], fill=CAR)
        d.ellipse([*P(cx - 2.5, 64.5), *P(cx + 2.5, 69.5)], fill=BG_BOTTOM)
    # 橘色油滴徽章（右上角，帶白色外框）
    r = 15
    bx, by = 77, 25
    d.ellipse([*P(bx - r - 2.5, by - r - 2.5), *P(bx + r + 2.5, by + r + 2.5)], fill=CAR)
    d.ellipse([*P(bx - r, by - r), *P(bx + r, by + r)], fill=ACCENT)
    # 油滴：圓 + 三角形尖端
    d.ellipse([*P(bx - 7.5, by - 0.5), *P(bx + 7.5, by + 14.5)], fill=CAR)
    poly([(bx, by - 11), (bx + 7.1, by + 4), (bx - 7.1, by + 4)], CAR)

    return art.resize((size, size), Image.LANCZOS)


def rounded_mask(size: int, radius_ratio: float) -> Image.Image:
    big = size * SS
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=int(big * radius_ratio), fill=255
    )
    return m.resize((size, size), Image.LANCZOS)


def legacy_icon(size: int) -> Image.Image:
    """含背景的圓角方形圖示（舊版 Android、Windows）。"""
    bg = gradient(size).convert("RGBA")
    bg.alpha_composite(draw_art(size, 1.0))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), rounded_mask(size, 0.22))
    return out


def adaptive_foreground(size: int) -> Image.Image:
    """自適應圖示前景：108dp 畫布，內容限制在中央 66dp 安全區內。"""
    return draw_art(size, 66 / 108 * 1.12)


def main() -> None:
    res = OUT / "android" / "res"
    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    fore = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for dpi, px in legacy.items():
        d = res / f"mipmap-{dpi}"
        d.mkdir(parents=True, exist_ok=True)
        legacy_icon(px).save(d / "ic_launcher.png")
        adaptive_foreground(fore[dpi]).save(d / "ic_launcher_foreground.png")

    v26 = res / "mipmap-anydpi-v26"
    v26.mkdir(parents=True, exist_ok=True)
    (v26 / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/garage_icon_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    values = res / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "garage_icon_colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="garage_icon_background">#0F4C5C</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )

    big = legacy_icon(1024)
    big.save(OUT / "icon_1024.png")
    win = OUT / "windows"
    win.mkdir(parents=True, exist_ok=True)
    big.save(
        win / "app_icon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print("已產生", OUT)


if __name__ == "__main__":
    main()
