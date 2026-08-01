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
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

/**
 * Turns the user's own Balatro into this mod's game.love, ON DEVICE.
 *
 * This is tools/build.py's extract -> inject -> package pipeline, re-expressed
 * in Java for the release APK -- which ships NO Balatro data whatsoever
 * (that is rule #1, and what makes the APK publishable). The user supplies a
 * legally obtained copy at first launch; the game is assembled into
 * getFilesDir()/balatro-game.love, and BalatroActivity boots the engine from
 * there ever after.
 *
 * Accepted containers, mirroring tools/check_balatro_source.py:
 *
 *   Balatro.exe          the Steam Windows binary: a PE with the game zip
 *                        FUSED after it. The zip's own offsets are relative
 *                        to the zip start, so the PE length is discovered
 *                        from the end-of-central-directory record and
 *                        streamed past.
 *   Balatro.app (as zip) macOS users must zip the .app to move it to a
 *                        phone; the game is the nested
 *                        Contents/Resources/Balatro.love inside it.
 *   Balatro.love / zip   the game archive directly (main.lua at the root).
 *
 * Identity comes from version.jkr -- three lines: display name, version
 * number, build id -- exactly the file the desktop checker trusts.
 *
 * The injection is byte-for-byte the one build.py performs: a single line,
 *     require "dualscreen.init"
 * appended to main.lua, plus the overlay files, which the release APK
 * carries in its assets under dualscreen/ (they are this project's own
 * GPL code, not Balatro's).
 */
public final class GameAssembler {
    private static final String TAG = "BalatroDS";

    /** The one modification made to vanilla. Must match tools/build.py. */
    private static final String INJECT_LINE = "require \"dualscreen.init\"";

    public static final String ASSEMBLED_NAME = "balatro-game.love";

    /** What probing the user's file learned. */
    public static final class Info {
        public String kind;          // human-readable container kind
        public File gameZip;         // the zip holding the game files
        public long zipStart;        // offset of the zip inside that file
        public int fileCount;
        public boolean hasMain;
        public String versionDisplay;  // version.jkr line 1
        public String versionNumber;   // version.jkr line 2
        public String versionBuild;    // version.jkr line 3
        public String problem;         // set when the file is unusable

        public boolean usable() {
            return problem == null && hasMain && versionNumber != null;
        }
    }

    public interface Progress {
        void update(String message, int percent);
    }

    private GameAssembler() {
    }

    // ------------------------------------------------------------------
    // Probing
    // ------------------------------------------------------------------

    /** Identify and validate a candidate file already copied into cache. */
    public static Info probe(Context ctx, File source) {
        Info info = new Info();
        try {
            byte[] head = new byte[4];
            try (FileInputStream in = new FileInputStream(source)) {
                if (in.read(head) < 4) {
                    info.problem = "File is too small to be anything.";
                    return info;
                }
            }

            if (head[0] == 'M' && head[1] == 'Z') {
                info.kind = "Windows Balatro.exe (fused)";
                info.gameZip = source;
                info.zipStart = fusedZipStart(source);
                if (info.zipStart < 0) {
                    info.problem = "This exe has no game archive fused to it.";
                    return info;
                }
            } else if (head[0] == 'P' && head[1] == 'K') {
                // A zip: either the game archive itself, or a zipped .app
                // with Balatro.love nested inside.
                File nested = extractNestedLove(ctx, source);
                if (nested != null) {
                    info.kind = "macOS Balatro.app (zipped)";
                    info.gameZip = nested;
                    info.zipStart = 0;
                } else {
                    info.kind = "Balatro game archive";
                    info.gameZip = source;
                    info.zipStart = 0;
                }
            } else {
                info.problem = "Not a Balatro.exe, a zipped Balatro.app,"
                        + " or a Balatro.love.";
                return info;
            }

            scanGameZip(info);
        } catch (Exception e) {
            Log.w(TAG, "probe failed", e);
            info.problem = "Could not read this file: " + e.getMessage();
        }
        return info;
    }

    /**
     * Offset of the zip fused after the PE image, or -1.
     *
     * The end-of-central-directory record stores the central directory's
     * size and its offset AS THE ZIP KNEW IT; in a fused file the directory
     * actually sits later by exactly the length of the prepended exe. That
     * difference IS the zip start.
     */
    private static long fusedZipStart(File f) throws IOException {
        try (RandomAccessFile raf = new RandomAccessFile(f, "r")) {
            long len = raf.length();
            int tail = (int) Math.min(len, 22 + 65535);
            byte[] buf = new byte[tail];
            raf.seek(len - tail);
            raf.readFully(buf);
            for (int i = tail - 22; i >= 0; i--) {
                if (buf[i] == 0x50 && buf[i + 1] == 0x4B
                        && buf[i + 2] == 0x05 && buf[i + 3] == 0x06) {
                    long cdSize = u32(buf, i + 12);
                    long cdOffset = u32(buf, i + 16);
                    long eocdPos = len - tail + i;
                    long prepended = (eocdPos - cdSize) - cdOffset;
                    return prepended >= 0 ? prepended : -1;
                }
            }
        }
        return -1;
    }

    private static long u32(byte[] b, int off) {
        return (b[off] & 0xFFL) | ((b[off + 1] & 0xFFL) << 8)
                | ((b[off + 2] & 0xFFL) << 16) | ((b[off + 3] & 0xFFL) << 24);
    }

