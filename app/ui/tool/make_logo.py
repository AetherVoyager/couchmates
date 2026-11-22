"""Draws the Couchmates logo and writes every icon the app uses.

    python tool/make_logo.py          # from app/ui

The logo: a white couch on an indigo-to-violet tile, with a play button on
the backrest. Drawn at 4x and scaled down, so edges stay smooth.
Writes assets/couchmates.png (in-app), assets/couchmates_foreground.png
(Android adaptive foreground), windows/runner/resources/app_icon.ico and
the Android launcher PNGs.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
S = 4096  # drawing canvas; everything below is in 1024 units times K
K = S / 1024

TOP, BOTTOM = (108, 123, 255), (142, 77, 255)
COUCH = (255, 255, 255)
PLAY = (122, 100, 255)


def box(x0, y0, x1, y1):
    return [x0 * K, y0 * K, x1 * K, y1 * K]


def gradient(size):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return g.resize((size, size), Image.BICUBIC)


def couch(draw, dx=0.0, dy=0.0, scale=1.0):
    """The couch and its play button, centred on the 1024 tile."""

    def b(x0, y0, x1, y1):
        c = 512
        return box(c + (x0 - c) * scale + dx, c + (y0 - c) * scale + dy, c + (x1 - c) * scale + dx, c + (y1 - c) * scale + dy)

    r = lambda v: v * K * scale  # noqa: E731
    draw.rounded_rectangle(b(262, 330, 762, 610), radius=r(78), fill=COUCH)  # backrest
    draw.rounded_rectangle(b(214, 560, 810, 712), radius=r(56), fill=COUCH)  # seat
    draw.rounded_rectangle(b(150, 470, 300, 742), radius=r(70), fill=COUCH)  # left arm
    draw.rounded_rectangle(b(724, 470, 874, 742), radius=r(70), fill=COUCH)  # right arm
    draw.rounded_rectangle(b(226, 722, 282, 800), radius=r(22), fill=COUCH)  # legs
    draw.rounded_rectangle(b(742, 722, 798, 800), radius=r(22), fill=COUCH)
    # Play button on the backrest.
    c, h = 512, 92
    pts = [(c - h * 0.62, 455 - h), (c - h * 0.62, 455 + h), (c + h * 0.95, 455)]
    draw.polygon([(512 * K + (x - 512) * K * scale + dx * K, 512 * K + (y - 512) * K * scale + dy * K) for x, y in pts], fill=PLAY)
    # A line where the seat cushion meets the backrest.
    draw.rounded_rectangle(b(300, 600, 724, 612), radius=r(6), fill=(226, 222, 255))


def tile(size):
    """The full icon: rounded gradient tile with the couch."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=230 * K, fill=255)
    img.paste(gradient(S), (0, 0), mask)
    couch(ImageDraw.Draw(img))
    return img.resize((size, size), Image.LANCZOS)


def foreground(size):
    """Android adaptive foreground: the couch alone inside the 66% safe zone."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    couch(ImageDraw.Draw(img), scale=0.62)
    return img.resize((size, size), Image.LANCZOS)


def main():
    tile(512).save(ROOT / "assets" / "couchmates.png")
    foreground(432).save(ROOT / "assets" / "couchmates_foreground.png")
    big = tile(256)
    big.save(
        ROOT / "windows" / "runner" / "resources" / "app_icon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    for name, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        folder = ROOT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{name}"
        if folder.is_dir():
            tile(px).save(folder / "ic_launcher.png")
    print("Wrote the Couchmates icons.")


if __name__ == "__main__":
    main()
