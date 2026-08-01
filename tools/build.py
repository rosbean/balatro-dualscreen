#!/usr/bin/env python3
"""
Build a dual-screen Balatro APK from your own copy of the game.

    python3 tools/build.py --balatro /path/to/Balatro.app
    python3 tools/build.py --balatro /path/to/Balatro.exe --output ~/balatro.apk

--balatro accepts any container: a Windows Balatro.exe, a macOS Balatro.app, a
bare .love archive, or an already-extracted directory.

What it does:

    validate  ->  extract  ->  inject overlay  ->  Game.love  ->  Gradle  ->  APK

**No Balatro code or assets live in this repository.** They come from the copy
you point at, are combined with this project's overlay in build/, and are
packaged on your machine. Nothing about your copy leaves it.

The single modification to the game is one appended line in main.lua:

    require "dualscreen.init"

Everything else the overlay does, it does by reassigning globals at runtime.
"""

import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from check_balatro_source import validate, report, NotBalatro  # noqa: E402
from extract_balatro import extract  # noqa: E402
from extract_icon import extract_icon  # noqa: E402
from package_love import package  # noqa: E402

# The version this project is developed and tested against. A different version
# is a warning, not a refusal - the overlay wraps globals rather than patching
# line numbers, so it usually survives a version bump. "Usually" is why this
# warns rather than staying silent.
EXPECTED_VERSION = "1.0.1o"
EXPECTED_BUILD = "PROD_PC_Console"

INJECT_LINE = 'require "dualscreen.init"'

BUILD_DIR = os.path.join(ROOT, "build")
GAME_SRC = os.path.join(BUILD_DIR, "game-src")
GAME_LOVE = os.path.join(BUILD_DIR, "Game.love")
OVERLAY_SRC = os.path.join(ROOT, "lua", "dualscreen")
ANDROID_DIR = os.path.join(ROOT, "android")
# The embed flavour reads the flavour-scoped asset dir. Putting the payload in
# src/main/assets/ also works but would bundle the game into the `normal`
# flavour too.
ASSET_DEST = os.path.join(ANDROID_DIR, "app", "src", "embed", "assets", "game.love")

GRADLE_TASK = ":app:assembleEmbedNoRecordDebug"
APK_PATH = os.path.join(
    ANDROID_DIR, "app", "build", "outputs", "apk",
    "embedNoRecord", "debug", "app-embed-noRecord-debug.apk",
)

# Copied into the game verbatim, except for these - documentation for people
# reading the repo, not part of the overlay.
OVERLAY_SKIP = {"README.md"}


def step(n, total, msg):
    print("[%d/%d] %s" % (n, total, msg))


def do_validate(balatro):
    step(1, 6, "Validating %s" % balatro)
    try:
        info = validate(balatro)
    except NotBalatro as e:
        raise SystemExit("ERROR: %s" % e)

    print()
    report(info)
    print()

    if not info["usable"]:
        raise SystemExit(
            "Refusing to build from this copy. See the report above."
        )

    if info["number"] != EXPECTED_VERSION or info["build"] != EXPECTED_BUILD:
        print("WARNING: this project is developed against Balatro %s %s;"
              % (EXPECTED_VERSION, EXPECTED_BUILD))
        print("         you have %s %s." % (info["number"], info["build"]))
        print("         The overlay wraps globals rather than patching line")
        print("         numbers, so it will probably still work - but if the")
        print("         hand or the buttons misbehave, this is the first thing")
        print("         to suspect.")
        print()

    return info


def do_extract(balatro):
    step(2, 6, "Extracting to %s" % os.path.relpath(GAME_SRC, ROOT))
    kind, count = extract(balatro, GAME_SRC, force=True)
    print("       %s container, %d files" % (kind, count))
    return count


