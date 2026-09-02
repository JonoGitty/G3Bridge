// 5x7 bitmap font blitter (CONTRACT §2). fp class.
//
// The glyph bank is built ONCE, at class init, from the ASCII-art tables below (no @:bitmap,
// no embeds): 100 glyphs x 7 rows, one 5-bit row mask per entry, bit 4 = leftmost column.
// Codes 32..126 are ASCII; 0x7F = REC dot, 0x80 = play triangle, 0x81 = pause bars,
// 0x82 = battery cell; anything else draws the box glyph (index 99).
//
// Every blit is allocation-free: a fastCodeAt loop over the string, integer maths only,
// clipped per pixel block against the buffer so a glyph hanging off any edge writes
// nothing out of bounds (fixed-length flash.Vector throws on an out-of-range index).
// Callers pass the buffer geometry (w, h) so nothing here reads Renderer.
class PixelFont {
    public static inline var GLYPH_W = 5;
    public static inline var GLYPH_H = 7;
    public static inline var ADVANCE = 6;                // 5 px glyph + 1 px gap
    public static inline var CODE_REC = 0x7F;
    public static inline var CODE_PLAY = 0x80;
    public static inline var CODE_PAUSE = 0x81;
    public static inline var CODE_CELL = 0x82;
    static inline var FIRST = 32;
    static inline var COUNT = 100;                       // 32..131 (131 = the box)
    static inline var BOX = 99;                          // glyph index of the "unknown" box

    // 7 row masks per glyph, glyph-major: ROWS[g * 7 + r]
    static var ROWS:haxe.ds.Vector<Int> = build();
    // 4x4 ordered-dither thresholds 0..15 for blitDither
    static var BAYER:haxe.ds.Vector<Int> = buildBayer();

    // ---------------------------------------------------------------- public API (contract)

    // clips to the buffer; advance = 6*scale
    public static function blit(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, colour:UInt, scale:Int):Void {
        if (scale < 1) scale = 1;
        var n = s.length;
        var adv = ADVANCE * scale;
        var gx = x;
        for (i in 0...n) {
            glyph(fb, w, h, gx, y, index(StringTools.fastCodeAt(s, i)), colour, scale);
            gx += adv;
        }
    }

    public static function width(s:String, scale:Int):Int {
        return s.length * ADVANCE * scale;
    }

    // per-glyph +/-1 px offsets from seed (card look). The offset of glyph i is a pure function of
    // (seed, i), so the same seed reproduces the same wobble frame after frame (ink does not crawl).
    public static function blitJitter(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, colour:UInt, scale:Int, seed:Int):Void {
        if (scale < 1) scale = 1;
        var n = s.length;
        var adv = ADVANCE * scale;
        var gx = x;
        for (i in 0...n) {
            var hh = Rng.hash2(seed, i);
            var dx = ((hh & 0xFF) % 3) - 1;
            var dy = (((hh >>> 8) & 0xFF) % 3) - 1;
            glyph(fb, w, h, gx + dx, y + dy, index(StringTools.fastCodeAt(s, i)), colour, scale);
            gx += adv;
        }
    }

    // ---------------------------------------------------------------- unit-internal helpers
    // (used by Hud and Cards; not part of the cross-unit contract)

    // One glyph by character code (lets Cards draw a number digit by digit with no string building).
    public static function blitChar(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, code:Int, colour:UInt, scale:Int):Void {
        if (scale < 1) scale = 1;
        glyph(fb, w, h, x, y, index(code), colour, scale);
    }

    // One glyph with the same seeded +/-1 px offset rule as blitJitter (glyph slot i of a run).
    public static function blitCharJitter(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, code:Int, colour:UInt, scale:Int, seed:Int, i:Int):Void {
        if (scale < 1) scale = 1;
        var hh = Rng.hash2(seed, i);
        var dx = ((hh & 0xFF) % 3) - 1;
        var dy = (((hh >>> 8) & 0xFF) % 3) - 1;
        glyph(fb, w, h, x + dx, y + dy, index(code), colour, scale);
    }

