// VHS post chain on the BitmapData (CONTRACT §2, DESIGN §3). fp class.
//
// Everything acts on the native-resolution BitmapData AFTER Renderer.present() and BEFORE the
// single composite, with native BitmapData ops only (copyPixels / copyChannel / scroll / fillRect /
// colorTransform, one strip applyFilter on glitch frames). Nothing is ever applied to the display
// object. Every sheet, scratch, Point, Rectangle, ColorTransform and filter is created in the
// constructor; apply() allocates nothing (CONTRACT rule 4; the eMac soak's mem series is the proof).
//
// Per-frame op count on a plain frame: scanline+vignette merge, grain merge, head-switch bar copy,
// one whole-frame colorTransform = 4 native ops (~3-4 ms at T1 per the BRIEF's measurement).
// A glitch frame adds: whole-frame scratch copy, one 32-row strip blur, 3-6 slice copies, one band
// colorTransform, two whole-frame copyChannel calls (~+2 ms). Tears add three band ops per band,
// a roll one scroll plus one band copy (three band ops when the picture wraps on a bad tape).
//
// Sheets: two scanline+vignette sheets per tier (normal, and 15% tighter for dread > 0.5), four
// 512x512 grain sheets of rising alpha rebuilt per tape from noise(seed), one opaque noise sheet
// (death static, head-switch bar, tear gaps, roll wrap bands) built once. Sheet building runs only
// in the constructor and buildForTape (between tapes), through one reused row buffer + setVector,
// with integer inner loops; the vignette curve is a 513-entry LUT over the squared radius.
import flash.display.BitmapData;
import flash.filters.BlurFilter;
import flash.geom.ColorTransform;
import flash.geom.Point;
import flash.geom.Rectangle;

class Camcorder {
    public static inline var G_NONE = 0;
    public static inline var G_TEAR = 1;                // tracking bands this frame
    public static inline var G_ROLL = 2;                // vertical roll this frame (rollPx set)
    public static inline var G_GLITCH = 4;              // slice offsets + strip blur + chroma
    public static inline var G_DROPOUT = 8;
    public static inline var G_STROBE = 16;
    public static inline var G_BLACKOUT = 32;           // (renderer already black; adds heavy grain)
    public static inline var G_NOISE_FULL = 64;         // death: full alpha grain
    static inline var GRAIN_SHEETS = 4;
    static inline var GRAIN_SIZE = 512;
    static inline var SCAN_ALPHA = 0x38;                // odd-row darkening (DESIGN §3; per-build constant, retune on the CRT)
    public static inline var HEAD_ROWS = 4;             // head-switch noise bar height (Main keeps the ST_MAP OSD strip above it)
    static inline var STRIP_ROWS = 32;                  // glitch blur strip height
    static inline var SEAM_ROWS = 6;                    // noise seam where a bad-tape roll wraps
    static inline var LUT_N = 513;                      // vignette LUT: squared normalised radius 0..2 in 1/256 steps
    static inline var CH_RED = 1;                       // flash.display.BitmapDataChannel values
    static inline var CH_BLUE = 4;
    public var dread:Float;                             // set per frame by Main
    public var flags:Int;
    public var rollPx:Int;
    public var tearBands:Int;                           // 1..4
    public var chromaPx:Int;                            // 0..5
    public var flickerBrightness:Float;                 // 0.85..1.05, per frame from Main (lightOffset-derived jitter)
    public var tPost:Int;