def do_inject():
    step(3, 6, "Injecting the overlay")

    if not os.path.isdir(OVERLAY_SRC):
        raise SystemExit("ERROR: overlay directory missing: %s" % OVERLAY_SRC)
    if not os.path.isfile(os.path.join(OVERLAY_SRC, "init.lua")):
        raise SystemExit(
            "ERROR: %s has no init.lua.\n"
            "The appended require line loads dualscreen/init.lua; without it the\n"
            "game will fail at startup." % OVERLAY_SRC
        )

    dest = os.path.join(GAME_SRC, "dualscreen")
    if os.path.exists(dest):
        shutil.rmtree(dest)
    shutil.copytree(
        OVERLAY_SRC, dest,
        ignore=lambda d, names: {n for n in names if n in OVERLAY_SKIP},
    )
    copied = sum(len(f) for _, _, f in os.walk(dest))
    print("       lua/dualscreen/ -> dualscreen/  (%d files)" % copied)

    main_lua = os.path.join(GAME_SRC, "main.lua")
    with open(main_lua, encoding="utf8", errors="surrogateescape") as f:
        body = f.read()

    if INJECT_LINE in body:
        # extract() rewrites game-src from scratch every run, so this should be
        # unreachable. If it fires, something is reusing a dirty tree.
        raise SystemExit(
            "ERROR: main.lua already contains the inject line. The extracted\n"
            "tree is not clean; delete build/game-src/ and retry."
        )

    if not body.endswith("\n"):
        body += "\n"
    body += "\n-- balatro-dualscreen-thor: load the dual-screen overlay.\n"
    body += "-- This is the ONLY modification made to the game's own source.\n"
    body += INJECT_LINE + "\n"

    with open(main_lua, "w", encoding="utf8", errors="surrogateescape") as f:
        f.write(body)

    print("       main.lua + %s" % INJECT_LINE)


def do_package():
    step(4, 6, "Packaging Game.love")
    count, size = package(GAME_SRC, GAME_LOVE)
    print("       %d files, %.1f MB -> %s"
          % (count, size / 1e6, os.path.relpath(GAME_LOVE, ROOT)))
    return count, size


OVERLAY_ASSETS = os.path.join(ANDROID_DIR, "app", "src", "embed", "assets",
                              "dualscreen")


def do_stage():
    step(5, 6, "Staging into the Android project")
    os.makedirs(os.path.dirname(ASSET_DEST), exist_ok=True)
    shutil.copyfile(GAME_LOVE, ASSET_DEST)
    # A developer build embeds the fully assembled game; loose overlay assets
    # are the RELEASE APK's business and must not ride along here.
    if os.path.exists(OVERLAY_ASSETS):
        shutil.rmtree(OVERLAY_ASSETS)
    print("       -> %s" % os.path.relpath(ASSET_DEST, ROOT))


def do_stage_release():
    """Stage the PUBLISHABLE apk: no game, no extracted icon -- only the
    overlay, which SetupActivity's on-device assembler injects into the
    user's own Balatro at first launch.

    Rule #1 is enforced here twice over: the embedded game.love is removed,
    and so is the generated icon overlay -- an APK published with the
    extracted GameIcon artwork would be distributing LocalThunk's asset just
    as surely as one with the game inside."""
    step(1, 2, "Staging the release APK (no Balatro inside)")
    if os.path.exists(ASSET_DEST):
        os.remove(ASSET_DEST)
        print("       removed embedded game.love")
    # The WHOLE generated icon dir, not a list of expected files: a stale
    # file from an older icon layout survived exactly such a list once and
    # shipped the extracted artwork inside a release APK. Directories are
    # removed wholesale; enumerations rot.
    if os.path.exists(ICON_RES):
        shutil.rmtree(ICON_RES)
        print("       removed extracted icon")
    if os.path.exists(OVERLAY_ASSETS):
        shutil.rmtree(OVERLAY_ASSETS)
    shutil.copytree(
        OVERLAY_SRC, OVERLAY_ASSETS,
        ignore=lambda d, names: {n for n in names if n in OVERLAY_SKIP},
    )
    n = sum(len(f) for _, _, f in os.walk(OVERLAY_ASSETS))
    print("       lua/dualscreen/ -> assets/dualscreen/  (%d files)" % n)


ICON_RES = os.path.join(ROOT, "android", "app", "src", "generated", "icon-res")

# The artwork layer, the adaptive icon that consumes it, and the legacy
# square for pre-26 launchers. All generated, all gitignored.
ICON_LAYER  = os.path.join(ICON_RES, "drawable-nodpi", "balatro_icon_fg.png")
ICON_BG     = os.path.join(ICON_RES, "drawable", "balatro_icon_bg.xml")
ICON_XML    = os.path.join(ICON_RES, "mipmap-anydpi-v26", "balatro_icon.xml")
ICON_LEGACY = os.path.join(ICON_RES, "mipmap-nodpi", "balatro_icon.png")

# An ADAPTIVE icon, not a plain square: modern launchers mask every icon to
# their shape (usually a circle) and shrink a legacy square inside a white
# disc -- observed on device, and ugly.
#
# The layer is the artwork INSET on the 108 dp canvas, over a dark backing.
# Full-bleed was tried first and read as over-zoomed: the launcher mask shows
# only the central ~67% of a full-bleed layer. At 14% inset the art spans
# ~78 of the canvas's 108 dp against the mask's ~72 dp circle, so it still
# overfills the circle slightly -- the whole image reads, only the square's
# corners and a thin edge crop away, and the backing colour never shows. The
# inset is resolved by Android at render time, which is what keeps this an
# XML tweak instead of pixel compositing in the build script.
ICON_BG_XML = """<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@android:color/black" />
    <item>
        <inset android:drawable="@drawable/balatro_icon_fg"
               android:inset="14%" />
    </item>
</layer-list>
"""

