"""RubberTap launcher icon: a latex drop carrying the tapping cut, over a cup.
Usage: python make_icon.py preview   -> preview PNGs in this folder
       python make_icon.py install   -> writes the Android mipmap files"""
import math, sys
from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).parent  # previews are written next to this script
RES = Path(__file__).resolve().parent.parent / "frontend/android/app/src/main/res"
FOREST = (23, 96, 63, 255)      # AppColors.forest  #17603F
FOREST_DEEP = (15, 70, 46, 255)
BRONZE = (232, 168, 74, 255)    # lighter bronze so it reads on green
WHITE = (255, 255, 255, 255)
S = 1728  # working canvas (108dp x 16)


def drop_points(cx, cy, r, tip_h, n=120):
    """Teardrop: circle of radius r centred (cx, cy), tip tip_h above centre."""
    t = math.acos(r / tip_h)            # tangent angle from the upward axis
    pts = [(cx, cy - tip_h)]
    start, end = -math.pi / 2 + t, 3 * math.pi / 2 - t
    for i in range(n + 1):
        a = start + (end - start) * i / n
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def foreground(mono=False):
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cx, r = S / 2, S * 0.132
    cy = S * 0.562
    tip_h = r * 1.95

    # the drop
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(drop_points(cx, cy, r, tip_h), fill=255)

    # the tapping cut: two slanted grooves across the drop
    cut = Image.new("L", (S, S), 0)
    low = Image.new("L", (S, S), 0)   # everything below the lower groove
    ang = math.radians(28)
    dx, dy = math.cos(ang), math.sin(ang)
    w = r * 0.19
    L = r * 2.0
    nx, ny = -dy * w / 2, dx * w / 2
    offs = (-0.10, 0.42)
    for off in offs:
        y0 = cy + r * off
        p1 = (cx - L * dx, y0 - L * dy)
        p2 = (cx + L * dx, y0 + L * dy)
        ImageDraw.Draw(cut).polygon([(p1[0] + nx, p1[1] + ny), (p2[0] + nx, p2[1] + ny),
                                     (p2[0] - nx, p2[1] - ny), (p1[0] - nx, p1[1] - ny)], fill=255)
    y0 = cy + r * offs[1]
    p1 = (cx - L * dx, y0 - L * dy)
    p2 = (cx + L * dx, y0 + L * dy)
    ImageDraw.Draw(low).polygon([p1, p2, (p2[0], S), (p1[0], S)], fill=255)

    zero = Image.new("L", (S, S), 0)
    drop = Image.composite(zero, mask, cut)          # drop minus the grooves
    upper = Image.composite(zero, drop, low)         # part above the lower groove
    lower = Image.composite(drop, zero, low)         # the collected latex below it
    im.paste(Image.new("RGBA", (S, S), WHITE), (0, 0), upper)
    im.paste(Image.new("RGBA", (S, S), WHITE if mono else BRONZE), (0, 0), lower)
    return im


def background():
    im = Image.new("RGBA", (S, S), FOREST)
    px = im.load()
    for y in range(S):          # soft top-to-bottom depth
        t = y / S
        c = tuple(int(FOREST[i] * (1 - t * .55) + FOREST_DEEP[i] * t * .55) for i in range(3)) + (255,)
        for x in range(0, S):
            px[x, y] = c
    return im


def legacy(size):
    """Pre-Android-8 icon: rounded square, artwork a little larger."""
    bg = background()
    fg = foreground()
    crop = int(S * 0.215)   # zoom into the safe zone
    art = Image.alpha_composite(bg, fg).crop((crop, crop, S - crop, S - crop))
    n = art.size[0]
    m = Image.new("L", (n, n), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * 0.23), fill=255)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(art, (0, 0), m)
    return out.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "preview"
    if mode == "preview":
        legacy(512).save(HERE / "icon_preview.png")
        circ = Image.alpha_composite(background(), foreground())
        m = Image.new("L", (S, S), 0)
        k = int(S * (108 - 72) / 2 / 108)
        ImageDraw.Draw(m).ellipse([k, k, S - k, S - k], fill=255)
        o = Image.new("RGBA", (S, S), (240, 240, 240, 255)); o.paste(circ, (0, 0), m)
        o.crop((k, k, S - k, S - k)).resize((512, 512), Image.LANCZOS).save(HERE / "icon_preview_round.png")
        small = legacy(96).resize((192, 192), Image.NEAREST); small.save(HERE / "icon_preview_small.png")
        print("previews written")
    else:
        dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
        fg, mono = foreground(), foreground(mono=True)
        for name, k in dens.items():
            d = RES / f"mipmap-{name}"
            fs = int(108 * k)
            fg.resize((fs, fs), Image.LANCZOS).save(d / "ic_launcher_foreground.png")
            mono.resize((fs, fs), Image.LANCZOS).save(d / "ic_launcher_monochrome.png")
            legacy(int(48 * k)).save(d / "ic_launcher.png")
        print("installed")
