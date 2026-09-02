// What the camera has seen, per cell (CONTRACT §1, DESIGN §4). Core class: no flash.* imports.
//
// Storage: one 1024-entry haxe.ds.Vector<Int> per touched 32x32 chunk, keyed by World.key(cx, cy),
// index (ly << 5) | lx. Bits 0-3 = faces seen (N=1, E=2, S=4, W=8), 4 = visited, 5/6/7 = wet/dark/pit.
// The chunk vectors are a POOL: all CAPACITY of them are allocated once in the constructor (rule 4
// exemption e, "a preallocated pool" variant, ~1.3 MB) and never freed. A first touch pops a vector off
// the free list and zeroes it; a dropped chunk leaves the Map and pushes its vector back, so nothing is
// allocated or garbage-collected in the frame loop however far the tape walks. The parallel
// residentKeys vector is the ONLY thing the farthest-chunk scan walks (Map.keys()/iterator() are never
// called).
//
// Residency capacity: Main calls evictFarthest only every 3rd frame and only once chunkCount() exceeds
// MAX_CHUNKS, so the resident set legitimately overshoots the cap between a touch and the evict (and the
// contract's own test touches 300 chunks before evicting). residentKeys therefore carries a slack of
// 64 entries beyond MAX_CHUNKS (CAPACITY = 320; the contract's MapMemory section says "MAX_CHUNKS
// entries" — the slack is the only difference, and nothing indexes residentKeys beyond residentCount).
// If even the slack is exhausted (never in play: a recordHits touches at most 4 chunks), the touch
// itself drops the chunk farthest from the touched cell, so nothing ever throws and nothing ever grows.
//
// Queue: a ring of QUEUE_SIZE (packed WORLD cell, kind) pairs. Kind k is exactly the bit index of the flag
// it announces (0..3 = N/E/S/W, 4 = visited, 5 = wet, 6 = dark, 7 = pit), so 1 << kind is the flag bit.
// When the ring is full the OLDEST item is dropped (the paper re-inks from memory, so nothing is lost
// for good). forEachKnown takes an INCLUSIVE rectangle (x0..x1, y0..y1).
class MapMemory {
    public static inline var F_N = 1;
    public static inline var F_E = 2;
    public static inline var F_S = 4;
    public static inline var F_W = 8;
    public static inline var VISITED = 16;
    public static inline var WET_SEEN = 32;
    public static inline var DARK_SEEN = 64;
    public static inline var PIT_SEEN = 128;
    public static inline var MAX_CHUNKS = 256;
    public static inline var INK_DIST = 10;            // cells; faces beyond this are not recorded (16.16 compare against INK_DIST << 16)
    public static inline var QUEUE_SIZE = 4096;
    public var residentKeys:haxe.ds.Vector<Int>;       // CAPACITY entries (MAX_CHUNKS + slack), parallel to the Map: keys of allocated chunks (evictFarthest scans this, never Map.keys())
    public var residentCount:Int;

    static inline var SLACK = 64;                      // overshoot tolerated between touches and the next evictFarthest
    static inline var CAPACITY = 320;                  // MAX_CHUNKS + SLACK
    static inline var CHUNK_AREA = 1024;
    static inline var QUEUE_MASK = 4095;               // QUEUE_SIZE - 1
    static inline var INK_DIST_FP = 655360;            // INK_DIST << 16
    static inline var K_VISITED = 4;
    static inline var K_WET = 5;
    static inline var K_DARK = 6;
    static inline var K_PIT = 7;

    var chunks:Map<Int, haxe.ds.Vector<Int>>;         // 1024 flags per chunk, key = World.key
    var free:haxe.ds.Vector<haxe.ds.Vector<Int>>;      // pool of chunk vectors not in the Map; residentCount + freeCount == CAPACITY
    var freeCount:Int;
    var queueCell:haxe.ds.Vector<Int>;                 // ring: packed cell
    var queueKind:haxe.ds.Vector<Int>;                 // ring: kind 0..7
    var queueHead:Int;
    var queueLen:Int;
    var lastKey:Int;                                   // one-entry chunk cache (a ray sweep stays in 1-2 chunks)
    var lastVec:haxe.ds.Vector<Int>;

    // allocates the queue, residentKeys and the whole chunk-vector pool (rule 4 exemption e: the
    // preallocated-pool variant, so touch() never allocates)
    public function new():Void {
        chunks = new Map<Int, haxe.ds.Vector<Int>>();
        residentKeys = new haxe.ds.Vector<Int>(CAPACITY);
        for (i in 0...CAPACITY) residentKeys[i] = 0;
        residentCount = 0;
        free = new haxe.ds.Vector<haxe.ds.Vector<Int>>(CAPACITY);
        for (i in 0...CAPACITY) {
            var v = new haxe.ds.Vector<Int>(CHUNK_AREA);
            for (j in 0...CHUNK_AREA) v[j] = 0;
            free[i] = v;
        }
        freeCount = CAPACITY;
        queueCell = new haxe.ds.Vector<Int>(QUEUE_SIZE);
        queueKind = new haxe.ds.Vector<Int>(QUEUE_SIZE);
        for (i in 0...QUEUE_SIZE) { queueCell[i] = 0; queueKind[i] = 0; }
        queueHead = 0;
        queueLen = 0;
        lastKey = 0;
        lastVec = null;
    }

