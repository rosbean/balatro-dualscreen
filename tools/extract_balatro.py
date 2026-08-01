#!/usr/bin/env python3
"""
Extract a Balatro copy into a plain directory.

    python3 tools/extract_balatro.py <container> <destination> [--force]

<container> is anything check_balatro_source.py accepts: a Balatro.exe, a
Balatro.app, a bare .love archive, or an already-extracted directory.

Container detection is NOT reimplemented here - find_game_root() is imported
from check_balatro_source so there is exactly one place that knows how the
four container shapes are laid out. build.py imports this module in
turn, for the same reason.

Nothing extracted by this script may be committed. The destination is expected
to be under reference/ or build/, both gitignored.
"""

import os
import shutil
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_balatro_source import find_game_root  # noqa: E402


def _safe_target(dest, name):
    """Resolve an archive member against dest, refusing to escape it.

    The container is user-supplied, so a crafted archive with '../' members or
    an absolute path is a real input. Cheap to guard, unpleasant to debug.
    """
    target = os.path.realpath(os.path.join(dest, name))
    root = os.path.realpath(dest)
    if target != root and not target.startswith(root + os.sep):
        raise ValueError("archive member escapes destination: %r" % name)
    return target


def extract(container, dest, force=False):
    """Extract `container` into `dest`. Returns the number of files written."""
    kind, handle = find_game_root(container)
    if handle is None:
        raise SystemExit("ERROR: could not find Balatro game files in %s" % container)

    if os.path.exists(dest):
        if not force:
            raise SystemExit(
                "ERROR: %s already exists. Pass --force to replace it." % dest
            )
        shutil.rmtree(dest)
    os.makedirs(dest)

    count = 0
    if isinstance(handle, zipfile.ZipFile):
        for info in handle.infolist():
            if info.is_dir():
                continue
            target = _safe_target(dest, info.filename)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with handle.open(info) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)
            count += 1
    else:
        for root, _dirs, files in os.walk(handle):
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), handle)
                target = _safe_target(dest, rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copyfile(os.path.join(root, f), target)
                count += 1

    return kind, count


def main():
    args = [a for a in sys.argv[1:] if a != "--force"]
    force = "--force" in sys.argv[1:]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)

    container, dest = args
    kind, count = extract(container, dest, force=force)
    print("Container:    %s" % kind)
    print("Extracted:    %d files -> %s" % (count, dest))


if __name__ == "__main__":
    main()