    // private — implementer may rename
    var tier:Int;
    var w:Int;
    var h:Int;
    var scan0:BitmapData; var scan1:BitmapData;         // scanline+vignette sheets per tier (normal)
    var scanTight0:BitmapData; var scanTight1:BitmapData; // tight-vignette variants
    var scratch0:BitmapData; var scratch1:BitmapData;   // whole-frame scratch per tier
    var frame0:Rectangle; var frame1:Rectangle;         // (0,0,w,h) per tier
    var scan:BitmapData;                                // current tier pointers
    var scanTight:BitmapData;
    var scratch:BitmapData;
    var frame:Rectangle;
    var grain:flash.Vector<BitmapData>;                 // GRAIN_SHEETS sheets of GRAIN_SIZE^2
    var grainFull:BitmapData;                           // opaque noise for G_NOISE_FULL, roll wrap bands, tear gaps, head-switch bar
    var pt2:Point;
    var ptZero:Point;
    var rc:Rectangle;
    var rc2:Rectangle;
    var rowRect:Rectangle;                              // sheet building: one row
    var rowBuf:flash.Vector<UInt>;                      // sheet building: GRAIN_SIZE entries (covers every sheet width)
    var colQ:flash.Vector<Int>;                         // sheet building: per-column squared normalised x, Q8
    var lut:flash.Vector<UInt>;                         // sheet building: 2 x LUT_N premultiplied-black ARGB values (even rows, odd rows)
    var ct:ColorTransform;                              // per-tape tint
    var ctFrame:ColorTransform;                         // tint x flicker (x strobe, x dread wash), written every frame
    var ctInvert:ColorTransform;                        // multipliers -1, offsets 255
    var blur:BlurFilter;                                // BlurFilter(3, 0, 1)
    var grainAlpha:Int;                                 // per tape 24..40
    var badTape:Bool;                                   // recurring slow-roll episodes
    var vigR0:Float;                                    // per-tape vignette start radius (normalised)
    var vigCorner:Float;                                // per-tape corner darkness 0..1
    var pendingTear:Int;                                // tearNow() schedule (band count), consumed by the next apply
    var pendingGlitch:Bool;                             // glitchNow() schedule
    var headPhase:Int;                                  // cycling x offset of the head-switch bar
    var badRollLeft:Int;                                // frames left in the current bad-tape roll episode
    var badRollOff:Int;                                 // current bad-tape roll offset (rows)
    var badRollSpeed:Int;                               // rows per frame during an episode

    // allocates sheets for BOTH tiers and 4 grain sheets 512x512, scratch BitmapData per tier, all Points/Rects/ColorTransforms
    public function new():Void {
        dread = 0.0;
        flags = 0;
        rollPx = 0;
        tearBands = 1;
        chromaPx = 0;
        flickerBrightness = 1.0;
        tPost = 0;
        grainAlpha = 32;
        badTape = false;
        vigR0 = 0.6;
        vigCorner = 0.65;
        pendingTear = 0;
        pendingGlitch = false;
        headPhase = 0;
        badRollLeft = 0;
        badRollOff = 0;
        badRollSpeed = 1;
        scan0 = new BitmapData(Renderer.W0, Renderer.H0, true, 0x00000000);
        scan1 = new BitmapData(Renderer.W1, Renderer.H1, true, 0x00000000);
        scanTight0 = new BitmapData(Renderer.W0, Renderer.H0, true, 0x00000000);
        scanTight1 = new BitmapData(Renderer.W1, Renderer.H1, true, 0x00000000);
        scratch0 = new BitmapData(Renderer.W0, Renderer.H0, false, 0xFF000000);
        scratch1 = new BitmapData(Renderer.W1, Renderer.H1, false, 0xFF000000);
        frame0 = new Rectangle(0, 0, Renderer.W0, Renderer.H0);
        frame1 = new Rectangle(0, 0, Renderer.W1, Renderer.H1);
        grain = new flash.Vector<BitmapData>(GRAIN_SHEETS, true);
        for (i in 0...GRAIN_SHEETS) grain[i] = new BitmapData(GRAIN_SIZE, GRAIN_SIZE, true, 0x00000000);
        grainFull = new BitmapData(GRAIN_SIZE, GRAIN_SIZE, false, 0xFF000000);
        pt2 = new Point(0, 0);
        ptZero = new Point(0, 0);
        rc = new Rectangle(0, 0, Renderer.W1, Renderer.H1);
        rc2 = new Rectangle(0, 0, Renderer.W1, Renderer.H1);
        rowRect = new Rectangle(0, 0, GRAIN_SIZE, 1);
        rowBuf = new flash.Vector<UInt>(GRAIN_SIZE, true);
        colQ = new flash.Vector<Int>(GRAIN_SIZE, true);
        lut = new flash.Vector<UInt>(LUT_N * 2, true);
        ct = new ColorTransform(1, 1, 1, 1, 0, 0, 0, 0);
        ctFrame = new ColorTransform(1, 1, 1, 1, 0, 0, 0, 0);
        ctInvert = new ColorTransform(-1, -1, -1, 1, 255, 255, 255, 0);
        blur = new BlurFilter(3, 0, 1);
        tier = -1;
        setTier(1);
        buildScanSheets();
        fillNoise(grainFull, Rng.hash2(0x5EED, 199), 255, 0);   // opaque static: built once, never per tape
        buildGrainSheets(0x5EED);
    }

