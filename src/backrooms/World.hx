// Resident chunk window with pool and pending ring (CONTRACT §1). Core class: no flash.* imports.
//
// The Map<Int, Chunk> keyed by World.key holds the resident chunks; residentKeys is the parallel
// dense vector every eviction scan walks (Map.keys() is never called after the constructor).
// MAX_CHUNKS Chunk objects are allocated once in the constructor and cycle between the pool and
// the map; nothing here allocates after that.  ensureAround queues the missing chunks of the
// window nearest first into a 16-entry ring (dropping ring entries that fell outside the new
// window); pump generates from the ring, taking a pooled Chunk or evicting the resident chunk
// farthest from the last ensureAround centre when the pool is empty.
//
// Error recovery: when ChunkGen.generate throws, the Chunk it was writing is still on the pool
// (the pool count is only decremented after generate returns) and the map is untouched.  Main
// increments genErrors; the next pump/generateNow notices, remembers the key that was in flight,
// and regenerates that key (and only that key) with altSeed = genErrors from then on, so the
// world stays deterministic within the run.
//
// cell() is the raycaster's hot call (~4,000 per frame): one key computation, a compare against
// the last chunk looked up, and a shifted index into its vector.
class World {
    public static inline var RESIDENT_RADIUS = 1;     // 3x3 ensured around the player
    public static inline var EVICT_RADIUS = 2;        // beyond Chebyshev 2 is evicted
    public static inline var MAX_CHUNKS = 25;
    static inline var PENDING_SIZE = 16;       // pending ring capacity (contract: "capacity 16")
    static inline var PENDING_MASK = 15;
    public var tapeSeed:Int;
    public var genErrors:Int;                         // incremented by Main when a generate throws; next attempt uses altSeed
    public var residentKeys:haxe.ds.Vector<Int>;      // MAX_CHUNKS entries, parallel to the Map: keys of resident chunks (eviction scans this, never Map.keys())
    public var residentCount:Int;

    // private storage
    var chunks:Map<Int, Chunk>;
    var pool:haxe.ds.Vector<Chunk>;                   // MAX_CHUNKS preallocated Chunk objects
    var poolCount:Int;                                // free objects in the pool
    var pending:haxe.ds.Vector<Int>;                  // ring of World.key values
    var pendingHead:Int;
    var pendingLen:Int;
    var lastKey:Int;                                  // last chunk looked up by cell()
    var lastChunk:Chunk;
    var winDx:haxe.ds.Vector<Int>;                    // window offsets, nearest first
    var winDy:haxe.ds.Vector<Int>;
    var winCount:Int;
    var centreX:Int;                                  // last ensureAround centre (eviction reference for pump)
    var centreY:Int;
    var inFlightKey:Int;                              // key of the chunk generate was last asked for
    var seenErrors:Int;                               // genErrors value already accounted for
    var failKey:Int;                                  // the key that threw; regenerated with failAlt
    var failAlt:Int;
    var hasFail:Bool;

    // preallocates a pool of MAX_CHUNKS Chunk objects and residentKeys
    public function new(tapeSeed:Int):Void {
        this.tapeSeed = tapeSeed;
        genErrors = 0;
        chunks = new Map<Int, Chunk>();
        pool = new haxe.ds.Vector<Chunk>(MAX_CHUNKS);
        for (i in 0...MAX_CHUNKS) pool[i] = new Chunk();
        poolCount = MAX_CHUNKS;
        residentKeys = new haxe.ds.Vector<Int>(MAX_CHUNKS);
        for (i in 0...MAX_CHUNKS) residentKeys[i] = 0;
        residentCount = 0;
        pending = new haxe.ds.Vector<Int>(PENDING_SIZE);
        for (i in 0...PENDING_SIZE) pending[i] = 0;
        pendingHead = 0;
        pendingLen = 0;
        lastKey = 0;
        lastChunk = null;
        centreX = 0;
        centreY = 0;
        inFlightKey = 0;
        seenErrors = 0;
        failKey = 0;
        failAlt = 0;
        hasFail = false;
        // window offsets sorted by squared distance (insertion sort, once)
        var r = RESIDENT_RADIUS;
        var side = 2 * r + 1;
        winCount = side * side;
        winDx = new haxe.ds.Vector<Int>(winCount);
        winDy = new haxe.ds.Vector<Int>(winCount);
        var n = 0;
        for (dy in -r...r + 1) {
            for (dx in -r...r + 1) {
                var d = dx * dx + dy * dy;
                var j = n;
                while (j > 0 && winDx[j - 1] * winDx[j - 1] + winDy[j - 1] * winDy[j - 1] > d) {
                    winDx[j] = winDx[j - 1];
                    winDy[j] = winDy[j - 1];
                    j--;
                }
                winDx[j] = dx;
                winDy[j] = dy;
                n++;
            }
        }
    }

    public static inline function key(cx:Int, cy:Int):Int return ((cx + 0x8000) << 16) | ((cy + 0x8000) & 0xFFFF);

    static inline function keyX(k:Int):Int return (k >>> 16) - 0x8000;
    static inline function keyY(k:Int):Int return (k & 0xFFFF) - 0x8000;

