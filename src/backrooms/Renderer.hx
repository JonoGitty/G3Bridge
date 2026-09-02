// Walls, floor and ceiling into a Vector.<uint> frame buffer (CONTRACT §2, DESIGN §1). fp class.
//
// Order per frame: walls first (one contiguous texel column per ray from the pre-shaded
// bank, written to x and x+1 from one fetch at the 2-px rungs), which also records per
// screen column where the wall starts and ends; then the ceiling rows above and the
// floor rows below. A row is a straight 16.16 walk in world coordinates relative to
// the camera cell (so the numbers stay small whatever the world coordinates are), in
// 8-px spans: each span re-reads the cell under it once (World's last-chunk cache) and
// switches texture there; the span's visibility against the walls is decided once from
// four per-span tables (min/max wall start/end over its 8 columns), so a span is either
// walked unbranched, skipped whole, or - only at a wall edge - tested per pixel. There is
// no overdraw and no per-pixel wall test away from edges.
//
// F2 walks every pixel, F1 every second pixel of every second row as 2x2 blocks (the
// check every 4 blocks), F0 fills each row with a per-band mean colour from the texture
// bank (a moving sine light band on the ceiling), with the same 8-px cell override on
// floor rows nearer than 6 cells. Rows at band 15 are filled black without a lookup.
//
// Allocation: everything is built in the constructor for BOTH tiers; setTier swaps
// references; render/present/presentStrip allocate nothing. Float appears only per
// column (the wall height) and per row (the walk start and step), never per pixel.
import flash.display.BitmapData;
import flash.geom.Rectangle;

class Renderer {
    public static inline var W1 = 320; public static inline var H1 = 240;
    public static inline var W0 = 256; public static inline var H0 = 192;
    static inline var ONE = 65536;                      // Cells.ONE
    static inline var TEX_ONE = 4194304;                // 64 << 16: one texture column in 16.16 texels
    static inline var BLACK:UInt = 0xFF000000;
    static inline var SPAN = 8;                         // the span rule: one cell read per 8 px
    static inline var F0_NEAR = 393216;                 // 6 << 16: F0 applies its cell override on rows nearer than this
    static inline var INV_ONE = 1.0 / 65536.0;

    public var w:Int;
    public var h:Int;
    public var tier:Int;
    public var fb:flash.Vector<UInt>;                   // current tier's buffer, length w*h, fixed; index = y*w + x
    public var bd:BitmapData;                           // current tier's BitmapData (opaque, transparent = false)
    public var rect:Rectangle;                          // (0,0,w,h) for the current tier
    public var colShift:Int;                            // 0 when hits.count == w, 1 when hits.count == w/2 (2-px columns)
    public var textures:Textures;
    public static inline var STRIP_H = 8;
    public var strip:flash.Vector<UInt>;                // current tier's w*STRIP_H opaque OSD strip (both tiers preallocated); Hud.drawStrip writes it
    public var stripRect:Rectangle;                     // (0, y, w, STRIP_H), reused
    public var vignetteBias:flash.Vector<Int>;          // per column 0..2, rebuilt in setTier
    public var rowBand:flash.Vector<Int>;               // per row base band for floor/ceiling (distance-based), rebuilt in setTier
    public var rowDist:flash.Vector<Int>;               // 16.16 depth per row
    public var wallBand:flash.Vector<Int>;              // per column band used for the wall this frame (SpritePass reads it to keep the Watcher darker)
    public var tRay:Int; public var tWall:Int; public var tFloor:Int;   // getTimer brackets, ms, for telemetry (written by render)

