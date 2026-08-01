#!/usr/bin/env python3
"""
Package a directory of game files into a .love archive.

    python3 tools/package_love.py <game-dir> <output.love>

A .love is a plain zip with main.lua at its ROOT - not nested inside a
directory. Getting that wrong produces an archive LOVE will refuse with "no
game" and no further explanation, so this refuses to write one.

Deterministic by construction: entries are sorted and every timestamp is
pinned, so packaging the same tree twice yields byte-identical output. Task
2.3 compares Game.love hashes built from the .app and the .exe containers -
that comparison is only meaningful if the packaging step contributes no
variance of its own.

build.py imports package() from here rather than reimplementing it.
"""

import os
import sys
import zipfile

# Fixed DOS timestamp (1980-01-01 00:00:00), the zip epoch. Any constant does,
# so long as it never varies between runs.
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def package(game_dir, out_path):
    """Zip `game_dir` into `out_path`. Returns (file_count, byte_size)."""
    if not os.path.isdir(game_dir):
        raise SystemExit("ERROR: not a directory: %s" % game_dir)
    if not os.path.isfile(os.path.join(game_dir, "main.lua")):
        raise SystemExit(
            "ERROR: %s has no main.lua at its root.\n"
            "A .love archive must contain main.lua at the top level; LOVE will\n"
            "show its 'no game' screen otherwise." % game_dir
        )

    files = []
    for root, dirs, names in os.walk(game_dir):
        dirs.sort()
        for n in sorted(names):
            full = os.path.join(root, n)
            rel = os.path.relpath(full, game_dir).replace(os.sep, "/")
            files.append((rel, full))
    files.sort()

    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for rel, full in files:
            info = zipfile.ZipInfo(rel, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(full, "rb") as f:
                z.writestr(info, f.read())

    return len(files), os.path.getsize(out_path)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    count, size = package(sys.argv[1], sys.argv[2])
    print("Packaged:     %d files -> %s (%.1f MB)" % (count, sys.argv[2], size / 1e6))


if __name__ == "__main__":
    main()
