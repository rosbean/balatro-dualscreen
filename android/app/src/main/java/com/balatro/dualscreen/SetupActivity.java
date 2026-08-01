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

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.ShortcutInfo;
import android.content.pm.ShortcutManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.Icon;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
/**
 * First-launch setup: the release APK contains no Balatro, and this screen is
 * where the user's own copy becomes the game.
 *
 * It is the LAUNCHER activity. When a game is already present -- assembled on
 * an earlier visit, or embedded in a developer build -- it forwards straight
 * to BalatroActivity and is never seen. Otherwise it walks the user through:
 * pick the file (Storage Access Framework, so any location the phone can
 * reach works), probe and display what was picked, then assemble.
 *
 * Deliberately a plain Activity with a programmatic layout: it must carry no
 * game assets (rule #1 -- so no Balatro styling either), and it runs BEFORE
 * the engine, in the same process the engine will later occupy.
 */
public class SetupActivity extends Activity {
    private static final String TAG = "BalatroDS";
    private static final int PICK_REQUEST = 41;

    private TextView status;
    private Button pickButton;
    private Button buildButton;
    private ProgressBar progress;

    private GameAssembler.Info info;

    // Pin-dialog handshake. requestPinShortcut opens the LAUNCHER'S OWN
    // confirmation activity, and starting the game immediately afterwards
    // covered it before the user could confirm, so no shortcut ever
    // appeared. The game now waits until that dialog
    // has come and gone: pinShown is set when we actually lose the
    // foreground to it, and onResume then continues.
    private boolean awaitingPin;
    private boolean pinShown;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // A game already on board means this screen has no job.
        if (GameAssembler.assembled(this) != null || hasEmbeddedGame()) {
            launchGame();
            return;
        }

