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

import java.util.ArrayList;
import java.util.List;

/**
 * The snapshot schema, and its parser.
 *
 * Wire format is deliberately primitive - semicolon-separated key=value pairs,
 * with the card array as a pipe-separated list of comma-separated tuples:
 *
 *   v=1;gen=42;mode=RUN;hands=3;discards=4;canPlay=1;canDiscard=0;
 *   cards=A,S,none,none,none,1,10,20,90,120|K,H,mult,foil,gold,0,110,20,90,120
 *
 * No JSON, because Balatro ships its own JSON handling and this project may not
 * touch game code, and pulling a Lua JSON library in to serialise ten fields
 * would be a poor trade. This format is three lines of Lua to write and one
 * split loop to read.
 *
 * TWO RULES, both taken from BanjoRecomp's own scar tissue
 * (their docs/android-dualscreen-framework-api.md):
 *
 *  1. displayMode MUST participate in dedupe comparisons. Otherwise a
 *     mode-only change gets dropped whenever the payload values happen not to
 *     differ - you switch from a run to the shop and screen 2 keeps showing a
 *     stale hand.
 *  2. Route EVERY snapshot through one update path regardless of mode, so that
 *     mode-specific handling cannot diverge.
 */
public class CompanionSnapshot {

    public static final int SCHEMA_VERSION = 1;

    public static class Card {
        public String rank = "?";
        public String suit = "?";
        public String enhancement = "none";
        public String edition = "none";
        public String seal = "none";
        public boolean highlighted;
        // Rect in screen-2 pixel space. Route (b) still needs these for hit
        // testing even though the pixels themselves come from LOVE.
        public int x, y, w, h;
    }

    public int schemaVersion = SCHEMA_VERSION;
    public long generation;
    public String displayMode = "BLACK";
    public int handsLeft;
    public int discardsLeft;
    public boolean canPlay;
    public boolean canDiscard;
    public final List<Card> cards = new ArrayList<>();

    /** The raw wire string, kept for the probe view's debug text. */
    public String raw = "";

    private static int toInt(String s, int fallback) {
        try {
            return Integer.parseInt(s.trim());
        } catch (RuntimeException e) {
            return fallback;
        }
    }

    private static long toLong(String s, long fallback) {
        try {
            return Long.parseLong(s.trim());
        } catch (RuntimeException e) {
            return fallback;
        }
    }

    /** Never throws. A malformed snapshot yields a best-effort object. */
    public static CompanionSnapshot parse(String wire) {
        CompanionSnapshot s = new CompanionSnapshot();
        s.raw = wire == null ? "" : wire;
        if (wire == null || wire.isEmpty()) {
            return s;
        }

        for (String field : wire.split(";")) {
            int eq = field.indexOf('=');
            if (eq <= 0) {
                continue;
            }
            String k = field.substring(0, eq).trim();
            String v = field.substring(eq + 1);

            switch (k) {
                case "v":         s.schemaVersion = toInt(v, SCHEMA_VERSION); break;
                case "gen":       s.generation    = toLong(v, 0); break;
                case "mode":      s.displayMode   = v.trim(); break;
                case "hands":     s.handsLeft     = toInt(v, 0); break;
                case "discards":  s.discardsLeft  = toInt(v, 0); break;
                case "canPlay":   s.canPlay       = "1".equals(v.trim()); break;
                case "canDiscard":s.canDiscard    = "1".equals(v.trim()); break;
                case "cards":     parseCards(s, v); break;
                default: break;   // forward compatibility: ignore unknown keys
            }
        }
        return s;
    }

    private static void parseCards(CompanionSnapshot s, String v) {
        if (v == null || v.trim().isEmpty()) {
            return;
        }
        for (String entry : v.split("\\|")) {
            if (entry.trim().isEmpty()) {
                continue;
            }
            String[] f = entry.split(",");
            Card c = new Card();
            if (f.length > 0) c.rank = f[0];
            if (f.length > 1) c.suit = f[1];
            if (f.length > 2) c.enhancement = f[2];
            if (f.length > 3) c.edition = f[3];
            if (f.length > 4) c.seal = f[4];
            if (f.length > 5) c.highlighted = "1".equals(f[5].trim());
            if (f.length > 6) c.x = toInt(f[6], 0);
            if (f.length > 7) c.y = toInt(f[7], 0);
            if (f.length > 8) c.w = toInt(f[8], 0);
            if (f.length > 9) c.h = toInt(f[9], 0);
            s.cards.add(c);
        }
    }

    /**
     * Dedupe key. displayMode is included deliberately - see rule 1 above.
     * generation is NOT, because it changes on every hand mutation and would
     * make the comparison useless.
     */
    public String dedupeKey() {
        StringBuilder sb = new StringBuilder(128);
        sb.append(displayMode).append('/')
          .append(handsLeft).append('/')
          .append(discardsLeft).append('/')
          .append(canPlay ? 1 : 0).append('/')
          .append(canDiscard ? 1 : 0).append('/')
          .append(cards.size());
        for (Card c : cards) {
            sb.append('/').append(c.rank).append(c.suit)
              .append(c.enhancement).append(c.edition).append(c.seal)
              .append(c.highlighted ? '*' : '.');
        }
        return sb.toString();
    }

    public int highlightedCount() {
        int n = 0;
        for (Card c : cards) {
            if (c.highlighted) n++;
        }
        return n;
    }
}
