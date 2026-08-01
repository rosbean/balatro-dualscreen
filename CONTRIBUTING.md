# Contributing

Thanks for taking a look.

## The one rule

**No Balatro code or assets may enter this repository.** Not Lua, not textures,
not sounds, not the icon. Everything from the game arrives at build time from a
copy the person building it already owns. A change that commits game data
cannot be merged, whatever else it does.

`tools/check_guards.py` enforces this. Run it before opening a pull request:

```bash
python3 tools/check_guards.py
```

## Wrap, don't replace

The overlay works by wrapping vanilla functions and calling through to them. A
wrapper inherits upstream fixes; a wholesale copy of a game function silently
reverts them and re-imports copyrighted code. If you genuinely need to replace
one, write down why in `docs/decisions/`.

## Preserve single-screen behaviour

Every dual-screen path needs a null path. With the second screen off, or on a
device that has only one, the game must behave exactly like vanilla.

## Before you open a pull request

- Build against both container formats if you touched extraction, injection or
  packaging — they take different code paths:
  ```bash
  python3 tools/build.py --balatro /path/to/Balatro.app
  python3 tools/build.py --balatro /path/to/Balatro.exe
  ```
- Test on a device. "The code looks right" is not verification.
- Keep comments functional: explain why something non-obvious is the way it is,
  and cite vanilla `file:line` when the reason lives in the game's own code.

## Signing

Nothing needs configuring. With no signing key present the release build falls
back to Android's debug key, which installs fine — it simply cannot upgrade an
APK from the Releases tab, since those are signed with a different key.
Uninstall first if you are replacing a released build.

To sign with your own key, put these in `~/.gradle/gradle.properties` (never in
the repository — `*.jks` and `gradle.properties` are gitignored for that
reason):

```
BALATRO_STORE_FILE=/absolute/path/to/your.jks
BALATRO_STORE_PASSWORD=...
BALATRO_KEY_ALIAS=...
BALATRO_KEY_PASSWORD=...
```

## Reporting bugs

Use the issue templates. Logs help enormously:

```bash
adb logcat -s SDL/APP:I BalatroDS:I
```
