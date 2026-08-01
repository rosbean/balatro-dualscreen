#!/usr/bin/env python3
"""
Check whether a Balatro copy is usable as a build base for this project.

Accepts any of the four containers a user might point at:
  Balatro.exe          Windows build (a zip with the game appended)
  Balatro.app          macOS bundle
  Game.love            a bare LOVE archive
  a directory          already-extracted game files

Reports the version, the build identity, and whether the source is engine
compatible with stock LOVE. Run this before building.

    python3 tools/check_balatro_source.py /path/to/Balatro.app
"""

import os
import sys
import zipfile

# Builds that ship LocalThunk's proprietary love.platform module. These cannot
# run on stock love-android no matter what else is true.
BAD_BUILDS = {
    "PROD_mobile": "the iOS / Mac App Store build",
}

# engine/ files that only exist in the mobile lineage.
MOBILE_ONLY = ("engine/platform.lua", "engine/load_manager.lua")


def find_game_root(path):
    """Return (kind, handle) where handle is a zipfile or a directory path."""
    if os.path.isdir(path):
        if path.endswith(".app"):
            # LOVE macOS bundles keep the game under Contents/Resources, either
            # as loose files or as a packed archive.
            res = os.path.join(path, "Contents", "Resources")
            loose = os.path.join(res, "game")
            if os.path.isfile(os.path.join(loose, "version.jkr")):
                return "app (loose)", loose
            if os.path.isdir(res):
                for name in sorted(os.listdir(res)):
                    if name.endswith(".love"):
                        return "app (packed)", zipfile.ZipFile(os.path.join(res, name))
            return None, None
        if os.path.isfile(os.path.join(path, "version.jkr")):
            return "directory", path
        return None, None

    if zipfile.is_zipfile(path):
        kind = "exe" if path.lower().endswith(".exe") else "love archive"
        return kind, zipfile.ZipFile(path)

    return None, None


def read_text(handle, name):
    if isinstance(handle, zipfile.ZipFile):
        try:
            return handle.read(name).decode("utf8", "replace")
        except KeyError:
            return None
    full = os.path.join(handle, name)
    if not os.path.isfile(full):
        return None
    with open(full, encoding="utf8", errors="replace") as f:
        return f.read()


def list_lua(handle):
    if isinstance(handle, zipfile.ZipFile):
        return [n for n in handle.namelist() if n.endswith(".lua")]
    out = []
    for root, _dirs, files in os.walk(handle):
        for f in files:
            if f.endswith(".lua"):
                rel = os.path.relpath(os.path.join(root, f), handle)
                out.append(rel.replace(os.sep, "/"))
    return out


def has_path(handle, prefix):
    if isinstance(handle, zipfile.ZipFile):
        return any(n.startswith(prefix) for n in handle.namelist())
    return os.path.exists(os.path.join(handle, prefix.rstrip("/")))


class NotBalatro(Exception):
    """The path is not a Balatro copy we can even inspect."""


def validate(path):
    """Inspect a Balatro copy and report what it is.

    Returns a dict. `wrong_build` and `incomplete` are lists of human-readable
    problems; both empty means usable. Raises NotBalatro if the path cannot be
    identified as Balatro at all.

    build.py calls this rather than shelling out to main(), so there is exactly
    one implementation of "is this copy usable".
    """
    if not os.path.exists(path):
        raise NotBalatro("no such path: %s" % path)

    kind, handle = find_game_root(path)
    if handle is None:
        raise NotBalatro(
            "could not find Balatro game files in %s\n"
            "Expected a Balatro.exe, a Balatro.app, a .love archive, or an\n"
            "extracted directory containing version.jkr." % path
        )

    version = read_text(handle, "version.jkr")
    if version is None:
        raise NotBalatro("version.jkr missing - this does not look like Balatro.")

    lines = [l.strip() for l in version.strip().splitlines()]
    display = lines[0] if lines else "?"
    number = lines[1] if len(lines) > 1 else "?"
    build = lines[2] if len(lines) > 2 else "?"

    lua = list_lua(handle)
    platform_hits = 0
    for name in lua:
        body = read_text(handle, name)
        if body:
            platform_hits += body.count("love.platform")

    mobile_files = [m for m in MOBILE_ONLY if m in lua]
    has_resources = has_path(handle, "resources/")
    has_localization = has_path(handle, "localization/")

    # Wrong lineage: no amount of re-extracting will help.
    wrong_build = []
    if build in BAD_BUILDS:
        wrong_build.append("Build '%s' is %s." % (build, BAD_BUILDS[build]))
    if platform_hits:
        wrong_build.append(
            "Uses love.platform (%d sites) - a LocalThunk launcher module that is "
            "not part of LOVE. Will not run on love-android." % platform_hits
        )
    if mobile_files:
        wrong_build.append("Contains mobile-only files: %s" % ", ".join(mobile_files))

    # Right lineage, missing pieces.
    incomplete = []
    if not has_resources:
        incomplete.append("No resources/ directory.")
    if not has_localization:
        incomplete.append("No localization/ directory.")

    return {
        "kind": kind,
        "display": display,
        "number": number,
        "build": build,
        "lua_files": len(lua),
        "platform_hits": platform_hits,
        "has_resources": has_resources,
        "has_localization": has_localization,
        "wrong_build": wrong_build,
        "incomplete": incomplete,
        "usable": not wrong_build and not incomplete,
    }


def report(info):
    """Print the human-readable form of validate()'s result."""
    print("Container:    %s" % info["kind"])
    print("Version:      %s  (%s)" % (info["display"], info["number"]))
    print("Build:        %s" % info["build"])
    print("Lua files:    %d" % info["lua_files"])
    print("love.platform: %d call sites" % info["platform_hits"])
    print("resources/:   %s" % ("present" if info["has_resources"] else "MISSING"))
    print("localization/: %s" % ("present" if info["has_localization"] else "MISSING"))
    print()

    if info["wrong_build"]:
        print("NOT USABLE - wrong build lineage:")
        for p in info["wrong_build"]:
            print("  - %s" % p)
        print()
        print("Use a Steam or GOG desktop copy. The iOS / Mac App Store build")
        print("will not work.")
        return

    if info["incomplete"]:
        print("INCOMPLETE - correct build lineage, but missing game assets:")
        for p in info["incomplete"]:
            print("  - %s" % p)
        print()
        print("Point this at a full Balatro install rather than a partial or")
        print("asset-stripped copy.")
        return

    print("USABLE as a build base.")
    print()
    print("Container fingerprint:")
    print("  version=%s build=%s lua_files=%d"
          % (info["number"], info["build"], info["lua_files"]))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)

    try:
        info = validate(sys.argv[1])
    except NotBalatro as e:
        print("ERROR: %s" % e)
        sys.exit(1)

    report(info)
    sys.exit(0 if info["usable"] else 1)


if __name__ == "__main__":
    main()
