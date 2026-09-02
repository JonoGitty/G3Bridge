// Hand-drawn paper map sheets (CONTRACT §2, DESIGN §4). fp class.
//
// Sheets: 384x384 opaque BitmapData covering 64x64 cells at 6 px per cell, keyed by World.key(x >> 6, y >> 6).
// At most MAX_SHEETS (9) are resident: the 3x3 around the residency centre (the player's cell while the
// map is closed, the VIEW centre while it is open). Storage is a set of parallel vectors indexed by slot
// (residentKeys / sheetBd / sheetSx / sheetSy / sheetCursor); a key lookup is a scan of at most 9 entries,
// which is cheaper than a Map on AVM2 and never allocates an iterator (rule 4). Sheet BitmapDatas are
// allocated at most 9 times per run (rule 4 exemption b; the count is the public sheetAllocs, which Main
// reports — MapPaper never calls Telemetry) and then pooled: an evicted sheet's bitmap is refilled with
// paper and reused for the next sheet.
//
// Ink: every queued item drained in a frame is drawn into ONE Shape and applied with ONE BitmapData.draw
// per sheet touched (at most INK_PER_FRAME items per frame). A face is two overlapping 1-px blue-black
// strokes with +-1 px jitter ALONG the stroke at each end, from Rng.hash3(TAG_INK, Cells.pack(x, y), face),
// so re-inking reproduces the same wobble. A sheet that is (re)created starts as bare paper and is
// re-inked from MapMemory cell by cell (row-major, resuming mid-row) at REINK_PER_FRAME items per frame
// (+ at most one cell's marks) — "pending": sheetCursor = next row, sheetCol = next cell of that row —
// and while it is pending compose shows a "still wet" pencil hatch over it.
//
// Live ink vs the scan (no double inking, no missed ink): every drained item has a cumulative index
// (drainedTotal + its position in the queue). When the scan draws a cell it stamps cellMark[slot][cell]
// with drainedTotal + queueLength(): every item then in the queue for that cell is already in the flags
// the scan read, so the drain skips items whose index is below the mark; items that arrive later have a
// higher index and are inked live. Items for cells the scan has not reached yet are skipped too (the scan
// will read them from memory). A cell with no flags at scan time keeps mark 0, so its later items are
// always drawn live. The only imprecision: MapMemory drops the OLDEST queue items when its ring
// overflows (4096 backlog) without telling us, which makes later indices read low — some items may then
// be skipped that should have been inked live; the next re-ink of the sheet restores them (memory keeps
// every flag), and nothing is ever drawn twice.
//
// Pixel identity (contract test 2): an evicted and re-inked sheet must equal the original although the
// draw ORDER differs. Alpha compositing is order-independent only for one colour, so no two marks of
// different colours ever share a pixel: face strokes have no perpendicular jitter (with hinting a 1-px
// stroke on an integer edge coordinate covers pixel row/col 0 of the cell, without hinting at most rows
// -1 and 0 = px 5 of the neighbour and px 0 here), every centre mark stays within coordinates 1.5..4.5
// of the cell (pixels 1..4), and the visited pencil dot is not drawn on a cell that is also wet/dark/pit
// (the wet ~ / dark hatch / pit cross mark it as visited). Everything that can overlap is INK on INK or
// PENCIL on PENCIL.
//
// Paper: a per-tape 512x512 master (noise fibre tinted warm, a faint cell grid, fold creases at thirds, one
// coffee ring); each sheet is a window of it at a seeded offset (hash of the tape seed and the sheet key),
// so an absent sheet composes as exactly the paper it would have had.
//
// tMap is written by Main (getTimer brackets around pump + compose, rule 10); MapPaper never reads the clock.
import flash.display.BitmapData;
import flash.display.Graphics;
import flash.display.Shape;
import flash.geom.ColorTransform;
import flash.geom.Matrix;
import flash.geom.Point;
import flash.geom.Rectangle;

