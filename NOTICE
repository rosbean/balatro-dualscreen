NOTICE
======

balatro-dualscreen-thor — an Android application, a Lua overlay, and a build
script that lets a person who already owns Balatro build an APK that uses both
AYN Thor screens.

Licensed under the GNU General Public License, version 3. The full licence text
is in COPYING.

This project redistributes no part of Balatro. There are three distinct
relationships to other people's work, and they are not the same relationship.
Each is stated separately below.


1. BanjoRecomp Android — CODE IS LIFTED AND ADAPTED (GPL-3.0)
-------------------------------------------------------------

Upstream project: Banjo: Recompiled — https://github.com/BanjoRecomp/BanjoRecomp
Android fork with dual-screen support, vendored locally at
`reference/banjo-recomp-android/` (gitignored; not redistributed here).
Licence: GNU General Public License version 3. Its COPYING is the file this
project's COPYING was taken from (sha1 31a3d460bb3c7d98845187c716a30db81c44b615).

**This is why this project is GPL-3.0.** Its Android dual-screen companion
implementation is the basis for the Android side of this project. Code is copied
and adapted, not merely consulted.

Files this project derives from. Each derived file carries a provenance comment
naming its source and what was changed.

DERIVED, PRESENT IN THIS REPOSITORY:

  android/app/src/main/java/com/balatro/dualscreen/companion/CompanionDisplayManager.java
      ← BanjoRecomp android/.../io/github/banjorecomp/DualScreenStatsManager.java
        Kept: start/stop/setAppForeground/hideForExternalActivity, the
        DisplayManager.DisplayListener hotplug handling,
        findSecondaryPresentationDisplay() and its
        DISPLAY_CATEGORY_PRESENTATION + != DEFAULT_DISPLAY filter,
        refreshPresentation()/dismissPresentation() and their ordering,
        logPresentationDisplays().
        Stripped: sprite theme and ROM extraction, the background executor
        serving them, DualScreenDebugAreas, debug key/button handlers,
        preview mode, the stats DTO.

  android/app/src/main/java/com/balatro/dualscreen/companion/CompanionPresentation.java
      ← BanjoRecomp android/.../io/github/banjorecomp/DualScreenStatsPresentation.java
        Kept: the Presentation subclass shape and the black window
        background. Stripped: debug-key dispatch, sprite-theme plumbing.

  android/app/src/main/java/com/balatro/dualscreen/BalatroActivity.java
      ← the `activityResumed && windowFocused` foreground rule from
        BanjoRecomp android/.../io/github/banjorecomp/BanjoSDLActivity.java:312.
        The rest of the class is this project's own.

  android/love/src/jni/lua-modules/dsbridge/dsbridge.c
      ← BanjoRecomp src/game/recomp_api.cpp:256-310
        The native→JNI call pattern: SDL_AndroidGetJNIEnv() →
        SDL_AndroidGetActivity() → GetObjectClass → GetStaticMethodID →
        CallStatic*Method, with DeleteLocalRef on BOTH the class and the
        activity and ExceptionCheck/ExceptionClear around the call.
        Adapted: Banjo passes eighteen fixed ints; this passes a single
        string, because Balatro's snapshot has a variable-length card array.

  android/app/src/main/java/com/balatro/dualscreen/companion/CompanionProbeView.java
      ← touch handling follows BanjoRecomp
        android/.../io/github/banjorecomp/DualScreenStatsView.java:225.

NOT YET DERIVED — planned, listed so the obligation is never retroactive:

  android/app/src/main/java/io/github/banjorecomp/DualScreenStatsView.java
      → its Canvas card-drawing patterns. Under ADR 0001 the hand is
        rendered in LÖVE and shipped as pixels, so these are unused.

COPYING and this NOTICE were in place before any of the above was written.
This list is updated as files are actually added.


2. balatro-portrait-mobile — RESEARCH INPUT ONLY, NO CODE TAKEN
---------------------------------------------------------------

https://github.com/ShaggyLorean/balatro-portrait-mobile

**No code from this project has been used, and none can be.** It carries no
licence grant — it is offered as-is for personal use, with no LICENSE file and
no permission to redistribute or relicense. Copying from it into a GPL-3.0
public repository is not available to us, regardless of how convenient any
particular line of it might be.

It was read as prior art. It demonstrated that Balatro's layout can be reflowed
on Android, and it showed where the layout logic lives. Those observations are
facts about Balatro's structure, not expression copied from the mod.


3. Bifrost — LED TECHNIQUE FOLLOWED (GPL-3.0)
---------------------------------------------

https://github.com/Pollux-MoonBench/Bifrost
Copyright (c) Pollux-MoonBench. Licensed under GPL-3.0.

An LED controller for the AYN Thor. Its `LedController` established how the
stick LEDs are reached: they are root-owned sysfs nodes under
/sys/class/sn3112{l,r}/led/brightness, written by asking the vendor's
PServerBinder service to run an echo, and the wire format is
`<zone>-<R>:<G>:<B>:<brightness>`.

android/app/src/main/java/com/balatro/dualscreen/ThorLeds.java follows that
technique. The implementation here is this project's own -- a much smaller
class with no animation engine, capability-based availability detection, and
its own batching and rate limiting -- but the protocol knowledge is Bifrost's,
and this project would not have found it independently. Both projects are
GPL-3.0, so following it is compatible either way.


4. Balatro / LocalThunk — THE TARGET GAME, NOTHING REDISTRIBUTED
-----------------------------------------------------------------

Balatro is by LocalThunk, published by Playstack. https://www.playbalatro.com/

**This repository contains no Balatro code and no Balatro assets.** Not Lua, not
textures, not sounds, not fonts, not localizations, not `.love` or `.jkr` files.
Nothing.

The build script requires the user to supply their own legally obtained copy of
the game. It extracts that copy locally, appends a single `require` line to the
game's `main.lua`, and packages the result into an APK on the user's own
machine. No game content passes through this repository at any point.

The Lua in `lua/dualscreen/` is this project's own work. It reassigns Balatro's
global functions at runtime rather than modifying them, so it contains no copied
game code.

This is an unofficial fan project. It is not affiliated with, endorsed by, or
connected to LocalThunk, Playstack, or AYN.


Trademarks
----------

"Balatro" is a trademark of its respective owner. "AYN" and "Thor" are
trademarks of AYN Technologies. Used here descriptively, to identify the game
this project targets and the device it runs on. No endorsement is implied.
