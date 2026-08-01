"""Regenerate the release APK's icon (this project's own original artwork).

Two stacked screens on a TRANSPARENT background -- the Thor's clamshell,
and nothing else. No Balatro assets are involved anywhere: this exists
precisely because the published APK may not carry LocalThunk's icon
(rule #1); personal builds still get the real artwork via
tools/extract_icon.py.

Deliberately minimal. Android draws the app's icon as a small badge in the
corner of a pinned shortcut, so after setup this sits beside the game's own
icon -- a detailed illustration turned to mush at that size, while a bare
mark reads instantly. The screens keep a dark fill and a cream outline so
they stay legible against light and dark launcher wallpapers alike.

Outputs (committed in the repo):
  android/app/src/main/res/drawable-nodpi/ds_icon_fg.png   adaptive foreground
  android/app/src/main/res/mipmap-nodpi/ds_icon.png        legacy square

Requires Pillow. Only needed when changing the design.
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

S = 1024
FELT = (30, 58, 47, 255)     # screen face
EDGE = (244, 238, 224, 255)  # cream bezel


def main():
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)

    cx = S // 2
    w, h, rad, stroke = 620, 300, 56, 34
    gap = 76
    top_y = (S - (2 * h + gap)) // 2

    for y0 in (top_y, top_y + h + gap):
        d.rounded_rectangle([cx - w // 2, y0, cx + w // 2, y0 + h],
                            radius=rad, fill=FELT, outline=EDGE, width=stroke)

    # Into the adaptive safe circle: the launcher mask shows roughly the
    # central two thirds, so the motif is scaled about the centre to fit.
    k = 0.72
    small = art.resize((int(S * k), int(S * k)), Image.LANCZOS)
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fg.alpha_composite(small, ((S - small.width) // 2, (S - small.height) // 2))
    fg.save(os.path.join(RES, "drawable-nodpi", "ds_icon_fg.png"))

    # Legacy square, transparency preserved.
    fg.resize((512, 512), Image.LANCZOS).save(
        os.path.join(RES, "mipmap-nodpi", "ds_icon.png"))
    print("release icon regenerated")


if __name__ == "__main__":
    main()
