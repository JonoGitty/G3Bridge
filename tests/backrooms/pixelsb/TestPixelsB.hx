// Runtime tests for the pixels-b unit (PixelFont, Hud, Cards) under haxe --interp.
// PixVec is shimmed (./flash/Vector.hx) with a bounds-checking buffer, Renderer by ./Renderer.hx.
//   sh tests/backrooms/pixelsb/run.sh
class TestPixelsB {
    static var fails = 0;
    static var passes = 0;

    static function check(name:String, ok:Bool):Void {
        if (ok) { passes++; Sys.println("pass: " + name); }
        else { fails++; Sys.println("FAIL: " + name); }
    }

    static function buf(n:Int, v:UInt):PixVec<UInt> {
        var b = new PixVec<UInt>(n, true);
        for (i in 0...n) b[i] = v;
        return b;
    }

    static function count(b:PixVec<UInt>, n:Int, col:UInt):Int {
        var c = 0;
        for (i in 0...n) if (b[i] == col) c++;
        return c;
    }

    static function countNot(b:PixVec<UInt>, n:Int, col:UInt):Int {
        var c = 0;
        for (i in 0...n) if (b[i] != col) c++;
        return c;
    }

    // horizontal extent [minX, maxX] of pixels equal to col
    static function extentX(b:PixVec<UInt>, w:Int, h:Int, col:UInt):Array<Int> {
        var mn = w, mx = -1;
        for (y in 0...h) for (x in 0...w) if (b[y * w + x] == col) { if (x < mn) mn = x; if (x > mx) mx = x; }
        return [mn, mx];
    }

    static function main():Void {
        testFont();
        testHud();
        testCards();
        Sys.println("TestPixelsB: " + passes + " pass, " + fails + " fail");
        if (fails > 0) Sys.exit(1);
    }

    // ------------------------------------------------------------ PixelFont
    static function testFont():Void {
        check("width(REC,1) == 18", PixelFont.width("REC", 1) == 18);
        check("width(REC,3) == 54", PixelFont.width("REC", 3) == 54);
        // glyph data for '0'..'9' and 'A'..'Z': 7 rows of 5 bits, non-empty
        var ok = true;
        for (c in 48...58) { var any = false; for (r in 0...7) { var m = PixelFont.rowMask(c, r); if (m < 0 || m > 31) ok = false; if (m != 0) any = true; } if (!any) ok = false; }
        for (c in 65...91) { var any = false; for (r in 0...7) { var m = PixelFont.rowMask(c, r); if (m < 0 || m > 31) ok = false; if (m != 0) any = true; } if (!any) ok = false; }
        check("digits and A-Z are 7 rows of 5 bits, non-empty", ok);
        check("space is empty", PixelFont.rowMask(32, 0) == 0 && PixelFont.rowMask(32, 6) == 0);
        check("unknown draws the box", PixelFont.rowMask(200, 0) == 31 && PixelFont.rowMask(200, 3) == 17);
        check("REC dot glyph exists", PixelFont.rowMask(PixelFont.CODE_REC, 3) == 31);
        // clipping: hanging off every edge, no throw, only in-bounds writes (the shim throws on OOB)
        var w = 32, h = 16, n = w * h;
        var b = buf(n, 0);
        var threw = false;
        try {
            PixelFont.blit(b, w, h, -3, 2, "AB", 0xFFFFFFFF, 1);
            PixelFont.blit(b, w, h, w - 2, 2, "AB", 0xFFFFFFFF, 1);
            PixelFont.blit(b, w, h, 4, -4, "AB", 0xFFFFFFFF, 1);
            PixelFont.blit(b, w, h, 4, h - 3, "AB", 0xFFFFFFFF, 1);
            PixelFont.blit(b, w, h, -7, -7, "XYZ", 0xFFFFFFFF, 3);
            PixelFont.blit(b, w, h, w - 4, h - 4, "XYZ", 0xFFFFFFFF, 3);
            PixelFont.blitJitter(b, w, h, -3, -3, "JIT", 0xFFFFFFFF, 2, 99);
            PixelFont.blitJitter(b, w, h, w - 1, h - 1, "JIT", 0xFFFFFFFF, 1, 7);
            PixelFont.blitDither(b, w, h, -3, h - 3, "DIT", 0xFFFFFFFF, 2, 8);
            PixelFont.blitChar(b, w, h, w - 1, 0, 65, 0xFFFFFFFF, 1);
            PixelFont.blitCharJitter(b, w, h, -1, h - 1, 65, 0xFFFFFFFF, 2, 5, 0);
            PixelFont.blit(b, w, h, 100, 100, "FAR", 0xFFFFFFFF, 1);
        } catch (e:Dynamic) { threw = true; Sys.println("  threw: " + e); }
        check("edge blits never write out of bounds", !threw);
        check("edge blits still write in-bounds pixels", count(b, n, 0xFFFFFFFF) > 0);
        // exact shape: 'I' at (0,0) scale 1 on a 5x7 buffer
        var g = buf(35, 0);
        PixelFont.blit(g, 5, 7, 0, 0, "I", 1, 1);
        check("'I' top row is ### centred", g[0] == 0 && g[1] == 1 && g[2] == 1 && g[3] == 1 && g[4] == 0);
        check("'I' mid row is the stem", g[3 * 5 + 2] == 1 && g[3 * 5 + 1] == 0);
        // scale 2 doubles every block
        var g2 = buf(10 * 14, 0);
        PixelFont.blit(g2, 10, 14, 0, 0, "I", 1, 2);
        check("scale 2 blocks are 2x2", g2[2] == 1 && g2[3] == 1 && g2[10 + 2] == 1 && g2[10 + 3] == 1 && g2[0] == 0);
        // dither level 16 = solid, 0 = nothing
        var d0 = buf(35, 0); PixelFont.blitDither(d0, 5, 7, 0, 0, "I", 1, 1, 0);
        var d16 = buf(35, 0); PixelFont.blitDither(d16, 5, 7, 0, 0, "I", 1, 1, 16);
        var d8 = buf(35, 0); PixelFont.blitDither(d8, 5, 7, 0, 0, "I", 1, 1, 8);
        check("dither 0 writes nothing, 16 solid, 8 between", count(d0, 35, 1) == 0 && count(d16, 35, 1) == 11 && count(d8, 35, 1) > 0 && count(d8, 35, 1) < 11);
        // jitter is a pure function of (seed, i): same seed twice -> identical pixels
        var j1 = buf(n, 0); PixelFont.blitJitter(j1, w, h, 2, 2, "ABC", 1, 1, 1234);
        var j2 = buf(n, 0); PixelFont.blitJitter(j2, w, h, 2, 2, "ABC", 1, 1, 1234);
        var same = true; for (i in 0...n) if (j1[i] != j2[i]) same = false;
        check("jitter is deterministic per seed", same);
    }

