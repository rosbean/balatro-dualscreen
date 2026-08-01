/*
 * balatro-dualscreen-thor
 * Copyright (C) 2026  balatro-dualscreen-thor contributors
 *
 * Touch handling follows BanjoRecomp Android (GPL-3.0),
 *   android/app/src/main/java/io/github/banjorecomp/DualScreenStatsView.java:225
 * which is the proof that MotionEvents reach a Presentation at all.
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

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.SystemClock;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import com.balatro.dualscreen.BalatroActivity;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
/**
 * The secondary display's content view.
 *
 * LOVE renders the panel and pushes finished frames here; this view blits
 * them and turns touches into semantic events. The snapshot-driven debug
 * drawing below is the fallback for before the first frame arrives.
 *
 * EDGE INSET is not cosmetic. The system edge-swipe gesture
 * monitor on display 4 stealing a drag that began at x=1, and cancelling a tap
 * at (74, 81) outright. Interactive targets stay inside EDGE_INSET.
 */
public class CompanionProbeView extends View {
    private static final String TAG = "BalatroDS";

    /** Keep touch targets this far from the panel edge. */
    private static final int EDGE_INSET = 120;

    private final Paint title = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint body = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint dim = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint frame_ = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint cardFill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint cardSel = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint cardText = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint btn = new Paint(Paint.ANTI_ALIAS_FLAG);

    private String status = "waiting";
    private CompanionSnapshot snapshot = new CompanionSnapshot();
    private int updates = 0;
    private String lastEvent = "-";

    private final Rect playRect = new Rect();
    private final Rect discardRect = new Rect();
    private final Rect sortRect = new Rect();

    /**
     * Where each card was drawn. Lua computes these rects when it renders
     * the panel; they are used for hit-testing only.
     */
    private final List<Rect> cardRects = new ArrayList<>();

    // --- frame path -------------------------------------------------------
    // When LOVE is pushing pixels, they take over the whole view and the debug
    // furniture is suppressed. Until then this stays null and the placeholder
    // drawing is what you see.
    //
    // There is no optimistic tap outline: Java decides nothing about what was
    // tapped, it forwards the coordinate, so there is nothing to echo.
    // --- drag ---------------------------------------------------------------
    // Vanilla lets you pick a card up and move it about for the fun of it.
    // A drag only begins once the finger passes DRAG_SLOP, so an ordinary tap
    // still selects rather than nudging the card.
    private static final int DRAG_SLOP = 24;
    private int dragCard = -1;
    private float downX, downY;
    private boolean dragging;

    // BanjoRecomp toggles its second screen with a double-tap
    // (DualScreenStatsView.java:140) and that was ported here first, but on a
    // panel you rest your hands on it fires by accident -- and accidentally
    // losing the hand mid-round is a bad failure. The toggle moved to
    // Options > Settings > Dual Screen, which is deliberate, discoverable, and
    // gives later options somewhere to live.
    //
    // This field remains because Lua still paints the panel black when the
    // setting is off; the window stays up either way.
    private boolean hidden;

    public void setHidden(boolean h) {
        if (hidden != h) {
            hidden = h;
            invalidate();
        }
    }

    private Bitmap frame;
    private ByteBuffer frameBuf;
    private long blitTotalNs, blitCount;
    private final Rect frameSrc = new Rect();
    private final Rect frameDst = new Rect();

    /**
     * Upload a raw RGBA8 frame. Timed: a full 1240x1080 frame is 5.4 MB, and
     * ADR 0001 only ever measured the LOVE-side readback.
     *
     * The Bitmap and its ByteBuffer are reused across frames. Reallocating 5.4
     * MB per frame would dominate the measurement and would be a real cost in
     * production too.
     */
    public void updateFrame(byte[] pixels, int w, int h) {
        if (pixels == null || w <= 0 || h <= 0) {
            return;
        }
        long t0 = SystemClock.elapsedRealtimeNanos();
        ensureBitmap(w, h);

        frameBuf.rewind();
        frameBuf.put(pixels, 0, Math.min(pixels.length, frameBuf.capacity()));
        frameBuf.rewind();
        frame.copyPixelsFromBuffer(frameBuf);

        countBlit(t0, w, h);
        invalidate();
    }

    /**
     * Shared-buffer frame: copy straight from the buffer the LOVE
     * thread filled, under its monitor -- dsbridge takes the same monitor
     * around its memcpy, which is what makes the handoff tear-free. One copy,
     * no allocation.
     */
    public void updateFrame(ByteBuffer buf, int w, int h) {
        if (buf == null || w <= 0 || h <= 0) {
            return;
        }
        long t0 = SystemClock.elapsedRealtimeNanos();
        ensureBitmap(w, h);

        synchronized (buf) {
            buf.rewind();
            frame.copyPixelsFromBuffer(buf);
        }

        countBlit(t0, w, h);
        invalidate();
    }

