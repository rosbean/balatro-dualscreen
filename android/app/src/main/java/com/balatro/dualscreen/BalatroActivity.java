/*
 * balatro-dualscreen-thor
 * Copyright (C) 2026  balatro-dualscreen-thor contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package com.balatro.dualscreen;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.Keep;

import com.balatro.dualscreen.companion.CompanionDisplayManager;
import com.balatro.dualscreen.companion.CompanionEventQueue;
import com.balatro.dualscreen.companion.CompanionSnapshot;

import org.love2d.android.GameActivity;

/**
 * The game activity, subclassed so this project has somewhere to own the
 * secondary display without editing love-android's own GameActivity.
 *
 * Everything about running the game - native library loading, the embedded
 * game.love, SDL's lifecycle - is inherited untouched. This class adds only
 * the dual-screen companion and the lifecycle signals it needs.
 *
 * The foreground rule is `activityResumed && windowFocused`, not resume alone.
 * That is lifted from BanjoRecomp (BanjoSDLActivity.java:312) and it is not a
 * refinement - the gap is observable on this device:
 *
 *     FOREGROUND resumed=true focused=false  ->  dismissed
 *     FOREGROUND resumed=true focused=true   ->  shown on displayId=4
 *
 * An activity resumes before it gains focus. Gating on onResume alone shows
 * the Presentation during that window and never corrects it, which on task
 * switch leaves it stranded over the launcher.
 */
public class BalatroActivity extends GameActivity {
    private static final String TAG = "BalatroDS";

    private boolean activityResumed;
    private boolean windowFocused;

    private CompanionDisplayManager companion;

    /**
     * Static, because JNI resolves these against the activity's class via
     * SDL_AndroidGetActivity() -> GetObjectClass() -> GetStaticMethodID().
     * That is the pattern from BanjoRecomp recomp_api.cpp:256; see
     * love/src/jni/lua-modules/dsbridge/dsbridge.c.
     *
     * @Keep matters: love-android's release build sets minifyEnabled true, and
     * R8 cannot see a call site for a method only ever reached from native
     * code. Without it these are stripped and the bridge silently dies in
     * release but works in debug.
     */
    private static volatile BalatroActivity instance;
    private static final CompanionEventQueue EVENTS = new CompanionEventQueue();
    private static final Handler UI = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        Log.i(TAG, "onCreate");
        super.onCreate(savedInstanceState);