class MapPaper {
    public static inline var CELL_PX = 6;
    public static inline var SHEET_CELLS = 64;
    public static inline var SHEET_PX = 384;
    public static inline var MAX_SHEETS = 9;
    public static inline var INK_PER_FRAME = 64;
    public static inline var REINK_PER_FRAME = 256;
    static inline var PAPER_PX = 512;            // paper master size
    static inline var PAPER_WINDOW = 128;        // PAPER_PX - SHEET_PX: range of the seeded window offset
    static inline var REINK_SCRATCH = 4096;      // SHEET_CELLS^2 cells per sheet (a row scan uses at most 64)
    static inline var SHEET_AREA = 4096;         // cells per sheet: cellMark stride per slot
    static inline var CURSOR_DONE = 64;          // sheetCursor value once every row is re-inked
    static inline var CENTRE_FLAGS = 224;        // MapMemory.WET_SEEN | DARK_SEEN | PIT_SEEN: the visited dot yields to these marks
    static inline var INK = 0x1A2A5A;            // blue-black ballpoint
    static inline var INK_ALPHA = 0.85;
    static inline var PENCIL = 0x777066;
    static inline var HATCH_STEP = 7;            // px between "still wet" hatch lines
    public var open:Bool;
    public var viewX:Int;                               // world-pixel (cell*6) coordinate of the view's top-left
    public var viewY:Int;
    public var centreX:Int;                             // residency centre in cells: the player's cell while closed, the VIEW centre while open (openAt/pan update it)
    public var centreY:Int;
    public var sheets:Int;                              // resident sheet count (telemetry)
    public var residentKeys:haxe.ds.Vector<Int>;        // MAX_SHEETS entries parallel to the sheet vectors (eviction scans this, never Map.keys())
    public var tMap:Int;
    public var sheetAllocs:Int;                         // BitmapData allocations so far (<= MAX_SHEETS per run); Main reports it in the tick record

    // geometry objects, created once (rule 4)
    var shape:Shape;
    var mtx:Matrix;
    var pt:Point;
    var rc:Rectangle;
    var ct:ColorTransform;
    var paper:BitmapData;                               // 512x512 paper master
    var tapeSeed:Int;
    // resident sheets, parallel to residentKeys
    var sheetBd:haxe.ds.Vector<BitmapData>;
    var sheetSx:haxe.ds.Vector<Int>;                    // sheet coordinate (x >> 6)
    var sheetSy:haxe.ds.Vector<Int>;
    var sheetCursor:haxe.ds.Vector<Int>;                // next row to re-ink; CURSOR_DONE when the sheet is fully inked
    var sheetCol:haxe.ds.Vector<Int>;                   // next cell of that row (0..63): a dense row resumes mid-row next pump
    var cellMark:haxe.ds.Vector<Int>;                   // MAX_SHEETS * SHEET_AREA: cumulative queue index up to which the scan covered the cell (0 = never)
    var drainedTotal:Int;                               // items ever removed from the queue by drainQueue; queue position i has index drainedTotal + i
    // bitmap pool (rule 4 exemption b: at most MAX_SHEETS allocations per run, then reuse)
    var pool:haxe.ds.Vector<BitmapData>;
    var poolCount:Int;
    // 3x3 residency order, nearest first
    var ringDx:haxe.ds.Vector<Int>;
    var ringDy:haxe.ds.Vector<Int>;
    // queue drain scratch
    var itemSlot:haxe.ds.Vector<Int>;
    // re-ink scratch (forEachKnown output)
    var reinkCells:haxe.ds.Vector<Int>;
    var reinkFlags:haxe.ds.Vector<Int>;
    // last frame-buffer size seen by compose (openAt/pan centre the view with it)
    var lastW:Int;
    var lastH:Int;

