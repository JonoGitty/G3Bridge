// Tape card, TAPE ENDS, pause and NO SIGNAL screens (CONTRACT §2). fp class.
//
// Pure frame-buffer writers: full fills plus PixelFont blits; the camcorder post still runs
// over them. The tape card is a VHS spine label filmed off a desk: a cream sticker with ruled
// lines and a coloured header band on the dark cassette shell, the tape number, the name and
// the recording date in felt-tip (double-struck ink with per-glyph jitter from the tape seed,
// the whole picture wobbling at 0.5 Hz).
//
// Allocation: none after the constructor. The tape number is drawn digit by digit
// (PixelFont.blitCharJitter) and the date line is two adjacent blits ("REC " then
// Tape.dateStr), so no string is ever built in the frame path (CONTRACT rule 4).
//
// Prompts: firstRun draws CLICK TO START (the first card of a session, and the bench's
// GESTURE_FS_RECT arm — the click focuses the plugin and is the fullscreen gesture);
// otherwise PRESS SPACE appears from 0.8 s, the moment Main accepts a dismiss key, which is
// also the bench's GESTURE_FS_NORECT prompt. Main chooses firstRun per gesture need.
class Cards {
    static inline var BLACK_UNTIL = 0.2;                // card: black, then
    static inline var BLUE_UNTIL = 0.6;                 // a blue field for 0.4 s, then the label
    static inline var PROMPT_FROM = 0.8;                // Main accepts a dismiss key from 0.8 s
    static inline var GH = 7;                           // glyph height at scale 1

    static inline var COL_BLACK:UInt = 0xFF000000;
    static inline var COL_BLUE:UInt = 0xFF0C1EB4;       // VCR blue field
    static inline var COL_SHELL:UInt = 0xFF1A1A1C;      // cassette shell
    static inline var COL_SHELL_LINE:UInt = 0xFF242426; // moulding line on the shell
    static inline var COL_LABEL:UInt = 0xFFE8E0C6;      // cream sticker
    static inline var COL_LABEL_EDGE:UInt = 0xFFB8AE90;
    static inline var COL_LABEL_BAND:UInt = 0xFFC8523E; // red header band
    static inline var COL_RULE:UInt = 0xFF9CAAC8;       // faint blue ruled lines
    static inline var COL_INK:UInt = 0xFF22285C;        // felt-tip blue-black
    static inline var COL_WHITE:UInt = 0xFFF0F0F0;

    // constant strings, built once
    var strTape:String;                                 // "TAPE #"
    var strRec:String;                                  // "REC "
    var strStart:String;
    var strSpace:String;
    var strPause:String;
    var strResume:String;
    var strNoSignal:String;

    public function new():Void {
        strTape = "TAPE #";
        strRec = "REC ";
        strStart = "CLICK TO START";
        strSpace = "PRESS SPACE";
        strPause = String.fromCharCode(PixelFont.CODE_PAUSE) + " PAUSE";
        strResume = "CLICK TO RESUME";
        strNoSignal = "NO SIGNAL";
    }

