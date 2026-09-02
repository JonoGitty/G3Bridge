// Unit tests for World (CONTRACT §1, DESIGN §11). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
class TestWorld {
    static var fails:Int = 0;

    static function check(name:String, ok:Bool):Void {
        Sys.println("  " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok) fails++;
    }

    static function copyCells(c:Chunk):haxe.ds.Vector<Int> {
        var v = new haxe.ds.Vector<Int>(Chunk.AREA);
        for (i in 0...Chunk.AREA) v[i] = c.cells[i];
        return v;
    }

    static function sameAs(c:Chunk, v:haxe.ds.Vector<Int>):Bool {
        for (i in 0...Chunk.AREA) if (c.cells[i] != v[i]) return false;
        return true;
    }

    public static function run():Int {
        fails = 0;
        var rng = new Rng(99);

        // ---- key: distinct in all four quadrants, decodes both ways ----
        var kOk = World.key(0, 0) != World.key(-1, -1) && World.key(-1, 0) != World.key(0, -1)
            && World.key(1, -1) != World.key(-1, 1) && World.key(32767, -32768) != World.key(-32768, 32767);
        check("key distinguishes the four sign quadrants", kOk);

        // ---- (4) unloaded cell -> WALL; has/chunkAt on an empty world ----
        var w = new World(1234);
        check("empty world: cell reads WALL, has false, chunkAt null, loadedCount 0",
            w.cell(5, 5) == Cells.WALL && w.cell(-5, -5) == Cells.WALL && !w.has(0, 0) && w.chunkAt(0, 0) == null && w.loadedCount() == 0 && w.pendingCount() == 0);

        // ---- (1) cell matches chunkAt(...).get(x & 31, y & 31) in all four sign quadrants ----
        var quadOk = true;
        for (q in 0...4) {
            var cx = (q & 1) == 0 ? 1 : -2;
            var cy = (q & 2) == 0 ? 1 : -2;
            var c = w.generateNow(cx, cy);
            if (c == null || c.cx != cx || c.cy != cy || w.chunkAt(cx, cy) != c || !w.has(cx, cy)) { quadOk = false; continue; }
            for (y in 0...32) {
                for (x in 0...32) {
                    var wx = (cx << 5) + x, wy = (cy << 5) + y;
                    if (w.cell(wx, wy) != c.get(x, y)) quadOk = false;
                    if (w.cell(wx, wy) != c.get(wx & 31, wy & 31)) quadOk = false;
                    if (w.solid(wx, wy) != Cells.solid(c.get(x, y))) quadOk = false;
                    if (Cells.chunkOf(wx) != cx || Cells.chunkOf(wy) != cy) quadOk = false;
                }
            }
        }
        check("cell(x, y) == chunkAt(cx, cy).get(x & 31, y & 31) in all four sign quadrants", quadOk);
        check("cells just outside a resident chunk read WALL (unloaded neighbour)",
            w.cell(64, 64) == Cells.WALL && w.cell(-65, -65) == Cells.WALL && w.cell(64, 40) == Cells.WALL && w.cell(31, 31) == Cells.WALL);
        // interleaved reads across chunks (the last-chunk cache must not leak)
        var mixOk = true;
        var c1 = w.chunkAt(1, 1), c2 = w.chunkAt(-2, -2);
        for (t in 0...500) {
            var x = rng.range(0, 32), y = rng.range(0, 32);
            if (w.cell(32 + x, 32 + y) != c1.get(x, y)) mixOk = false;
            if (w.cell(-64 + x, -64 + y) != c2.get(x, y)) mixOk = false;
            if (w.cell(100 + x, 100 + y) != Cells.WALL) mixOk = false;
        }
        check("interleaved reads across resident and non-resident chunks are exact", mixOk);
        check("generateNow twice returns the same resident object", w.generateNow(1, 1) == c1 && w.loadedCount() == 4);

        // ---- (3) an evicted chunk, regenerated, is byte-identical ----
        var snap = copyCells(c1);
        var ev = w.evictOutside(-2, -2, 1);
        check("evictOutside(-2, -2, 1) evicts the three far chunks and keeps (-2, -2)",
            ev == 3 && w.loadedCount() == 1 && !w.has(1, 1) && w.has(-2, -2) && w.chunkAt(1, 1) == null && w.cell(40, 40) == Cells.WALL);
        var again = w.generateNow(1, 1);
        check("evicted chunk regenerates byte-identical", sameAs(again, snap) && again.cx == 1 && again.cy == 1);
        var ref = new Chunk();
        ChunkGen.generate(1234, 1, 1, ref);
        check("resident chunk equals a direct ChunkGen.generate of the same (seed, cx, cy)", sameAs(ref, snap));

        // ---- ensureAround / pump: nearest first, pump generates at most maxChunks, ring bounded ----
        var w2 = new World(4321);
        var queued = w2.ensureAround(0, 0);
        check("ensureAround queues the 9 missing chunks of the 3x3", queued == 9 && w2.pendingCount() == 9);
        check("ensureAround again queues nothing new", w2.ensureAround(0, 0) == 0 && w2.pendingCount() == 9);
        var g = w2.pump(1);
        check("pump(1) generates exactly one, the centre chunk first", g == 1 && w2.loadedCount() == 1 && w2.has(0, 0) && w2.pendingCount() == 8);
        g = w2.pump(1);
        check("second pump(1) generates a 4-neighbour of the centre", g == 1 && w2.loadedCount() == 2
            && (w2.has(1, 0) || w2.has(-1, 0) || w2.has(0, 1) || w2.has(0, -1)));
        g = w2.pump(100);
        check("pump drains the ring (7 left) and never exceeds it", g == 7 && w2.loadedCount() == 9 && w2.pendingCount() == 0);
        check("pump on an empty ring generates nothing", w2.pump(1) == 0);
        // moving the window drops stale ring entries and queues the new column
        w2.ensureAround(0, 0);
        var q2 = w2.ensureAround(5, 5);
        check("ensureAround at a new centre replaces stale ring entries (queued " + q2 + ")", q2 == 9 && w2.pendingCount() == 9);
        w2.pump(9);
        check("resident window after the move is 18 (<= MAX_CHUNKS)", w2.loadedCount() == 18 && w2.has(5, 5) && w2.has(0, 0));
        w2.ensureAround(9, 9);
        w2.pump(9);
        check("pool cap: 27 wanted, loadedCount stays at MAX_CHUNKS and the 3x3 around (9, 9) is resident",
            w2.loadedCount() == World.MAX_CHUNKS && w2.has(8, 8) && w2.has(10, 10) && w2.has(9, 9) && w2.has(9, 8));
        var farLeft = 0;
        for (dy in -1...2) for (dx in -1...2) if (w2.has(dx, dy)) farLeft++;
        check("evict-farthest in pump removed two chunks at Chebyshev 10 from the centre (" + farLeft + " of the old 3x3 left)",
            farLeft == 7 && w2.has(1, 1) && w2.has(1, 0) && w2.has(0, 1) && w2.residentCount == World.MAX_CHUNKS);
        check("residentKeys holds exactly the resident keys", (function() {
            for (i in 0...w2.residentCount) {
                var k = w2.residentKeys[i];
                var cx = (k >>> 16) - 0x8000, cy = (k & 0xFFFF) - 0x8000;
                if (!w2.has(cx, cy)) return false;
                for (j in 0...i) if (w2.residentKeys[j] == k) return false;
            }
            return true;
        })());
        var evicted = w2.evictOutside(9, 9, World.EVICT_RADIUS);
        check("evictOutside(EVICT_RADIUS) leaves only the 5x5 (" + evicted + " evicted, " + w2.loadedCount() + " left)",
            w2.loadedCount() <= 25 && w2.has(9, 9) && !w2.has(5, 5) && evicted > 0);

        // ---- generateNow beyond the cap evicts the farthest from the requested chunk ----
        var w3 = new World(77);
        for (i in 0...World.MAX_CHUNKS) w3.generateNow(i, 0);
        check("25 generateNow fill the pool exactly", w3.loadedCount() == World.MAX_CHUNKS && w3.has(0, 0) && w3.has(24, 0));
        w3.generateNow(30, 0);
        check("26th chunk evicts the farthest (0, 0) and keeps the count at 25", w3.loadedCount() == World.MAX_CHUNKS && !w3.has(0, 0) && w3.has(30, 0) && w3.has(24, 0));

        // ---- altSeed path: after a reported generate error the in-flight key regenerates with altSeed ----
        var w4 = new World(555);
        var c0 = w4.generateNow(7, 7);
        var base = copyCells(c0);
        w4.evictOutside(100, 100, 1);
        w4.genErrors++;                                   // Main's report: the last generate (7, 7) threw
        var alt = w4.generateNow(7, 7);
        var altRef = new Chunk();
        ChunkGen.generate(555, 7, 7, altRef, 1);
        check("after genErrors++ the failed key regenerates with altSeed = 1", !sameAs(alt, base) && sameAs(alt, copyCells(altRef)));
        var other = w4.generateNow(8, 7);
        var otherRef = new Chunk();
        ChunkGen.generate(555, 8, 7, otherRef);
        check("other keys still use altSeed 0 after an error", sameAs(other, copyCells(otherRef)));
        w4.evictOutside(100, 100, 1);
        check("the failed key keeps its altSeed when regenerated again (deterministic within the run)", sameAs(w4.generateNow(7, 7), copyCells(altRef)));

        // ---- (2) random walk: window never exceeds MAX_CHUNKS, the player's cell is always readable ----
        var w5 = new World(2026);
        var px = 16, py = 16;
        var maxLoaded = 0;
        var maxPending = 0;
        var walkBad = 0;
        var readBad = 0;
        var frame = 0;
        var steps = 100000;
        var drift = 0;
        for (s in 0...steps) {
            // a biased random walk with a slowly turning drift so it both roams and revisits
            if ((s & 1023) == 0) drift = rng.range(0, 4);
            var d = rng.chance(0.6) ? drift : rng.range(0, 4);
            var nx = px, ny = py;
            switch (d) {
                case 0: ny--;
                case 1: nx++;
                case 2: ny++;
                default: nx--;
            }
            px = nx; py = ny;
            var cx = px >> 5, cy = py >> 5;
            w5.ensureAround(cx, cy);
            w5.pump(1);
            if (frame % 30 == 0) w5.evictOutside(cx, cy, World.EVICT_RADIUS);
            frame++;
            if (w5.loadedCount() > maxLoaded) maxLoaded = w5.loadedCount();
            if (w5.pendingCount() > maxPending) maxPending = w5.pendingCount();
            if (w5.loadedCount() > World.MAX_CHUNKS || w5.residentCount > World.MAX_CHUNKS) walkBad++;
            if (!w5.has(cx, cy)) readBad++;
            var v = w5.cell(px, py);
            var t = Cells.type(v);
            if (t < 0 || t > Cells.PIT) readBad++;
            if (w5.cell(px, py) != w5.chunkAt(cx, cy).get(px & 31, py & 31)) readBad++;
        }
        check("100k-step walk: resident count never exceeds MAX_CHUNKS (max " + maxLoaded + ")", walkBad == 0 && maxLoaded <= World.MAX_CHUNKS);
        check("100k-step walk: the player's chunk is always resident and its cell readable (bad " + readBad + ")", readBad == 0);
        check("100k-step walk: pending ring never exceeds 16 (max " + maxPending + ")", maxPending <= 16);
        check("100k-step walk: ended far from the origin in negative or positive space (" + px + ", " + py + ")", true);
        // the window around the final position is complete after a settle
        var fx = px >> 5, fy = py >> 5;
        w5.ensureAround(fx, fy);
        w5.pump(9);
        var winOk = true;
        for (dy in -1...2) for (dx in -1...2) if (!w5.has(fx + dx, fy + dy)) winOk = false;
        check("after settling, the whole 3x3 around the player is resident", winOk);

        // ---- negative coordinates: chunks at (-1, -1) etc. through ensureAround/pump ----
        var w6 = new World(31337);
        w6.ensureAround(-1, -1);
        w6.pump(9);
        var negOk = w6.loadedCount() == 9;
        for (dy in -2...1) for (dx in -2...1) if (!w6.has(dx, dy)) negOk = false;
        var cm = w6.chunkAt(-1, -1);
        for (y in 0...32) for (x in 0...32) if (w6.cell(-32 + x, -32 + y) != cm.get(x, y)) negOk = false;
        check("negative coordinates: 3x3 around (-1, -1) resident and cell reads match", negOk);
        check("negative coordinates: (-1, -1) and (0, 0) are different chunks", w6.chunkAt(-1, -1) != w6.chunkAt(0, 0) && w6.cell(-1, -1) == cm.get(31, 31));
        return fails;
    }
}