    // allocates the Shape, Matrix, Points/Rects, the 512x512 paper master, the reink scratch vectors, residentKeys
    public function new():Void {
        open = false;
        viewX = 0;
        viewY = 0;
        centreX = 0;
        centreY = 0;
        sheets = 0;
        residentKeys = new haxe.ds.Vector<Int>(MAX_SHEETS);
        sheetBd = new haxe.ds.Vector<BitmapData>(MAX_SHEETS);
        sheetSx = new haxe.ds.Vector<Int>(MAX_SHEETS);
        sheetSy = new haxe.ds.Vector<Int>(MAX_SHEETS);
        sheetCursor = new haxe.ds.Vector<Int>(MAX_SHEETS);
        sheetCol = new haxe.ds.Vector<Int>(MAX_SHEETS);
        pool = new haxe.ds.Vector<BitmapData>(MAX_SHEETS);
        for (i in 0...MAX_SHEETS) {
            residentKeys[i] = 0;
            sheetBd[i] = null;
            sheetSx[i] = 0;
            sheetSy[i] = 0;
            sheetCursor[i] = CURSOR_DONE;
            sheetCol[i] = 0;
            pool[i] = null;
        }
        cellMark = new haxe.ds.Vector<Int>(MAX_SHEETS * SHEET_AREA);
        for (i in 0...MAX_SHEETS * SHEET_AREA) cellMark[i] = 0;
        drainedTotal = 0;
        poolCount = 0;
        sheetAllocs = 0;
        tMap = 0;
        tapeSeed = 0;
        lastW = 320;
        lastH = 240;
        shape = new Shape();
        mtx = new Matrix();
        pt = new Point(0, 0);
        rc = new Rectangle(0, 0, SHEET_PX, SHEET_PX);
        ct = new ColorTransform(1.0, 0.96, 0.86, 1.0, 10, 4, -8);
        paper = new BitmapData(PAPER_PX, PAPER_PX, false, 0xFFE8E0C8);
        ringDx = new haxe.ds.Vector<Int>(MAX_SHEETS);
        ringDy = new haxe.ds.Vector<Int>(MAX_SHEETS);
        ringDx[0] = 0;  ringDy[0] = 0;
        ringDx[1] = 1;  ringDy[1] = 0;
        ringDx[2] = -1; ringDy[2] = 0;
        ringDx[3] = 0;  ringDy[3] = 1;
        ringDx[4] = 0;  ringDy[4] = -1;
        ringDx[5] = 1;  ringDy[5] = 1;
        ringDx[6] = -1; ringDy[6] = 1;
        ringDx[7] = 1;  ringDy[7] = -1;
        ringDx[8] = -1; ringDy[8] = -1;
        itemSlot = new haxe.ds.Vector<Int>(INK_PER_FRAME);
        for (i in 0...INK_PER_FRAME) itemSlot[i] = -1;
        reinkCells = new haxe.ds.Vector<Int>(REINK_SCRATCH);
        reinkFlags = new haxe.ds.Vector<Int>(REINK_SCRATCH);
        for (i in 0...REINK_SCRATCH) { reinkCells[i] = 0; reinkFlags[i] = 0; }
        buildPaperMaster(0x5EEDBEEF);
    }

    // ---- paper master --------------------------------------------------------------------------

    // paper master (noise fibre, grid, creases, coffee ring), disposes all sheets
    public function buildForTape(t:Tape):Void {
        tapeSeed = t.seed;
        while (sheets > 0) releaseSlot(sheets - 1);
        buildPaperMaster(Rng.hash2(tapeSeed, Rng.TAG_PAPER));
    }

    function buildPaperMaster(seed:Int):Void {
        var r = new Rng(seed);                           // outside the frame loop (tape start)
        // fibre: low-contrast grey noise, tinted warm by the ColorTransform (r 1.0, g 0.96, b 0.86 + offsets)
        paper.noise(r.nextInt(), 208, 236, 7, true);
        rc.x = 0; rc.y = 0; rc.width = PAPER_PX; rc.height = PAPER_PX;
        paper.colorTransform(rc, ct);
        var g = shape.graphics;
        g.clear();
        // faint cell grid, a slightly stronger line every 8 cells
        var n = Std.int(PAPER_PX / CELL_PX) + 1;
        for (i in 0...n) {
            var p = i * CELL_PX;
            g.lineStyle(1, 0x9AA6B8, (i & 7) == 0 ? 0.20 : 0.10, true);
            g.moveTo(p, 0); g.lineTo(p, PAPER_PX);
            g.moveTo(0, p); g.lineTo(PAPER_PX, p);
        }
        // fold creases at thirds (+- a few px per tape): a soft shadow and a sharp fold line
        for (k in 1...3) {
            var fx = Std.int(PAPER_PX * k / 3) + r.range(-8, 9);
            var fy = Std.int(PAPER_PX * k / 3) + r.range(-8, 9);
            g.lineStyle(3, 0x6A5A48, 0.10, true);
            g.moveTo(fx, 0); g.lineTo(fx, PAPER_PX);
            g.moveTo(0, fy); g.lineTo(PAPER_PX, fy);
            g.lineStyle(1, 0x5A4A38, 0.18, true);
            g.moveTo(fx + 1, 0); g.lineTo(fx + 1, PAPER_PX);
            g.moveTo(0, fy + 1); g.lineTo(PAPER_PX, fy + 1);
        }
        // one coffee ring somewhere per tape: a wide faint ring with a sharper inner rim, slightly off-centre
        var cx = r.range(48, PAPER_PX - 48);
        var cy = r.range(48, PAPER_PX - 48);
        var rad = r.range(28, 45);
        g.lineStyle(5, 0x7A5230, 0.14, true);
        g.drawCircle(cx, cy, rad);
        g.lineStyle(2, 0x6A4220, 0.22, true);
        g.drawCircle(cx + 1, cy - 1, rad + 1);
        g.lineStyle(1, 0x5A3618, 0.18, true);
        g.drawCircle(cx - 1, cy + 1, rad - 2);
        // a few pencil smudges
        for (k in 0...3) {
            var sx = r.range(16, PAPER_PX - 16);
            var sy = r.range(16, PAPER_PX - 16);
            g.lineStyle(2, PENCIL, 0.06, true);
            g.moveTo(sx - 12, sy + 2); g.lineTo(sx + 14, sy - 3);
            g.moveTo(sx - 9, sy + 5); g.lineTo(sx + 11, sy + 1);
        }
        paper.draw(shape);
        g.clear();
    }

