#!/usr/bin/env python3
"""Capture both screens of a dual-screen device into one stacked image.

    python3 tools/capture_screens.py out.png            both screens, stacked
    python3 tools/capture_screens.py out.png --top      primary only
    python3 tools/capture_screens.py out.png --panel    secondary only

Needs adb (found automatically) and Pillow. The device must be awake -- a
sleeping screen captures as solid black rather than failing.
"""
import io
import os
import shutil
import subprocess
import sys

try:
    from PIL import Image
except ImportError:
    raise SystemExit("Pillow is required:  python3 -m pip install --user Pillow")

GAP = 18
BG = (18, 18, 20)


def find_adb():
    """adb from PATH, then the usual SDK locations."""
    found = shutil.which("adb")
    if found:
        return found
    candidates = []
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        root = os.environ.get(var)
        if root:
            candidates.append(os.path.join(root, "platform-tools", "adb"))
    candidates += [
        os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"),
        os.path.expanduser("~/Android/Sdk/platform-tools/adb"),
        "/usr/local/bin/adb",
        "/opt/homebrew/bin/adb",
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    raise SystemExit(
        "adb not found. Install Android platform-tools, or set ANDROID_HOME,\n"
        "or add adb to PATH."
    )


ADB = find_adb()


def adb(*args, binary=False):
    r = subprocess.run([ADB, *args], capture_output=True)
    if binary:
        return r.stdout
    return r.stdout.decode("utf8", "replace")


def displays():
    """Physical display IDs, primary first.

    The logical id from `dumpsys display` does not work with screencap -d;
    SurfaceFlinger's physical ids do.
    """
    out = adb("shell", "dumpsys", "SurfaceFlinger", "--display-id")
    ids = [line.split()[1] for line in out.splitlines()
           if line.startswith("Display ")]
    if not ids:
        raise SystemExit("no displays reported -- is a device connected?  "
                         "(%s devices)" % ADB)
    return ids


def grab(display_id):
    raw = adb("exec-out", "screencap", "-p", "-d", display_id, binary=True)
    if not raw:
        raise SystemExit("empty capture from display %s" % display_id)
    return Image.open(io.BytesIO(raw)).convert("RGB")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "screens.png"
    mode = sys.argv[2] if len(sys.argv) > 2 else "--both"

    if not adb("devices").strip().splitlines()[1:]:
        raise SystemExit("no device connected (check `adb devices`)")

    ids = displays()
    if mode == "--top":
        img = grab(ids[0])
    elif mode == "--panel":
        if len(ids) < 2:
            raise SystemExit("only one display found")
        img = grab(ids[1])
    else:
        if len(ids) < 2:
            raise SystemExit("only one display found; use --top")
        top, panel = grab(ids[0]), grab(ids[1])
        w = max(top.width, panel.width)
        img = Image.new("RGB", (w, top.height + GAP + panel.height), BG)
        img.paste(top, ((w - top.width) // 2, 0))
        img.paste(panel, ((w - panel.width) // 2, top.height + GAP))

    img.save(out)
    print("%s  %dx%d" % (out, img.width, img.height))

    extrema = img.convert("L").getextrema()
    if extrema[1] < 12:
        print("  note: the image is essentially black -- wake the device "
              "and try again.")


if __name__ == "__main__":
    main()
