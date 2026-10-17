"""App Store 用の画像を作る（iPhone 6.9インチ：1320x2868）。

シミュレータで撮った本物の画面（store-screenshots）に、上部の見出しを付けるだけ。画面そのものには手を加えない。
有料の内容が写る画像には「プレミアム（有料）」の注記を入れる（App Store Review Guidelines 2.3.2）。

使い方: python scripts/make-store-images.py スクリーンショットのフォルダ 出力フォルダ フォント(NotoSansJP-VF.ttf)
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

WIDTH, HEIGHT = 1320, 2868
INK = (51, 38, 41)
PINK = (255, 92, 133)
SUB = (120, 104, 107)

SLIDES = [
    ("1_preview", "撮った作品は、そのまま。", "アプリ内カメラで作品を撮影", None),
    ("2_cutout", "作品を自動で切り抜き", "端末の中で処理。写真を外部に送りません", None),
    ("3_background", "背景だけを差し替え", "木・布・カフェ・植物など。明るさや影も調整", "※一部の背景はプレミアム（有料）です"),
    ("4_export", "そのままSNSへ", "1:1・4:5・9:16で保存・共有", "※この背景と透かしなしの書き出しはプレミアム（有料）です"),
]


def font(path, size, weight):
    f = ImageFont.truetype(path, size)
    try:
        f.set_variation_by_axes([weight])
    except Exception:
        pass
    return f


def fitted(draw, text, font_path, size, weight, max_width):
    """左右の余白に収まるまで文字を小さくする。"""
    while True:
        f = font(font_path, size, weight)
        box = draw.textbbox((0, 0), text, font=f)
        if box[2] - box[0] <= max_width or size <= 40:
            return f
        size -= 4


def centered(draw, y, text, f, fill):
    box = draw.textbbox((0, 0), text, font=f)
    draw.text(((WIDTH - (box[2] - box[0])) / 2 - box[0], y), text, font=f, fill=fill)
    return box[3] - box[1]


def make(screens: Path, out: Path, font_path: str):
    out.mkdir(parents=True, exist_ok=True)
    for name, title, subtitle, note in SLIDES:
        canvas = Image.new("RGB", (WIDTH, HEIGHT))
        draw = ImageDraw.Draw(canvas)
        # 背景：上がピーチ、下がクリームのグラデーション
        for y in range(HEIGHT):
            t = min(1, y / (HEIGHT * 0.6))
            color = tuple(int(a + (b - a) * t) for a, b in zip((255, 226, 214), (255, 248, 242)))
            draw.line([(0, y), (WIDTH, y)], fill=color)

        margin = 110
        y = 150
        y += centered(draw, y, title, fitted(draw, title, font_path, 104, 900, WIDTH - margin * 2), INK) + 46
        y += centered(draw, y, subtitle, fitted(draw, subtitle, font_path, 50, 600, WIDTH - margin * 2), PINK) + 30
        if note:
            centered(draw, y, note, fitted(draw, note, font_path, 36, 500, WIDTH - margin * 2), SUB)

        # 本物の画面を縮小して角丸で置く（画面の中身は変えない）
        shot = Image.open(screens / f"{name}.png").convert("RGB")
        scale = 0.78
        sw, sh = int(shot.width * scale), int(shot.height * scale)
        shot = shot.resize((sw, sh), Image.LANCZOS)
        x = (WIDTH - sw) // 2
        top = 560
        radius = 70
        mask = Image.new("L", (sw, sh), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), radius=radius, fill=255)

        shadow = Image.new("L", (WIDTH, HEIGHT), 0)
        ImageDraw.Draw(shadow).rounded_rectangle((x, top + 24, x + sw, top + sh + 24), radius=radius, fill=90)
        shadow = shadow.filter(ImageFilter.GaussianBlur(36))
        canvas.paste((150, 90, 90), (0, 0), shadow)
        canvas.paste(shot, (x, top), mask)
        ImageDraw.Draw(canvas).rounded_rectangle((x, top, x + sw - 1, top + sh - 1), radius=radius,
                                                  outline=(255, 255, 255), width=6)

        canvas.save(out / f"{name}.png", optimize=True)
        print(out / f"{name}.png", canvas.size)


if __name__ == "__main__":
    make(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