    // ---- sheet residency --------------------------------------------------------------------------

    static inline function floorDiv(a:Int, n:Int):Int {
        return a >= 0 ? Std.int(a / n) : -Std.int((-a + n - 1) / n);
    }

    // Slot of the resident sheet with this key, or -1.
    function findSlot(key:Int):Int {
        var keys = residentKeys;
        var n = sheets;
        for (i in 0...n) if (keys[i] == key) return i;
        return -1;
    }

    // Slot of the resident sheet farthest (Chebyshev, in sheets) from sheet (csx, csy); -1 if none.
    function farthestSlot(csx:Int, csy:Int):Int {
        var best = -1;
        var bestD = -1;
        for (i in 0...sheets) {
            var dx = sheetSx[i] - csx; if (dx < 0) dx = -dx;
            var dy = sheetSy[i] - csy; if (dy < 0) dy = -dy;
            var d = dx > dy ? dx : dy;
            if (d > bestD) { bestD = d; best = i; }
        }
        return best;
    }

    // Returns slot i's bitmap to the pool and swap-removes the slot.
    function releaseSlot(i:Int):Void {
        pool[poolCount] = sheetBd[i];
        poolCount++;
        sheets--;
        var last = sheets;
        residentKeys[i] = residentKeys[last];
        sheetBd[i] = sheetBd[last];
        sheetSx[i] = sheetSx[last];
        sheetSy[i] = sheetSy[last];
        sheetCursor[i] = sheetCursor[last];
        sheetCol[i] = sheetCol[last];
        if (i != last) {                                   // the moved sheet keeps its scan marks
            var marks = cellMark;
            var src = last * SHEET_AREA;
            var dst = i * SHEET_AREA;
            for (k in 0...SHEET_AREA) marks[dst + k] = marks[src + k];
        }
        residentKeys[last] = 0;
        sheetBd[last] = null;
        sheetCursor[last] = CURSOR_DONE;
        sheetCol[last] = 0;
    }

    // Seeded paper-window offset of a sheet (pure function of the tape seed and the sheet key).
    inline function paperOffX(key:Int):Int return Rng.hash3(tapeSeed, Rng.TAG_PAPER, key) & (PAPER_WINDOW - 1);
    inline function paperOffY(key:Int):Int return (Rng.hash3(tapeSeed, Rng.TAG_PAPER, key) >>> 8) & (PAPER_WINDOW - 1);

    // Makes sheet (sx, sy) resident as bare paper, pending a re-ink from row 0; returns its slot.
    // Allocates a BitmapData only while fewer than MAX_SHEETS exist (rule 4 exemption b, logged); otherwise reuses the pool.
    function acquireSheet(sx:Int, sy:Int):Int {
        if (sheets >= MAX_SHEETS) {                        // never with the 3x3 rule; keeps the set bounded regardless
            var f = farthestSlot(centreX >> 6, centreY >> 6);
            if (f < 0) return -1;
            releaseSlot(f);
        }
        var bd:BitmapData;
        if (poolCount > 0) {
            poolCount--;
            bd = pool[poolCount];
            pool[poolCount] = null;
        } else {
            bd = allocSheet();
        }
        var key = World.key(sx, sy);
        rc.x = paperOffX(key); rc.y = paperOffY(key); rc.width = SHEET_PX; rc.height = SHEET_PX;
        pt.x = 0; pt.y = 0;
        bd.copyPixels(paper, rc, pt);
        var slot = sheets;
        residentKeys[slot] = key;
        sheetBd[slot] = bd;
        sheetSx[slot] = sx;
        sheetSy[slot] = sy;
        sheetCursor[slot] = 0;
        sheetCol[slot] = 0;
        var marks = cellMark;                              // a fresh sheet has covered nothing yet
        var base = slot * SHEET_AREA;
        for (k in 0...SHEET_AREA) marks[base + k] = 0;
        sheets++;
        return slot;
    }