    // grain alpha, tint ct, vignette variant; rebuilds the 4 grain sheets with noise(seed)
    public function buildForTape(t:Tape):Void {
        // The tape's tint is a colour cast: the multipliers are normalised to a unit mean so a tape never
        // darkens or brightens the whole picture (the shade bands are gameplay signal) — only its hue shifts.
        var m = (t.tintR + t.tintG + t.tintB) / 3.0;
        if (m < 0.5 || m > 2.0) m = 1.0;
        ct.redMultiplier = t.tintR / m; ct.greenMultiplier = t.tintG / m; ct.blueMultiplier = t.tintB / m;
        ct.redOffset = t.offR; ct.greenOffset = t.offG; ct.blueOffset = t.offB;
        grainAlpha = t.grainAlpha;
        if (grainAlpha < 8) grainAlpha = 8;
        if (grainAlpha > 96) grainAlpha = 96;
        badTape = t.badTape;
        // vignette variant: a pure function of the tape seed (same tape, same sheets)
        vigR0 = 0.52 + 0.16 * Rng.unit(Rng.hash3(t.seed, Rng.TAG_GRAIN, 1));
        vigCorner = 0.58 + 0.14 * Rng.unit(Rng.hash3(t.seed, Rng.TAG_GRAIN, 2));
        buildScanSheets();
        buildGrainSheets(Rng.hash3(t.seed, Rng.TAG_GRAIN, 3));
        pendingTear = 0;
        pendingGlitch = false;
        badRollLeft = 0;
        badRollOff = 0;
        headPhase = 0;
        flags = 0;
        rollPx = 0;
        chromaPx = 0;
        tearBands = 1;
        dread = 0.0;
    }

    public function setTier(tier:Int):Void {
        if (this.tier == tier) return;
        this.tier = tier;
        if (tier == 0) {
            w = Renderer.W0; h = Renderer.H0;
            scan = scan0; scanTight = scanTight0; scratch = scratch0; frame = frame0;
        } else {
            w = Renderer.W1; h = Renderer.H1;
            scan = scan1; scanTight = scanTight1; scratch = scratch1; frame = frame1;
        }
        // a roll offset measured in the old tier's rows is meaningless in the new one
        badRollOff = 0;
        badRollLeft = 0;
    }

    // Non-negative per-frame pseudo-random from the frame seed and a tag; no allocation, no shared state.
    static inline function rnd(seed:Int, k:Int):Int return Rng.hash2(seed, k) >>> 1;