    // Blit with an ordered-dither alpha: level 0..16 pixels-in-16 are written (0 = nothing, 16 = solid).
    // Simulates a fade without blending (Hud.drawPlayFade).
    public static function blitDither(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, colour:UInt, scale:Int, level:Int):Void {
        if (level <= 0) return;
        if (level >= 16) { blit(fb, w, h, x, y, s, colour, scale); return; }
        if (scale < 1) scale = 1;
        var rows = ROWS;
        var bayer = BAYER;
        var n = s.length;
        var adv = ADVANCE * scale;
        var gx = x;
        for (i in 0...n) {
            var base = index(StringTools.fastCodeAt(s, i)) * GLYPH_H;
            for (r in 0...GLYPH_H) {
                var m = rows[base + r];
                if (m == 0) continue;
                var y0 = y + r * scale;
                var y1 = y0 + scale;
                if (y0 < 0) y0 = 0;
                if (y1 > h) y1 = h;
                if (y0 >= y1) continue;
                for (c in 0...GLYPH_W) {
                    if ((m & (16 >> c)) == 0) continue;
                    var x0 = gx + c * scale;
                    var x1 = x0 + scale;
                    if (x0 < 0) x0 = 0;
                    if (x1 > w) x1 = w;
                    if (x0 >= x1) continue;
                    for (yy in y0...y1) {
                        var row = yy * w;
                        var brow = (yy & 3) << 2;
                        for (xx in x0...x1) {
                            if (bayer[brow | (xx & 3)] < level) fb[row + xx] = colour;
                        }
                    }
                }
            }
            gx += adv;
        }
    }

    // Glyph index for a character code (box for anything outside the bank).
    public static inline function index(code:Int):Int {
        return (code >= FIRST && code < FIRST + COUNT - 1) ? code - FIRST : BOX;
    }

    // Row mask r (0..6) of the glyph for code — for tests and for callers that want the raw shape.
    public static function rowMask(code:Int, r:Int):Int {
        return ROWS[index(code) * GLYPH_H + r];
    }

    // ---------------------------------------------------------------- drawing

    // One glyph at (x, y), scale x scale blocks, clipped. Scale 1 takes a tighter path (the HUD case).
    static function glyph(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, gi:Int, colour:UInt, scale:Int):Void {
        var rows = ROWS;
        var base = gi * GLYPH_H;
        if (scale == 1) {
            // whole glyph inside the buffer: no per-pixel clipping
            if (x >= 0 && y >= 0 && x + GLYPH_W <= w && y + GLYPH_H <= h) {
                var idx = y * w + x;
                for (r in 0...GLYPH_H) {
                    var m = rows[base + r];
                    if (m != 0) {
                        if ((m & 16) != 0) fb[idx] = colour;
                        if ((m & 8) != 0) fb[idx + 1] = colour;
                        if ((m & 4) != 0) fb[idx + 2] = colour;
                        if ((m & 2) != 0) fb[idx + 3] = colour;
                        if ((m & 1) != 0) fb[idx + 4] = colour;
                    }
                    idx += w;
                }
                return;
            }
            if (x + GLYPH_W <= 0 || x >= w || y + GLYPH_H <= 0 || y >= h) return;
            for (r in 0...GLYPH_H) {
                var py = y + r;
                if (py < 0 || py >= h) continue;
                var m = rows[base + r];
                if (m == 0) continue;
                var row = py * w;
                for (c in 0...GLYPH_W) {
                    if ((m & (16 >> c)) == 0) continue;
                    var px = x + c;
                    if (px >= 0 && px < w) fb[row + px] = colour;
                }
            }
            return;
        }
        var gw = GLYPH_W * scale;
        var gh = GLYPH_H * scale;
        if (x + gw <= 0 || x >= w || y + gh <= 0 || y >= h) return;
        for (r in 0...GLYPH_H) {
            var m = rows[base + r];
            if (m == 0) continue;
            var y0 = y + r * scale;
            var y1 = y0 + scale;
            if (y0 < 0) y0 = 0;
            if (y1 > h) y1 = h;
            if (y0 >= y1) continue;
            for (c in 0...GLYPH_W) {
                if ((m & (16 >> c)) == 0) continue;
                var x0 = x + c * scale;
                var x1 = x0 + scale;
                if (x0 < 0) x0 = 0;
                if (x1 > w) x1 = w;
                if (x0 >= x1) continue;
                var span = x1 - x0;
                var idx = y0 * w + x0;
                for (yy in y0...y1) {
                    var i = idx;
                    for (k in 0...span) { fb[i] = colour; i++; }
                    idx += w;
                }
            }
        }
    }

    // ---------------------------------------------------------------- glyph bank (built once)

    static function buildBayer():haxe.ds.Vector<Int> {
        var b = new haxe.ds.Vector<Int>(16);
        b[0] = 0;  b[1] = 8;  b[2] = 2;  b[3] = 10;
        b[4] = 12; b[5] = 4;  b[6] = 14; b[7] = 6;
        b[8] = 3;  b[9] = 11; b[10] = 1; b[11] = 9;
        b[12] = 15; b[13] = 7; b[14] = 13; b[15] = 5;
        return b;
    }

    static var bank:haxe.ds.Vector<Int>;