    private void ensureBitmap(int w, int h) {
        if (frame == null || frame.getWidth() != w || frame.getHeight() != h) {
            if (frame != null) {
                frame.recycle();
            }
            frame = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
            frameBuf = ByteBuffer.allocateDirect(w * h * 4);
            frameSrc.set(0, 0, w, h);
            Log.i(TAG, "frame buffer allocated " + w + "x" + h
                    + " (" + (w * h * 4 / 1024) + " KiB)");
        }
    }

    private void countBlit(long t0, int w, int h) {
        blitTotalNs += SystemClock.elapsedRealtimeNanos() - t0;
        blitCount++;
        // Every ~20 s at the push rate; the old every-30 cadence was the
        // loudest thing in logcat by far.
        if (blitCount % 600 == 0) {
            Log.i(TAG, String.format(
                    "java blit: n=%d mean=%.2f ms (%dx%d, %d KiB/frame)",
                    blitCount, (blitTotalNs / (double) blitCount) / 1e6,
                    w, h, w * h * 4 / 1024));
        }
    }

    /** Reset the running blit average between measurements. */
    public void resetBlitStats() {
        blitTotalNs = 0;
        blitCount = 0;
    }

    private void layoutCards(int w, int h) {
        cardRects.clear();
        int n = snapshot.cards.size();
        if (n <= 0) {
            return;
        }
        int usable = w - 2 * EDGE_INSET;
        int gap = 16;
        int cw = Math.min(180, (usable - (n - 1) * gap) / n);
        int ch = (int) (cw * 1.4f);
        int total = n * cw + (n - 1) * gap;
        int x0 = (w - total) / 2;
        int y0 = (h - ch) / 2;
        for (int i = 0; i < n; i++) {
            CompanionSnapshot.Card card = snapshot.cards.get(i);
            int lift = card.highlighted ? -40 : 0;
            int x = x0 + i * (cw + gap);
            cardRects.add(new Rect(x, y0 + lift, x + cw, y0 + lift + ch));
        }
    }

    public CompanionProbeView(Context context) {
        super(context);
        setBackgroundColor(Color.BLACK);

        title.setColor(0xFFE53935);
        title.setTextSize(52f);
        body.setColor(Color.WHITE);
        body.setTextSize(32f);
        dim.setColor(0xFF9E9E9E);
        dim.setTextSize(24f);
        frame_.setColor(0xFF1565C0);
        frame_.setStyle(Paint.Style.STROKE);
        frame_.setStrokeWidth(6f);
        cardFill.setColor(0xFF37474F);
        cardSel.setColor(0xFF1565C0);
        cardText.setColor(Color.WHITE);
        cardText.setTextSize(30f);
        btn.setTextSize(34f);
    }

    public void setStatus(String s) {
        status = s;
        invalidate();
    }

    public void updateSnapshot(CompanionSnapshot s) {
        if (s == null) {
            return;
        }
        snapshot = s;
        updates++;
        layoutCards(getWidth(), getHeight());
        invalidate();
    }

    @Override
    protected void onSizeChanged(int w, int h, int ow, int oh) {
        super.onSizeChanged(w, h, ow, oh);
        Log.i(TAG, "probe view size " + w + "x" + h);
        layoutButtons(w, h);
        layoutCards(w, h);
        invalidate();
    }

    private void layoutButtons(int w, int h) {
        int bw = (w - 2 * EDGE_INSET - 2 * 30) / 3;
        int bh = 150;
        int top = h - EDGE_INSET - bh;
        playRect.set(EDGE_INSET, top, EDGE_INSET + bw, top + bh);
        discardRect.set(playRect.right + 30, top, playRect.right + 30 + bw, top + bh);
        sortRect.set(discardRect.right + 30, top, discardRect.right + 30 + bw, top + bh);
    }

    // --- input ------------------------------------------------------------

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        // ACTION_CANCEL must revert, never commit. The FIRST touch
        // after the Presentation gains focus arrive as DOWN then CANCEL, dead
        // centre - not an edge effect. Treating DOWN as a committed selection
        // shows a card as selected when it is not, once per session.
        // While disabled the panel is inert: the hand is on screen 1, and the
        // way back is Options > Settings > Dual Screen, not a gesture here.
        if (hidden) {
            return true;
        }

        final int action = e.getActionMasked();

        if (action == MotionEvent.ACTION_CANCEL) {
            Log.i(TAG, "touch cancelled - reverting");
            if (dragging) {
                emit("DRAG_END::" + snapshot.generation);
            }
            emit("HOVER_END::" + snapshot.generation);
            dragging = false;
            dragCard = -1;
            return true;
        }

