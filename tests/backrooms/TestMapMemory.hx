// Unit tests for MapMemory (CONTRACT §1 tests 1-4, DESIGN §11). Runs under haxe --interp via TestAll.
// Uses the real MapMemory, RayHits, Cells and World.key. Prints one line per check; returns the number of failed checks.
class TestMapMemory {
    static var fails:Int;

    static function check(name:String, ok:Bool):Void {
        if (!ok) fails++;
        Sys.println("  " + (ok ? "ok  " : "FAIL") + " " + name);
    }

    static inline var INK_FP = MapMemory.INK_DIST << 16;

    // Fills column i of h as a hit on (x, y) face f at 16.16 distance d.
    static function col(h:RayHits, i:Int, hit:Int, d:Int, x:Int, y:Int, f:Int):Void {
        h.hit[i] = hit;
        h.dist[i] = d;
        h.cellX[i] = x;
        h.cellY[i] = y;
        h.face[i] = f;
        h.side[i] = (f == Cells.E || f == Cells.W) ? 0 : 1;
        h.cell[i] = Cells.WALL;
        h.texX[i] = 0;
    }

    static function chebChunks(k:Int, pcx:Int, pcy:Int):Int {
        var cx = (k >>> 16) - 0x8000;
        var cy = (k & 0xFFFF) - 0x8000;
        var dx = cx - pcx; if (dx < 0) dx = -dx;
        var dy = cy - pcy; if (dy < 0) dy = -dy;
        return dx > dy ? dx : dy;
    }

    public static function run():Int {
        fails = 0;
        testFaces();
        testVisit();
        testRecordHits();
        testQueue();
        testCap();
        testForEachKnown();
        return fails;
    }

    // (1) face bits round-trip; seeFace returns true exactly once per face; unknown chunks read 0 without being touched
    static function testFaces():Void {
        var m = new MapMemory();
        check("fresh: chunkCount 0, queue empty", m.chunkCount() == 0 && m.queueLength() == 0);
        check("unknown chunk reads 0 and is not allocated", m.flags(1000, 1000) == 0 && m.chunkCount() == 0);
        check("seeFace N first time true", m.seeFace(5, 7, Cells.N));
        check("flags == F_N", m.flags(5, 7) == MapMemory.F_N);
        check("seeFace N again false", !m.seeFace(5, 7, Cells.N));
        check("seeFace E/S/W true once each", m.seeFace(5, 7, Cells.E) && m.seeFace(5, 7, Cells.S) && m.seeFace(5, 7, Cells.W));
        check("all four faces set", m.flags(5, 7) == (MapMemory.F_N | MapMemory.F_E | MapMemory.F_S | MapMemory.F_W));
        check("repeat of every face false", !m.seeFace(5, 7, Cells.E) && !m.seeFace(5, 7, Cells.S) && !m.seeFace(5, 7, Cells.W));
        check("face bit order N=1 E=2 S=4 W=8", MapMemory.F_N == 1 << Cells.N && MapMemory.F_E == 1 << Cells.E
            && MapMemory.F_S == 1 << Cells.S && MapMemory.F_W == 1 << Cells.W);
        check("neighbour cell untouched", m.flags(6, 7) == 0 && m.flags(5, 8) == 0);
        check("one chunk allocated", m.chunkCount() == 1);
        // negative coordinates land in their own chunk and read back exactly
        check("negative cell seeFace true", m.seeFace(-1, -1, Cells.W));
        check("negative cell flags", m.flags(-1, -1) == MapMemory.F_W && m.flags(-1, -2) == 0 && m.flags(0, -1) == 0);
        check("negative chunk allocated separately", m.chunkCount() == 2);
        check("chunk edge cells (31,31) and (32,32) are distinct chunks", m.seeFace(31, 31, Cells.S) && m.seeFace(32, 32, Cells.N)
            && m.flags(31, 31) == MapMemory.F_S && m.flags(32, 32) == MapMemory.F_N && m.chunkCount() == 3);
        // the 4 faces are the only face bits: never leaks into VISITED
        check("faces never set VISITED", (m.flags(5, 7) & MapMemory.VISITED) == 0);
    }

