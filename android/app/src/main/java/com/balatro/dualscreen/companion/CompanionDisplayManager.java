/*
 * balatro-dualscreen-thor
 * Copyright (C) 2026  balatro-dualscreen-thor contributors
 *
 * Derived from BanjoRecomp Android, which is licensed GPL-3.0:
 *   android/app/src/main/java/io/github/banjorecomp/DualScreenStatsManager.java
 * Upstream: https://github.com/BanjoRecomp/BanjoRecomp
 *
 * Kept from the original, structurally unchanged because it is correct and
 * was proven on this exact device:
 *   - start() / stop() / setAppForeground() / hideForExternalActivity()
 *   - DisplayManager.DisplayListener hotplug handling
 *   - findSecondaryPresentationDisplay(), the DISPLAY_CATEGORY_PRESENTATION +
 *     != DEFAULT_DISPLAY filter (DualScreenStatsManager.java:321)
 *   - refreshPresentation() / dismissPresentation() and their ordering
 *   - logPresentationDisplays()
 *
 * Stripped, as none of it applies here: the Banjo sprite theme and its ROM
 * extraction, the background-executor plumbing that served it,
 * DualScreenDebugAreas, the debug key/button handlers, preview mode, and the
 * stats DTO.
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

package com.balatro.dualscreen.companion;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;
import android.view.WindowManager;
import java.nio.ByteBuffer;
/**
 * Owns the secondary-display Presentation: finds the display, shows and
 * dismisses the window, and follows hotplug and foreground changes.
 *
 * Two rules this class exists to enforce, both learned the expensive way by
 * the project it is lifted from:
 *
 * 1. NEVER CACHE THE DISPLAY ID. Rediscover through DisplayManager every time,
 *    by capability (FLAG_PRESENTATION via DISPLAY_CATEGORY_PRESENTATION), never
 *    by model string or by matching a resolution. Note that the
 *    Thor's ids do survive a reboot - that is a diagnostic fact, not a licence
 *    to cache.
 *
 * 2. FOREGROUND MEANS RESUMED AND FOCUSED. The caller decides that; see
 *    BalatroActivity.updateForeground(). Gating on resume alone leaves the
 *    Presentation stranded over the launcher on a task switch.
 */
public class CompanionDisplayManager implements DisplayManager.DisplayListener {
    private static final String TAG = "BalatroDS";

    private final Context context;
    private final DisplayManager displayManager;

    private CompanionPresentation presentation;
    private boolean started;
    private boolean appForeground;

    private CompanionSnapshot latest = new CompanionSnapshot();
    private String lastDedupeKey = "";

    /**
     * Pretend no secondary display exists.
     *
     * The Thor's second panel is built in and cannot be detached, and neither
     * `cmd display` nor `settings put global overlay_display_devices` can
     * remove it - the latter only adds simulated displays. So the single-screen
     * null path cannot be exercised on this hardware by removing hardware.
     *
     * This makes it testable anyway:
     *
     *     adb shell am start -n com.balatro.dualscreen/.BalatroActivity \
     *         --ez ds_force_no_secondary true
     *
     * It tests OUR code path, not the device. A real single-screen device is
     * still needed. Kept rather than deleted
     * because 7.2 will want it again.
     */
    private boolean forceNoSecondaryDisplay;