    // ------------------------------------------------------------ Hud
    static function testHud():Void {
        var hud = new Hud();
        var t = Tape.make(17, 1);
        t.dateStr = "03.11.1996";
        t.dateSeconds = 10 * 3600.0;
        t.hudSkin = 0;
        hud.setTape(t);
        check("timestamp at start", hud.timestamp() == "03.11.1996 10:00:00");
        for (i in 0...60) hud.tick(1.0, i + 1.0, 0);
        check("tick(1.0) x60 advances 60 s", hud.clockSeconds() == 10 * 3600 + 60 && hud.timestamp() == "03.11.1996 10:01:00");
        hud.tick(0.0, 60.0, 5);
        check("tsSkip = 5 advances 5 s at once", hud.timestamp() == "03.11.1996 10:01:05");
        // sub-second ticks accumulate: 20 x 0.05 = 1 s
        for (i in 0...20) hud.tick(0.05, 0, 0);
        check("20 x 0.05 s ticks = 1 s", hud.clockSeconds() == 10 * 3600 + 66);
        // midnight rolls the date
        t.dateSeconds = 23 * 3600.0 + 59 * 60 + 58;
        hud.setTape(t);
        for (i in 0...5) hud.tick(1.0, 0, 0);
        check("midnight rolls the date forward", hud.timestamp() == "04.11.1996 00:00:03");
        t.dateStr = "31.12.1999"; t.dateSeconds = 86399; hud.setTape(t); hud.tick(2.0, 0, 0);
        check("new year rolls month and year", hud.timestamp() == "01.01.2000 00:00:01");
        t.dateStr = "28.02.1996"; t.dateSeconds = 86399; hud.setTape(t); hud.tick(1.0, 0, 0);
        check("leap day 1996", hud.timestamp() == "29.02.1996 00:00:00");
        t.dateStr = "garbage"; hud.setTape(t);
        check("malformed date falls back without throwing", hud.timestamp().length == 19);
        // draw at T0 for every skin, battery and strobe combination: no OOB write, something drawn
        t.dateStr = "03.11.1996"; t.dateSeconds = 45296;
        var w = 256, h = 192, n = w * h;
        var threw = false, drewAll = true;
        for (skin in 0...3) {
            t.hudSkin = skin; hud.setTape(t); hud.tick(0.3, 0, 0);
            for (bi in 0...5) {
                var batt = bi * 0.25;
                for (strobe in 0...2) {
                    var b = buf(n, 0xFF808080);
                    try { hud.draw(b, w, h, batt, strobe == 1); } catch (e:Dynamic) { threw = true; Sys.println("  draw threw: " + e); }
                    if (countNot(b, n, 0xFF808080) < 100) drewAll = false;
                }
            }
        }
        check("draw at T0: never out of bounds", !threw);
        check("draw at T0: every skin/battery/strobe draws an OSD", drewAll);
        // REC dot blinks at 1 Hz and Main can hide it for a frame
        t.hudSkin = 0; hud.setTape(t);
        var b0 = buf(n, 0); hud.tick(0.1, 0, 0); hud.draw(b0, w, h, 1.0, false);
        var b1 = buf(n, 0); hud.tick(0.5, 0, 0); hud.draw(b1, w, h, 1.0, false);
        check("REC dot on in the first half second, off in the second", count(b0, n, 0xFFE83030) > 0 && count(b1, n, 0xFFE83030) == 0);
        hud.tick(0.5, 0, 0); hud.recVisible = false;
        var b2 = buf(n, 0); hud.draw(b2, w, h, 1.0, false);
        check("recVisible = false hides the dot", count(b2, n, 0xFFE83030) == 0);
        hud.recVisible = true;
        // T1 too
        var b3 = buf(320 * 240, 0); var threw2 = false;
        try { hud.draw(b3, 320, 240, 0.05, true); hud.draw(b3, 320, 240, 0.05, false); } catch (e:Dynamic) { threw2 = true; }
        check("draw at T1 with a dying battery, both strobe phases", !threw2);
        // play fade
        var pf = buf(n, 0); hud.drawPlayFade(pf, w, h, 0.5);
        var pf0 = buf(n, 0); hud.drawPlayFade(pf0, w, h, 0.0);
        var pf1 = buf(n, 0); hud.drawPlayFade(pf1, w, h, 1.0);
        check("PLAY fade: 0 draws nothing, 0.5 fewer than 1.0", countNot(pf0, n, 0) == 0 && countNot(pf, n, 0) > 0 && countNot(pf, n, 0) < countNot(pf1, n, 0));
        // strip: every one of w x 8 entries written, opaque
        for (skin in 0...3) {
            t.hudSkin = skin; hud.setTape(t); hud.tick(0.2, 0, 0);
            var sw = skin == 1 ? 320 : 256;
            var strip = buf(sw * 8, 0);
            var ok = true;
            try { hud.drawStrip(strip, sw, 0.7, false); hud.drawStrip(strip, sw, 0.05, true); } catch (e:Dynamic) { ok = false; Sys.println("  strip threw: " + e); }
            var all = true; for (i in 0...sw * 8) if ((strip[i] >> 24) != 0xFF) all = false;
            check("drawStrip skin " + skin + " writes every entry opaque", ok && all);
            check("drawStrip skin " + skin + " carries text", countNot(strip, sw * 8, strip[sw * 8 - 1]) > 40);
        }
    }