    // black -> blue field 0.4 s -> label with jitter/wobble; "CLICK TO START" when firstRun
    public function drawCard(fb:flash.Vector<UInt>, w:Int, h:Int, t:Tape, seconds:Float, firstRun:Bool):Void {
        if (seconds < BLACK_UNTIL) { fillAll(fb, w * h, COL_BLACK); return; }
        if (seconds < BLUE_UNTIL) { fillAll(fb, w * h, COL_BLUE); return; }

        // the shell, with a couple of moulding lines
        fillAll(fb, w * h, COL_SHELL);
        var mould = h >> 4;
        fill(fb, w, h, 0, mould, w, mould + 1, COL_SHELL_LINE);
        fill(fb, w, h, 0, h - mould, w, h - mould + 1, COL_SHELL_LINE);

        // 0.5 Hz wobble of the whole card, as if filmed handheld off a desk
        var wx = Std.int(Math.sin(seconds * Math.PI) * 2.0);
        var wy = Std.int(Math.cos(seconds * Math.PI * 0.7) * 1.5);

        // the sticker
        var inset = Std.int(w / 10);
        var lx0 = inset + wx;
        var lx1 = w - inset + wx;
        var ly0 = Std.int(h * 0.22) + wy;
        var ly1 = Std.int(h * 0.78) + wy;
        fill(fb, w, h, lx0 + 2, ly0 + 2, lx1 + 2, ly1 + 2, COL_BLACK);        // drop shadow
        fill(fb, w, h, lx0, ly0, lx1, ly1, COL_LABEL);
        fill(fb, w, h, lx0, ly0, lx1, ly0 + 1, COL_LABEL_EDGE);
        fill(fb, w, h, lx0, ly1 - 1, lx1, ly1, COL_LABEL_EDGE);
        fill(fb, w, h, lx0, ly0, lx0 + 1, ly1, COL_LABEL_EDGE);
        fill(fb, w, h, lx1 - 1, ly0, lx1, ly1, COL_LABEL_EDGE);
        fill(fb, w, h, lx0 + 1, ly0 + 1, lx1 - 1, ly0 + 6, COL_LABEL_BAND);   // header band

        // the writing area: each line at the largest scale (<= 3 / 2 / 2) that fits its width
        var tx = lx0 + 10;
        var xEnd = lx1 - 8;
        var avail = xEnd - tx;
        var seed = t == null ? 0 : t.seed;
        var y = ly0 + 12;

        // line 1: TAPE #017 — the number drawn digit by digit, at least three digits
        var n = t == null ? 0 : t.index;
        if (n < 0) n = 0;
        var nd = digitCount(n);
        if (nd < 3) nd = 3;
        var s1 = fitGlyphs(6 + nd, avail, 3);
        rule(fb, w, h, tx, y, xEnd, s1);
        inkText(fb, w, h, tx, y, strTape, s1, seed);
        inkInt(fb, w, h, tx + PixelFont.width(strTape, s1), y, n, nd, s1, seed ^ 0x1D2B);
        y += GH * s1 + 8;

        // line 2: the name (ASCII, <= 28 chars per Tape)
        var name = t == null ? null : t.name;
        var nl = name == null ? 0 : name.length;
        var s2 = nl == 0 ? 2 : fitGlyphs(nl, avail, 2);
        rule(fb, w, h, tx, y, xEnd, s2);
        if (nl > 0) inkText(fb, w, h, tx, y, name, s2, seed ^ 0x3A5F);
        y += GH * s2 + 8;

        // line 3: REC DD.MM.YYYY — "REC " then the tape's own date string, adjacent
        var ds = t == null ? null : t.dateStr;
        var dl = ds == null ? 0 : ds.length;
        var s3 = fitGlyphs(4 + dl, avail, 2);
        rule(fb, w, h, tx, y, xEnd, s3);
        inkText(fb, w, h, tx, y, strRec, s3, seed ^ 0x6C11);
        if (dl > 0) inkText(fb, w, h, tx + PixelFont.width(strRec, s3), y, ds, s3, seed ^ 0x2E77);

        // the prompt under the sticker, blinking at 1 Hz, on when the label first appears
        var blink = (Std.int((seconds - BLUE_UNTIL) * 2.0) & 1) == 0;
        var prompt = firstRun ? strStart : (seconds >= PROMPT_FROM ? strSpace : null);
        if (prompt != null && blink) {
            var px = (w - PixelFont.width(prompt, 1)) >> 1;
            var py = ly1 + ((h - ly1 - GH) >> 1);
            PixelFont.blit(fb, w, h, px + 1, py + 1, prompt, COL_BLACK, 1);
            PixelFont.blit(fb, w, h, px, py, prompt, COL_WHITE, 1);
        }
    }

    // "TAPE ENDS" / "TAPE DAMAGED" / "BATTERY", centred, scale 3
    public function drawEnds(fb:flash.Vector<UInt>, w:Int, h:Int, seconds:Float, caption:String):Void {
        fillAll(fb, w * h, COL_BLACK);
        if (caption == null || caption.length == 0) return;
        var scale = fitGlyphs(caption.length, w - 16, 3);
        var cx = (w - PixelFont.width(caption, scale)) >> 1;
        var cy = (h - GH * scale) >> 1;
        // a VCR-generated caption trembles: per-glyph +/-1 px, re-seeded every 1/6 s
        PixelFont.blitJitter(fb, w, h, cx, cy, caption, COL_WHITE, scale, Std.int(seconds * 6.0));
    }