ICON_ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/balatro_icon_bg" />
    <foreground android:drawable="@android:color/transparent" />
</adaptive-icon>
"""


def do_icon(balatro):
    """Best-effort: give the APK the game's own icon, from the user's container.

    Never committed (rule #1) -- everything lands in the gitignored generated
    res overlay, and the ICON manifest placeholder in app/build.gradle selects
    it only when the layer exists. Containers differ honestly here: the .app
    ships GameIcon.icns (the real artwork); the Steam .exe only embeds the
    LOVE engine icon, which is no better than the fallback but is what that
    container truthfully provides.
    """
    # Wholesale, for the same reason as the release path: stale files from
    # older icon layouts must not survive into any APK.
    if os.path.exists(ICON_RES):
        shutil.rmtree(ICON_RES)
    png = extract_icon(balatro)
    if png is None:
        print("       icon: none extracted; APK keeps the stock LOVE icon")
        return
    for path, content in ((ICON_LAYER, png),
                          (ICON_LEGACY, png),
                          (ICON_BG, ICON_BG_XML.encode()),
                          (ICON_XML, ICON_ADAPTIVE_XML.encode())):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(content)
    print("       icon: %d KiB from the container -> adaptive icon in %s"
          % (len(png) // 1024, os.path.relpath(ICON_RES, ROOT)))


def do_gradle(output):
    step(6, 6, "Building the APK (Gradle)")
    gradlew = os.path.join(ANDROID_DIR, "gradlew")
    if not os.path.isfile(gradlew):
        raise SystemExit(
            "ERROR: %s not found. Is android/ populated?" % gradlew
        )

    env = os.environ.copy()
    if not env.get("ANDROID_HOME") and not env.get("ANDROID_SDK_ROOT"):
        raise SystemExit(
            "ERROR: ANDROID_HOME is not set.\n"
            "Source your Android environment first - see docs/android-build.md:\n"
            "    source ~/.config/android-build-env.sh"
        )

    proc = subprocess.run(
        [gradlew, GRADLE_TASK, "--console=plain"],
        cwd=ANDROID_DIR, env=env,
    )
    if proc.returncode != 0:
        raise SystemExit("ERROR: Gradle build failed (exit %d)." % proc.returncode)

    if not os.path.isfile(APK_PATH):
        raise SystemExit("ERROR: Gradle succeeded but %s is missing." % APK_PATH)

    if output:
        output = os.path.abspath(os.path.expanduser(output))
        os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
        shutil.copyfile(APK_PATH, output)
        final = output
    else:
        final = APK_PATH

    print()
    print("APK: %s (%.1f MB)" % (final, os.path.getsize(final) / 1e6))
    return final


def main():
    p = argparse.ArgumentParser(
        description="Build a dual-screen Balatro APK from your own copy of the game.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="This project ships no Balatro code or assets. You supply the game.",
    )
    p.add_argument("--balatro",
                   help="path to Balatro.app, Balatro.exe, a .love, or an extracted dir")
    p.add_argument("--output", help="copy the finished APK here")
    p.add_argument("--no-apk", action="store_true",
                   help="stop after Game.love; skip staging and Gradle. Useful for "
                        "comparing output across containers without a toolchain.")
    p.add_argument("--release", action="store_true",
                   help="build the PUBLISHABLE apk: contains no Balatro at all. "
                        "The game is assembled on device from the user's own copy "
                        "at first launch. --balatro is not needed and not used.")
    args = p.parse_args()

    if args.release:
        if args.balatro:
            p.error("--release builds contain no Balatro; drop --balatro")
        do_stage_release()
        do_gradle(args.output)
        print()
        print("This APK ships NO Balatro code or assets. Safe to publish.")
        return

    if not args.balatro:
        p.error("--balatro is required (or use --release)")

    do_validate(args.balatro)
    do_extract(args.balatro)
    do_inject()
    do_package()

    if args.no_apk:
        print()
        print("Stopped before the APK (--no-apk). Game.love is at %s"
              % os.path.relpath(GAME_LOVE, ROOT))
        return

    do_stage()
    do_icon(args.balatro)
    do_gradle(args.output)


if __name__ == "__main__":
    main()