    // per-tier storage
    var fb0:flash.Vector<UInt>; var fb1:flash.Vector<UInt>;
    var bd0:BitmapData; var bd1:BitmapData;
    var rect0:Rectangle; var rect1:Rectangle;
    var strip0:flash.Vector<UInt>; var strip1:flash.Vector<UInt>;
    var stripRect0:Rectangle; var stripRect1:Rectangle;
    var vignetteBias0:flash.Vector<Int>; var vignetteBias1:flash.Vector<Int>;
    var rowBand0:flash.Vector<Int>; var rowBand1:flash.Vector<Int>;
    var rowDist0:flash.Vector<Int>; var rowDist1:flash.Vector<Int>;
    var wallBand0:flash.Vector<Int>; var wallBand1:flash.Vector<Int>;
    var dStart0:flash.Vector<Int>; var dStart1:flash.Vector<Int>;   // per screen column: first wall row (ceiling ends here)
    var dEnd0:flash.Vector<Int>; var dEnd1:flash.Vector<Int>;       // per screen column: one past the last wall row (floor starts here)
    var spSMin0:flash.Vector<Int>; var spSMin1:flash.Vector<Int>;   // per 8-px span: min/max of dStart and dEnd over the span
    var spSMax0:flash.Vector<Int>; var spSMax1:flash.Vector<Int>;
    var spEMin0:flash.Vector<Int>; var spEMin1:flash.Vector<Int>;
    var spEMax0:flash.Vector<Int>; var spEMax1:flash.Vector<Int>;
    // current tier's views of the above
    var dStart:flash.Vector<Int>;
    var dEnd:flash.Vector<Int>;
    var spSMin:flash.Vector<Int>;
    var spSMax:flash.Vector<Int>;
    var spEMin:flash.Vector<Int>;
    var spEMax:flash.Vector<Int>;
    var sineLift:flash.Vector<Int>;                     // 64-entry 0..2 band lift for the F0 ceiling light band
    var frameCounter:Int;                               // phase of the F0 light band

    // allocates BOTH tiers' fb + bd up front
    public function new(textures:Textures):Void {
        this.textures = textures;
        fb0 = new flash.Vector<UInt>(W0 * H0, true);
        fb1 = new flash.Vector<UInt>(W1 * H1, true);
        bd0 = new BitmapData(W0, H0, false, 0xFF000000);
        bd1 = new BitmapData(W1, H1, false, 0xFF000000);
        rect0 = new Rectangle(0, 0, W0, H0);
        rect1 = new Rectangle(0, 0, W1, H1);
        strip0 = new flash.Vector<UInt>(W0 * STRIP_H, true);
        strip1 = new flash.Vector<UInt>(W1 * STRIP_H, true);
        stripRect0 = new Rectangle(0, 0, W0, STRIP_H);
        stripRect1 = new Rectangle(0, 0, W1, STRIP_H);
        vignetteBias0 = new flash.Vector<Int>(W0, true);
        vignetteBias1 = new flash.Vector<Int>(W1, true);
        wallBand0 = new flash.Vector<Int>(W0, true);
        wallBand1 = new flash.Vector<Int>(W1, true);
        rowBand0 = new flash.Vector<Int>(H0, true);
        rowBand1 = new flash.Vector<Int>(H1, true);
        rowDist0 = new flash.Vector<Int>(H0, true);
        rowDist1 = new flash.Vector<Int>(H1, true);
        dStart0 = new flash.Vector<Int>(W0, true);
        dStart1 = new flash.Vector<Int>(W1, true);
        dEnd0 = new flash.Vector<Int>(W0, true);
        dEnd1 = new flash.Vector<Int>(W1, true);
        spSMin0 = new flash.Vector<Int>(W0 >> 3, true);
        spSMin1 = new flash.Vector<Int>(W1 >> 3, true);
        spSMax0 = new flash.Vector<Int>(W0 >> 3, true);
        spSMax1 = new flash.Vector<Int>(W1 >> 3, true);
        spEMin0 = new flash.Vector<Int>(W0 >> 3, true);
        spEMin1 = new flash.Vector<Int>(W1 >> 3, true);
        spEMax0 = new flash.Vector<Int>(W0 >> 3, true);
        spEMax1 = new flash.Vector<Int>(W1 >> 3, true);
        sineLift = new flash.Vector<Int>(64, true);
        for (i in 0...64) sineLift[i] = Std.int((Math.sin(i * Math.PI / 32.0) + 1.0) * 1.25);   // 0..2, a soft bump
        for (i in 0...(W0 * H0)) fb0[i] = BLACK;
        for (i in 0...(W1 * H1)) fb1[i] = BLACK;
        for (i in 0...(W0 * STRIP_H)) strip0[i] = BLACK;
        for (i in 0...(W1 * STRIP_H)) strip1[i] = BLACK;
        buildTables(W0, H0, rowDist0, rowBand0, vignetteBias0, wallBand0, dStart0, dEnd0);
        buildTables(W1, H1, rowDist1, rowBand1, vignetteBias1, wallBand1, dStart1, dEnd1);
        colShift = 0;
        tRay = 0; tWall = 0; tFloor = 0;
        frameCounter = 0;
        tier = -1;
        setTier(1);
    }