        instance = this;
        companion = new CompanionDisplayManager(this);
        // Debug: exercise the single-screen null path on a device whose second
        // panel cannot be detached. See CompanionDisplayManager.
        if (getIntent() != null
                && getIntent().getBooleanExtra("ds_force_no_secondary", false)) {
            Log.i(TAG, "ds_force_no_secondary set - pretending there is one screen");
            companion.setForceNoSecondaryDisplay(true);
        }
        companion.start();
    }

    @Override
    public void onResume() {
        super.onResume();
        activityResumed = true;
        Log.i(TAG, "onResume");
        updateForeground();
    }

    @Override
    protected void onPause() {
        activityResumed = false;
        Log.i(TAG, "onPause");
        updateForeground();
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        windowFocused = hasFocus;
        Log.i(TAG, "onWindowFocusChanged hasFocus=" + hasFocus);
        updateForeground();
        super.onWindowFocusChanged(hasFocus);
    }

    @Override
    protected void onDestroy() {
        Log.i(TAG, "onDestroy");
        if (instance == this) {
            instance = null;
        }
        EVENTS.clear();
        if (companion != null) {
            companion.stop();
            companion = null;
        }
        super.onDestroy();

        // Die with the activity, so the next launch starts a fresh process.
        //
        // On the in-game Quit button, SDL ends the native thread and finishes
        // the activity, but Android keeps the empty process cached -- and
        // neither LOVE nor SDL can survive a second run in it. Observed
        // directly: relaunching into the cached process fails with
        //   [love "boot.lua"]:48: Failed to initialize filesystem: already
        //   initialized
        // and the app hangs until the user force-stops it. This is vanilla
        // behaviour too; killing the process
        // once the activity is torn down is the standard SDL-app fix, and by
        // this point everything -- companion display included -- is already
        // shut down.
        android.os.Process.killProcess(android.os.Process.myPid());
    }

    /** Single place that decides whether the companion display should be up. */
    private void updateForeground() {
        boolean foreground = activityResumed && windowFocused;
        Log.i(TAG, "foreground=" + foreground
                + " (resumed=" + activityResumed + " focused=" + windowFocused + ")");
        if (companion != null) {
            companion.setAppForeground(foreground);
        }
    }

    /**
     * Boot from the ON-DEVICE ASSEMBLED game when one exists.
     *
     * getGamePath() -- called lazily from the SDL thread -- routes through
     * this method in the embed flavour. Preference order:
     *
     *   1. the embedded assets/game.love (developer builds, freshest);
     *   2. getFilesDir()/balatro-game.love, assembled by SetupActivity from
     *      the user's own Balatro copy (release builds ship no game at all).
     *
     * Embedded-first matters when a dev APK is installed over a release
     * install: the assembled game survives in files/, and preferring it
     * would silently shadow the build under test.
     */
    @Override
    protected void copyGameInsideArchive() {
        super.copyGameInsideArchive();
        if (gamePath == null || gamePath.length() == 0) {
            java.io.File assembled = GameAssembler.assembled(this);
            if (assembled != null) {
                gamePath = assembled.getAbsolutePath();
                storagePermissionUnnecessary = true;
                Log.i(TAG, "booting assembled game: " + gamePath);
            }
        }
    }

    // --- native bridge (called from the LOVE/SDL thread, not the UI thread) ---

    /**
     * Lua -> Java. Receives a serialised snapshot and routes it to the
     * companion display.
     *
     * Marshals to the UI thread because it touches a View. Returns immediately
     * so the game thread never blocks on the second screen; a slow or absent
     * companion must not cost frames on screen 1.
     */
    /**
     * THE ROTATION FIX. SDL re-requests the screen orientation AT RUNTIME from
     * its orientation hint -- SDLActivity.setOrientationBis picks
     * SCREEN_ORIENTATION_SENSOR_LANDSCAPE or FULL_SENSOR (SDLActivity.java:
     * 994-1030) -- and the SENSOR_* orientations BYPASS the user's rotation
     * lock. That is why the top screen rotated on physical rotation despite
     * the manifest's android:screenOrientation="landscape", despite
     * auto-rotate being off, and why driving `settings put system
     * user_rotation` over adb never reproduced it: sensor orientations ignore
     * that setting entirely.
     *
     * This game is landscape, on this device, always. Whatever SDL asks for,
     * request plain locked LANDSCAPE.
     */
    @Override
    public void setOrientationBis(int w, int h, boolean resizable, String hint) {
        Log.i(TAG, "orientation: SDL asked (hint=" + hint + "); forcing locked landscape");
        setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
    }

    // ------------------------------------------------------------------
    // Joystick LED bridge. Constructed once; every call is a no-op on
    // hardware without the vendor service.
    // ------------------------------------------------------------------

    private static ThorLeds leds;

    @Keep
    public static void setLedsFromNative(final int r, final int g, final int b) {
        ThorLeds l = leds;
        if (l == null) {
            synchronized (BalatroActivity.class) {
                if (leds == null) leds = new ThorLeds();
                l = leds;
            }
        }
        l.setColor(r, g, b);
    }

    @Keep
    public static void pushSnapshotFromNative(String wire) {
        final BalatroActivity self = instance;
        if (self == null) {
            return;
        }
        UI.post(new Runnable() {
            @Override public void run() {
                if (self.companion != null) {
                    self.companion.updateSnapshot(CompanionSnapshot.parse(wire));
                }
            }
        });
    }

    /** Java -> Lua. Drains one semantic event, or null when the queue is empty. */
    @Keep
    public static String pollEventFromNative() {
        return EVENTS.poll();
    }

    /**
     * Whether a companion Presentation is currently up. This is what Lua's
     * DS.active derives from, so a device with one screen reports false and the
     * overlay keeps to its single-screen path.
     */
    @Keep
    public static boolean isCompanionShowingFromNative() {
        final BalatroActivity self = instance;
        return self != null && self.companion != null && self.companion.isShowing();
    }

    // ------------------------------------------------------------------
    // The zero-copy frame path.
    //
    // The byte[] route below cost, per push: a 5.2 MB Java allocation
    // (NewByteArray), a JNI copy into it, a copy into the direct buffer, and
    // a copy into the Bitmap -- at ~50 pushes/s, hundreds of MB/s of copies
    // and enough garbage to keep two collectors busy (the Lua side made a
    // 5.2 MB string per push as well).
    //
    // Now there is ONE persistent direct ByteBuffer. The LOVE thread memcpys
    // straight from LOVE's ImageData into it (dsbridge holds the address),
    // and the UI thread copies it into the Bitmap. Two copies total, no
    // steady-state allocation. The buffer OBJECT is the monitor both sides
    // take -- dsbridge via JNI MonitorEnter, the view via synchronized -- so
    // a blit can never read a half-written frame.
    // ------------------------------------------------------------------

    private static java.nio.ByteBuffer sharedFrame;

    /** LOVE thread. (Re)allocate the shared buffer; dsbridge caches it. */
    @Keep
    public static java.nio.ByteBuffer acquireFrameBufferFromNative(int w, int h) {
        java.nio.ByteBuffer buf = java.nio.ByteBuffer.allocateDirect(w * h * 4);
        sharedFrame = buf;
        Log.i(TAG, "shared frame buffer " + w + "x" + h
                + " (" + (w * h * 4 / 1024) + " KiB, direct)");
        return buf;
    }

    /** LOVE thread, after it filled the shared buffer. */
    @Keep
    public static void frameReadyFromNative(final int w, final int h) {
        final BalatroActivity self = instance;
        final java.nio.ByteBuffer buf = sharedFrame;
        if (self == null || buf == null || w <= 0 || h <= 0) {
            return;
        }
        UI.post(new Runnable() {
            @Override public void run() {
                if (self.companion != null) {
                    self.companion.updateFrame(buf, w, h);
                }
            }
        });
    }

    /**
     * Lua -> Java, raw RGBA8 frame -- the byte[] FALLBACK path, kept for a
     * build whose native module predates the shared buffer. Costs three more
     * copies and 5.2 MB of garbage per push than the path above.
     */
    @Keep
    public static void pushFrameFromNative(final byte[] pixels, final int w, final int h) {
        final BalatroActivity self = instance;
        if (self == null || pixels == null || w <= 0 || h <= 0) {
            return;
        }
        UI.post(new Runnable() {
            @Override public void run() {
                if (self.companion != null) {
                    self.companion.updateFrame(pixels, w, h);
                }
            }
        });
    }

    /**
     * The companion content view's size, as "WxH", or null if none is up.
     *
     * Lua must size its canvas from this and never from Display.getMode(),
     * which reports the native PORTRAIT panel. Note this is the
     * view size (1240x1025 on the Thor), not the display size (1240x1080) --
     * the system bar takes the difference.
     */
    @Keep
    public static String getCompanionSizeFromNative() {
        final BalatroActivity self = instance;
        if (self == null || self.companion == null) {
            return null;
        }
        return self.companion.contentSize();
    }

    /** Double-tap on screen 2 hides/restores it. UI thread. */
    public static void toggleCompanionHidden() {
        final BalatroActivity self = instance;
        if (self != null && self.companion != null) {
            self.companion.toggleUserHidden();
        }
    }

    /** Called from the UI thread when screen 2 is touched. */
    public static void postEvent(String event) {
        EVENTS.offer(event);
    }
}