        buildUi();
    }

    private boolean hasEmbeddedGame() {
        try {
            getAssets().open("game.love").close();
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    private void launchGame() {
        startActivity(new Intent(this, BalatroActivity.class));
        finish();
    }

    // ------------------------------------------------------------------
    // UI
    // ------------------------------------------------------------------

    private void buildUi() {
        int pad = (int) (16 * getResources().getDisplayMetrics().density);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(20, 32, 26));
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Balatro Dual Screen — first-time setup");
        title.setTextSize(22);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(Color.WHITE);
        root.addView(title);

        addBody(root,
                "This mod is a FREE release. If you have paid money for it, "
                + "demand a refund.");
        addBody(root,
                "This app contains no Balatro. To play, you must provide a "
                + "legally obtained copy of the game you already own: the "
                + "Steam Balatro.exe (Windows), a ZIP of Balatro.app (macOS), "
                + "or the Balatro.love archive.");
        addBody(root,
                "Supported version: Steam 1.0.1o (PROD_PC_Console) — the "
                + "version this mod is built and tested against. Other PC "
                + "versions may work but are untested. Console, mobile and "
                + "demo builds are not supported.");

        pickButton = new Button(this);
        pickButton.setText("Choose your Balatro file…");
        pickButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                i.addCategory(Intent.CATEGORY_OPENABLE);
                i.setType("*/*");
                startActivityForResult(i, PICK_REQUEST);
            }
        });
        root.addView(pickButton, buttonParams(pad));

        status = new TextView(this);
        status.setTypeface(Typeface.MONOSPACE);
        status.setTextSize(14);
        status.setTextColor(Color.rgb(200, 210, 205));
        status.setPadding(0, pad, 0, pad);
        status.setText("No file selected yet.");
        root.addView(status);

        buildButton = new Button(this);
        buildButton.setText("Start build");
        buildButton.setEnabled(false);
        buildButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                startBuild();
            }
        });
        root.addView(buildButton, buttonParams(pad));

        progress = new ProgressBar(this, null,
                android.R.attr.progressBarStyleHorizontal);
        progress.setMax(100);
        progress.setVisibility(View.GONE);
        root.addView(progress);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(root);
        setContentView(scroll);
    }

    private void addBody(LinearLayout root, String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(15);
        tv.setTextColor(Color.rgb(220, 226, 222));
        tv.setPadding(0, (int) (10 * getResources().getDisplayMetrics().density), 0, 0);
        root.addView(tv);
    }

    private LinearLayout.LayoutParams buttonParams(int pad) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = pad;
        return lp;
    }

    // ------------------------------------------------------------------
    // Pick -> copy -> probe
    // ------------------------------------------------------------------

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != PICK_REQUEST || result != RESULT_OK || data == null
                || data.getData() == null) {
            return;
        }
        final Uri uri = data.getData();
        status.setText("Reading the selected file…");
        pickButton.setEnabled(false);
        buildButton.setEnabled(false);

        new Thread(new Runnable() {
            @Override public void run() {
                probeInBackground(uri);
            }
        }, "balatro-probe").start();
    }

    private void probeInBackground(Uri uri) {
        String name = displayName(uri);
        GameAssembler.Info result = null;
        String failure = null;
        try {
            File cached = new File(getCacheDir(), "balatro-source.bin");
            try (InputStream in = getContentResolver().openInputStream(uri);
                 FileOutputStream out = new FileOutputStream(cached)) {
                byte[] buf = new byte[64 * 1024];
                for (int n; (n = in.read(buf)) > 0; ) {
                    out.write(buf, 0, n);
                }
            }
            result = GameAssembler.probe(this, cached);
            // Zipped .app containers also carry the game's icon; stash it for
            // the home-screen shortcut offer after the build. Best-effort.
            IconExtractor.tryExtract(this, cached);
        } catch (Exception e) {
            Log.w(TAG, "setup: copy/probe failed", e);
            failure = e.getMessage();
        }

        final GameAssembler.Info probed = result;
        final String error = failure;
        final String displayName = name;
        runOnUiThread(new Runnable() {
            @Override public void run() {
                pickButton.setEnabled(true);
                if (error != null || probed == null) {
                    status.setText("Could not read that file:\n  " + error);
                    return;
                }
                info = probed;
                showProbe(displayName, probed);
            }
        });
    }

    private void showProbe(String name, GameAssembler.Info p) {
        StringBuilder sb = new StringBuilder();
        sb.append("Selected: ").append(name).append('\n');
        if (p.problem != null) {
            sb.append("\n✗ ").append(p.problem);
            buildButton.setEnabled(false);
        } else {
            sb.append("Detected: ").append(p.kind).append('\n');
            sb.append("Version:  ").append(p.versionDisplay)
              .append(" (").append(p.versionNumber).append(", ")
              .append(p.versionBuild).append(")\n");
            sb.append("Files:    ").append(p.fileCount).append('\n');
            if (!"1.0.1o".equals(p.versionNumber)) {
                sb.append("\n⚠ This is not 1.0.1o. The build can go "
                        + "ahead, but this version is untested and things "
                        + "may be broken.\n");
            }
            sb.append("\n✓ This looks buildable.");
            buildButton.setEnabled(true);
        }
        status.setText(sb.toString());
    }

    /**
     * Offer a pinned home-screen shortcut, then start the game.
     *
     * The shortcut is the one place Android accepts a RUNTIME icon
     * (Icon.createWithBitmap and friends) -- so when the container was a
     * zipped .app, the shortcut can wear the game's own icon, extracted from
     * the user's copy and never leaving the device. The APK's launcher icon
     * itself stays this project's original artwork; a packaged resource
     * cannot be swapped at runtime, and packaging the real one would mean
     * distributing it.
     *
     * The extracted art is re-composed 14% inset over its own dark backing
     * before createWithAdaptiveBitmap: a full-bleed adaptive bitmap is
     * masked to its central ~2/3, the same over-zoom the APK icon pipeline
     * hit and solved the same way.
     */
    private void offerShortcutThenLaunch() {
        if (Build.VERSION.SDK_INT < 26) {
            launchGame();
            return;
        }
        final ShortcutManager sm =
                getSystemService(ShortcutManager.class);
        if (sm == null || !sm.isRequestPinShortcutSupported()) {
            launchGame();
            return;
        }

        new AlertDialog.Builder(this)
                .setTitle("Add to home screen?")
                .setMessage("Add a Balatro shortcut to your home screen?"
                        + (IconExtractor.extracted(this) != null
                           ? " It will use the game's own icon, taken from"
                             + " your copy."
                           : ""))
                .setPositiveButton("Add", new DialogInterface
                        .OnClickListener() {
                    @Override public void onClick(
                            DialogInterface d, int w) {
                        awaitingPin = true;
                        pinShown = false;
                        status.setText("Confirm the shortcut, then Balatro"
                                + " will start…");
                        requestPin(sm);
                        // A launcher that silently ignores the request would
                        // otherwise strand us here.
                        status.postDelayed(new Runnable() {
                            @Override public void run() {
                                if (awaitingPin) {
                                    awaitingPin = false;
                                    launchGame();
                                }
                            }
                        }, 20000);
                    }
                })
                .setNegativeButton("Not now", new DialogInterface
                        .OnClickListener() {
                    @Override public void onClick(
                            DialogInterface d, int w) {
                        launchGame();
                    }
                })
                .setCancelable(false)
                .show();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (awaitingPin) {
            pinShown = true;      // the launcher's dialog took the foreground
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (awaitingPin && pinShown) {
            awaitingPin = false;
            launchGame();
        }
    }

    private void requestPin(ShortcutManager sm) {
        try {
            Intent launch = new Intent(Intent.ACTION_MAIN);
            launch.setClass(this, BalatroActivity.class);

            ShortcutInfo.Builder b =
                    new ShortcutInfo.Builder(this, "balatro")
                            .setShortLabel("Balatro")
                            .setLongLabel("Balatro Dual Screen")
                            .setIntent(launch);

            File iconFile = IconExtractor.extracted(this);
            if (iconFile != null) {
                Bitmap art =
                        BitmapFactory.decodeFile(
                                iconFile.getAbsolutePath());
                if (art != null) {
                    int s = 432;
                    Bitmap composed =
                            Bitmap.createBitmap(s, s,
                                    Bitmap.Config.ARGB_8888);
                    Canvas c =
                            new Canvas(composed);
                    c.drawColor(0xFF120A08);   // dark backing, never visible
                    int inset = (int) (s * 0.14f);
                    Rect dst = new Rect(
                            inset, inset, s - inset, s - inset);
                    // NEAREST-NEIGHBOUR for small sources. The .exe's
                    // Balatro icon is 32 px pixel art (its bigger entries
                    // are LOVE's heart, see IconExtractor); smoothing that
                    // up to 432 px turns it to mush, while hard pixels read
                    // as intentional. The .app's 1024 px art is filtered
                    // normally on the way down.
                    boolean pixelArt = art.getWidth() <= 64;
                    Paint p = new Paint();
                    p.setFilterBitmap(!pixelArt);
                    p.setAntiAlias(!pixelArt);
                    c.drawBitmap(art, null, dst, p);
                    b.setIcon(Icon
                            .createWithAdaptiveBitmap(composed));
                }
            }
            sm.requestPinShortcut(b.build(), null);
        } catch (Exception e) {
            Log.w(TAG, "shortcut pin failed", e);
        }
    }

    private String displayName(Uri uri) {
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) {
                    return c.getString(idx);
                }
            }
        } catch (Exception ignored) {
        }
        return "(unnamed file)";
    }

    // ------------------------------------------------------------------
    // Build
    // ------------------------------------------------------------------

    private void startBuild() {
        if (info == null || !info.usable()) {
            return;
        }
        pickButton.setEnabled(false);
        buildButton.setEnabled(false);
        progress.setVisibility(View.VISIBLE);
        progress.setProgress(2);
        status.setText("Building…");

        new Thread(new Runnable() {
            @Override public void run() {
                try {
                    GameAssembler.assemble(SetupActivity.this, info,
                            new GameAssembler.Progress() {
                        @Override public void update(final String msg,
                                                     final int pct) {
                            runOnUiThread(new Runnable() {
                                @Override public void run() {
                                    status.setText(msg);
                                    progress.setProgress(pct);
                                }
                            });
                        }
                    });
                    runOnUiThread(new Runnable() {
                        @Override public void run() {
                            progress.setProgress(100);
                            status.setText("Done.");
                            offerShortcutThenLaunch();
                        }
                    });
                } catch (final Exception e) {
                    Log.w(TAG, "setup: build failed", e);
                    runOnUiThread(new Runnable() {
                        @Override public void run() {
                            progress.setVisibility(View.GONE);
                            pickButton.setEnabled(true);
                            buildButton.setEnabled(true);
                            status.setText("Build failed:\n  " + e.getMessage()
                                    + "\n\nNothing was left half-built; try again.");
                        }
                    });
                }
            }
        }, "balatro-assemble").start();
    }
}