    // Row depth (eye at half height, walls one cell high: depth = (h/2) / |y - h/2|), row band, vignette columns. Once per tier.
    function buildTables(tw:Int, th:Int, rd:flash.Vector<Int>, rb:flash.Vector<Int>, vig:flash.Vector<Int>, wb:flash.Vector<Int>, ds:flash.Vector<Int>, de:flash.Vector<Int>):Void {
        var half = th >> 1;
        for (y in 0...th) {
            var p = y - half;
            if (p < 0) p = -p;
            var d = p == 0 ? ONE * Raycaster.MAX_DIST : Std.int((half * 65536.0) / p);
            rd[y] = d;
            var b = bandOf(d);
            if (b > 15) b = 15;
            if (b < 0) b = 0;
            rb[y] = b;
        }
        var hw = tw >> 1;
        for (x in 0...tw) {
            var dx = x < hw ? hw - x : x - hw;                // 0..hw
            var k = Std.int((dx * 16) / hw);                  // 0..16
            vig[x] = k >= 14 ? 2 : (k >= 10 ? 1 : 0);         // outer 12.5% +2, next 25% +1
            wb[x] = 15;
            ds[x] = half;
            de[x] = half;
        }
    }

    // index swap only
    public function setTier(t:Int):Void {
        tier = t;
        if (t == 0) {
            w = W0; h = H0; fb = fb0; bd = bd0; rect = rect0; strip = strip0; stripRect = stripRect0;
            vignetteBias = vignetteBias0; rowBand = rowBand0; rowDist = rowDist0; wallBand = wallBand0;
            dStart = dStart0; dEnd = dEnd0; spSMin = spSMin0; spSMax = spSMax0; spEMin = spEMin0; spEMax = spEMax0;
        } else {
            w = W1; h = H1; fb = fb1; bd = bd1; rect = rect1; strip = strip1; stripRect = stripRect1;
            vignetteBias = vignetteBias1; rowBand = rowBand1; rowDist = rowDist1; wallBand = wallBand1;
            dStart = dStart1; dEnd = dEnd1; spSMin = spSMin1; spSMax = spSMax1; spEMin = spEMin1; spEMax = spEMax1;
        }
    }

    // Draws walls, floor and ceiling into fb from hits. lightOffset 0..15; floorMode 0/1/2; camera (px,py,ang) and ray dir tables from rc.
    public function render(hits:RayHits, rc:Raycaster, px:Float, py:Float, lightOffset:Int, floorMode:Int, world:World):Void {
        colShift = hits.count == w ? 0 : 1;
        if (lightOffset < 0) lightOffset = 0;
        if (lightOffset > 15) lightOffset = 15;
        var t0 = flash.Lib.getTimer();
        drawWalls(hits, lightOffset);
        var t1 = flash.Lib.getTimer();
        tWall = t1 - t0;
        if (floorMode <= 0) drawF0(hits, rc, px, py, lightOffset, world);
        else if (floorMode == 1) drawF1(hits, rc, px, py, lightOffset, world);
        else drawF2(hits, rc, px, py, lightOffset, world);
        tFloor = flash.Lib.getTimer() - t1;
        frameCounter++;
    }