    /** Pull Contents/Resources/Balatro.love out of a zipped .app, or null. */
    private static File extractNestedLove(Context ctx, File zip)
            throws IOException {
        try (ZipInputStream in = new ZipInputStream(
                new BufferedInputStream(new FileInputStream(zip)))) {
            for (ZipEntry e; (e = in.getNextEntry()) != null; ) {
                if (e.getName().endsWith("Contents/Resources/Balatro.love")) {
                    File out = new File(ctx.getCacheDir(), "balatro-inner.love");
                    try (FileOutputStream os = new FileOutputStream(out)) {
                        pipe(in, os);
                    }
                    return out;
                }
            }
        }
        return null;
    }

    /** Count entries, find main.lua, read version.jkr. */
    private static void scanGameZip(Info info) throws IOException {
        try (ZipInputStream in = openGameZip(info)) {
            int count = 0;
            for (ZipEntry e; (e = in.getNextEntry()) != null; ) {
                if (e.isDirectory()) {
                    continue;
                }
                count++;
                String name = e.getName();
                if (name.equals("main.lua")) {
                    info.hasMain = true;
                } else if (name.equals("version.jkr")) {
                    String[] lines = new String(readAll(in),
                            StandardCharsets.UTF_8).trim().split("\\r?\\n");
                    if (lines.length > 0) info.versionDisplay = lines[0].trim();
                    if (lines.length > 1) info.versionNumber = lines[1].trim();
                    if (lines.length > 2) info.versionBuild = lines[2].trim();
                }
            }
            info.fileCount = count;
        }
        if (!info.hasMain) {
            info.problem = "No main.lua inside - this is not the game archive.";
        } else if (info.versionNumber == null) {
            info.problem = "No version.jkr inside - this does not look like Balatro.";
        }
    }

    private static ZipInputStream openGameZip(Info info) throws IOException {
        FileInputStream fs = new FileInputStream(info.gameZip);
        long skipped = 0;
        while (skipped < info.zipStart) {
            long s = fs.skip(info.zipStart - skipped);
            if (s <= 0) {
                fs.close();
                throw new IOException("could not seek to the fused zip");
            }
            skipped += s;
        }
        return new ZipInputStream(new BufferedInputStream(fs));
    }

    // ------------------------------------------------------------------
    // Assembly
    // ------------------------------------------------------------------

    /**
     * Build getFilesDir()/balatro-game.love from a probed source: every game
     * file re-packed, main.lua with the require line appended, the overlay
     * from the APK's assets added under dualscreen/. Written to a temp file
     * and renamed, so a killed build can never leave a half game behind.
     */
    public static File assemble(Context ctx, Info info, Progress progress)
            throws IOException {
        String[] overlay = ctx.getAssets().list("dualscreen");
        if (overlay == null || overlay.length == 0) {
            throw new IOException("this APK carries no dualscreen overlay in"
                    + " its assets; it is not a release build");
        }

        File dest = new File(ctx.getFilesDir(), ASSEMBLED_NAME);
        File tmp = new File(ctx.getFilesDir(), ASSEMBLED_NAME + ".tmp");
        int total = Math.max(info.fileCount, 1);
        int done = 0;
        boolean injected = false;

        try (ZipInputStream in = openGameZip(info);
             ZipOutputStream out = new ZipOutputStream(
                     new java.io.BufferedOutputStream(
                             new FileOutputStream(tmp)))) {

            for (ZipEntry e; (e = in.getNextEntry()) != null; ) {
                if (e.isDirectory()) {
                    continue;
                }
                out.putNextEntry(new ZipEntry(e.getName()));
                if (e.getName().equals("main.lua")) {
                    byte[] body = readAll(in);
                    out.write(body);
                    String tailText = new String(
                            body, Math.max(0, body.length - 1),
                            body.length > 0 ? Math.min(1, body.length) : 0,
                            StandardCharsets.UTF_8);
                    if (!tailText.equals("\n")) {
                        out.write('\n');
                    }
                    out.write(INJECT_LINE.getBytes(StandardCharsets.UTF_8));
                    out.write('\n');
                    injected = true;
                } else {
                    pipe(in, out);
                }
                out.closeEntry();

                done++;
                if (progress != null && done % 8 == 0) {
                    progress.update("Packing game files (" + done + "/"
                            + total + ")", 5 + (int) (85L * done / total));
                }
            }

            if (!injected) {
                throw new IOException("main.lua vanished between probe and build");
            }

            if (progress != null) {
                progress.update("Adding the dual-screen overlay", 92);
            }
            for (String name : overlay) {
                out.putNextEntry(new ZipEntry("dualscreen/" + name));
                try (InputStream as = ctx.getAssets().open("dualscreen/" + name)) {
                    pipe(as, out);
                }
                out.closeEntry();
            }
        } catch (IOException e) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
            throw e;
        }

        if (progress != null) {
            progress.update("Finishing", 98);
        }
        //noinspection ResultOfMethodCallIgnored
        dest.delete();
        if (!tmp.renameTo(dest)) {
            throw new IOException("could not move the finished game into place");
        }
        Log.i(TAG, "assembled " + dest + " (" + dest.length() + " bytes)");
        return dest;
    }

    /** The assembled game, or null if none has been built yet. */
    public static File assembled(Context ctx) {
        File f = new File(ctx.getFilesDir(), ASSEMBLED_NAME);
        return f.exists() && f.length() > 0 ? f : null;
    }

    // ------------------------------------------------------------------

    private static void pipe(InputStream in, OutputStream out)
            throws IOException {
        byte[] buf = new byte[64 * 1024];
        for (int n; (n = in.read(buf)) > 0; ) {
            out.write(buf, 0, n);
        }
    }

    private static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        pipe(in, bos);
        return bos.toByteArray();
    }
}