    // the full post chain in DESIGN 3 order; reads dread/flags/rollPx/tearBands/chromaPx/flickerBrightness
    public function apply(bd:BitmapData, frameSeed:Int):Void {
        var t0 = flash.Lib.getTimer();
        // the tier follows the buffer we are handed, whatever order Main swapped things in
        if (bd.width != w || bd.height != h) setTier(bd.width <= Renderer.W0 ? 0 : 1);
        var w = this.w;
        var h = this.h;
        var frame = this.frame;
        var ptZero = this.ptZero;
        var rc = this.rc;
        var rc2 = this.rc2;
        var pt2 = this.pt2;
        var seed = frameSeed;
        var f = flags;
        var bands = tearBands;
        if (pendingTear != 0) { f |= G_TEAR; bands = pendingTear; pendingTear = 0; }
        if (pendingGlitch) { f |= G_GLITCH; pendingGlitch = false; }
        var d = dread;
        if (d < 0.0) d = 0.0;
        if (d > 1.0) d = 1.0;
        var noiseFull = (f & G_NOISE_FULL) != 0;
        var blackout = (f & G_BLACKOUT) != 0;

        if (!noiseFull) {
            // Dread-driven spontaneous degradation (DESIGN §3 triggers), odds per frame in 1/1000:
            // tears every 12-25 s at rest (3/1000 ~ 17 s at 20 fps), every 2-5 s at dread > 0.4
            // (10..25/1000), doubled on a bad tape; dropouts every 6-15 s (5/1000), more with dread.
            if ((f & G_TEAR) == 0) {
                var tearRate = d < 0.4 ? 3 : 10 + Std.int((d - 0.4) * 25.0);
                if (badTape) tearRate <<= 1;
                if (rnd(seed, 1) % 1000 < tearRate) {
                    f |= G_TEAR;
                    bands = 1 + rnd(seed, 2) % (1 + Std.int(d * 3.0));
                }
            }
            if ((f & G_DROPOUT) == 0) {
                if (rnd(seed, 3) % 1000 < 5 + Std.int(d * 10.0)) f |= G_DROPOUT;
            }
            var chroma = chromaPx;
            if ((f & G_GLITCH) != 0 && chroma == 0) chroma = 2 + Std.int(d * 3.0);
            if (chroma > 5) chroma = 5;
            if (chroma < 0) chroma = 0;

            // (1) scratch copy only when a shifted copy of the frame is needed
            if ((f & (G_TEAR | G_GLITCH)) != 0 || chroma > 0) scratch.copyPixels(bd, frame, ptZero);
            // (2) glitch: strip blur, slice offsets, inverted band, chroma
            if ((f & G_GLITCH) != 0) doGlitch(bd, seed);
            if (chroma > 0) doChroma(bd, chroma);
            // (3) tear bands
            if ((f & G_TEAR) != 0) doTear(bd, seed, bands);
            // (4) roll: the scheduled roll (chase, pit tumble) wraps into noise; a bad tape's own slow
            //     roll episodes wrap the picture itself with a noise seam, then snap back
            if ((f & G_ROLL) != 0 && rollPx != 0) doRoll(bd, rollPx, seed);
            if (badTape) {
                if (badRollLeft > 0) {
                    badRollLeft--;
                    badRollOff += badRollSpeed;
                    if (badRollOff >= h) badRollOff -= h;
                    if (badRollLeft == 0) badRollOff = 0;       // tracking catches: the picture snaps back
                } else if (rnd(seed, 7) % 1000 < 3) {
                    badRollLeft = 30 + rnd(seed, 8) % 41;       // 30..70 frames
                    badRollOff = 0;
                    badRollSpeed = 1 + (rnd(seed, 9) & 1);      // 1..2 rows per frame
                }
                if (badRollOff > 0) doRollWrap(bd, badRollOff, seed);
            }
            // (5) scanline + vignette sheet (tight variant under dread)
            bd.copyPixels(d > 0.5 ? scanTight : scan, frame, ptZero, null, null, true);
            // (6) grain window at a random offset; heavier sheet with dread; blackout = heaviest, twice
            var gi = Std.int(d * 4.0);
            if (gi > 3) gi = 3;
            if (blackout) gi = 3;
            var g = grain[gi];
            rc.x = rnd(seed, 4) % (GRAIN_SIZE - w);
            rc.y = rnd(seed, 5) % (GRAIN_SIZE - h);
            rc.width = w;
            rc.height = h;
            bd.copyPixels(g, rc, ptZero, null, null, true);
            if (blackout) {
                rc.x = rnd(seed, 15) % (GRAIN_SIZE - w);
                rc.y = rnd(seed, 16) % (GRAIN_SIZE - h);
                bd.copyPixels(g, rc, ptZero, null, null, true);
            }
        } else {
            // death: pure noise, opaque, then the scanlines so the snow still reads as the same picture
            rc.x = rnd(seed, 4) % (GRAIN_SIZE - w);
            rc.y = rnd(seed, 5) % (GRAIN_SIZE - h);
            rc.width = w;
            rc.height = h;
            bd.copyPixels(grainFull, rc, ptZero);
            bd.copyPixels(scan, frame, ptZero, null, null, true);
        }

        // (7) head-switch bar: bottom rows from the opaque noise sheet at a cycling x offset
        headPhase += 7;
        if (headPhase >= GRAIN_SIZE - w) headPhase -= GRAIN_SIZE - w;
        rc2.x = headPhase;
        rc2.y = rnd(seed, 6) % (GRAIN_SIZE - HEAD_ROWS);
        rc2.width = w;
        rc2.height = HEAD_ROWS;
        pt2.x = 0;
        pt2.y = h - HEAD_ROWS;
        bd.copyPixels(grainFull, rc2, pt2);

        // (8) dropout streaks
        if ((f & G_DROPOUT) != 0 && !noiseFull) doDropout(bd, seed);

        // (9) tint x flicker (x 0.6 on strobe frames), +/-4 brightness jitter, washed out with dread
        var b = flickerBrightness;
        if (b < 0.0) b = 0.0;
        if (b > 2.0) b = 2.0;
        if ((f & G_STROBE) != 0) b *= 0.6;
        var wash = 1.0 - d * 0.25;
        var lift = d * 24.0 + (rnd(seed, 19) % 9) - 4;
        var cf = ctFrame;
        cf.redMultiplier = ct.redMultiplier * b * wash;
        cf.greenMultiplier = ct.greenMultiplier * b * wash;
        cf.blueMultiplier = ct.blueMultiplier * b * wash;
        cf.redOffset = ct.redOffset * b + lift;
        cf.greenOffset = ct.greenOffset * b + lift;
        cf.blueOffset = ct.blueOffset * b + lift;
        bd.colorTransform(frame, cf);

        // one-shot flags are consumed; ROLL/STROBE/BLACKOUT/NOISE_FULL are state and stay with Main
        flags = flags & ~(G_TEAR | G_GLITCH | G_DROPOUT);
        tPost = flash.Lib.getTimer() - t0;
    }