    // The one allocation MapPaper makes after start: bounded by MAX_SHEETS over the whole run, counted in sheetAllocs.
    function allocSheet():BitmapData {
        sheetAllocs++;
        return new BitmapData(SHEET_PX, SHEET_PX, false, 0xFFE8E0C8);
    }

    // Drops every sheet outside the 3x3 around the residency centre.
    function evictOutside():Void {
        var csx = centreX >> 6;
        var csy = centreY >> 6;
        var i = 0;
        while (i < sheets) {
            var dx = sheetSx[i] - csx; if (dx < 0) dx = -dx;
            var dy = sheetSy[i] - csy; if (dy < 0) dy = -dy;
            if (dx > 1 || dy > 1) releaseSlot(i);          // swap-remove: re-examine slot i
            else i++;
        }
    }

    // Makes at most one missing sheet of the 3x3 resident (nearest first); returns true if one was created.
    function ensureOne():Bool {
        var csx = centreX >> 6;
        var csy = centreY >> 6;
        for (k in 0...MAX_SHEETS) {
            var sx = csx + ringDx[k];
            var sy = csy + ringDy[k];
            if (findSlot(World.key(sx, sy)) < 0) {
                acquireSheet(sx, sy);
                return true;
            }
        }
        return false;
    }

    // ---- ink --------------------------------------------------------------------------------------

    // jitter -1..1 from two bits of h at shift s (0 twice as likely: a pen wobble, not a scatter)
    static inline function jit(h:Int, s:Int):Int {
        var v = (h >>> s) & 3;
        return v == 3 ? 0 : v - 1;
    }

    // Two overlapping 1-px ink strokes along face `face` of world cell (x, y), in sheet pixels. The jitter
    // (+-1 px per end per stroke) runs ALONG the edge only, so the stroke never leaves the edge pixel and
    // never touches a centre mark (see the header on pixel identity).
    function drawFace(g:Graphics, x:Int, y:Int, face:Int):Void {
        var h = Rng.hash3(Rng.TAG_INK, Cells.pack(x, y), face);
        var px = (x & 63) * CELL_PX;
        var py = (y & 63) * CELL_PX;
        g.lineStyle(1, INK, INK_ALPHA, true);
        if (face == Cells.N || face == Cells.S) {          // horizontal edge at py (N) or py + 6 (S)
            var ey = face == Cells.N ? py : py + CELL_PX;
            g.moveTo(px + jit(h, 0), ey);
            g.lineTo(px + CELL_PX + jit(h, 2), ey);
            g.moveTo(px + jit(h, 4), ey);
            g.lineTo(px + CELL_PX + jit(h, 6), ey);
        } else {                                           // vertical edge at px + 6 (E) or px (W)
            var ex = face == Cells.E ? px + CELL_PX : px;
            g.moveTo(ex, py + jit(h, 0));
            g.lineTo(ex, py + CELL_PX + jit(h, 2));
            g.moveTo(ex, py + jit(h, 4));
            g.lineTo(ex, py + CELL_PX + jit(h, 6));
        }
    }

