// Windowed BFS for the Hound (CONTRACT §1). Core class: no flash.* imports.
//
// Breadth-first search over walkable cells in the 24x24 window centred on the start
// (x in [sx - HALF, sx + HALF), same for y), 4-connected, N/E/S/W expansion order.
// Residency clamping is free: World.cell reads WALL for any non-resident chunk, so the
// search never leaves loaded chunks and crosses chunk edges like any other cell.
//
// Scratch is three static vectors allocated once at class init. The window is indexed
// with a stride of 32 (index = (ly << 5) | lx, 768 entries of which 576 are used) so the
// loop splits an index back into x and y with a shift and a mask: no division, no Float.
// `visited` is stamp-based (a cell is visited when visited[i] == stamp), so no clearing
// per call; the stamp wraps after 2^31 calls, at which point the vector is re-zeroed
// once. bfs allocates nothing: no `new`, no closure, no iterator, no string.
//
// Cost bound: at most 576 dequeues (expansions) and 4 neighbour probes each, so at most
// ~2300 World.cell calls per call (the contract's 0.4 ms). The amortisation is the
// caller's: Hound re-paths every 0.5 s (repathTimer), never every frame.
class Path {
    public static inline var HALF = 12;                // window is (2*HALF)^2 = 576 cells around the start
    public static inline var MAX_LEN = 128;
    static inline var SIDE = 24;                       // 2 * HALF
    static inline var SHIFT = 5;                       // index stride 32 >= SIDE: idx = (ly << SHIFT) | lx
    static inline var STRIDE = 32;
    static inline var MASK = 31;
    static inline var WINDOW = 768;                    // SIDE * STRIDE
    static inline var CLAMP = 16000;                   // |dx|, |dy| cap for the nearest-cell metric (keeps the square in Int)
    public static var expansions:Int = 0;              // nodes expanded by the last call (telemetry/tests)

    // static scratch, stamp-based so no clearing per call
    static var visited:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(WINDOW);
    static var queue:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(WINDOW);
    static var parent:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(WINDOW);
    static var stamp:Int = 0;

    // BFS over walkable cells inside the window centred on (sx, sy), clamped to resident chunks. sx/sy/tx/ty are WORLD cell coordinates;
    // out receives the path as packed WORLD cells (Cells.pack(x, y), never chunk-local) from the first step to the target (start excluded),
    // at most MAX_LEN. Returns path length, 0 if start == target, -1 if unreachable.
    // A target outside the window resolves to the reachable in-window cell nearest to it (Euclidean); if that is the
    // start itself there is nothing to walk and the result is -1 (the Hound then takes its greedy step).
    public static function bfs(world:World, sx:Int, sy:Int, tx:Int, ty:Int, out:haxe.ds.Vector<Int>):Int {
        expansions = 0;
        if (sx == tx && sy == ty) return 0;

        // next stamp; on wrap re-zero the vector once (never in practice: 2^31 calls)
        var st = stamp + 1;
        if (st <= 0) {
            var v = visited;
            for (i in 0...WINDOW) v[i] = 0;
            st = 1;
        }
        stamp = st;

        var vis = visited;
        var q = queue;
        var par = parent;
        var x0 = sx - HALF;                            // window origin (inclusive)
        var y0 = sy - HALF;

        var startIdx = (HALF << SHIFT) | HALF;
        vis[startIdx] = st;
        par[startIdx] = -1;
        q[0] = startIdx;
        var head = 0;
        var tail = 1;

        var lx = tx - x0;
        var ly = ty - y0;
        var targetIn = lx >= 0 && lx < SIDE && ly >= 0 && ly < SIDE;
        var targetIdx = targetIn ? (ly << SHIFT) | lx : -1;

        // nearest-reachable fallback for an out-of-window target: squared Euclidean distance in
        // Int, with each axis capped at CLAMP so the sum never overflows (a target that far away
        // only ever ties, and ties keep the first cell dequeued, the one nearest the start)
        var bestIdx = startIdx;
        var bdx = sx - tx; if (bdx < 0) bdx = -bdx; if (bdx > CLAMP) bdx = CLAMP;
        var bdy = sy - ty; if (bdy < 0) bdy = -bdy; if (bdy > CLAMP) bdy = CLAMP;
        var bestD = bdx * bdx + bdy * bdy;

        var found = -1;
        var n = 0;
        while (head < tail) {
            var cur = q[head++];
            n++;
            if (cur == targetIdx) { found = cur; break; }
            var cy = cur >> SHIFT;
            var cx = cur & MASK;
            var wx = x0 + cx;
            var wy = y0 + cy;
            if (!targetIn) {
                var ex = wx - tx; if (ex < 0) ex = -ex; if (ex > CLAMP) ex = CLAMP;
                var ey = wy - ty; if (ey < 0) ey = -ey; if (ey > CLAMP) ey = CLAMP;
                var d = ex * ex + ey * ey;
                if (d < bestD) { bestD = d; bestIdx = cur; }
            }
            // N
            if (cy > 0) {
                var ni = cur - STRIDE;
                if (vis[ni] != st) {
                    vis[ni] = st;
                    if (Cells.walkable(world.cell(wx, wy - 1))) { par[ni] = cur; q[tail++] = ni; }
                }
            }
            // E
            if (cx < SIDE - 1) {
                var ni = cur + 1;
                if (vis[ni] != st) {
                    vis[ni] = st;
                    if (Cells.walkable(world.cell(wx + 1, wy))) { par[ni] = cur; q[tail++] = ni; }
                }
            }
            // S
            if (cy < SIDE - 1) {
                var ni = cur + STRIDE;
                if (vis[ni] != st) {
                    vis[ni] = st;
                    if (Cells.walkable(world.cell(wx, wy + 1))) { par[ni] = cur; q[tail++] = ni; }
                }
            }
            // W
            if (cx > 0) {
                var ni = cur - 1;
                if (vis[ni] != st) {
                    vis[ni] = st;
                    if (Cells.walkable(world.cell(wx - 1, wy))) { par[ni] = cur; q[tail++] = ni; }
                }
            }
        }
        expansions = n;

        if (found < 0) {
            if (targetIn) return -1;                   // walled off inside the window
            found = bestIdx;
            if (found == startIdx) return -1;          // nothing reachable is closer than where we stand
        }

        // path length: walk parents back to the start
        var len = 0;
        var k = found;
        while (k != startIdx) { len++; k = par[k]; }

        // write the first min(len, MAX_LEN, out.length) steps, start excluded, in walking order
        var cap = MAX_LEN;
        if (out.length < cap) cap = out.length;
        var keep = len < cap ? len : cap;
        k = found;
        var pos = len - 1;
        while (k != startIdx) {
            if (pos < keep) out[pos] = Cells.pack(x0 + (k & MASK), y0 + (k >> SHIFT));
            pos--;
            k = par[k];
        }
        return keep;
    }
}