    // schedule a tear for the next apply (Main calls on events)
    public function tearNow(bands:Int):Void {
        if (bands < 1) bands = 1;
        if (bands > 4) bands = 4;
        tearBands = bands;
        pendingTear = bands;
        flags |= G_TEAR;
    }

    public function glitchNow():Void {
        pendingGlitch = true;
        flags |= G_GLITCH;
    }

    // ---- effect steps (no allocation; every geometry object is a field) ----

    // one 32-row strip blurred from the scratch copy, 3-6 slice offsets, one inverted band
    function doGlitch(bd:BitmapData, seed:Int):Void {
        var w = this.w;
        var h = this.h;
        var rc2 = this.rc2;
        var pt2 = this.pt2;
        var scratch = this.scratch;
        var sy = rnd(seed, 10) % (h - STRIP_ROWS);
        rc2.x = 0; rc2.y = sy; rc2.width = w; rc2.height = STRIP_ROWS;
        pt2.x = 0; pt2.y = sy;
        bd.applyFilter(scratch, rc2, pt2, blur);
        var n = 3 + rnd(seed, 11) % 4;
        for (i in 0...n) {
            var y = rnd(seed, 20 + i) % (h - 8);
            var rows = 2 + rnd(seed, 30 + i) % 7;
            var dx = 2 + rnd(seed, 40 + i) % 15;
            if ((rnd(seed, 50 + i) & 1) == 0) { rc2.x = 0; pt2.x = dx; }
            else { rc2.x = dx; pt2.x = 0; }
            rc2.y = y; rc2.width = w - dx; rc2.height = rows;
            pt2.y = y;
            bd.copyPixels(scratch, rc2, pt2);
        }
        var by = rnd(seed, 12) % (h - 12);
        var bh = 4 + rnd(seed, 13) % 9;
        rc2.x = 0; rc2.y = by; rc2.width = w; rc2.height = bh;
        bd.colorTransform(rc2, ctInvert);
    }

    // chroma bleed: red pulled right, blue pulled left, both from the scratch copy
    function doChroma(bd:BitmapData, c:Int):Void {
        var rc2 = this.rc2;
        var pt2 = this.pt2;
        rc2.x = 0; rc2.y = 0; rc2.width = w - c; rc2.height = h;
        pt2.x = c; pt2.y = 0;
        bd.copyChannel(scratch, rc2, pt2, CH_RED, CH_RED);
        rc2.x = c;
        pt2.x = 0;
        bd.copyChannel(scratch, rc2, pt2, CH_BLUE, CH_BLUE);
    }