    // visit marks VISITED (+ WET/DARK/PIT_SEEN from the cell type), true once
    static function testVisit():Void {
        var m = new MapMemory();
        check("visit floor true", m.visit(5, 7, Cells.FLOOR));
        check("visit sets VISITED only", m.flags(5, 7) == MapMemory.VISITED);
        check("visit again false", !m.visit(5, 7, Cells.FLOOR));
        check("visit wet (with LIGHT bit) true", m.visit(6, 7, Cells.WET | Cells.LIGHT | (3 << Cells.VAR_SHIFT)));
        check("wet sets VISITED|WET_SEEN", m.flags(6, 7) == (MapMemory.VISITED | MapMemory.WET_SEEN));
        check("visit wet again false", !m.visit(6, 7, Cells.WET));
        check("visit dark", m.visit(7, 7, Cells.DARK) && m.flags(7, 7) == (MapMemory.VISITED | MapMemory.DARK_SEEN));
        check("visit pit", m.visit(8, 7, Cells.PIT) && m.flags(8, 7) == (MapMemory.VISITED | MapMemory.PIT_SEEN));
        check("visit wall-typed value sets VISITED only", m.visit(9, 7, Cells.WALL | Cells.DAMAGED) && m.flags(9, 7) == MapMemory.VISITED);
        // faces and visit coexist in one byte
        m.seeFace(5, 7, Cells.N);
        check("face + visited coexist", m.flags(5, 7) == (MapMemory.VISITED | MapMemory.F_N));
        check("visited cell still refuses a second visit", !m.visit(5, 7, Cells.FLOOR));
    }

    // (2) recordHits records every hit column under INK_DIST once, ignores misses and far hits, returns the new count
    static function testRecordHits():Void {
        var m = new MapMemory();
        var h = new RayHits(8);
        col(h, 0, 1, 3 * Cells.ONE, 10, 10, Cells.N);          // recorded
        col(h, 1, 1, INK_FP, 20, 10, Cells.N);                  // exactly INK_DIST: ignored
        col(h, 2, 1, INK_FP - 1, 11, 10, Cells.E);              // just inside: recorded
        col(h, 3, 0, Cells.ONE, 12, 10, Cells.N);               // miss: ignored
        col(h, 4, 1, 3 * Cells.ONE, 10, 10, Cells.N);           // duplicate of column 0: not new
        col(h, 5, 1, 2 * Cells.ONE, 10, 10, Cells.S);           // same cell, other face: recorded
        col(h, 6, 1, Cells.ONE, 13, 10, Cells.W);               // beyond count: ignored
        col(h, 7, 1, Cells.ONE, 14, 10, Cells.W);
        h.count = 6;
        var n = m.recordHits(h);
        check("recordHits returns 3 new faces", n == 3);
        check("(10,10) has N|S", m.flags(10, 10) == (MapMemory.F_N | MapMemory.F_S));
        check("(11,10) has E", m.flags(11, 10) == MapMemory.F_E);
        check("column at INK_DIST ignored", m.flags(20, 10) == 0);
        check("miss ignored", m.flags(12, 10) == 0);
        check("columns past count ignored", m.flags(13, 10) == 0 && m.flags(14, 10) == 0);
        check("queue holds exactly the 3 new faces", m.queueLength() == 3);
        check("recordHits again returns 0", m.recordHits(h) == 0 && m.queueLength() == 3);
        // a sweep that crosses a chunk boundary records both sides (the per-call chunk cache must switch)
        var m2 = new MapMemory();
        var h2 = new RayHits(320);
        for (i in 0...320) {
            var x = 20 + (i >> 3);                               // 20..59 crosses x = 32
            col(h2, i, 1, 4 * Cells.ONE, x, ((i >> 2) & 1) == 0 ? 31 : 32, i & 3);   // 8 columns per x: 2 rows x 4 faces
        }
        h2.count = 320;
        var n2 = m2.recordHits(h2);
        var expect = 40 * 2 * 4;                                 // every (x, y, face) of the sweep is distinct
        check("320-column sweep: every distinct (cell, face) recorded once (" + n2 + ")", n2 == expect);
        check("sweep touched all four chunks", m2.chunkCount() == 4);
        check("sweep flags on both sides of the x=32 boundary", m2.flags(31, 31) == 15 && m2.flags(32, 32) == 15);
        check("sweep repeat records nothing", m2.recordHits(h2) == 0);
    }

