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

package com.balatro.dualscreen.companion;

import android.util.Log;

import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Semantic events from screen 2 back to Lua.
 *
 * Crosses a real thread boundary: events are produced on the Android UI thread
 * (a touch on the Presentation) and consumed on the LOVE/SDL thread (Lua's
 * love.update). ConcurrentLinkedQueue rather than a lock, because the producer
 * must never block the UI thread and the consumer must never block the frame.
 *
 * Wire format, one event per line:  NAME:arg1:arg2:generation
 *
 * THE GENERATION COUNTER IS NOT OPTIONAL. Every snapshot carries a
 * monotonically increasing counter; every event echoes back the generation it
 * was decided against; Lua drops any event whose generation does not match the
 * current one. Without it, a tap that lands during a deal animation acts on
 * whichever card now occupies that index - rare wrong-card plays that are
 * miserable to reproduce, let alone diagnose.
 *
 * The queue is bounded. A wedged or backgrounded Lua side must not let touches
 * accumulate without limit; old events are dropped in preference to new ones
 * because a stale tap is worthless anyway.
 */
public class CompanionEventQueue {
    private static final String TAG = "BalatroDS";
    private static final int MAX_PENDING = 64;

    private final ConcurrentLinkedQueue<String> queue = new ConcurrentLinkedQueue<>();
    private final AtomicInteger size = new AtomicInteger();
    private final AtomicInteger dropped = new AtomicInteger();

    /** Called from the UI thread. */
    public void offer(String event) {
        if (event == null || event.isEmpty()) {
            return;
        }
        while (size.get() >= MAX_PENDING) {
            if (queue.poll() != null) {
                size.decrementAndGet();
                int d = dropped.incrementAndGet();
                if (d == 1 || d % 32 == 0) {
                    Log.w(TAG, "event queue full, dropped " + d + " stale event(s)");
                }
            } else {
                break;
            }
        }
        queue.offer(event);
        size.incrementAndGet();
    }

    /** Called from the LOVE/SDL thread. Returns null when empty. */
    public String poll() {
        String e = queue.poll();
        if (e != null) {
            size.decrementAndGet();
        }
        return e;
    }

    public int pending() {
        return size.get();
    }

    public int droppedCount() {
        return dropped.get();
    }

    public void clear() {
        while (queue.poll() != null) {
            size.decrementAndGet();
        }
    }
}
