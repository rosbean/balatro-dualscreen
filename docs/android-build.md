# Android build environment

Exact versions, where each one comes from, and how to reproduce the setup.

**Every version here is pinned to what love-android 11.5 declares.** None of it is
assumed. The evidence is quoted below so a future session can re-check it against a
different love-android tag rather than trusting this page.

Host: macOS 26.5.2, Apple Silicon (arm64).

---

## The pins, and where they come from

Read out of `love2d/love-android` at tags `11.5` and `11.5a`. **The two tags declare
identical build configuration** — same Gradle, same AGP, same NDK, same SDK levels — so
the choice between them does not affect the toolchain.

| Thing | Version | Declared in |
|---|---|---|
| Gradle | **8.1** | `gradle/wrapper/gradle-wrapper.properties` → `gradle-8.1-bin.zip` |
| Android Gradle Plugin | **8.1.1** | `build.gradle` → `com.android.tools.build:gradle:8.1.1` |
| NDK | **25.2.9519653** (r25c) | `app/build.gradle` and `love/build.gradle` → `ndkVersion` |
| compileSdk / targetSdk | **34** | `app/build.gradle`, `love/build.gradle` |
| minSdk | 16 | same |
| Native build system | **ndkBuild** | `love/build.gradle` → `externalNativeBuild { ndkBuild { path 'src/jni/Android.mk' } }` |
| ABIs (release) | `armeabi-v7a`, `arm64-v8a` | `love/build.gradle` `ndk.abiFilters` |
| ABIs (debug) | the above **plus `x86_64`** | `love/build.gradle` `buildTypes.debug.ndk` |

### Why JDK 17 — the one that had to be checked, not assumed

The build plan proposed JDK 17. Checking it against the real wrapper confirms it, and also
shows it is a narrow window rather than a floor:

- **AGP 8.1.1 requires JDK 17 or newer.** That is the floor.
- **Gradle 8.1 cannot run on JDK 20 or later.** JDK 20 needs Gradle 8.3; JDK 21 needs
  Gradle 8.5. That is the ceiling.

So the usable range is **JDK 17–19**, and 17 is the sensible pick. A newer JDK is not a
safe "upgrade" here — moving past 19 means moving Gradle first, which means moving off the
version love-android pins.

Installed: **OpenJDK 17.0.20** (Homebrew, `aarch64`, native arm64).

### Corrections to the build plan

Three things in the original plan did not survive contact with the
actual love-android 11.5 configuration. All three are now fixed in the plan; recorded here
so the reason is not lost.

1. **SDK platform is 34, not 33.** The plan said `platforms;android-33`. love-android 11.5
   sets `compileSdk 34`. The Thor runs Android 13 / API 33 — that is the *device* level and
   does not determine which platform you compile against. `platforms;android-34` installed.
2. **CMake is not used.** The plan listed `cmake` among the sdkmanager packages. love-android
   11.5 builds its native code with **ndkBuild** via `src/jni/Android.mk`; there is no
   `CMakeLists.txt` in the engine build path. CMake 3.22.1 was installed anyway — it is
   harmless, and a native module may want it — but it is not what compiles the engine.
3. **"Add a C module to love-android's CMake" is the wrong mechanism.** For the
   same reason: it will be an `Android.mk` / ndkBuild addition.

A fourth: **build via `./gradlew`, not a system `gradle`.** The wrapper is
what pins Gradle 8.1. Invoking a system Gradle bypasses the pin and picks up whatever is
installed — currently nothing, deliberately.

---

## What is installed

```
JDK          openjdk 17.0.20 (Homebrew)   /opt/homebrew/opt/openjdk@17
                                          JAVA_HOME = .../libexec/openjdk.jdk/Contents/Home
SDK root                                  ~/Library/Android/sdk        (~2.6 GB)
  cmdline-tools;latest   22.0
  platform-tools         37.0.0           adb 1.0.41
  platforms;android-34   rev 3
  build-tools;34.0.0     34.0.0
  ndk;25.2.9519653       r25c             2.1 GB — the bulk of the install
  cmake;3.22.1           3.22.1           installed but unused by love-android
Gradle       none installed system-wide — use love-android's ./gradlew (8.1)
```

