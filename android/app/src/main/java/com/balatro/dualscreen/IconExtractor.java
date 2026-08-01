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

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Pulls the game's icon out of the user's own Balatro container, for the
 * HOME-SCREEN SHORTCUT offered after assembly.
 *
 * Android accepts a runtime bitmap for a pinned shortcut -- the one icon
 * mechanism that does. The APK's own launcher icon stays this project's
 * original mark: an installed icon must be a packaged resource, and packaging
 * LocalThunk's artwork would be distributing it (rule #1). Whatever is
 * extracted here stays in the app's private files, exactly like the assembled
 * game.
 *
 * Both containers carry an icon:
 *
 *   zipped .app   Contents/Resources/GameIcon.icns, whose modern entries are
 *                 raw PNG. The largest is 1024 px of the real artwork.
 *
 *   Balatro.exe   PE resources. THE LARGEST ICON IS THE WRONG ONE: the exe
 *                 carries two RT_GROUP_ICONs -- group 1 is love.exe's stock
 *                 pink/blue heart at up to 256 px, and a later group (736 in
 *                 the Steam 1.0.1o build) holds Balatro's own icon at up to
 *                 32 px. Taking "the biggest" ships the LOVE heart. Groups
 *                 added after the engine's own belong to the game packager,
 *                 so the HIGHEST-numbered group wins.
 *
 * 32 px is small for a launcher icon, but Balatro's icon is pixel art, so the
 * shortcut upscales it with nearest-neighbour and it stays crisp.
 */
final class IconExtractor {
    private static final String TAG = "BalatroDS";
    private static final String ICON_FILE = "balatro-icon.png";

    private IconExtractor() {
    }

    /** The previously extracted icon, or null. */
    static File extracted(Context ctx) {
        File f = new File(ctx.getFilesDir(), ICON_FILE);
        return f.exists() && f.length() > 0 ? f : null;
    }

    /** Best-effort extraction; quietly does nothing when there is no icon. */
    static void tryExtract(Context ctx, File container) {
        try {
            Bitmap bmp = null;

            byte[] head = new byte[2];
            try (FileInputStream in = new FileInputStream(container)) {
                if (in.read(head) < 2) {
                    return;
                }
            }

            if (head[0] == 'P' && head[1] == 'K') {
                byte[] icns = readIcns(container);
                if (icns != null) {
                    byte[] png = largestPng(icns);
                    if (png != null) {
                        bmp = BitmapFactory.decodeByteArray(png, 0, png.length);
                    }
                }
            } else if (head[0] == 'M' && head[1] == 'Z') {
                bmp = iconFromExe(container);
            }

            if (bmp == null) {
                return;
            }
            File out = new File(ctx.getFilesDir(), ICON_FILE);
            try (FileOutputStream os = new FileOutputStream(out)) {
                bmp.compress(Bitmap.CompressFormat.PNG, 100, os);
            }
            Log.i(TAG, "icon: extracted " + bmp.getWidth() + "x"
                    + bmp.getHeight() + " from the container");
        } catch (Exception e) {
            Log.w(TAG, "icon: extraction failed (shortcut uses the app icon)", e);
        }
    }

    // ------------------------------------------------------------------
    // macOS .app -> icns
    // ------------------------------------------------------------------

    private static byte[] readIcns(File zip) throws IOException {
        try (ZipInputStream in = new ZipInputStream(
                new BufferedInputStream(new FileInputStream(zip)))) {
            for (ZipEntry e; (e = in.getNextEntry()) != null; ) {
                if (e.getName().endsWith("Contents/Resources/GameIcon.icns")) {
                    ByteArrayOutputStream bos = new ByteArrayOutputStream();
                    byte[] buf = new byte[64 * 1024];
                    for (int n; (n = in.read(buf)) > 0; ) {
                        bos.write(buf, 0, n);
                    }
                    return bos.toByteArray();
                }
            }
        }
        return null;
    }

