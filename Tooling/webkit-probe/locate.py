"""Prints "x y w h" in points of the composer on a screenshot: the bounding box of its green
border (#22c55e), which nothing else on the probe page uses. Prints nothing when it is not on
screen. The page's own coordinates do not map to the screen once the keyboard pans it, so the
pixels are what the taps aim at.
"""

import sys

from PIL import Image

image = Image.open(sys.argv[1]).convert("RGB")
scale = image.width / 402
px = image.load()
xs, ys = [], []
for y in range(0, image.height, 2):
    for x in range(0, image.width, 2):
        r, g, b = px[x, y]
        if abs(r - 34) < 30 and abs(g - 197) < 30 and abs(b - 94) < 30:
            xs.append(x)
            ys.append(y)
if xs:
    x0, y0 = min(xs) / scale, min(ys) / scale
    print(int(x0), int(y0), int((max(xs) / scale) - x0), int((max(ys) / scale) - y0))