    public CompanionDisplayManager(Context context) {
        this.context = context;
        this.displayManager =
                (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
    }

    public void start() {
        if (started || displayManager == null) {
            return;
        }
        started = true;
        displayManager.registerDisplayListener(this, null);
        logPresentationDisplays();
        refreshPresentation();
    }

    public void stop() {
        if (!started) {
            return;
        }
        // Drop any pending background transition, so a grace-period
        // callback cannot fire against a torn-down manager.
        mainHandler.removeCallbacks(applyBackground);
        dismissPresentation();
        if (displayManager != null) {
            displayManager.unregisterDisplayListener(this);
        }
        started = false;
    }

    /**
     * Going to background is DEBOUNCED; coming to foreground is not.
     *
     * The foreground rule is `activityResumed && windowFocused`
     * (BalatroActivity.updateForeground), and rotating the device makes the
     * system briefly withdraw window focus and hand it straight back. That is
     * not a backgrounding, but it looked exactly like one, so every rotation
     * ran a full dismiss-and-rebuild of the Presentation. Captured:
     *
     *     display changed: 0
     *     companion foreground=false
     *     companion dismissed
     *     companion foreground=true
     *     companion shown on display 4 / Screen-2
     *
     * — the window destroyed and recreated, the view re-laid-out, the bitmap
     * reallocated and the LOVE side's panel size reset to 0x0, three times over
     * for three rotations. That thrash is what "rotating breaks everything"
     * actually was.
     *
     * A real backgrounding still dismisses, just a beat later, which is
     * invisible. A transient blip now cancels itself. Foreground is applied
     * immediately, so returning to the app is never delayed.
     */
    private static final long BACKGROUND_GRACE_MS = 400;

    private final Handler mainHandler =
            new Handler(Looper.getMainLooper());

    private final Runnable applyBackground = new Runnable() {
        @Override
        public void run() {
            if (appForeground) {
                appForeground = false;
                Log.i(TAG, "companion foreground=false (grace elapsed)");
                refreshPresentation();
            }
        }
    };

    public void setAppForeground(boolean foreground) {
        if (foreground) {
            mainHandler.removeCallbacks(applyBackground);
            if (appForeground) {
                return;
            }
            appForeground = true;
            Log.i(TAG, "companion foreground=true");
            refreshPresentation();
            return;
        }

        // Losing foreground: wait out the grace period before believing it.
        if (!appForeground) {
            return;
        }
        mainHandler.removeCallbacks(applyBackground);
        mainHandler.postDelayed(applyBackground, BACKGROUND_GRACE_MS);
    }

    /** Called when something else is about to take over the screen. */
    public void hideForExternalActivity() {
        dismissPresentation();
    }

    /**
     * The player has double-tapped screen 2 to hide it.
     *
     * The Presentation deliberately STAYS UP -- it has to, or there would be no
     * surface left to receive the double-tap that brings it back. It just draws
     * black and reports itself as not showing, which is what makes Lua fall the
     * hand back to screen 1.
     */
    private boolean userHidden;

    /**
     * True when a Presentation is up AND the player has not hidden it. This is
     * the seed of Lua's DS.active, so the hand follows it automatically: when
     * this goes false the draw suppression stops and screen 1 renders
     * the hand again.
     */
    public boolean isShowing() {
        return presentation != null && !userHidden;
    }

    /** Returns the new hidden state. */
    public boolean toggleUserHidden() {
        userHidden = !userHidden;
        Log.i(TAG, "companion userHidden=" + userHidden);
        if (presentation != null) {
            presentation.setHidden(userHidden);
        }
        return userHidden;
    }

    /**
     * THE single update path for snapshots, whatever the display mode.
     *
     * Banjo's second rule: route every snapshot through one path regardless of
     * mode, so mode-specific handling cannot diverge. Their first rule is
     * honoured inside CompanionSnapshot.dedupeKey(), which includes
     * displayMode - a mode-only change must not be swallowed just because the
     * card values happen to match.
     */
    public void updateSnapshot(CompanionSnapshot snapshot) {
        if (snapshot == null) {
            return;
        }
        latest = snapshot;

        String key = snapshot.dedupeKey();
        boolean changed = !key.equals(lastDedupeKey);
        lastDedupeKey = key;

        if (presentation != null) {
            presentation.updateSnapshot(snapshot);
        }
        if (changed) {
            Log.i(TAG, "snapshot gen=" + snapshot.generation
                    + " mode=" + snapshot.displayMode
                    + " cards=" + snapshot.cards.size()
                    + " highlighted=" + snapshot.highlightedCount());
        }
    }

    public CompanionSnapshot latestSnapshot() {
        return latest;
    }

    /** "WxH" of the companion content view, or null when none is up. */
    public String contentSize() {
        if (presentation == null) {
            return null;
        }
        return presentation.contentSize();
    }

    /** Raw frame from LOVE. Goes straight to the view; never deduped. */
    public void updateFrame(byte[] pixels, int w, int h) {
        if (presentation != null) {
            presentation.updateFrame(pixels, w, h);
        }
    }

    /** Shared-buffer frame. The buffer object is the lock. */
    public void updateFrame(ByteBuffer buf, int w, int h) {
        if (presentation != null) {
            presentation.updateFrame(buf, w, h);
        }
    }

    // --- DisplayManager.DisplayListener -----------------------------------

    @Override
    public void onDisplayAdded(int displayId) {
        Log.i(TAG, "display added: " + displayId);
        refreshPresentation();
    }

    @Override
    public void onDisplayRemoved(int displayId) {
        Log.i(TAG, "display removed: " + displayId);
        if (isOurDisplay(displayId)) {
            dismissPresentation();
        }
        refreshPresentation();
    }

    @Override
    public void onDisplayChanged(int displayId) {
        Log.i(TAG, "display changed: " + displayId);

        // React only to OUR display, or to any change while we have
        // no presentation at all (one may now be attachable).
        //
        // Previously refreshPresentation() ran unconditionally. Rotating the
        // device fires onDisplayChanged for the PRIMARY display too -- verified
        // in practice, which logged "display changed: 4" immediately followed
        // by "display changed: 0" -- so a rotation tore the companion down and
        // rebuilt it twice, once of them for a display we do not use.
        if (presentation == null) {
            refreshPresentation();
            return;
        }
        if (!isOurDisplay(displayId)) {
            return;
        }

        // Banjo tears down and rebuilds rather than trying to adapt in place.
        // A changed display may have a new size or rotation, and rebuilding is
        // both simpler and cheap.
        dismissPresentation();
        refreshPresentation();
    }

    private boolean isOurDisplay(int displayId) {
        return presentation != null
                && presentation.getDisplay() != null
                && presentation.getDisplay().getDisplayId() == displayId;
    }

    // --- presentation lifecycle -------------------------------------------

    private void refreshPresentation() {
        if (!started) {
            return;
        }

        if (!appForeground) {
            dismissPresentation();
            return;
        }

        Display display = findSecondaryPresentationDisplay();
        if (display == null) {
            // No secondary display: the null path. The game keeps running as a
            // normal landscape build and nothing here complains.
            dismissPresentation();
            return;
        }

        if (isOurDisplay(display.getDisplayId())) {
            // Already up on the right display; nothing to do.
            return;
        }

        dismissPresentation();

        CompanionPresentation p = new CompanionPresentation(context, display);
        try {
            p.show();
            presentation = p;
            presentation.setStatus("foreground, display " + display.getDisplayId());
            // Replay whatever we last knew, so a Presentation recreated by a
            // lifecycle event does not sit blank until the next hand mutation.
            presentation.updateSnapshot(latest);
            presentation.setHidden(userHidden);
            Log.i(TAG, "companion shown on display "
                    + display.getDisplayId() + " / " + display.getName());
        } catch (WindowManager.InvalidDisplayException e) {
            // The display went away between discovery and show(). Not fatal.
            Log.w(TAG, "unable to show companion presentation", e);
            presentation = null;
        }
    }

    private void dismissPresentation() {
        if (presentation == null) {
            return;
        }
        try {
            presentation.dismiss();
            Log.i(TAG, "companion dismissed");
        } catch (RuntimeException e) {
            Log.w(TAG, "error dismissing companion presentation", e);
        } finally {
            presentation = null;
        }
    }

    /**
     * Capability-based discovery. Lifted verbatim in spirit from
     * DualScreenStatsManager.java:321 - no model strings, no resolution
     * matching, no cached ids.
     */
    /** See forceNoSecondaryDisplay. Debug affordance. */
    public void setForceNoSecondaryDisplay(boolean force) {
        if (forceNoSecondaryDisplay == force) {
            return;
        }
        forceNoSecondaryDisplay = force;
        Log.i(TAG, "forceNoSecondaryDisplay=" + force);
        refreshPresentation();
    }

    private Display findSecondaryPresentationDisplay() {
        if (forceNoSecondaryDisplay || displayManager == null) {
            return null;
        }
        Display[] displays =
                displayManager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        for (Display display : displays) {
            if (display != null && display.isValid()
                    && display.getDisplayId() != Display.DEFAULT_DISPLAY) {
                return display;
            }
        }
        return null;
    }

    private void logPresentationDisplays() {
        if (displayManager == null) {
            Log.i(TAG, "DisplayManager unavailable");
            return;
        }
        Display[] displays =
                displayManager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        Log.i(TAG, "presentation display count: " + displays.length);
        for (Display display : displays) {
            if (display != null) {
                Log.i(TAG, "presentation display: id=" + display.getDisplayId()
                        + " name=" + display.getName()
                        + " valid=" + display.isValid());
            }
        }
    }
}