    // dims the frame (every other pixel) and blits "|| PAUSE"; windowed adds "CLICK TO RESUME" (Safari 3 gives the plugin no keys until a click refocuses it)
    public function drawPause(fb:flash.Vector<UInt>, w:Int, h:Int, windowed:Bool):Void {
        // checkerboard half-brightness: every other pixel, the phase alternating per row
        var end = 0;
        for (yy in 0...h) {
            var i = end + (yy & 1);
            end += w;
            while (i < end) {
                fb[i] = ((fb[i] >> 1) & 0x7F7F7F) | 0xFF000000;
                i += 2;
            }
        }
        PixelFont.blit(fb, w, h, 17, 17, strPause, COL_BLACK, 2);
        PixelFont.blit(fb, w, h, 16, 16, strPause, COL_WHITE, 2);
        if (windowed) {
            var px = (w - PixelFont.width(strResume, 1)) >> 1;
            var py = h - 24;
            PixelFont.blit(fb, w, h, px + 1, py + 1, strResume, COL_BLACK, 1);
            PixelFont.blit(fb, w, h, px, py, strResume, COL_WHITE, 1);
        }
    }

    // blue field for frames 0-1, then "NO SIGNAL" top-left
    public function drawNoSignal(fb:flash.Vector<UInt>, w:Int, h:Int, frame:Int):Void {
        if (frame < 2) { fillAll(fb, w * h, COL_BLUE); return; }
        PixelFont.blit(fb, w, h, 17, 17, strNoSignal, COL_BLACK, 2);
        PixelFont.blit(fb, w, h, 16, 16, strNoSignal, COL_WHITE, 2);
    }

    // ---------------------------------------------------------------- internals

    // number of decimal digits of n >= 0 (at least 1)
    static function digitCount(n:Int):Int {
        var c = 1;
        while (n >= 10) { n = Std.int(n / 10); c++; }
        return c;
    }

    // largest scale <= max at which nGlyphs glyphs fit in avail px (never below 1)
    static function fitGlyphs(nGlyphs:Int, avail:Int, max:Int):Int {
        var sc = max;
        while (sc > 1 && nGlyphs * PixelFont.ADVANCE * sc > avail) sc--;
        return sc;
    }

    // the ruled line under a text line of the given scale
    static function rule(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, xEnd:Int, scale:Int):Void {
        var base = y + GH * scale + 2;
        fill(fb, w, h, x - 4, base, xEnd, base + 1, COL_RULE);
    }

    // text double-struck in felt-tip with seeded jitter (the second strike 1 px right thickens the stroke)
    static function inkText(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, scale:Int, seed:Int):Void {
        PixelFont.blitJitter(fb, w, h, x, y, s, COL_INK, scale, seed);
        PixelFont.blitJitter(fb, w, h, x + 1, y, s, COL_INK, scale, seed);
    }

    // n >= 0 in felt-tip, zero-padded to nd digits, most significant first — no string is built
    static function inkInt(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, n:Int, nd:Int, scale:Int, seed:Int):Void {
        var div = 1;
        for (k in 1...nd) div *= 10;
        var adv = PixelFont.ADVANCE * scale;
        for (i in 0...nd) {
            var d = Std.int(n / div);
            n -= d * div;
            div = Std.int(div / 10);
            var code = 48 + (d % 10);
            PixelFont.blitCharJitter(fb, w, h, x, y, code, COL_INK, scale, seed, i);
            PixelFont.blitCharJitter(fb, w, h, x + 1, y, code, COL_INK, scale, seed, i);
            x += adv;
        }
    }

    static function fillAll(fb:flash.Vector<UInt>, n:Int, col:UInt):Void {
        for (i in 0...n) fb[i] = col;
    }

    // clipped rectangle fill, [x0, x1) x [y0, y1)
    static function fill(fb:flash.Vector<UInt>, w:Int, h:Int, x0:Int, y0:Int, x1:Int, y1:Int, col:UInt):Void {
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > w) x1 = w;
        if (y1 > h) y1 = h;
        if (x0 >= x1 || y0 >= y1) return;
        var span = x1 - x0;
        var idx = y0 * w + x0;
        for (yy in y0...y1) {
            var i = idx;
            for (k in 0...span) { fb[i] = col; i++; }
            idx += w;
        }
    }
}
