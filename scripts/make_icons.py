"""앱 아이콘 생성: 코트 초록 바탕 + 흰 셔틀콕. 실행: python3 scripts/make_icons.py"""
from PIL import Image, ImageDraw
import os

GREEN = (19, 100, 79)
LINE = (255, 255, 255)
CORK = (242, 194, 48)
OUT = os.path.join(os.path.dirname(__file__), "..", "public", "icons")

def draw(size: int, pad: float) -> Image.Image:
    S = size * 4  # 크게 그려서 줄이면 가장자리가 부드럽다
    im = Image.new("RGB", (S, S), GREEN)
    d = ImageDraw.Draw(im)
    inner = S * (1 - 2 * pad)
    ox = oy = S * pad
    cx = ox + inner / 2
    # 셔틀콕: 아래 코르크(반원), 위로 벌어지는 깃털 치마
    cork_r = inner * 0.13
    cork_cy = oy + inner * 0.80
    top_y = oy + inner * 0.16
    skirt_bottom = cork_cy - cork_r * 0.15
    top_half = inner * 0.30
    bottom_half = cork_r * 0.95
    w = max(2, int(inner * 0.035))
    # 깃털 치마 외곽
    d.polygon([(cx - top_half, top_y), (cx + top_half, top_y), (cx + bottom_half, skirt_bottom), (cx - bottom_half, skirt_bottom)], outline=LINE, width=w)
    # 깃털 줄기
    for t in (-0.5, 0, 0.5):
        d.line([(cx + t * top_half * 1.3, top_y), (cx + t * bottom_half, skirt_bottom)], fill=LINE, width=w)
    # 깃털 끝 물결
    n = 6
    for i in range(n):
        x0 = cx - top_half + (2 * top_half) * i / n
        x1 = cx - top_half + (2 * top_half) * (i + 1) / n
        d.arc([x0, top_y - inner * 0.05, x1, top_y + inner * 0.05], 180, 360, fill=LINE, width=w)
    # 띠
    band_y = skirt_bottom - inner * 0.07
    bw = bottom_half + (top_half - bottom_half) * ((skirt_bottom - band_y) / (skirt_bottom - top_y))
    d.line([(cx - bw, band_y), (cx + bw, band_y)], fill=LINE, width=w)
    # 코르크
    d.pieslice([cx - cork_r, cork_cy - cork_r, cx + cork_r, cork_cy + cork_r], 0, 180, fill=CORK)
    d.rectangle([cx - cork_r, cork_cy - cork_r * 0.25, cx + cork_r, cork_cy], fill=CORK)
    return im.resize((size, size), Image.LANCZOS)

os.makedirs(OUT, exist_ok=True)
draw(32, 0.06).save(os.path.join(OUT, "icon-32.png"))
draw(180, 0.12).save(os.path.join(OUT, "apple-touch-icon.png"))
draw(192, 0.12).save(os.path.join(OUT, "icon-192.png"))
draw(512, 0.12).save(os.path.join(OUT, "icon-512.png"))
draw(512, 0.22).save(os.path.join(OUT, "icon-maskable-512.png"))  # 안드로이드 원형 마스크 안전 영역
print("icons written to", os.path.abspath(OUT))