Homebrew's `openjdk@17` **formula** was used rather than the Temurin **cask**, because the
formula installs under `/opt/homebrew` with no privilege escalation. The cask writes to
`/Library/Java/JavaVirtualMachines` and needs a password. Homebrew's post-install caveat
suggests a `sudo ln -sfn` to register the JDK with the system Java wrappers — **that is not
needed here** and was not done; `JAVA_HOME` points at the keg directly.

The SDK command-line tools were downloaded from Google directly rather than via a Homebrew
cask, again to avoid privilege escalation:

```
https://dl.google.com/android/repository/commandlinetools-mac_arm64-15859902_latest.zip
```

Note that Google publishes a **native arm64** build of the command-line tools; the
`repository2-3.xml` manifest lists `macosx/aarch64` separately from `macosx/x64`.

---

## Reproducing this setup

Nothing below needs a password.

```bash
brew install openjdk@17

SDK="$HOME/Library/Android/sdk"
mkdir -p "$SDK/cmdline-tools"
curl -L -o /tmp/clt.zip \
  https://dl.google.com/android/repository/commandlinetools-mac_arm64-15859902_latest.zip
unzip -q /tmp/clt.zip -d /tmp/cltx
mv /tmp/cltx/cmdline-tools "$SDK/cmdline-tools/latest"

export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME="$SDK"
export PATH="$JAVA_HOME/bin:$SDK/cmdline-tools/latest/bin:$PATH"

yes | sdkmanager --licenses
sdkmanager --install "platform-tools" "platforms;android-34" \
                     "build-tools;34.0.0" "ndk;25.2.9519653" "cmake;3.22.1"
```

Then use the env file rather than exporting by hand:

```bash
source ~/.config/android-build-env.sh
android_build_env_check
```

`android_build_env_check` is defined by that file and prints one line per tool. Expected:

```
android build env:
  ok    java           openjdk version "17.0.20" 2026-07-21
  ok    javac          javac 17.0.20
  ok    adb            Android Debug Bridge version 1.0.41
  ok    ndk-build      GNU Make 4.3
  ok    platform-34    $ANDROID_HOME/platforms/android-34
  ok    build-tools    34.0.0
```

---

## Notes worth keeping

- **The NDK is arm64-native despite the directory name.** The macOS toolchain sits at
  `ndk/25.2.9519653/toolchains/llvm/prebuilt/**darwin-x86_64**/`, which reads like an
  x86-only build. It is not — the binaries are universal:
  `clang: Mach-O universal binary with 2 architectures [x86_64] [arm64]`.
  **No Rosetta 2 is required.** Do not install it on this account.
- **`ndk-build` is GNU Make.** `ndk-build --version` reports `GNU Make 4.3`, which is
  correct and not a misconfiguration.
- **Debug builds compile three ABIs.** `love/build.gradle` adds `x86_64` to `abiFilters` in
  the debug build type, on top of `armeabi-v7a` and `arm64-v8a`. Expect debug native builds
  to take roughly half again as long as release. If build times are painful, that
  is the first thing to trim.
- **`sdkmanager` is deprecated** in cmdline-tools 22 — it prints a warning pointing at the
  new `android` CLI (`android sdk`). It still works. The warning is noise, not a failure.

---

## Device connection

**Wired USB.** Plugged in, USB debugging enabled in Developer options, on-device
"Allow USB debugging?" accepted. No wireless pairing was used, so there is nothing to
re-pair after a reboot.

```
$ adb devices -l
4aab4069   device usb:0-1 product:kalama model:AYN_Thor device:kalama transport_id:1
```

| property | value |
|---|---|
| `ro.product.model` | `AYN Thor` |
| `ro.product.manufacturer` | `AYN` |
| `ro.product.device` / `name` | `kalama` |
| `ro.build.version.release` / `sdk` | **13 / 33** |
| `ro.build.display.id` | `Thor_V1.0.0.377_20260206_165408_user` |
| `ro.product.cpu.abi` | **`arm64-v8a`** |
| `ro.product.cpu.abilist` | `arm64-v8a, armeabi-v7a, armeabi` |

Matches the plan's target exactly: arm64-v8a, Android 13 / API 33. love-android's release
`abiFilters` (`armeabi-v7a`, `arm64-v8a`) covers this device; the `x86_64` that debug builds
add is dead weight here and is the first thing to trim if build times hurt.

If `adb devices` shows `unauthorized`, the on-device confirmation dialog is still pending.
If it shows nothing at all, check the cable — a charge-only cable enumerates no USB device
on the host at all.