    // ---------------------------------------------------------------- walls

    // One texel column per ray; records dStart/dEnd/wallBand per screen column and the per-span min/max tables.
    function drawWalls(hits:RayHits, lo:Int):Void {
        var w = this.w;
        var h = this.h;
        var fb = this.fb;
        var bank = textures.bank;
        var hDist = hits.dist;
        var hTex = hits.texX;
        var hSide = hits.side;
        var hCell = hits.cell;
        var vig = vignetteBias;
        var wb = wallBand;
        var dS = dStart;
        var dE = dEnd;
        var n = hits.count;
        var cs = colShift;
        var hOne = h * 65536.0;
        var half = h >> 1;
        var x = 0;
        if (cs == 0) {
            for (i in 0...n) {
                if (x >= w) break;
                var dist = hDist[i];
                var band = ((dist * 5) >> 18) + lo + hSide[i] + vig[x];
                if (band > 15) band = 15;
                var lineH = Std.int(hOne / dist);
                if (lineH < 1) lineH = 1;
                var ds = (h - lineH) >> 1;
                var de = ds + lineH;
                var step = Std.int(TEX_ONE / lineH);
                var ty = 0;
                if (ds < 0) { ty = (-ds) * step; ds = 0; }
                if (de > h) de = h;
                var tex = bank[Textures.wallId(hCell[i])];
                var tb = (band << Textures.BAND_SHIFT) | (hTex[i] << 6);
                var idx = ds * w + x;
                for (y in ds...de) {
                    fb[idx] = tex[tb + (ty >> 16)];
                    idx += w;
                    ty += step;
                }
                wb[x] = band; dS[x] = ds; dE[x] = de;
                x++;
            }
        } else {
            for (i in 0...n) {
                if (x + 1 >= w) break;
                var dist = hDist[i];
                var band = ((dist * 5) >> 18) + lo + hSide[i] + vig[x];
                if (band > 15) band = 15;
                var lineH = Std.int(hOne / dist);
                if (lineH < 1) lineH = 1;
                var ds = (h - lineH) >> 1;
                var de = ds + lineH;
                var step = Std.int(TEX_ONE / lineH);
                var ty = 0;
                if (ds < 0) { ty = (-ds) * step; ds = 0; }
                if (de > h) de = h;
                var tex = bank[Textures.wallId(hCell[i])];
                var tb = (band << Textures.BAND_SHIFT) | (hTex[i] << 6);
                var idx = ds * w + x;
                for (y in ds...de) {
                    var c = tex[tb + (ty >> 16)];
                    fb[idx] = c;
                    fb[idx + 1] = c;
                    idx += w;
                    ty += step;
                }
                wb[x] = band; wb[x + 1] = band;
                dS[x] = ds; dS[x + 1] = ds;
                dE[x] = de; dE[x + 1] = de;
                x += 2;
            }
        }
        // columns without a ray (never in practice): black wall row at the horizon, nothing else drawn there
        while (x < w) {
            fb[half * w + x] = BLACK;
            wb[x] = 15; dS[x] = half; dE[x] = half + 1;
            x++;
        }
        // per-span visibility tables
        var sMin = spSMin; var sMax = spSMax; var eMin = spEMin; var eMax = spEMax;
        var ng = w >> 3;
        x = 0;
        for (g in 0...ng) {
            var a0 = h; var a1 = 0; var b0 = h; var b1 = 0;
            for (k in 0...SPAN) {
                var a = dS[x]; var b = dE[x];
                if (a < a0) a0 = a;
                if (a > a1) a1 = a;
                if (b < b0) b0 = b;
                if (b > b1) b1 = b;
                x++;
            }
            sMin[g] = a0; sMax[g] = a1; eMin[g] = b0; eMax[g] = b1;
        }
    }

