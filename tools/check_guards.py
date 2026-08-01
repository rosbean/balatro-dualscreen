#!/usr/bin/env python3
"""
Fail loudly if the repository has drifted from its own rules.

    python3 tools/check_guards.py

Modelled on BanjoRecomp's check_android_port_guards.py. Run it before every
commit that touches the build, and before any release.

It checks the two things that are easy to break silently:

  1. Nothing copyrighted is tracked. This is rule #1 of the project and the
     thing that makes it publishable at all. A stray extraction into the wrong
     directory, or an asset path that stops matching .gitignore, would not
     otherwise announce itself.

  2. No Thor-specific constants. Detect the second display by
     FLAG_PRESENTATION, never by model string and never by matching 1240x1080.
     The moment a resolution is hardcoded the project stops working on any
     other dual-screen device, and nothing at runtime will tell you.

Exit status 0 = clean, 1 = at least one guard failed.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# love-android legitimately ships Lua: LuaJIT's dynasm/jit tooling and LOVE's
# own boot scripts. Counted rather than ignored, so a Balatro file dropped into
# the vendored tree is still caught.
VENDORED_LUA_COUNT = 131

# Thor panel dimensions. Fine to mention in comments and docs -- the findings
# are full of them -- but never as a live constant in code.
FORBIDDEN_NUMBERS = ("1240", "1080", "1920")

CODE_EXT = (".lua", ".java", ".c", ".h", ".py")

failures = []
notes = []


def git(*args):
    out = subprocess.run(["git", "-C", ROOT] + list(args),
                         capture_output=True, text=True)
    return out.stdout.splitlines()


def tracked():
    return git("ls-files")


def fail(msg):
    failures.append(msg)


def note(msg):
    notes.append(msg)


# --- 1. nothing copyrighted -------------------------------------------------

def check_no_game_content(files):
    bad = [f for f in files
           if re.match(r"^(local-balatro/|reference/|build/)", f)
           and f != "local-balatro/README.md"]
    if bad:
        fail("Tracked files under local-balatro/, reference/ or build/:\n    "
             + "\n    ".join(bad[:20]))

    payload = [f for f in files if f.endswith((".love", ".jkr", ".apk"))]
    if payload:
        fail("Tracked game payload or build artefact:\n    "
             + "\n    ".join(payload[:20]))

    stray = [f for f in files
             if f.endswith(".lua")
             and not f.startswith("lua/dualscreen/")
             and not f.startswith("android/")]
    if stray:
        fail("Lua outside lua/dualscreen/ and the vendored android/ tree:\n    "
             + "\n    ".join(stray[:20]))

    vendored = [f for f in files if f.startswith("android/") and f.endswith(".lua")]
    if len(vendored) != VENDORED_LUA_COUNT:
        fail("android/ has %d tracked .lua files, expected %d.\n"
             "    love-android ships exactly %d (LuaJIT tooling + LOVE boot\n"
             "    scripts). A different count means either the vendored tree\n"
             "    changed or Balatro Lua has been added to it."
             % (len(vendored), VENDORED_LUA_COUNT, VENDORED_LUA_COUNT))
    else:
        note("android/ vendored Lua: %d files, as expected" % len(vendored))


# --- 2. no device-specific constants ---------------------------------------

def check_no_thor_constants(files):
    """Only our own code is checked; the vendored tree is not ours to police."""
    # This file is exempt: it necessarily contains the very numbers and
    # model-string patterns it searches for, and its docstring explains the
    # rule. Without this it fails on itself, which it duly did on first run.
    ours = [f for f in files
            if f.endswith(CODE_EXT)
            and f != "tools/check_guards.py"
            and (f.startswith("lua/") or f.startswith("tools/")
                 or f.startswith("android/app/src/main/java/com/balatro/")
                 or f.startswith("android/love/src/jni/lua-modules/dsbridge/"))]

    for rel in ours:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                stripped = line.strip()
                # Comments may discuss the device freely; the findings and the
                # ADRs depend on being able to quote real measurements.
                if stripped.startswith(("--", "//", "#", "*", "/*")):
                    continue
                code = line.split("--")[0].split("//")[0]

                for num in FORBIDDEN_NUMBERS:
                    if re.search(r"(?<![\w.])" + num + r"(?![\w.])", code):
                        fail("%s:%d hardcodes %s outside a comment:\n    %s"
                             % (rel, n, num, stripped[:100]))

                # One allowlisted literal: the RGB-LED setting's user-facing
                # label names the hardware the feature drives. The rule this
                # scan enforces is about DETECTION -- and detection for that
                # feature is capability-based (a vendor service lookup;
                # ThorLeds.java contains no model strings). A label is not a
                # capability check.
                if 'AYN Thor:' in code:
                    continue

                if re.search(r"(?i)(ro\.product\.model|Build\.MODEL|"
                             r"getprop\s+ro\.product|\bAYN\b|\bThor\b)", code):
                    fail("%s:%d looks like a device model check:\n    %s"
                         % (rel, n, stripped[:100]))


# --- 3. the discovery rule is actually followed ----------------------------

def check_display_discovery():
    mgr = os.path.join(ROOT, "android/app/src/main/java/com/balatro/dualscreen"
                             "/companion/CompanionDisplayManager.java")
    if not os.path.isfile(mgr):
        fail("CompanionDisplayManager.java is missing")
        return
    src = open(mgr, encoding="utf8", errors="replace").read()
    if "DISPLAY_CATEGORY_PRESENTATION" not in src:
        fail("CompanionDisplayManager no longer discovers by "
             "DISPLAY_CATEGORY_PRESENTATION")
    else:
        note("display discovery is capability-based")


def main():
    files = tracked()
    if not files:
        print("ERROR: no tracked files -- is this a git repository?")
        sys.exit(1)

    check_no_game_content(files)
    check_no_thor_constants(files)
    check_display_discovery()

    for n in notes:
        print("  ok    %s" % n)

    if failures:
        print()
        for f in failures:
            print("  FAIL  %s" % f)
        print("\n%d guard(s) failed." % len(failures))
        sys.exit(1)

    print("\nAll guards passed. %d tracked files checked." % len(files))
    sys.exit(0)


if __name__ == "__main__":
    main()