    // Kind 4..7 marks at the centre of world cell (x, y): pencil dot, wet ~, dark hatch, pit circle + cross.
    // Every mark stays within coordinates 1.5..4.5 of the cell (pixels 1..4, with the 1-px stroke width), so
    // it never shares a pixel with the ink on the edges (pixel 0 here, pixel 5 of the neighbour at most).
    function drawMark(g:Graphics, x:Int, y:Int, kind:Int):Void {
        var cx = (x & 63) * CELL_PX + 3;
        var cy = (y & 63) * CELL_PX + 3;
        switch (kind) {
            case 4:                                           // visited: 1-px pencil dot (pixel 3,3)
                g.lineStyle(Math.NaN);
                g.beginFill(PENCIL, 0.9);
                g.drawRect(cx, cy, 1, 1);
                g.endFill();
            case 5:                                           // wet: a 3-px scribbled ~ (the curve stays within cy +- 0.75)
                g.lineStyle(1, 0x4A6A9A, 0.7, true);
                g.moveTo(cx - 1.5, cy);
                g.curveTo(cx - 0.75, cy - 1.5, cx, cy);
                g.curveTo(cx + 0.75, cy + 1.5, cx + 1.5, cy);
            case 6:                                           // dark: pencil hatch across pixels 1..4
                g.lineStyle(1, PENCIL, 0.55, true);
                g.moveTo(cx - 1.5, cy + 1.5); g.lineTo(cx + 1.5, cy - 1.5);
                g.moveTo(cx - 1.5, cy);       g.lineTo(cx, cy - 1.5);
                g.moveTo(cx, cy + 1.5);       g.lineTo(cx + 1.5, cy);
            default:                                          // pit: 3-px filled circle + cross
                g.lineStyle(Math.NaN);
                g.beginFill(INK, 0.9);
                g.drawCircle(cx, cy, 1.5);
                g.endFill();
                g.lineStyle(1, INK, INK_ALPHA, true);
                g.moveTo(cx - 1.5, cy - 1.5); g.lineTo(cx + 1.5, cy + 1.5);
                g.moveTo(cx + 1.5, cy - 1.5); g.lineTo(cx - 1.5, cy + 1.5);
        }
    }

    // Everything MapMemory knows about world cell (x, y): faces first, then the centre marks (the visited dot
    // only when no wet/dark/pit mark stands in for it). Returns items drawn.
    function drawKnown(g:Graphics, x:Int, y:Int, f:Int):Int {
        var n = 0;
        if ((f & MapMemory.F_N) != 0) { drawFace(g, x, y, Cells.N); n++; }
        if ((f & MapMemory.F_E) != 0) { drawFace(g, x, y, Cells.E); n++; }
        if ((f & MapMemory.F_S) != 0) { drawFace(g, x, y, Cells.S); n++; }
        if ((f & MapMemory.F_W) != 0) { drawFace(g, x, y, Cells.W); n++; }
        if ((f & MapMemory.VISITED) != 0 && (f & CENTRE_FLAGS) == 0) { drawMark(g, x, y, 4); n++; }
        if ((f & MapMemory.WET_SEEN) != 0) { drawMark(g, x, y, 5); n++; }
        if ((f & MapMemory.DARK_SEEN) != 0) { drawMark(g, x, y, 6); n++; }
        if ((f & MapMemory.PIT_SEEN) != 0) { drawMark(g, x, y, 7); n++; }
        return n;
    }

    // Drains up to INK_PER_FRAME queued items: one Shape and one draw per sheet touched. Returns items inked.
    // An item is inked live only if its sheet is resident, the scan has already passed its cell, and it
    // arrived after that scan (index >= cellMark); everything else is (or will be) inked by the scan.
    function drainQueue(mem:MapMemory):Int {
        var n = mem.queueLength();
        if (n <= 0) return 0;
        if (n > INK_PER_FRAME) n = INK_PER_FRAME;
        var marks = cellMark;
        var base = drainedTotal;
        var touched = 0;                                   // bit mask of slots with work
        for (i in 0...n) {
            var c = mem.queuePeekCell(i);
            var x = Cells.unpackX(c);
            var y = Cells.unpackY(c);
            var slot = findSlot(World.key(x >> 6, y >> 6));
            if (slot >= 0) {
                var row = y & 63;
                var col = x & 63;
                var cur = sheetCursor[slot];
                // not scanned yet (row beyond the cursor, or the unscanned tail of the cursor row): the scan inks it
                if (row > cur || (row == cur && col >= sheetCol[slot])) slot = -1;
                // scanned, and the scan's memory read already included this item: it is on the sheet
                else if (base + i < marks[slot * SHEET_AREA + (row << 6) + col]) slot = -1;
                // the visited dot yields to a wet/dark/pit mark of the same cell
                else if (mem.queuePeekKind(i) == 4 && (mem.flags(x, y) & CENTRE_FLAGS) != 0) slot = -1;
            }
            itemSlot[i] = slot;                            // -1 = not resident: memory keeps it, the sheet re-inks when it comes back
            if (slot >= 0) touched |= 1 << slot;
        }
        var inked = 0;
        if (touched != 0) {
            var g = shape.graphics;
            for (slot in 0...sheets) {
                if ((touched & (1 << slot)) == 0) continue;
                g.clear();
                for (i in 0...n) {
                    if (itemSlot[i] != slot) continue;
                    var c = mem.queuePeekCell(i);
                    var x = Cells.unpackX(c);
                    var y = Cells.unpackY(c);
                    var kind = mem.queuePeekKind(i);
                    if (kind < 4) drawFace(g, x, y, kind);
                    else drawMark(g, x, y, kind);
                    inked++;
                }
                sheetBd[slot].draw(shape);
            }
            g.clear();
        }
        mem.queueDrop(n);
        drainedTotal += n;
        return inked;
    }

