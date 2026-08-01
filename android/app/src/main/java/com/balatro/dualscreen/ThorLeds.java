/*
 * balatro-dualscreen-thor
 * Copyright (C) 2026  balatro-dualscreen-thor contributors
 *
 * Technique from the ThorLedsDemo reference (itself derived from Bifrost's
 * LedController): the stick LEDs are root-owned
 * sysfs nodes, written by asking the vendor's PServerBinder service to run an
 * echo for us. Transaction code 0, payload [command, "1"], FLAG_ONEWAY.
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

import android.os.IBinder;
import android.os.Parcel;
import android.util.Log;

/**
 * Drives the joystick RGB LEDs on devices that expose them.
 *
 * DETECTION IS CAPABILITY-BASED, deliberately: availability means the vendor
 * service exists, full stop. No build-prop or model-string checks -- that is
 * the same rule this project applies to display discovery, and the service
 * lookup is also simply the more truthful test (the reference doc's own words:
 * isAvailable is authoritative, the model guess is not). On any other device
 * the service is absent and every call is a silent no-op.
 *
 * Constraints inherited from the reference:
 *  - The nodes are write-only; current LED state cannot be read back, so the
 *    previous colour/brightness cannot be saved or restored.
 *  - The brightness byte on the wire is left at 255 and RGB is sent
 *    unscaled -- the pre-multiplied path is the one proven at animation rates.
 *  - FLAG_ONEWAY means no error feedback; a rejected write looks identical to
 *    a successful one.
 *  - Each write is an IPC plus a root shell command: batch both sticks into
 *    one command, dedupe identical repeats.
 */
final class ThorLeds {
    private static final String TAG = "BalatroDS";
    private static final String NODE_LEFT = "/sys/class/sn3112l/led/brightness";
    private static final String NODE_RIGHT = "/sys/class/sn3112r/led/brightness";
    private static final long DEDUPE_WINDOW_MS = 16L;

    private final IBinder binder;
    private final Object lock = new Object();
    private String lastCommand = null;
    private long lastWriteAt = 0L;

    ThorLeds() {
        IBinder b = null;
        try {
            Class<?> sm = Class.forName("android.os.ServiceManager");
            b = (IBinder) sm.getDeclaredMethod("getService", String.class)
                    .invoke(null, "PServerBinder");
        } catch (Exception e) {
            // Not this hardware, or a firmware that removed the service.
            // The feature quietly does not exist here.
        }
        binder = b;
        Log.i(TAG, "leds: service " + (binder != null ? "available" : "absent"));
    }

    boolean isAvailable() {
        return binder != null;
    }

    /** Both sticks, all four zones, one IPC. Values 0..255. */
    void setColor(int r, int g, int b) {
        if (binder == null) return;
        r = clamp(r); g = clamp(g); b = clamp(b);

        String rgb = r + ":" + g + ":" + b + ":255";
        String command =
                "echo 1-" + rgb + " > " + NODE_LEFT
                + " && echo 2-" + rgb + " > " + NODE_LEFT
                + " && echo 1-" + rgb + " > " + NODE_RIGHT
                + " && echo 2-" + rgb + " > " + NODE_RIGHT;

        synchronized (lock) {
            long now = System.currentTimeMillis();
            if (command.equals(lastCommand) && now - lastWriteAt < DEDUPE_WINDOW_MS) {
                return;
            }
            lastCommand = command;
            lastWriteAt = now;

            Parcel data = Parcel.obtain();
            Parcel reply = Parcel.obtain();
            try {
                data.writeStringArray(new String[] { command, "1" });
                binder.transact(0, data, reply, IBinder.FLAG_ONEWAY);
            } catch (Exception e) {
                Log.w(TAG, "leds: write failed", e);
            } finally {
                data.recycle();
                reply.recycle();
            }
        }
    }

    private static int clamp(int v) {
        return v < 0 ? 0 : (v > 255 ? 255 : v);
    }
}