    /** icns = 8-byte header, then (4cc type, u32 big-endian length) chunks. */
    private static byte[] largestPng(byte[] icns) {
        byte[] best = null;
        int i = 8;
        while (i + 8 <= icns.length) {
            long len = ((icns[i + 4] & 0xFFL) << 24) | ((icns[i + 5] & 0xFFL) << 16)
                    | ((icns[i + 6] & 0xFFL) << 8) | (icns[i + 7] & 0xFFL);
            if (len < 8 || i + len > icns.length) {
                break;
            }
            int off = i + 8;
            int n = (int) (len - 8);
            if (n > 8 && (icns[off] & 0xFF) == 0x89 && icns[off + 1] == 'P'
                    && icns[off + 2] == 'N' && icns[off + 3] == 'G'
                    && (best == null || n > best.length)) {
                best = new byte[n];
                System.arraycopy(icns, off, best, 0, n);
            }
            i += len;
        }
        return best;
    }

    // ------------------------------------------------------------------
    // Windows .exe -> PE resources
    // ------------------------------------------------------------------

    private static byte[] pe;
    private static int[][] peSections;   // {virtualAddress, size, rawPointer}

    private static Bitmap iconFromExe(File exe) throws IOException {
        pe = readFile(exe);
        try {
            int peOff = i32(0x3C);
            if (pe[peOff] != 'P' || pe[peOff + 1] != 'E') {
                return null;
            }
            int nSections = u16(peOff + 6);
            int optSize = u16(peOff + 20);
            int opt = peOff + 24;
            int ddOff = opt + (u16(opt) == 0x10B ? 0x60 : 0x70);
            int rsrcRva = i32(ddOff + 16);
            if (rsrcRva == 0) {
                return null;
            }

            peSections = new int[nSections][3];
            int secOff = opt + optSize;
            for (int i = 0; i < nSections; i++) {
                int o = secOff + 40 * i;
                peSections[i][0] = i32(o + 12);                     // vaddr
                peSections[i][1] = Math.max(i32(o + 8), i32(o + 16));
                peSections[i][2] = i32(o + 20);                     // raw ptr
            }

            int rsrc = rvaToOff(rsrcRva);
            if (rsrc < 0) {
                return null;
            }

            // Winner: the highest-numbered RT_GROUP_ICON's largest entry.
            int bestGroupId = -1;
            int wantIconId = -1;
            int wantSize = -1;
            for (int[] type : dirEntries(rsrc, rsrc)) {
                if (type[0] != 14 || (type[1] & 0x80000000) == 0) {   // RT_GROUP_ICON
                    continue;
                }
                for (int[] name : dirEntries(rsrc + (type[1] & 0x7FFFFFFF), rsrc)) {
                    int groupId = name[0] & 0x7FFFFFFF;
                    int[][] leaves = (name[1] & 0x80000000) != 0
                            ? dirEntries(rsrc + (name[1] & 0x7FFFFFFF), rsrc)
                            : new int[][]{{name[0], name[1]}};
                    for (int[] leaf : leaves) {
                        if ((leaf[1] & 0x80000000) != 0) {
                            continue;
                        }
                        int dataOff = rvaToOff(i32(rsrc + leaf[1]));
                        if (dataOff < 0) {
                            continue;
                        }
                        int count = u16(dataOff + 4);
                        for (int i = 0; i < count; i++) {
                            int e = dataOff + 6 + 14 * i;
                            int w = (pe[e] & 0xFF) == 0 ? 256 : (pe[e] & 0xFF);
                            int id = u16(e + 12);
                            if (groupId > bestGroupId
                                    || (groupId == bestGroupId && w > wantSize)) {
                                if (groupId > bestGroupId) {
                                    wantSize = -1;
                                }
                                if (w > wantSize) {
                                    bestGroupId = groupId;
                                    wantIconId = id;
                                    wantSize = w;
                                }
                            }
                        }
                    }
                }
            }
            if (wantIconId < 0) {
                return null;
            }
            Log.i(TAG, "icon: exe group " + bestGroupId + ", icon id "
                    + wantIconId + " (" + wantSize + "px)");

            // Fetch that RT_ICON.
            for (int[] type : dirEntries(rsrc, rsrc)) {
                if (type[0] != 3 || (type[1] & 0x80000000) == 0) {   // RT_ICON
                    continue;
                }
                for (int[] name : dirEntries(rsrc + (type[1] & 0x7FFFFFFF), rsrc)) {
                    if ((name[0] & 0x7FFFFFFF) != wantIconId) {
                        continue;
                    }
                    int[][] leaves = (name[1] & 0x80000000) != 0
                            ? dirEntries(rsrc + (name[1] & 0x7FFFFFFF), rsrc)
                            : new int[][]{{name[0], name[1]}};
                    for (int[] leaf : leaves) {
                        if ((leaf[1] & 0x80000000) != 0) {
                            continue;
                        }
                        int off = rvaToOff(i32(rsrc + leaf[1]));
                        int size = i32(rsrc + leaf[1] + 4);
                        if (off < 0) {
                            continue;
                        }
                        if ((pe[off] & 0xFF) == 0x89 && pe[off + 1] == 'P') {
                            return BitmapFactory.decodeByteArray(pe, off, size);
                        }
                        return bitmapFromDib(off);
                    }
                }
            }
            return null;
        } finally {
            pe = null;
            peSections = null;
        }
    }