    // ------------------------------------------------------------ Cards
    static function testCards():Void {
        var cards = new Cards();
        var t = Tape.make(17, 1);
        t.name = "BASEMENT LEVEL - DANNY";
        t.dateStr = "03.11.1996";
        var w = 320, h = 240, n = w * h;
        var BLUE:UInt = 0xFF0C1EB4, INK:UInt = 0xFF22285C, WHITE:UInt = 0xFFF0F0F0, BLACK:UInt = 0xFF000000;
        var b = buf(n, 0x12345678);
        cards.drawCard(b, w, h, t, 0.1, false);
        check("card at 0.1 s is black", count(b, n, BLACK) == n);
        cards.drawCard(b, w, h, t, 0.4, false);
        check("card at 0.4 s is the blue field", count(b, n, BLUE) == n);
        cards.drawCard(b, w, h, t, 1.0, false);
        check("card at 1 s is blue-free", count(b, n, BLUE) == 0);
        check("card at 1 s has felt-tip ink", count(b, n, INK) > 200);
        check("card at 1 s (not first run) shows PRESS SPACE in white", count(b, n, WHITE) > 30);
        // the tape number: draw a card for tape 17 and for tape 18 -> the ink differs only around the digits
        var b17 = buf(n, 0); cards.drawCard(b17, w, h, t, 1.0, false);
        var t18 = Tape.make(18, 1); t18.name = t.name; t18.dateStr = t.dateStr; t18.seed = t.seed;
        var b18 = buf(n, 0); cards.drawCard(b18, w, h, t18, 1.0, false);
        var diff = 0; for (i in 0...n) if (b17[i] != b18[i]) diff++;
        check("tape number is drawn (17 vs 18 differ)", diff > 10 && diff < 2000);
        var bc = buf(n, 0); cards.drawCard(bc, w, h, t, 0.7, false);
        check("no prompt before 0.8 s when not first run", count(bc, n, WHITE) == 0);
        var bf = buf(n, 0); cards.drawCard(bf, w, h, t, 0.7, true);
        check("CLICK TO START from the start when firstRun", count(bf, n, WHITE) > 30);
        var bb = buf(n, 0); cards.drawCard(bb, w, h, t, 1.5, true);
        check("prompt blinks off in the second half second", count(bb, n, WHITE) == 0);
        // robustness: big index, long name, null tape, T0
        var threw = false;
        try {
            var tb = Tape.make(1234, 1); tb.name = "ABCDEFGHIJKLMNOPQRSTUVWXYZAB"; tb.dateStr = "31.12.1999";
            var x = buf(n, 0); cards.drawCard(x, w, h, tb, 2.3, true);
            check("28-char name is inked", count(x, n, INK) > 200);
            var x0 = buf(256 * 192, 0); cards.drawCard(x0, 256, 192, tb, 4.4, false);
            cards.drawCard(x0, 256, 192, null, 1.0, true);
            var tn = Tape.make(3, 1); tn.name = null; tn.dateStr = null;
            cards.drawCard(x0, 256, 192, tn, 1.0, false);
        } catch (e:Dynamic) { threw = true; Sys.println("  card threw: " + e); }
        check("card never writes out of bounds (big index, long name, null tape, T0)", !threw);
        // ENDS: centred within +/-2 px, scale 3
        for (cap in ["TAPE ENDS", "TAPE DAMAGED", "BATTERY"]) {
            var e = buf(n, 0);
            cards.drawEnds(e, w, h, 0.0, cap);
            var ext = extentX(e, w, h, WHITE);
            var left = ext[0], right = w - 1 - ext[1];
            var d = left - right; if (d < 0) d = -d;
            // jitter is +/-1 per glyph and the last column of a glyph may be blank; allow 2 px plus one glyph cell (3 px at scale 3)
            check("ENDS '" + cap + "' centred (left " + left + ", right " + right + ")", count(e, n, WHITE) > 100 && d <= 2 + 3);
        }
        var e0 = buf(n, 0xFF445566); cards.drawEnds(e0, w, h, 1.0, null);
        check("ENDS with null caption is plain black", count(e0, n, BLACK) == n);
        var e2 = buf(256 * 192, 0); var threw3 = false;
        try { cards.drawEnds(e2, 256, 192, 0.5, "TAPE DAMAGED"); } catch (e:Dynamic) { threw3 = true; }
        check("ENDS at T0 fits", !threw3 && count(e2, 256 * 192, WHITE) > 100);
        // PAUSE: every other pixel dimmed
        var p = buf(n, 0xFFFFFFFF);
        cards.drawPause(p, w, h, false);
        var dim = count(p, n, 0xFF7F7F7F), full = count(p, n, 0xFFFFFFFF);
        check("pause dims half the pixels (" + dim + " dim, " + full + " full)", dim > n / 2 - 400 && dim <= n / 2 && full > n / 2 - 400);
        check("pause checkerboard alternates per row", p[0] == 0xFF7F7F7F && p[1] == 0xFFFFFFFF && p[w] == 0xFFFFFFFF && p[w + 1] == 0xFF7F7F7F);
        var pw = buf(n, 0xFF202020); cards.drawPause(pw, w, h, true);
        var pn = buf(n, 0xFF202020); cards.drawPause(pn, w, h, false);
        check("windowed pause adds CLICK TO RESUME", count(pw, n, WHITE) > count(pn, n, WHITE) + 30);
        // NO SIGNAL
        var ns = buf(n, 0); cards.drawNoSignal(ns, w, h, 0);
        check("NO SIGNAL frame 0 is blue", count(ns, n, BLUE) == n);
        cards.drawNoSignal(ns, w, h, 1);
        check("NO SIGNAL frame 1 is blue", count(ns, n, BLUE) == n);
        var ns2 = buf(n, 0xFF303030); cards.drawNoSignal(ns2, w, h, 2);
        check("NO SIGNAL frame 2 blits the caption over the picture", count(ns2, n, WHITE) > 30 && count(ns2, n, 0xFF303030) > n - 2000);
    }
}