        if (action == MotionEvent.ACTION_DOWN) {
            downX = e.getX();
            downY = e.getY();
            dragging = false;
            dragCard = (frame != null) ? cardAt((int) downX, (int) downY) : -1;
            if (frame != null) {
                // Hold-to-inspect. Sent as a COORDINATE, not a hand index:
                // Lua resolves it against the screen-2 hash, so shop and
                // booster-pack cards get their tooltips too. dragCard is still
                // resolved above, but only to seed a drag.
                emit("HOVER_AT:" + (int) downX + "|" + (int) downY
                        + ":" + snapshot.generation);
            }
            return true;
        }

        if (action == MotionEvent.ACTION_MOVE) {
            if (dragCard < 0) {
                return true;
            }
            if (!dragging
                    && Math.hypot(e.getX() - downX, e.getY() - downY) < DRAG_SLOP) {
                return true;   // inside the slop: this may still be a tap
            }
            dragging = true;
            // Deliberately NOT generation-checked. A drag is one continuous
            // gesture against a card the player is looking at; dropping frames
            // on a generation bump mid-drag would make it stutter.
            // dragCard is only used to resolve the FIRST event of a drag; Lua
            // then holds the card object, because align_cards re-sorts the hand
            // by x position mid-drag and every index shifts under us.
            emit("DRAG_CARD:" + dragCard + "|" + (int) e.getX() + "|" + (int) e.getY()
                    + ":" + snapshot.generation);
            return true;
        }

        if (action != MotionEvent.ACTION_UP) {
            return true;
        }

        if (dragging) {
            emit("DRAG_END::" + snapshot.generation);
            emit("HOVER_END::" + snapshot.generation);
            dragging = false;
            dragCard = -1;
            return true;
        }
        emit("HOVER_END::" + snapshot.generation);
        dragCard = -1;

        int x = (int) e.getX();
        int y = (int) e.getY();
        long gen = snapshot.generation;

        // Report WHERE, not WHAT.
        //
        // This used to hit-test four hardcoded rects (play / discard /
        // sort_rank / sort_suit) shipped in the snapshot, then fall back to a
        // card index, with a comment explaining that buttons had to be checked
        // first so an overlap could not cost the player a hand. All of that
        // was Java re-deriving something LOVE already knows.
        //
        // Now a tap is just a coordinate. Lua resolves it against DS.HASH2 --
        // the same backwards collision walk Controller runs on screen 1 -- and
        // calls the hit node's own click(). Z-order falls out of the walk, so
        // the overlap problem disappears rather than being worked around, and
        // any UI later drawn on screen 2 becomes clickable with no change here.
        //
        // Card indices are still used for DRAG (above), because a drag has to
        // follow one specific card across frames while align_cards re-sorts
        // the hand underneath it.
        if (frame != null) {
            emit("CLICK:" + x + "|" + y + ":" + gen);
            return true;
        }

        // No frame yet means nothing is on screen to hit. The old placeholder
        // layout that used to be tappable here is gone with the debug view.
        return true;
    }

    /** Topmost card under a point, or -1. Later cards overlap earlier ones. */
    private int cardAt(int x, int y) {
        for (int i = snapshot.cards.size() - 1; i >= 0; i--) {
            CompanionSnapshot.Card c = snapshot.cards.get(i);
            if (c.w > 0 && c.h > 0
                    && x >= c.x && x < c.x + c.w
                    && y >= c.y && y < c.y + c.h) {
                return i;
            }
        }
        return -1;
    }

    private void emit(String event) {
        lastEvent = event;
        Log.i(TAG, "event -> " + event);
        BalatroActivity.postEvent(event);
        invalidate();
    }

    // --- drawing ----------------------------------------------------------

    @Override
    protected void onDraw(Canvas c) {
        int w = getWidth(), h = getHeight();
        c.drawColor(Color.BLACK);

        // Once LOVE is pushing pixels they ARE the screen; the debug
        // furniture would only obscure them.
        if (hidden) {
            return;   // black; the hand is on screen 1
        }

        if (frame != null && !frame.isRecycled()) {
            frameDst.set(0, 0, w, h);
            c.drawBitmap(frame, frameSrc, frameDst, null);
            // No optimistic outline. The round trip measures 3-7 ms and the
            // local feedback was insurance rather than necessity; LOVE renders
            // the game's own selection lift on screen 2, so
            // drawing our own indicator on top is just noise. The pending
            // fields are kept because they still measure the round trip.
            return;
        }

        // Before LOVE's first frame arrives -- app launch, or the moments after
        // the Presentation is recreated by a lifecycle event -- the panel stays
        // black. The debug furniture that used to live here showed the
        // "Balatro dual-screen bridge" placeholder for the first few seconds of
        // every boot, which read as a glitch rather than as loading.
    }
}