    // ---------------------------------------------------------------- F2: every pixel

    function drawF2(hits:RayHits, rc:Raycaster, px:Float, py:Float, lo:Int, world:World):Void {
        var n = hits.count;
        if (n < 2) return;
        var w = this.w;
        var h = this.h;
        var fb = this.fb;
        var bank = textures.bank;
        var rd = rowDist;
        var rb = rowBand;
        var dS = dStart;
        var dE = dEnd;
        var sMin = spSMin; var sMax = spSMax; var eMin = spEMin; var eMax = spEMax;
        var half = h >> 1;
        var ng = w >> 3;
        // camera cell and the fraction inside it: the walk is relative to the cell so 16.16 never overflows
        var cx0 = Std.int(px); if (px < cx0) cx0--;
        var cy0 = Std.int(py); if (py < cy0) cy0--;
        var fracX = px - cx0;
        var fracY = py - cy0;
        var rdx = rc.dirX; var rdy = rc.dirY;
        var dx0 = rdx[0]; var dy0 = rdy[0];
        var pxStep = 1.0 / ((n - 1) << colShift);                       // ray-table steps per screen pixel
        var ddx = (rdx[n - 1] - dx0) * pxStep;
        var ddy = (rdy[n - 1] - dy0) * pxStep;

        // ceiling rows 0 .. half-1: visible where y < dStart[x]
        for (y in 0...half) {
            var band = rb[y] + lo;
            if (band > 15) band = 15;
            var idx = y * w;
            if (band == 15) {
                var x = 0;
                for (g in 0...ng) {
                    if (y < sMin[g]) { for (k in 0...SPAN) { fb[idx] = BLACK; idx++; } }
                    else if (y >= sMax[g]) idx += SPAN;
                    else { for (k in 0...SPAN) { if (y < dS[x + k]) fb[idx] = BLACK; idx++; } }
                    x += SPAN;
                }
                continue;
            }
            var fd = rd[y] * INV_ONE;
            var fx = Std.int((fracX + fd * dx0) * 65536.0);
            var fy = Std.int((fracY + fd * dy0) * 65536.0);
            var sx = Std.int(fd * ddx * 65536.0);
            var sy = Std.int(fd * ddy * 65536.0);
            var bb = band << Textures.BAND_SHIFT;
            var x = 0;
            for (g in 0...ng) {
                if (y < sMin[g]) {
                    var tex = bank[Textures.ceilId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    for (k in 0...SPAN) {
                        fb[idx] = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                        fx += sx; fy += sy; idx++;
                    }
                } else if (y >= sMax[g]) {
                    fx += sx << 3; fy += sy << 3; idx += SPAN;
                } else {
                    var tex = bank[Textures.ceilId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    for (k in 0...SPAN) {
                        if (y < dS[x + k]) fb[idx] = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                        fx += sx; fy += sy; idx++;
                    }
                }
                x += SPAN;
            }
        }

        // floor rows half+1 .. h-1: visible where y >= dEnd[x]
        for (y in (half + 1)...h) {
            var band = rb[y] + lo;
            if (band > 15) band = 15;
            var idx = y * w;
            if (band == 15) {
                var x = 0;
                for (g in 0...ng) {
                    if (y >= eMax[g]) { for (k in 0...SPAN) { fb[idx] = BLACK; idx++; } }
                    else if (y < eMin[g]) idx += SPAN;
                    else { for (k in 0...SPAN) { if (y >= dE[x + k]) fb[idx] = BLACK; idx++; } }
                    x += SPAN;
                }
                continue;
            }
            var fd = rd[y] * INV_ONE;
            var fx = Std.int((fracX + fd * dx0) * 65536.0);
            var fy = Std.int((fracY + fd * dy0) * 65536.0);
            var sx = Std.int(fd * ddx * 65536.0);
            var sy = Std.int(fd * ddy * 65536.0);
            var bb = band << Textures.BAND_SHIFT;
            var x = 0;
            for (g in 0...ng) {
                if (y >= eMax[g]) {
                    var tex = bank[Textures.floorId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    for (k in 0...SPAN) {
                        fb[idx] = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                        fx += sx; fy += sy; idx++;
                    }
                } else if (y < eMin[g]) {
                    fx += sx << 3; fy += sy << 3; idx += SPAN;
                } else {
                    var tex = bank[Textures.floorId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    for (k in 0...SPAN) {
                        if (y >= dE[x + k]) fb[idx] = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                        fx += sx; fy += sy; idx++;
                    }
                }
                x += SPAN;
            }
        }
    }

    // ---------------------------------------------------------------- F1: 2x2 blocks

    // Every second pixel of every second row, written as 2x2 blocks sampled at the block's top-left; the cell check every 4 blocks.
    function drawF1(hits:RayHits, rc:Raycaster, px:Float, py:Float, lo:Int, world:World):Void {
        var n = hits.count;
        if (n < 2) return;
        var w = this.w;
        var h = this.h;
        var fb = this.fb;
        var bank = textures.bank;
        var rd = rowDist;
        var rb = rowBand;
        var dS = dStart;
        var dE = dEnd;
        var sMin = spSMin; var sMax = spSMax; var eMin = spEMin; var eMax = spEMax;
        var half = h >> 1;
        var ng = w >> 3;
        var cx0 = Std.int(px); if (px < cx0) cx0--;
        var cy0 = Std.int(py); if (py < cy0) cy0--;
        var fracX = px - cx0;
        var fracY = py - cy0;
        var rdx = rc.dirX; var rdy = rc.dirY;
        var dx0 = rdx[0]; var dy0 = rdy[0];
        var pxStep = 1.0 / ((n - 1) << colShift);
        var ddx = (rdx[n - 1] - dx0) * pxStep;
        var ddy = (rdy[n - 1] - dy0) * pxStep;

        // ceiling: row pairs (y, y+1) for y = 0, 2, .. < half (half is even for both tiers); visible where y < dStart[x]
        var y = 0;
        while (y < half) {
            var y1 = y + 1;
            var band = rb[y] + lo;
            if (band > 15) band = 15;
            var idx = y * w;
            if (band == 15) {
                var x = 0;
                for (g in 0...ng) {
                    if (y1 < sMin[g]) { for (k in 0...SPAN) { fb[idx] = BLACK; fb[idx + w] = BLACK; idx++; } }
                    else if (y >= sMax[g]) idx += SPAN;
                    else {
                        for (k in 0...SPAN) {
                            var s = dS[x + k];
                            if (y < s) fb[idx] = BLACK;
                            if (y1 < s) fb[idx + w] = BLACK;
                            idx++;
                        }
                    }
                    x += SPAN;
                }
                y += 2;
                continue;
            }
            var fd = rd[y] * INV_ONE;
            var fx = Std.int((fracX + fd * dx0) * 65536.0);
            var fy = Std.int((fracY + fd * dy0) * 65536.0);
            var sx = Std.int(fd * ddx * 131072.0);                     // per block (2 px)
            var sy = Std.int(fd * ddy * 131072.0);
            var bb = band << Textures.BAND_SHIFT;
            var x = 0;
            for (g in 0...ng) {
                if (y1 < sMin[g]) {
                    var tex = bank[Textures.ceilId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    for (k in 0...4) {
                        var c = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                        fb[idx] = c; fb[idx + 1] = c; fb[idx + w] = c; fb[idx + w + 1] = c;
                        fx += sx; fy += sy; idx += 2;
                    }
                } else if (y >= sMax[g]) {
                    fx += sx << 2; fy += sy << 2; idx += SPAN;
                } else {
                    var tex = bank[Textures.ceilId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    var xx = x;
                    for (k in 0...4) {
                        var c = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                        var s0 = dS[xx]; var s1 = dS[xx + 1];
                        if (y < s0) fb[idx] = c;
                        if (y < s1) fb[idx + 1] = c;
                        if (y1 < s0) fb[idx + w] = c;
                        if (y1 < s1) fb[idx + w + 1] = c;
                        fx += sx; fy += sy; idx += 2; xx += 2;
                    }
                }
                x += SPAN;
            }
            y += 2;
        }

        // floor: row pairs from half+1; the last row is a single when the count is odd; visible where y >= dEnd[x]
        y = half + 1;
        while (y < h) {
            var y1 = y + 1;
            var two = y1 < h;
            var band = rb[y] + lo;
            if (band > 15) band = 15;
            var idx = y * w;
            if (band == 15) {
                var x = 0;
                for (g in 0...ng) {
                    if (y >= eMax[g]) {
                        if (two) { for (k in 0...SPAN) { fb[idx] = BLACK; fb[idx + w] = BLACK; idx++; } }
                        else { for (k in 0...SPAN) { fb[idx] = BLACK; idx++; } }
                    }
                    else if (y1 < eMin[g]) idx += SPAN;
                    else {
                        for (k in 0...SPAN) {
                            var e = dE[x + k];
                            if (y >= e) fb[idx] = BLACK;
                            if (two && y1 >= e) fb[idx + w] = BLACK;
                            idx++;
                        }
                    }
                    x += SPAN;
                }
                y += 2;
                continue;
            }
            var fd = rd[y] * INV_ONE;
            var fx = Std.int((fracX + fd * dx0) * 65536.0);
            var fy = Std.int((fracY + fd * dy0) * 65536.0);
            var sx = Std.int(fd * ddx * 131072.0);
            var sy = Std.int(fd * ddy * 131072.0);
            var bb = band << Textures.BAND_SHIFT;
            var x = 0;
            for (g in 0...ng) {
                if (y >= eMax[g]) {
                    var tex = bank[Textures.floorId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    if (two) {
                        for (k in 0...4) {
                            var c = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                            fb[idx] = c; fb[idx + 1] = c; fb[idx + w] = c; fb[idx + w + 1] = c;
                            fx += sx; fy += sy; idx += 2;
                        }
                    } else {
                        for (k in 0...4) {
                            var c = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                            fb[idx] = c; fb[idx + 1] = c;
                            fx += sx; fy += sy; idx += 2;
                        }
                    }
                } else if (y1 < eMin[g]) {
                    fx += sx << 2; fy += sy << 2; idx += SPAN;
                } else {
                    var tex = bank[Textures.floorId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16)))];
                    var xx = x;
                    for (k in 0...4) {
                        var c = tex[bb | (((fx >> 10) & 63) << 6) | ((fy >> 10) & 63)];
                        var e0 = dE[xx]; var e1 = dE[xx + 1];
                        if (y >= e0) fb[idx] = c;
                        if (y >= e1) fb[idx + 1] = c;
                        if (two) {
                            if (y1 >= e0) fb[idx + w] = c;
                            if (y1 >= e1) fb[idx + w + 1] = c;
                        }
                        fx += sx; fy += sy; idx += 2; xx += 2;
                    }
                }
                x += SPAN;
            }
            y += 2;
        }
    }

    // ---------------------------------------------------------------- F0: flat rows

    // Per-row solid colours (the texture's per-band mean), a moving sine light band on the ceiling, and the 8-px cell override on floor rows nearer than 6 cells.
    function drawF0(hits:RayHits, rc:Raycaster, px:Float, py:Float, lo:Int, world:World):Void {
        var w = this.w;
        var h = this.h;
        var fb = this.fb;
        var avg = textures.avgCol;
        var rd = rowDist;
        var rb = rowBand;
        var dS = dStart;
        var dE = dEnd;
        var sMin = spSMin; var sMax = spSMax; var eMin = spEMin; var eMax = spEMax;
        var lift = sineLift;
        var phase = frameCounter;
        var half = h >> 1;
        var ng = w >> 3;
        var ceilBase = Textures.T_CEIL << 4;
        var carpetBase = Textures.T_CARPET << 4;

        // ceiling: visible where y < dStart[x]
        for (y in 0...half) {
            var band = rb[y] - lift[((y << 1) + phase) & 63];
            if (band < 0) band = 0;
            band += lo;
            if (band > 15) band = 15;
            var col = avg[ceilBase | band];
            var idx = y * w;
            var x = 0;
            for (g in 0...ng) {
                if (y < sMin[g]) { for (k in 0...SPAN) { fb[idx] = col; idx++; } }
                else if (y >= sMax[g]) idx += SPAN;
                else { for (k in 0...SPAN) { if (y < dS[x + k]) fb[idx] = col; idx++; } }
                x += SPAN;
            }
        }

        // floor: visible where y >= dEnd[x]; near rows re-read the cell every 8 px for WET / PIT / RIM / DARK
        var n = hits.count;
        var walk = n >= 2;
        var cx0 = 0; var cy0 = 0; var fracX = 0.0; var fracY = 0.0;
        var dx0 = 0.0; var dy0 = 0.0; var ddx = 0.0; var ddy = 0.0;
        if (walk) {
            cx0 = Std.int(px); if (px < cx0) cx0--;
            cy0 = Std.int(py); if (py < cy0) cy0--;
            fracX = px - cx0;
            fracY = py - cy0;
            var rdx = rc.dirX; var rdy = rc.dirY;
            dx0 = rdx[0]; dy0 = rdy[0];
            var pxStep = 1.0 / ((n - 1) << colShift);
            ddx = (rdx[n - 1] - dx0) * pxStep;
            ddy = (rdy[n - 1] - dy0) * pxStep;
        }
        for (y in (half + 1)...h) {
            var band = rb[y] + lo;
            if (band > 15) band = 15;
            var idx = y * w;
            var x = 0;
            var d = rd[y];
            if (walk && band < 15 && d <= F0_NEAR) {
                var fd = d * INV_ONE;
                var fx = Std.int((fracX + fd * dx0) * 65536.0);
                var fy = Std.int((fracY + fd * dy0) * 65536.0);
                var sx = Std.int(fd * ddx * 524288.0);                 // per span (8 px)
                var sy = Std.int(fd * ddy * 524288.0);
                for (g in 0...ng) {
                    if (y >= eMax[g]) {
                        var col = avg[(Textures.floorId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16))) << 4) | band];
                        for (k in 0...SPAN) { fb[idx] = col; idx++; }
                    } else if (y < eMin[g]) {
                        idx += SPAN;
                    } else {
                        var col = avg[(Textures.floorId(world.cell(cx0 + (fx >> 16), cy0 + (fy >> 16))) << 4) | band];
                        for (k in 0...SPAN) { if (y >= dE[x + k]) fb[idx] = col; idx++; }
                    }
                    fx += sx; fy += sy;
                    x += SPAN;
                }
            } else {
                var col = avg[carpetBase | band];
                for (g in 0...ng) {
                    if (y >= eMax[g]) { for (k in 0...SPAN) { fb[idx] = col; idx++; } }
                    else if (y < eMin[g]) idx += SPAN;
                    else { for (k in 0...SPAN) { if (y >= dE[x + k]) fb[idx] = col; idx++; } }
                    x += SPAN;
                }
            }
        }
    }

    // bd.setVector(rect, fb) — the whole frame; NEVER called in ST_MAP (it would overwrite the composed map with the stale fb)
    public function present():Void {
        bd.setVector(rect, fb);
    }

    // bd.setVector(stripRect at row y, strip): the ST_MAP OSD bar straight into bd; fb untouched, no allocation
    public function presentStrip(y:Int):Void {
        stripRect.y = y;
        bd.setVector(stripRect, strip);
    }

    // (dist * 5) >> 18 — the distance part of the shade band, exposed for the contract's unit table
    public static inline function bandOf(dist:Int):Int return (dist * 5) >> 18;
}