    // (4) the queue delivers each new item once, in order, exposes cell + kind, drops the oldest when full, never throws
    static function testQueue():Void {
        var m = new MapMemory();
        m.seeFace(1, 1, Cells.N);
        m.visit(2, 2, Cells.WET);
        m.seeFace(-3, -4, Cells.W);
        check("queue length 4 (face, visited, wet, face)", m.queueLength() == 4);
        check("item 0 = (1,1) kind N", m.queuePeekCell(0) == Cells.pack(1, 1) && m.queuePeekKind(0) == 0);
        check("item 1 = (2,2) kind visited(4)", m.queuePeekCell(1) == Cells.pack(2, 2) && m.queuePeekKind(1) == 4);
        check("item 2 = (2,2) kind wet(5)", m.queuePeekCell(2) == Cells.pack(2, 2) && m.queuePeekKind(2) == 5);
        check("item 3 = (-3,-4) kind W(3), world coords round-trip", m.queuePeekCell(3) == Cells.pack(-3, -4) && m.queuePeekKind(3) == 3
            && Cells.unpackX(m.queuePeekCell(3)) == -3 && Cells.unpackY(m.queuePeekCell(3)) == -4);
        check("kind is the bit index of the flag", 1 << m.queuePeekKind(1) == MapMemory.VISITED && 1 << m.queuePeekKind(2) == MapMemory.WET_SEEN);
        m.queueDrop(1);
        check("queueDrop(1): head advances", m.queueLength() == 3 && m.queuePeekCell(0) == Cells.pack(2, 2) && m.queuePeekKind(0) == 4);
        m.seeFace(1, 1, Cells.N);
        check("a repeated face is not queued", m.queueLength() == 3);
        m.visit(7, 7, Cells.DARK);
        check("dark visit queues visited then dark(6)", m.queueLength() == 5 && m.queuePeekKind(3) == 4 && m.queuePeekKind(4) == 6);
        m.visit(8, 8, Cells.PIT);
        check("pit visit queues pit(7)", m.queueLength() == 7 && m.queuePeekKind(6) == 7);
        m.queueDrop(100);
        check("queueDrop beyond length clamps to empty", m.queueLength() == 0);
        m.queueDrop(0);
        m.queueDrop(-1);
        check("queueDrop(0)/(-1) no-ops", m.queueLength() == 0);
        // overflow: QUEUE_SIZE + 10 distinct faces along one row (never throws; the oldest 10 are dropped)
        var extra = 10;
        var total = MapMemory.QUEUE_SIZE + extra;
        var threw = false;
        try {
            for (x in 0...total) m.seeFace(x, 0, Cells.N);
        } catch (e:String) { threw = true; }
        check("overflow never throws", !threw);
        check("overflow: length capped at QUEUE_SIZE", m.queueLength() == MapMemory.QUEUE_SIZE);
        check("overflow: oldest dropped, head is item #10", m.queuePeekCell(0) == Cells.pack(extra, 0));
        check("overflow: newest kept at the tail", m.queuePeekCell(MapMemory.QUEUE_SIZE - 1) == Cells.pack(total - 1, 0));
        check("overflow: order preserved across the ring wrap", m.queuePeekCell(1000) == Cells.pack(extra + 1000, 0));
        check("overflow: memory kept every face (queue loss is not memory loss)", m.flags(0, 0) == MapMemory.F_N && m.flags(total - 1, 0) == MapMemory.F_N);
        // drain in pages, the way MapPaper does, until empty: each item seen exactly once in order
        var seen = 0;
        var ordered = true;
        while (m.queueLength() > 0) {
            var n = m.queueLength();
            if (n > 64) n = 64;
            for (i in 0...n) {
                if (m.queuePeekCell(i) != Cells.pack(extra + seen, 0)) ordered = false;
                seen++;
            }
            m.queueDrop(n);
        }
        check("paged drain delivers each item once in order", ordered && seen == MapMemory.QUEUE_SIZE);
    }