    /** 32-bpp icon DIB: 40-byte header, doubled height, bottom-up BGRA. */
    private static Bitmap bitmapFromDib(int off) {
        int hdr = i32(off);
        int w = i32(off + 4);
        int h2 = i32(off + 8);
        int bpp = u16(off + 14);
        if (hdr != 40 || bpp != 32 || w <= 0 || h2 <= 0) {
            Log.w(TAG, "icon: unsupported DIB (" + bpp + "bpp)");
            return null;
        }
        int h = h2 / 2;
        int[] px = new int[w * h];
        int stride = w * 4;
        for (int y = 0; y < h; y++) {
            int src = off + 40 + (h - 1 - y) * stride;   // bottom-up
            int dst = y * w;
            for (int x = 0; x < w; x++) {
                int b = pe[src] & 0xFF, g = pe[src + 1] & 0xFF;
                int r = pe[src + 2] & 0xFF, a = pe[src + 3] & 0xFF;
                px[dst + x] = (a << 24) | (r << 16) | (g << 8) | b;
                src += 4;
            }
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888);
    }

    private static int[][] dirEntries(int dir, int rsrc) {
        int named = u16(dir + 12);
        int ids = u16(dir + 14);
        int[][] out = new int[named + ids][2];
        for (int i = 0; i < named + ids; i++) {
            out[i][0] = i32(dir + 16 + 8 * i);
            out[i][1] = i32(dir + 16 + 8 * i + 4);
        }
        return out;
    }

    private static int rvaToOff(int rva) {
        for (int[] s : peSections) {
            if (rva >= s[0] && rva < s[0] + s[1]) {
                return s[2] + (rva - s[0]);
            }
        }
        return -1;
    }

    private static int u16(int off) {
        return (pe[off] & 0xFF) | ((pe[off + 1] & 0xFF) << 8);
    }

    private static int i32(int off) {
        return (pe[off] & 0xFF) | ((pe[off + 1] & 0xFF) << 8)
                | ((pe[off + 2] & 0xFF) << 16) | ((pe[off + 3] & 0xFF) << 24);
    }

    private static byte[] readFile(File f) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream((int) f.length());
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[256 * 1024];
            for (int n; (n = in.read(buf)) > 0; ) {
                bos.write(buf, 0, n);
            }
        }
        return bos.toByteArray();
    }
}