    // ---- chunk storage -------------------------------------------------------------------------

    // The flag vector of chunk (cx, cy), or null if the chunk was never touched.
    function peek(cx:Int, cy:Int):haxe.ds.Vector<Int> {
        var k = World.key(cx, cy);
        if (k == lastKey && lastVec != null) return lastVec;
        var v = chunks.get(k);
        if (v != null) { lastKey = k; lastVec = v; }
        return v;
    }

    // The flag vector of chunk (cx, cy), taking one from the pool on first touch (never allocates: the pool
    // holds CAPACITY vectors and residentCount + freeCount == CAPACITY, so after the drop below it is non-empty).
    function touch(cx:Int, cy:Int):haxe.ds.Vector<Int> {
        var k = World.key(cx, cy);
        if (k == lastKey && lastVec != null) return lastVec;
        var v = chunks.get(k);
        if (v == null) {
            if (freeCount == 0) dropFarthestFrom(cx, cy);                // never in play; keeps the set bounded
            freeCount--;
            v = free[freeCount];
            free[freeCount] = null;
            for (i in 0...CHUNK_AREA) v[i] = 0;                          // a pooled vector carries its old occupant's flags
            chunks.set(k, v);
            residentKeys[residentCount] = k;
            residentCount++;
        }
        lastKey = k;
        lastVec = v;
        return v;
    }

    static inline function keyCx(k:Int):Int return (k >>> 16) - 0x8000;
    static inline function keyCy(k:Int):Int return (k & 0xFFFF) - 0x8000;

    // Removes resident slot i (swap-remove so residentKeys[0..residentCount) stays dense); its vector goes back to the pool.
    function dropSlot(i:Int):Void {
        var k = residentKeys[i];
        free[freeCount] = chunks.get(k);
        freeCount++;
        chunks.remove(k);
        if (k == lastKey) lastVec = null;
        residentCount--;
        residentKeys[i] = residentKeys[residentCount];
        residentKeys[residentCount] = 0;
    }

    // Index of the resident chunk with the largest Chebyshev distance from chunk (pcx, pcy); -1 if none.
    // Ties go to the first (oldest) slot found, so eviction order is deterministic.
    function farthestSlot(pcx:Int, pcy:Int):Int {
        var keys = residentKeys;
        var n = residentCount;
        var best = -1;
        var bestD = -1;
        for (i in 0...n) {
            var k = keys[i];
            var dx = keyCx(k) - pcx; if (dx < 0) dx = -dx;
            var dy = keyCy(k) - pcy; if (dy < 0) dy = -dy;
            var d = dx > dy ? dx : dy;
            if (d > bestD) { bestD = d; best = i; }
        }
        return best;
    }

    function dropFarthestFrom(pcx:Int, pcy:Int):Void {
        var i = farthestSlot(pcx, pcy);
        if (i >= 0) dropSlot(i);
    }

    // ---- queue ----------------------------------------------------------------------------------

    function push(cell:Int, kind:Int):Void {
        if (queueLen == QUEUE_SIZE) {                  // full: the oldest item makes room
            queueHead = (queueHead + 1) & QUEUE_MASK;
            queueLen--;
        }
        var at = (queueHead + queueLen) & QUEUE_MASK;
        queueCell[at] = cell;
        queueKind[at] = kind;
        queueLen++;
    }

    // ---- public API -----------------------------------------------------------------------------

    // 0 if the chunk is unknown
    public function flags(x:Int, y:Int):Int {
        var v = peek(x >> 5, y >> 5);
        if (v == null) return 0;
        return v[((y & 31) << 5) | (x & 31)];
    }

    // sets F_* bit; true if it was newly set (and then queued)
    public function seeFace(x:Int, y:Int, face:Int):Bool {
        var v = touch(x >> 5, y >> 5);
        var i = ((y & 31) << 5) | (x & 31);
        var bit = 1 << face;
        var f = v[i];
        if ((f & bit) != 0) return false;
        v[i] = f | bit;
        push(Cells.pack(x, y), face);
        return true;
    }