    // (3) cap: after touching 300 chunks, evictFarthest leaves MAX_CHUNKS and the nearest are kept
    static function testCap():Void {
        var m = new MapMemory();
        for (cx in 0...300) m.visit(cx * 32 + 16, 16, Cells.FLOOR);
        check("300 chunks touched", m.chunkCount() == 300);
        var dropped = m.evictFarthest(16, 16);
        check("evictFarthest drops 44", dropped == 44);
        check("chunkCount == MAX_CHUNKS after evict", m.chunkCount() == MapMemory.MAX_CHUNKS);
        var keptOk = true;
        for (cx in 0...256) if (m.flags(cx * 32 + 16, 16) != MapMemory.VISITED) keptOk = false;
        var goneOk = true;
        for (cx in 256...300) if (m.flags(cx * 32 + 16, 16) != 0) goneOk = false;
        check("the nearest 256 chunks are kept", keptOk);
        check("the farthest 44 are gone (read back as unknown)", goneOk);
        check("evictFarthest again drops 0", m.evictFarthest(16, 16) == 0 && m.chunkCount() == MapMemory.MAX_CHUNKS);
        check("residentKeys count matches chunkCount", m.residentCount == m.chunkCount());
        // a dropped chunk can be re-touched: it comes back empty and counts again
        check("dropped chunk re-touch starts empty", m.seeFace(299 * 32 + 16, 16, Cells.N) && m.flags(299 * 32 + 16, 16) == MapMemory.F_N
            && m.chunkCount() == MapMemory.MAX_CHUNKS + 1);
        check("re-touched far chunk is the one evicted next", m.evictFarthest(16, 16) == 1 && m.flags(299 * 32 + 16, 16) == 0);
        // 2-D: touch 300 random chunks, evict around a player chunk, and compare with a brute-force nearest-256 rule
        var pcx = 3, pcy = -2;
        var m3 = new MapMemory();
        var r3 = new Rng(77);
        var keys = new haxe.ds.Vector<Int>(300);
        var t3 = 0;
        while (t3 < 300) {
            var cx = r3.range(-20, 21);
            var cy = r3.range(-20, 21);
            var x = cx * 32 + r3.range(0, 32);
            var y = cy * 32 + r3.range(0, 32);
            var before = m3.chunkCount();
            m3.seeFace(x, y, r3.range(0, 4));
            if (m3.chunkCount() > before) { keys[t3] = World.key(cx, cy); t3++; }
        }
        m3.evictFarthest(pcx * 32 + 5, pcy * 32 + 9);
        var strict = true;
        var maxKept3 = -1;
        for (i in 0...m3.residentCount) {
            var d = chebChunks(m3.residentKeys[i], pcx, pcy);
            if (d > maxKept3) maxKept3 = d;
        }
        for (i in 0...300) {
            var k = keys[i];
            var resident = false;
            for (j in 0...m3.residentCount) if (m3.residentKeys[j] == k) { resident = true; break; }
            if (!resident && chebChunks(k, pcx, pcy) < maxKept3) strict = false;
        }
        check("2-D strict: no dropped chunk is nearer than the farthest kept one", strict);
        // touching far beyond the cap without evicting never throws and never grows past the tolerated overshoot
        var m4 = new MapMemory();
        var threw = false;
        try {
            for (cx in 0...400) m4.seeFace(cx * 32, 0, Cells.N);
        } catch (e:String) { threw = true; }
        check("400 touches without evict: never throws", !threw);
        check("400 touches without evict: bounded (" + m4.chunkCount() + ")", m4.chunkCount() >= MapMemory.MAX_CHUNKS && m4.chunkCount() <= MapMemory.MAX_CHUNKS + 64);
        check("400 touches then evict: exactly MAX_CHUNKS", m4.evictFarthest(399 * 32, 0) >= 0 && m4.chunkCount() == MapMemory.MAX_CHUNKS);
        check("400 touches then evict near the end: the last chunk is kept", m4.flags(399 * 32, 0) == MapMemory.F_N);
        // pool: a long walk far past the cap with evictions on the way (the vectors are recycled): every re-touched
        // chunk comes back with NOTHING of its previous occupant, the count stays bounded, and new flags still stick
        var m5 = new MapMemory();
        var clean = true;
        var bounded = true;
        for (cx in 0...1200) {
            var x = cx * 32 + (cx & 31);
            if (m5.flags(x, 5) != 0 || m5.flags(cx * 32 + 31, 31) != 0) clean = false;   // never seen before (or evicted): reads 0
            m5.seeFace(x, 5, Cells.E);
            m5.visit(cx * 32 + 31, 31, Cells.PIT);
            if (m5.flags(x, 5) != MapMemory.F_E || m5.flags(cx * 32 + 31, 31) != (MapMemory.VISITED | MapMemory.PIT_SEEN)) clean = false;
            if ((cx % 50) == 49) m5.evictFarthest(x, 5);
            if (m5.chunkCount() > MapMemory.MAX_CHUNKS + 64) bounded = false;
        }
        check("pool: 1200 chunks over the cap, every fresh chunk reads 0 and takes new flags", clean);
        check("pool: resident count stays bounded through 1200 touches", bounded);
        m5.evictFarthest(1199 * 32, 5);
        check("pool: after the walk, exactly MAX_CHUNKS resident and the newest kept", m5.chunkCount() == MapMemory.MAX_CHUNKS
            && m5.flags(1199 * 32 + (1199 & 31), 5) == MapMemory.F_E);
        // a chunk evicted and walked back into starts empty and can be re-inked from scratch (the recycled vector was zeroed)
        var m6 = new MapMemory();
        for (cx in 0...300) m6.seeFace(cx * 32 + 3, 3, Cells.N);
        m6.evictFarthest(299 * 32, 3);                                                // drops chunks 0..43
        check("pool: evicted chunk 0 reads unknown", m6.flags(3, 3) == 0);
        check("pool: chunk 0 re-touched with a different face shows only that face", m6.seeFace(3, 3, Cells.W) && m6.flags(3, 3) == MapMemory.F_W
            && m6.flags(4, 3) == 0);
    }