    // Parse one glyph: 7 rows of 5 characters, '#' (or any non-space) = set.
    static function def(code:Int, r0:String, r1:String, r2:String, r3:String, r4:String, r5:String, r6:String):Void {
        var base = (code - FIRST) * GLYPH_H;
        bank[base] = mask(r0);
        bank[base + 1] = mask(r1);
        bank[base + 2] = mask(r2);
        bank[base + 3] = mask(r3);
        bank[base + 4] = mask(r4);
        bank[base + 5] = mask(r5);
        bank[base + 6] = mask(r6);
    }

    static function mask(row:String):Int {
        var m = 0;
        for (c in 0...GLYPH_W) {
            if (c < row.length && StringTools.fastCodeAt(row, c) != 32) m |= 16 >> c;
        }
        return m;
    }

    static function build():haxe.ds.Vector<Int> {
        bank = new haxe.ds.Vector<Int>(COUNT * GLYPH_H);
        for (i in 0...COUNT * GLYPH_H) bank[i] = 0;
        // --- punctuation and digits
        def(32,  "     ", "     ", "     ", "     ", "     ", "     ", "     ");   // space
        def(33,  "  #  ", "  #  ", "  #  ", "  #  ", "     ", "     ", "  #  ");   // !
        def(34,  " # # ", " # # ", " # # ", "     ", "     ", "     ", "     ");   // "
        def(35,  " # # ", " # # ", "#####", " # # ", "#####", " # # ", " # # ");   // #
        def(36,  "  #  ", " ####", "# #  ", " ### ", "  # #", "#### ", "  #  ");   // $
        def(37,  "##   ", "##  #", "   # ", "  #  ", " #   ", "#  ##", "   ##");   // %
        def(38,  " ##  ", "#  # ", "# #  ", " #   ", "# # #", "#  # ", " ## #");   // &
        def(39,  " ##  ", "  #  ", " #   ", "     ", "     ", "     ", "     ");   // '
        def(40,  "   # ", "  #  ", " #   ", " #   ", " #   ", "  #  ", "   # ");   // (
        def(41,  " #   ", "  #  ", "   # ", "   # ", "   # ", "  #  ", " #   ");   // )
        def(42,  "     ", "  #  ", "# # #", " ### ", "# # #", "  #  ", "     ");   // *
        def(43,  "     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     ");   // +
        def(44,  "     ", "     ", "     ", "     ", " ##  ", "  #  ", " #   ");   // ,
        def(45,  "     ", "     ", "     ", "#####", "     ", "     ", "     ");   // -
        def(46,  "     ", "     ", "     ", "     ", "     ", " ##  ", " ##  ");   // .
        def(47,  "     ", "    #", "   # ", "  #  ", " #   ", "#    ", "     ");   // /
        def(48,  " ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### ");   // 0
        def(49,  "  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### ");   // 1
        def(50,  " ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####");   // 2
        def(51,  "#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### ");   // 3
        def(52,  "   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # ");   // 4
        def(53,  "#####", "#    ", "#### ", "    #", "    #", "#   #", " ### ");   // 5
        def(54,  "  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### ");   // 6
        def(55,  "#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   ");   // 7
        def(56,  " ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### ");   // 8
        def(57,  " ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  ");   // 9
        def(58,  "     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     ");   // :
        def(59,  "     ", " ##  ", " ##  ", "     ", " ##  ", "  #  ", " #   ");   // ;
        def(60,  "   # ", "  #  ", " #   ", "#    ", " #   ", "  #  ", "   # ");   // <
        def(61,  "     ", "     ", "#####", "     ", "#####", "     ", "     ");   // =
        def(62,  " #   ", "  #  ", "   # ", "    #", "   # ", "  #  ", " #   ");   // >
        def(63,  " ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  ");   // ?
        def(64,  " ### ", "#   #", "    #", " ## #", "# # #", "# # #", " ### ");   // @
        // --- upper case
        def(65,  "  #  ", " # # ", "#   #", "#   #", "#####", "#   #", "#   #");   // A
        def(66,  "#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### ");   // B
        def(67,  " ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### ");   // C
        def(68,  "###  ", "#  # ", "#   #", "#   #", "#   #", "#  # ", "###  ");   // D
        def(69,  "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####");   // E
        def(70,  "#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    ");   // F
        def(71,  " ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ####");   // G
        def(72,  "#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #");   // H
        def(73,  " ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### ");   // I
        def(74,  "  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  ");   // J
        def(75,  "#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #");   // K
        def(76,  "#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####");   // L
        def(77,  "#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #");   // M
        def(78,  "#   #", "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #");   // N
        def(79,  " ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### ");   // O
        def(80,  "#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    ");   // P
        def(81,  " ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #");   // Q
        def(82,  "#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #");   // R
        def(83,  " ####", "#    ", "#    ", " ### ", "    #", "    #", "#### ");   // S
        def(84,  "#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ");   // T
        def(85,  "#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### ");   // U
        def(86,  "#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  ");   // V
        def(87,  "#   #", "#   #", "#   #", "# # #", "# # #", "# # #", " # # ");   // W
        def(88,  "#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #");   // X
        def(89,  "#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  ");   // Y
        def(90,  "#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####");   // Z
        def(91,  " ### ", " #   ", " #   ", " #   ", " #   ", " #   ", " ### ");   // [
        def(92,  "     ", "#    ", " #   ", "  #  ", "   # ", "    #", "     ");   // backslash
        def(93,  " ### ", "   # ", "   # ", "   # ", "   # ", "   # ", " ### ");   // ]
        def(94,  "  #  ", " # # ", "#   #", "     ", "     ", "     ", "     ");   // ^
        def(95,  "     ", "     ", "     ", "     ", "     ", "     ", "#####");   // _
        def(96,  " #   ", "  #  ", "   # ", "     ", "     ", "     ", "     ");   // `
        // --- lower case
        def(97,  "     ", "     ", " ### ", "    #", " ####", "#   #", " ####");   // a
        def(98,  "#    ", "#    ", "# ## ", "##  #", "#   #", "#   #", "#### ");   // b
        def(99,  "     ", "     ", " ### ", "#    ", "#    ", "#   #", " ### ");   // c
        def(100, "    #", "    #", " ## #", "#  ##", "#   #", "#   #", " ####");   // d
        def(101, "     ", "     ", " ### ", "#   #", "#####", "#    ", " ### ");   // e
        def(102, "  ## ", " #  #", " #   ", "###  ", " #   ", " #   ", " #   ");   // f
        def(103, "     ", " ####", "#   #", "#   #", " ####", "    #", " ### ");   // g
        def(104, "#    ", "#    ", "# ## ", "##  #", "#   #", "#   #", "#   #");   // h
        def(105, "  #  ", "     ", " ##  ", "  #  ", "  #  ", "  #  ", " ### ");   // i
        def(106, "   # ", "     ", "  ## ", "   # ", "   # ", "#  # ", " ##  ");   // j
        def(107, "#    ", "#    ", "#  # ", "# #  ", "##   ", "# #  ", "#  # ");   // k
        def(108, " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### ");   // l
        def(109, "     ", "     ", "## # ", "# # #", "# # #", "#   #", "#   #");   // m
        def(110, "     ", "     ", "# ## ", "##  #", "#   #", "#   #", "#   #");   // n
        def(111, "     ", "     ", " ### ", "#   #", "#   #", "#   #", " ### ");   // o
        def(112, "     ", "     ", "#### ", "#   #", "#### ", "#    ", "#    ");   // p
        def(113, "     ", "     ", " ## #", "#  ##", " ####", "    #", "    #");   // q
        def(114, "     ", "     ", "# ## ", "##  #", "#    ", "#    ", "#    ");   // r
        def(115, "     ", "     ", " ####", "#    ", " ### ", "    #", "#### ");   // s
        def(116, " #   ", " #   ", "###  ", " #   ", " #   ", " #  #", "  ## ");   // t
        def(117, "     ", "     ", "#   #", "#   #", "#   #", "#  ##", " ## #");   // u
        def(118, "     ", "     ", "#   #", "#   #", "#   #", " # # ", "  #  ");   // v
        def(119, "     ", "     ", "#   #", "#   #", "# # #", "# # #", " # # ");   // w
        def(120, "     ", "     ", "#   #", " # # ", "  #  ", " # # ", "#   #");   // x
        def(121, "     ", "     ", "#   #", "#   #", " ####", "    #", " ### ");   // y
        def(122, "     ", "     ", "#####", "   # ", "  #  ", " #   ", "#####");   // z
        def(123, "   # ", "  #  ", "  #  ", " #   ", "  #  ", "  #  ", "   # ");   // {
        def(124, "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ");   // |
        def(125, " #   ", "  #  ", "  #  ", "   # ", "  #  ", "  #  ", " #   ");   // }
        def(126, "     ", "     ", " #  #", "# # #", "#  # ", "     ", "     ");   // ~
        // --- OSD symbols
        def(127, "     ", " ### ", "#####", "#####", "#####", " ### ", "     ");   // REC dot
        def(128, "#    ", "##   ", "###  ", "#### ", "###  ", "##   ", "#    ");   // play triangle
        def(129, "## ##", "## ##", "## ##", "## ##", "## ##", "## ##", "## ##");   // pause bars
        def(130, "#### ", "#### ", "#### ", "#### ", "#### ", "#### ", "#### ");   // battery cell
        def(131, "#####", "#   #", "#   #", "#   #", "#   #", "#   #", "#####");   // unknown = box
        var out = bank;
        bank = null;
        return out;
    }
}