    // sets VISITED (+ WET/DARK/PIT_SEEN from the cell type); true if new
    public function visit(x:Int, y:Int, cellValue:Int):Bool {
        var v = touch(x >> 5, y >> 5);
        var i = ((y & 31) << 5) | (x & 31);
        var f = v[i];
        var want = VISITED;
        var t = cellValue & Cells.TYPE_MASK;
        if (t == Cells.WET) want |= WET_SEEN;
        else if (t == Cells.DARK) want |= DARK_SEEN;
        else if (t == Cells.PIT) want |= PIT_SEEN;
        var added = want & ~f;
        if (added == 0) return false;
        v[i] = f | added;
        var p = Cells.pack(x, y);
        if ((added & VISITED) != 0) push(p, K_VISITED);
        if ((added & WET_SEEN) != 0) push(p, K_WET);
        if ((added & DARK_SEEN) != 0) push(p, K_DARK);
        if ((added & PIT_SEEN) != 0) push(p, K_PIT);
        return (added & VISITED) != 0;
    }

    // for every column with hit == 1 and dist < INK_DIST << 16: seeFace(cellX, cellY, face); returns newly set count
    public function recordHits(h:RayHits):Int {
        var n = h.count;
        var hit = h.hit;
        var dist = h.dist;
        var cellX = h.cellX;
        var cellY = h.cellY;
        var face = h.face;
        var added = 0;
        // local chunk cache: consecutive columns almost always land in the same chunk
        var ccx = 0x7FFFFFFF;
        var ccy = 0x7FFFFFFF;
        var v:haxe.ds.Vector<Int> = null;
        for (i in 0...n) {
            if (hit[i] != 1) continue;
            if (dist[i] >= INK_DIST_FP) continue;
            var x = cellX[i];
            var y = cellY[i];
            var cx = x >> 5;
            var cy = y >> 5;
            if (cx != ccx || cy != ccy) {
                v = touch(cx, cy);
                ccx = cx;
                ccy = cy;
            }
            var idx = ((y & 31) << 5) | (x & 31);
            var fc = face[i];
            var bit = 1 << fc;
            var f = v[idx];
            if ((f & bit) != 0) continue;
            v[idx] = f | bit;
            push(Cells.pack(x, y), fc);
            added++;
        }
        return added;
    }

    public function chunkCount():Int {
        return residentCount;
    }

    // while chunkCount() > MAX_CHUNKS drop the chunk with the largest Chebyshev distance; returns dropped count
    public function evictFarthest(px:Int, py:Int):Int {
        var pcx = px >> 5;
        var pcy = py >> 5;
        var dropped = 0;
        while (residentCount > MAX_CHUNKS) {
            var i = farthestSlot(pcx, pcy);
            if (i < 0) break;
            dropSlot(i);
            dropped++;
        }
        return dropped;
    }

    // queue of newly inked items for MapPaper: packed WORLD cell (Cells.pack(x, y), never chunk-local) with the face or flag in a parallel vector
    public function queueLength():Int {
        return queueLen;
    }

    // i in 0..queueLength()-1, packed x,y
    public function queuePeekCell(i:Int):Int {
        return queueCell[(queueHead + i) & QUEUE_MASK];
    }

    // 0..3 = face N/E/S/W; 4 = visited; 5 = wet; 6 = dark; 7 = pit
    public function queuePeekKind(i:Int):Int {
        return queueKind[(queueHead + i) & QUEUE_MASK];
    }

    // remove the first n items
    public function queueDrop(n:Int):Void {
        if (n <= 0) return;
        if (n > queueLen) n = queueLen;
        queueHead = (queueHead + n) & QUEUE_MASK;
        queueLen -= n;
    }

    // re-ink support for a sheet: iterate all known cells in the INCLUSIVE rectangle x0..x1, y0..y1
    // (chunk-major order); fills packed cells + flags, returns count (stops at max)
    public function forEachKnown(x0:Int, y0:Int, x1:Int, y1:Int, out:haxe.ds.Vector<Int>, outFlags:haxe.ds.Vector<Int>, max:Int):Int {
        var n = 0;
        if (max <= 0 || x1 < x0 || y1 < y0) return 0;
        var cx0 = x0 >> 5;
        var cx1 = x1 >> 5;
        var cy0 = y0 >> 5;
        var cy1 = y1 >> 5;
        for (cy in cy0...cy1 + 1) {
            var by = cy << 5;
            var ly0 = y0 - by; if (ly0 < 0) ly0 = 0;
            var ly1 = y1 - by; if (ly1 > 31) ly1 = 31;
            for (cx in cx0...cx1 + 1) {
                var v = chunks.get(World.key(cx, cy));
                if (v == null) continue;
                var bx = cx << 5;
                var lx0 = x0 - bx; if (lx0 < 0) lx0 = 0;
                var lx1 = x1 - bx; if (lx1 > 31) lx1 = 31;
                for (ly in ly0...ly1 + 1) {
                    var row = ly << 5;
                    var wy = by + ly;
                    for (lx in lx0...lx1 + 1) {
                        var f = v[row | lx];
                        if (f == 0) continue;
                        if (n >= max) return n;
                        out[n] = Cells.pack(bx + lx, wy);
                        outFlags[n] = f;
                        n++;
                    }
                }
            }
        }
        return n;
    }
}