    // forEachKnown: inclusive rectangle, world-packed cells, flags, max honoured, negative coordinates, multi-chunk
    static function testForEachKnown():Void {
        var m = new MapMemory();
        var out = new haxe.ds.Vector<Int>(64);
        var outF = new haxe.ds.Vector<Int>(64);
        check("forEachKnown on empty memory returns 0", m.forEachKnown(0, 0, 63, 63, out, outF, 64) == 0);
        m.seeFace(3, 3, Cells.N);
        m.seeFace(4, 3, Cells.E);
        m.visit(40, 3, Cells.WET);                              // second chunk along x
        m.seeFace(3, 4, Cells.S);                               // outside the y range below
        var n = m.forEachKnown(0, 0, 63, 3, out, outF, 64);
        check("rect (0,0)-(63,3) inclusive holds 3 cells", n == 3);
        var found3 = false, found4 = false, found40 = false, wrong = false;
        for (i in 0...n) {
            var x = Cells.unpackX(out[i]);
            var y = Cells.unpackY(out[i]);
            if (x == 3 && y == 3 && outF[i] == MapMemory.F_N) found3 = true;
            else if (x == 4 && y == 3 && outF[i] == MapMemory.F_E) found4 = true;
            else if (x == 40 && y == 3 && outF[i] == (MapMemory.VISITED | MapMemory.WET_SEEN)) found40 = true;
            else wrong = true;
        }
        check("cells and flags reported exactly", found3 && found4 && found40 && !wrong);
        check("max honoured", m.forEachKnown(0, 0, 63, 3, out, outF, 2) == 2);
        check("single-cell rect", m.forEachKnown(3, 3, 3, 3, out, outF, 64) == 1 && out[0] == Cells.pack(3, 3));
        check("row 4 alone", m.forEachKnown(0, 4, 63, 4, out, outF, 64) == 1 && out[0] == Cells.pack(3, 4) && outF[0] == MapMemory.F_S);
        check("empty rect (x1 < x0) returns 0", m.forEachKnown(5, 0, 4, 10, out, outF, 64) == 0);
        check("max 0 returns 0", m.forEachKnown(0, 0, 63, 63, out, outF, 0) == 0);
        m.seeFace(-35, -35, Cells.W);
        var nn = m.forEachKnown(-40, -40, -30, -30, out, outF, 64);
        check("negative rect", nn == 1 && Cells.unpackX(out[0]) == -35 && Cells.unpackY(out[0]) == -35 && outF[0] == MapMemory.F_W);
        // a sheet-sized query (64x64 spanning 4 chunks) counts every known cell once
        var m2 = new MapMemory();
        var big = new haxe.ds.Vector<Int>(4096);
        var bigF = new haxe.ds.Vector<Int>(4096);
        var placed = 0;
        for (y in 0...64) for (x in 0...64) if (((x * 7 + y * 13) & 3) == 0) { m2.seeFace(x, y, Cells.N); placed++; }
        var got = m2.forEachKnown(0, 0, 63, 63, big, bigF, 4096);
        var uniq = true;
        for (i in 0...got) for (j in i + 1...got) if (big[i] == big[j]) uniq = false;
        check("64x64 query over 4 chunks: " + placed + " cells, each once", got == placed && uniq);
        check("row scan of the same sheet sums to the same count", {
            var sum = 0;
            for (row in 0...64) sum += m2.forEachKnown(0, row, 63, row, big, bigF, 64);
            sum == placed;
        });
    }
}