    // world coords; Cells.WALL if the chunk is not resident
    public function cell(x:Int, y:Int):Int {
        var k = (((x >> 5) + 0x8000) << 16) | (((y >> 5) + 0x8000) & 0xFFFF);
        var c = lastChunk;
        if (c == null || k != lastKey) {
            c = chunks.get(k);
            if (c == null) return Cells.WALL;
            lastChunk = c;
            lastKey = k;
        }
        return c.cells[((y & 31) << 5) | (x & 31)];
    }

    // Cells.solid(cell(x, y))
    public inline function solid(x:Int, y:Int):Bool return Cells.solid(cell(x, y));

    public function has(cx:Int, cy:Int):Bool {
        return chunks.exists(key(cx, cy));
    }

    // null if not resident
    public function chunkAt(cx:Int, cy:Int):Chunk {
        return chunks.get(key(cx, cy));
    }

    // queues every missing chunk in the (2R+1)^2 window, nearest first; returns queued count
    public function ensureAround(cx:Int, cy:Int):Int {
        centreX = cx;
        centreY = cy;
        // drop ring entries that fell outside the new window (compacting in place)
        var kept = 0;
        for (j in 0...pendingLen) {
            var k = pending[(pendingHead + j) & PENDING_MASK];
            var dx = keyX(k) - cx;
            var dy = keyY(k) - cy;
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            if (dx > RESIDENT_RADIUS || dy > RESIDENT_RADIUS) continue;
            pending[(pendingHead + kept) & PENDING_MASK] = k;
            kept++;
        }
        pendingLen = kept;
        var queued = 0;
        for (i in 0...winCount) {
            var k = key(cx + winDx[i], cy + winDy[i]);
            if (chunks.exists(k)) continue;
            var dup = false;
            for (j in 0...pendingLen) {
                if (pending[(pendingHead + j) & PENDING_MASK] == k) { dup = true; break; }
            }
            if (dup) continue;
            if (pendingLen >= PENDING_SIZE) break;
            pending[(pendingHead + pendingLen) & PENDING_MASK] = k;
            pendingLen++;
            queued++;
        }
        return queued;
    }

    // generates up to maxChunks from the queue (pool or evict-farthest to make room, scanning residentKeys); returns generated count
    public function pump(maxChunks:Int):Int {
        noteErrors();
        var generated = 0;
        while (generated < maxChunks && pendingLen > 0) {
            var k = pending[pendingHead];
            pendingHead = (pendingHead + 1) & PENDING_MASK;
            pendingLen--;
            if (chunks.exists(k)) continue;
            var c = acquire(centreX, centreY);
            gen(k, c);
            generated++;
        }
        return generated;
    }

    // returns evicted count; evicted chunks go back to the pool
    public function evictOutside(cx:Int, cy:Int, r:Int):Int {
        var n = 0;
        var i = 0;
        while (i < residentCount) {
            var k = residentKeys[i];
            var dx = keyX(k) - cx;
            var dy = keyY(k) - cy;
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            if (dx > r || dy > r) {
                removeAt(i);
                n++;
            } else {
                i++;
            }
        }
        return n;
    }

    public function loadedCount():Int {
        return residentCount;
    }

    public function pendingCount():Int {
        return pendingLen;
    }

    // synchronous (used by tests and Bench)
    public function generateNow(cx:Int, cy:Int):Chunk {
        var k = key(cx, cy);
        var c = chunks.get(k);
        if (c != null) return c;
        noteErrors();
        return gen(k, acquire(cx, cy));
    }

    // ---- private ----

    // Main bumped genErrors since we last looked: the chunk in flight is the one that threw
    function noteErrors():Void {
        if (genErrors != seenErrors) {
            seenErrors = genErrors;
            hasFail = true;
            failKey = inFlightKey;
            failAlt = genErrors;
        }
    }

    // a free Chunk to generate into: the pool's top, after evicting the farthest resident chunk if the pool is empty.
    // The object stays on the pool until gen() succeeds, so a throw inside generate leaks nothing.
    function acquire(cx:Int, cy:Int):Chunk {
        if (poolCount == 0) evictFarthest(cx, cy);
        return pool[poolCount - 1];
    }

    // generates key k into c (the pool top), then makes it resident
    function gen(k:Int, c:Chunk):Chunk {
        inFlightKey = k;
        var alt = (hasFail && k == failKey) ? failAlt : 0;
        ChunkGen.generate(tapeSeed, keyX(k), keyY(k), c, alt);
        poolCount--;
        chunks.set(k, c);
        residentKeys[residentCount] = k;
        residentCount++;
        return c;
    }

    function evictFarthest(cx:Int, cy:Int):Void {
        if (residentCount == 0) return;
        var best = 0;
        var bestD = -1;
        for (i in 0...residentCount) {
            var k = residentKeys[i];
            var dx = keyX(k) - cx;
            var dy = keyY(k) - cy;
            if (dx < 0) dx = -dx;
            if (dy < 0) dy = -dy;
            var d = dx > dy ? dx : dy;
            if (d > bestD) { bestD = d; best = i; }
        }
        removeAt(best);
    }

    // swap-removes resident slot i: the chunk goes back to the pool
    function removeAt(i:Int):Void {
        var k = residentKeys[i];
        var c = chunks.get(k);
        chunks.remove(k);
        if (c != null) {
            pool[poolCount] = c;
            poolCount++;
            if (c == lastChunk) lastChunk = null;
        }
        residentCount--;
        residentKeys[i] = residentKeys[residentCount];
        residentKeys[residentCount] = 0;
    }
}