    // Re-inks the pending sheet nearest the centre, cell by cell in row-major order, until REINK_PER_FRAME
    // items are drawn (the cell that crosses the line completes, so at most 7 over; one Shape, one draw);
    // a row left unfinished resumes at sheetCol next pump. Every cell drawn is stamped with the current
    // queue index so drainQueue never inks the same item again. Returns items drawn.
    function reinkOne(mem:MapMemory):Int {
        var csx = centreX >> 6;
        var csy = centreY >> 6;
        var slot = -1;
        var bestD = 0x7FFFFFFF;
        for (i in 0...sheets) {
            if (sheetCursor[i] >= CURSOR_DONE) continue;
            var dx = sheetSx[i] - csx; if (dx < 0) dx = -dx;
            var dy = sheetSy[i] - csy; if (dy < 0) dy = -dy;
            var d = dx > dy ? dx : dy;
            if (d < bestD) { bestD = d; slot = i; }
        }
        if (slot < 0) return 0;
        var g = shape.graphics;
        g.clear();
        var drawn = 0;
        var x0 = sheetSx[slot] << 6;
        var y0 = sheetSy[slot] << 6;
        var row = sheetCursor[slot];
        var col = sheetCol[slot];
        var cells = reinkCells;
        var flags = reinkFlags;
        var marks = cellMark;
        var markBase = slot * SHEET_AREA;
        var mark = drainedTotal + mem.queueLength();       // every item queued so far is in the flags we are about to read
        while (row < CURSOR_DONE && drawn < REINK_PER_FRAME) {
            var wy = y0 + row;
            var n = mem.forEachKnown(x0 + col, wy, x0 + SHEET_CELLS - 1, wy, cells, flags, SHEET_CELLS);
            var i = 0;
            while (i < n && drawn < REINK_PER_FRAME) {
                var x = Cells.unpackX(cells[i]);
                drawn += drawKnown(g, x, wy, flags[i]);
                marks[markBase + (row << 6) + (x & 63)] = mark;
                i++;
            }
            if (i < n) {                                   // budget spent mid-row: resume at the first undrawn known cell
                col = Cells.unpackX(cells[i]) & 63;
                break;
            }
            row++;
            col = 0;
        }
        sheetCursor[slot] = row;
        sheetCol[slot] = col;
        if (drawn > 0) sheetBd[slot].draw(shape);
        g.clear();
        return drawn;
    }

    // ---- public per-frame API ----------------------------------------------------------------------

    // drains up to INK_PER_FRAME queued items into ONE Shape and ONE draw per sheet touched; re-inks a pending sheet up to REINK_PER_FRAME under the
    // "still wet" hatch; evicts sheets beyond the 3x3 around (centreX, centreY) — px,py (the player's cell) set the centre only while !open; returns items inked
    public function pump(mem:MapMemory, px:Int, py:Int):Int {
        if (!open) {
            centreX = px;
            centreY = py;
        }
        evictOutside();
        ensureOne();
        var inked = drainQueue(mem);
        inked += reinkOne(mem);
        return inked;
    }

    // centres the view (and residency) on the player
    public function openAt(px:Float, py:Float):Void {
        open = true;
        viewX = Std.int(Math.floor(px * CELL_PX)) - (lastW >> 1);
        viewY = Std.int(Math.floor(py * CELL_PX)) - (lastH >> 1);
        centreX = Std.int(Math.floor(px));
        centreY = Std.int(Math.floor(py));
    }

    // residency snaps back to the player (on the next pump)
    public function close():Void {
        open = false;
    }

    // pixels; moves the residency centre with the view, so sheets 200 cells back re-ink from MapMemory instead of showing bare paper
    public function pan(dx:Int, dy:Int):Void {
        viewX += dx;
        viewY += dy;
        centreX = floorDiv(viewX + (lastW >> 1), CELL_PX);
        centreY = floorDiv(viewY + (lastH >> 1), CELL_PX);
    }