    // tracking tear: n bands 6-40 rows tall shifted 2-12 px either way, noise in the gap, grey edge rows
    function doTear(bd:BitmapData, seed:Int, n:Int):Void {
        var w = this.w;
        var h = this.h;
        var rc2 = this.rc2;
        var pt2 = this.pt2;
        var scratch = this.scratch;
        if (n < 1) n = 1;
        if (n > 4) n = 4;
        for (i in 0...n) {
            var bh = 6 + rnd(seed, 60 + i) % 35;
            var by = rnd(seed, 70 + i) % (h - bh);
            var dx = 2 + rnd(seed, 80 + i) % 11;
            var right = (rnd(seed, 85 + i) & 1) == 0;
            rc2.y = by; rc2.width = w - dx; rc2.height = bh;
            pt2.y = by;
            if (right) { rc2.x = 0; pt2.x = dx; } else { rc2.x = dx; pt2.x = 0; }
            bd.copyPixels(scratch, rc2, pt2);
            // the gap the shift opened, filled from the opaque noise sheet
            rc2.x = rnd(seed, 90 + i) % (GRAIN_SIZE - dx);
            rc2.y = rnd(seed, 100 + i) % (GRAIN_SIZE - bh);
            rc2.width = dx;
            pt2.x = right ? 0 : w - dx;
            bd.copyPixels(grainFull, rc2, pt2);
            rc2.x = 0; rc2.y = by; rc2.width = w; rc2.height = 2;
            bd.fillRect(rc2, 0xFF6C6C6C);
            rc2.y = by + bh - 2;
            bd.fillRect(rc2, 0xFF383838);
        }
    }

    // vertical roll: scroll the frame and fill the wrap band from the noise sheet, with a dark bar at the seam
    function doRoll(bd:BitmapData, k:Int, seed:Int):Void {
        var w = this.w;
        var h = this.h;
        var rc2 = this.rc2;
        var pt2 = this.pt2;
        if (k > h - 1) k = h - 1;
        if (k < 1 - h) k = 1 - h;
        bd.scroll(0, k);
        var band = k > 0 ? k : -k;
        var top = k > 0 ? 0 : h - band;
        rc2.x = rnd(seed, 17) % (GRAIN_SIZE - w);
        rc2.y = rnd(seed, 18) % (GRAIN_SIZE - band);
        rc2.width = w;
        rc2.height = band;
        pt2.x = 0;
        pt2.y = top;
        bd.copyPixels(grainFull, rc2, pt2);
        rc2.x = 0;
        rc2.width = w;
        rc2.height = 2;
        rc2.y = k > 0 ? band - 2 : top;
        if (rc2.y < 0) rc2.y = 0;
        bd.fillRect(rc2, 0xFF101010);
    }

    // bad-tape roll: the picture itself wraps (bottom k rows reappear at the top) with a noise seam.
    // Three band ops: park the bottom rows in the scratch, scroll, restore them at the top.
    function doRollWrap(bd:BitmapData, k:Int, seed:Int):Void {
        var w = this.w;
        var h = this.h;
        var rc2 = this.rc2;
        var pt2 = this.pt2;
        var scratch = this.scratch;
        if (k > h - 1) k = h - 1;
        if (k < 1) return;
        rc2.x = 0; rc2.y = h - k; rc2.width = w; rc2.height = k;
        pt2.x = 0; pt2.y = h - k;
        scratch.copyPixels(bd, rc2, pt2);
        bd.scroll(0, k);
        pt2.y = 0;
        bd.copyPixels(scratch, rc2, pt2);
        var seam = k < SEAM_ROWS ? k : SEAM_ROWS;
        rc2.x = rnd(seed, 17) % (GRAIN_SIZE - w);
        rc2.y = rnd(seed, 18) % (GRAIN_SIZE - seam);
        rc2.height = seam;
        pt2.y = k - seam;
        bd.copyPixels(grainFull, rc2, pt2);
    }

    // 1-3 near-white streaks, 1-2 rows tall, 16-115 px long
    function doDropout(bd:BitmapData, seed:Int):Void {
        var w = this.w;
        var h = this.h;
        var rc2 = this.rc2;
        var n = 1 + rnd(seed, 14) % 3;
        for (i in 0...n) {
            var y = rnd(seed, 110 + i) % (h - 2);
            var rows = 1 + (rnd(seed, 120 + i) & 1);
            var len = 16 + rnd(seed, 130 + i) % 100;
            var x = rnd(seed, 140 + i) % (w - 16);
            if (x + len > w) len = w - x;
            rc2.x = x; rc2.y = y; rc2.width = len; rc2.height = rows;
            bd.fillRect(rc2, 0xFFF2F2F2);
        }
    }

    // ---- sheet building (constructor and buildForTape only; allocates nothing, may use Float outside the pixel loops) ----

