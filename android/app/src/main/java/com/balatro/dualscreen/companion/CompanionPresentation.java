/*
 * balatro-dualscreen-thor
 * Copyright (C) 2026  balatro-dualscreen-thor contributors
 *
 * Derived from BanjoRecomp Android, which is licensed GPL-3.0:
 *   android/app/src/main/java/io/github/banjorecomp/DualScreenStatsPresentation.java
 * Adapted: the debug-key dispatch and sprite-theme plumbing are removed; the
 * stats view is replaced by this project's own probe view.
 * Upstream: https://github.com/BanjoRecomp/BanjoRecomp
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

import android.app.Presentation;
import android.content.Context;
import android.content.pm.ActivityInfo;
import android.os.Bundle;
import android.view.Display;
import android.view.KeyEvent;
import android.view.Window;
import android.view.WindowManager;
import java.nio.ByteBuffer;
/**
 * The window on the secondary display. Deliberately as thin as Banjo's - all
 * it does is own a content view and paint the window background black so that
 * nothing shows through during layout.
 */
public class CompanionPresentation extends Presentation {

    private CompanionProbeView view;

    public CompanionPresentation(Context outerContext, Display display) {
        super(outerContext, display);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Window window = getWindow();
        if (window != null) {
            window.setBackgroundDrawableResource(android.R.color.black);

            // Never take key focus.
            //
            // A Presentation is a real window and will happily accept input
            // focus, and hardware key and gamepad events follow focus. With
            // this window focused, the Thor's physical controls were being
            // routed here instead of to the game on display 0 -- Balatro drew
            // its controller pips (it can see the pad) but never received a
            // press.
            //
            // FLAG_NOT_FOCUSABLE affects key input only; touch is still
            // delivered, which is what screen 2 actually needs.
            window.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);

            // Lock this window landscape.
            //
            // A Presentation is a SEPARATE WINDOW and does not inherit the
            // activity's screenOrientation. The activity has been locked
            // landscape (app.orientation=landscape), so the
            // top screen was never the problem -- but this window was still
            // free to follow the display's rotation.
            //
            // That matters here because the secondary panel is natively
            // portrait and is presented rotated: dumpsys reports it as
            // 1080x1240 base with a 1240x1080 rotated override. If the window
            // flips, the panel dimensions transpose while the LOVE side is
            // still rendering and pushing at the old size, and the blit is
            // garbage.
            //
            // This is a whole-app design decision -- the game is landscape,
            // on both screens -- not a device-specific constant.
            WindowManager.LayoutParams lp = window.getAttributes();
            lp.screenOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE;
            window.setAttributes(lp);
        }

        view = new CompanionProbeView(getContext());
        setContentView(view);
    }

    /** Push a one-line status string to the probe view. */
    public void setStatus(String status) {
        if (view != null) {
            view.setStatus(status);
        }
    }

    public void updateSnapshot(CompanionSnapshot snapshot) {
        if (view != null) {
            view.updateSnapshot(snapshot);
        }
    }

    /**
     * Defensive backstop to the FLAG_NOT_FOCUSABLE above: if any key event
     * still reaches this window, refuse it so the default dispatcher passes it
     * on rather than consuming it here.
     */
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        return false;
    }

    /** "WxH", or null before the view has been laid out. */
    public String contentSize() {
        if (view == null || view.getWidth() <= 0 || view.getHeight() <= 0) {
            return null;
        }
        return view.getWidth() + "x" + view.getHeight();
    }

    public void setHidden(boolean hidden) {
        if (view != null) {
            view.setHidden(hidden);
        }
    }

    public void updateFrame(byte[] pixels, int w, int h) {
        if (view != null) {
            view.updateFrame(pixels, w, h);
        }
    }

    /** Shared-buffer frame. */
    public void updateFrame(ByteBuffer buf, int w, int h) {
        if (view != null) {
            view.updateFrame(buf, w, h);
        }
    }
}
