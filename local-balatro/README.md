# Local Balatro copies — NEVER COMMIT

Two Steam 1.0.1o `PROD_PC_Console` copies, kept here so the build process can be
tested against **both container formats**. Their contents are byte-for-byte
identical (verified); only the packaging differs.

| File | Container | Game data at |
|---|---|---|
| `Balatro.app` | macOS bundle | `Contents/Resources/Balatro.love` (packed) |
| `Balatro.exe` | Windows PE | zip appended to the executable |

This directory is gitignored and must stay that way. It exists for local build
testing only. Nothing in it is redistributable.

Validate either with:

    python3 tools/check_balatro_source.py local-balatro/Balatro.app
    python3 tools/check_balatro_source.py local-balatro/Balatro.exe