    function buildScanSheets():Void {
        fillScan(scan0, Renderer.W0, Renderer.H0, vigR0, vigCorner);
        fillScan(scan1, Renderer.W1, Renderer.H1, vigR0, vigCorner);
        fillScan(scanTight0, Renderer.W0, Renderer.H0, vigR0 * 0.85, vigCorner + 0.08);
        fillScan(scanTight1, Renderer.W1, Renderer.H1, vigR0 * 0.85, vigCorner + 0.08);
    }

    // Odd rows black at SCAN_ALPHA; vignette rising from radius r0 (normalised, 1 = mid-edge) to `corner` at the corners.
    // The alpha curve over the squared radius q = nx^2 + ny^2 (0..2) is tabulated once per sheet into `lut`
    // (two tables: even rows, odd rows), so the pixel loop is one add, one shift and one table read.
    function fillScan(s:BitmapData, W:Int, H:Int, r0:Float, corner:Float):Void {
        var buf = rowBuf;
        var rr = rowRect;
        var cq = colQ;
        var lut = this.lut;
        rr.x = 0; rr.width = W; rr.height = 1;
        var r0sq = r0 * r0;
        var span = 2.0 - r0sq;
        if (span < 0.05) span = 0.05;
        if (corner > 0.9) corner = 0.9;
        var scanA = SCAN_ALPHA / 255.0;
        for (i in 0...LUT_N) {
            var v = (i / 256.0 - r0sq) / span;
            if (v < 0.0) v = 0.0;
            if (v > 1.0) v = 1.0;
            var vig = corner * v * (0.5 + 0.5 * v);
            var a0 = Std.int(vig * 255.0 + 0.5);
            var a1 = Std.int((1.0 - (1.0 - scanA) * (1.0 - vig)) * 255.0 + 0.5);
            if (a0 > 255) a0 = 255;
            if (a1 > 255) a1 = 255;
            lut[i] = a0 << 24;
            lut[LUT_N + i] = a1 << 24;
        }
        var cx = W * 0.5;
        for (x in 0...W) {
            var nx = (x + 0.5 - cx) / cx;
            cq[x] = Std.int(nx * nx * 256.0);
        }
        var cy = H * 0.5;
        s.lock();
        for (y in 0...H) {
            var ny = (y + 0.5 - cy) / cy;
            var rq = Std.int(ny * ny * 256.0);
            var base = (y & 1) == 1 ? LUT_N : 0;
            for (x in 0...W) {
                var q = cq[x] + rq;
                if (q >= LUT_N) q = LUT_N - 1;
                buf[x] = lut[base + q];
            }
            rr.y = y;
            s.setVector(rr, buf);
        }
        s.unlock();
    }

    // 4 grey noise sheets of rising alpha (sheet 0 = the tape's grainAlpha, sheet 3 ~3.25x), each from noise(seed).
    // Generated in-process (xorshift, seeded) so the same tape gives the same grain in Flash and in Ruffle.
    function buildGrainSheets(seed:Int):Void {
        for (i in 0...GRAIN_SHEETS) {
            var a = (grainAlpha * (4 + i * 3)) >> 2;
            if (a > 200) a = 200;
            fillNoise(grain[i], Rng.hash2(seed, 100 + i), a, 8);
        }
    }

    // GRAIN_SIZE^2 grey noise, alpha = base +/- spread (per pixel), lightly streaked horizontally like tape grain
    function fillNoise(s:BitmapData, seed:Int, base:Int, spread:Int):Void {
        var buf = rowBuf;
        var rr = rowRect;
        rr.x = 0; rr.width = GRAIN_SIZE; rr.height = 1;
        var x = Rng.mix(seed);
        if (x == 0) x = 0x9E3779B9;
        var n = GRAIN_SIZE;
        var lo = base - spread;
        var hi = base + spread;
        if (lo < 0) lo = 0;
        if (hi > 255) hi = 255;
        var mod = hi - lo + 1;
        s.lock();
        for (y in 0...n) {
            var prev = 128;
            for (i in 0...n) {
                x ^= x << 13; x ^= x >>> 17; x ^= x << 5;
                var g = (x >>> 24) & 255;
                var gs = (g + prev) >> 1;
                prev = g;
                var a = lo + ((x >>> 8) & 0xFFFF) % mod;
                buf[i] = (a << 24) | (gs << 16) | (gs << 8) | gs;
            }
            rr.y = y;
            s.setVector(rr, buf);
        }
        s.unlock();
    }
}