    // Composites the visible sheet window into bd (2-4 copyPixels), then the player arrowhead at (px,py,ang) via one Shape draw, with the hand wobble offset.
    public function compose(bd:BitmapData, w:Int, h:Int, px:Float, py:Float, ang:Float, wobbleX:Int, wobbleY:Int):Void {
        if (w != lastW || h != lastH) {                    // openAt/pan centred with the last size: keep the same centre at the real size
            viewX += (lastW - w) >> 1;
            viewY += (lastH - h) >> 1;
            lastW = w;
            lastH = h;
        }
        var vx = viewX + wobbleX;
        var vy = viewY + wobbleY;
        var sx0 = floorDiv(vx, SHEET_PX);
        var sx1 = floorDiv(vx + w - 1, SHEET_PX);
        var sy0 = floorDiv(vy, SHEET_PX);
        var sy1 = floorDiv(vy + h - 1, SHEET_PX);
        var g = shape.graphics;
        g.clear();
        for (sy in sy0...sy1 + 1) {
            for (sx in sx0...sx1 + 1) {
                var ox = sx * SHEET_PX;                     // sheet origin in world px
                var oy = sy * SHEET_PX;
                var srcX = vx - ox; if (srcX < 0) srcX = 0;
                var srcY = vy - oy; if (srcY < 0) srcY = 0;
                var endX = vx + w - ox; if (endX > SHEET_PX) endX = SHEET_PX;
                var endY = vy + h - oy; if (endY > SHEET_PX) endY = SHEET_PX;
                var dx = ox + srcX - vx;
                var dy = oy + srcY - vy;
                pt.x = dx; pt.y = dy;
                var key = World.key(sx, sy);
                var slot = findSlot(key);
                if (slot >= 0) {
                    rc.x = srcX; rc.y = srcY; rc.width = endX - srcX; rc.height = endY - srcY;
                    bd.copyPixels(sheetBd[slot], rc, pt);
                    if (sheetCursor[slot] < CURSOR_DONE) {   // still wet: pencil hatch over the visible part
                        drawHatch(g, dx, dy, endX - srcX, endY - srcY);
                    }
                } else {                                       // not resident: the paper this sheet would have
                    rc.x = paperOffX(key) + srcX; rc.y = paperOffY(key) + srcY; rc.width = endX - srcX; rc.height = endY - srcY;
                    bd.copyPixels(paper, rc, pt);
                }
            }
        }
        // the player: a red arrowhead pointing along ang, with a faint ink ring
        var cx = px * CELL_PX - vx;
        var cy = py * CELL_PX - vy;
        var ca = Math.cos(ang);
        var sa = Math.sin(ang);
        g.lineStyle(1, INK, 0.35, true);
        g.drawCircle(cx, cy, 6);
        g.lineStyle(1, 0x5A1410, 0.9, true);
        g.beginFill(0xB8322A, 0.92);
        g.moveTo(cx + ca * 7, cy + sa * 7);
        g.lineTo(cx + Math.cos(ang + 2.5) * 5, cy + Math.sin(ang + 2.5) * 5);
        g.lineTo(cx - ca * 1.5, cy - sa * 1.5);
        g.lineTo(cx + Math.cos(ang - 2.5) * 5, cy + Math.sin(ang - 2.5) * 5);
        g.lineTo(cx + ca * 7, cy + sa * 7);
        g.endFill();
        bd.draw(shape);
        g.clear();
    }

    // Diagonal pencil lines (x + y = c, every HATCH_STEP px) clipped to the rectangle (rx, ry, rw, rh).
    function drawHatch(g:Graphics, rx:Int, ry:Int, rw:Int, rh:Int):Void {
        g.lineStyle(1, PENCIL, 0.22, true);
        var c0 = rx + ry;
        var c1 = rx + rw + ry + rh;
        var m = c0 % HATCH_STEP; if (m < 0) m += HATCH_STEP;
        var c = m == 0 ? c0 : c0 + HATCH_STEP - m;         // first multiple of HATCH_STEP >= c0
        while (c < c1) {
            var x1 = c - ry - rh; if (x1 < rx) x1 = rx;
            var x2 = c - ry; if (x2 > rx + rw) x2 = rx + rw;
            if (x1 < x2) {
                g.moveTo(x1, c - x1);
                g.lineTo(x2, c - x2);
            }
            c += HATCH_STEP;
        }
    }
}
