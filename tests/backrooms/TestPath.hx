// Unit tests for Path (CONTRACT §1). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
// Uses TestRaycaster.GridWorld (a World whose cell() reads a flat grid at any world origin).

import TestRaycaster.GridWorld;

class TestPath {
    static var fails:Int = 0;
    static inline var SIDE = 24;                       // 2 * Path.HALF

    static function check(name:String, ok:Bool):Void {
        Sys.println("  " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok) fails++;
    }

    // ---- reference: plain BFS over the window with Arrays (test-side only) ----
    // Returns shortest length in steps, -1 if unreachable; fills reach[] with the BFS distance
    // of every reachable window cell (-1 otherwise). Window = [x0, x0 + 24) x [y0, y0 + 24).
    static function refBfs(w:World, x0:Int, y0:Int, sx:Int, sy:Int, tx:Int, ty:Int, reach:Array<Int>):Int {
        for (i in 0...SIDE * SIDE) reach[i] = -1;
        var q = new Array<Int>();
        var si = (sy - y0) * SIDE + (sx - x0);
        reach[si] = 0;
        q.push(si);
        var head = 0;
        var dxs = [0, 1, 0, -1];
        var dys = [-1, 0, 1, 0];
        while (head < q.length) {
            var cur = q[head++];
            var cy = Std.int(cur / SIDE);
            var cx = cur - cy * SIDE;
            for (k in 0...4) {
                var nx = cx + dxs[k], ny = cy + dys[k];
                if (nx < 0 || ny < 0 || nx >= SIDE || ny >= SIDE) continue;
                var ni = ny * SIDE + nx;
                if (reach[ni] >= 0) continue;
                if (!Cells.walkable(w.cell(x0 + nx, y0 + ny))) continue;
                reach[ni] = reach[cur] + 1;
                q.push(ni);
            }
        }
        var lx = tx - x0, ly = ty - y0;
        if (lx < 0 || ly < 0 || lx >= SIDE || ly >= SIDE) return -1;
        return reach[ly * SIDE + lx];
    }

    // validates a returned path: every cell walkable and in the window, consecutive cells 4-adjacent,
    // the first adjacent to the start, the last equal to (ex, ey). Returns a reason string or "".
    static function validate(w:World, sx:Int, sy:Int, ex:Int, ey:Int, out:haxe.ds.Vector<Int>, len:Int):String {
        var x0 = sx - Path.HALF, y0 = sy - Path.HALF;
        var px = sx, py = sy;
        for (i in 0...len) {
            var x = Cells.unpackX(out[i]);
            var y = Cells.unpackY(out[i]);
            if (x < x0 || x >= x0 + SIDE || y < y0 || y >= y0 + SIDE) return "cell outside window at " + i;
            if (!Cells.walkable(w.cell(x, y))) return "solid cell at " + i;
            var d = (x - px < 0 ? px - x : x - px) + (y - py < 0 ? py - y : y - py);
            if (d != 1) return "not 4-adjacent at " + i;
            px = x; py = y;
        }
        if (len > 0 && (px != ex || py != ey)) return "path ends at (" + px + "," + py + ") not (" + ex + "," + ey + ")";
        return "";
    }

    public static function run():Int {
        fails = 0;
        var rng = new Rng(777);
        var out = new haxe.ds.Vector<Int>(Path.MAX_LEN);

        // ------------------------------------------------------------------
        // (a) U-bend: start and target on either side of a wall, the only way round is below it
        //     grid origin (0,0), 24x24, walkable; wall x = 12 from y = 0..19 -> go round at y >= 20
        var u = new GridWorld(0, 0, 24, 24, Cells.FLOOR);
        for (y in 0...20) u.setCell(12, y, Cells.WALL);
        var n = Path.bfs(u, 12 - 2, 5, 12 + 2, 5, out);   // start (10,5) window = [-2,22) x [-7,17): y=20 is OUTSIDE
        check("U-bend: unreachable when the bend lies outside the window (" + n + ")", n == -1);
        var n2 = Path.bfs(u, 10, 12, 14, 12, out);         // window [-2,22) x [0,24): the bend at y = 20 is inside
        // shortest: (10,12) -> down to (10,20) = 8, across to (14,20) = 4, up to (14,12) = 8 -> 20
        check("U-bend: length 20 round the wall (" + n2 + ")", n2 == 20);
        check("U-bend: path valid", validate(u, 10, 12, 14, 12, out, n2) == "");
        var passesBend = false;
        for (i in 0...n2) if (Cells.unpackX(out[i]) == 12 && Cells.unpackY(out[i]) >= 20) passesBend = true;
        check("U-bend: path passes x = 12 below the wall", passesBend);
        check("U-bend: expansions bounded by the window", Path.expansions > 0 && Path.expansions <= SIDE * SIDE);

        // ------------------------------------------------------------------
        // (b) across a chunk edge: grid at (20, 20) spans x = 20..43 (chunk edge at x = 32), with a
        //     wall on x = 32 except one gap at y = 40 -> the route crosses the chunk boundary there
        var ce = new GridWorld(20, 20, 24, 24, Cells.FLOOR);
        for (y in 20...44) ce.setCell(32, y, Cells.WALL);
        ce.setCell(32, 40, Cells.FLOOR);
        var n3 = Path.bfs(ce, 26, 30, 38, 30, out);        // window [14,38) x [18,42): target x = 38 is outside!
        check("chunk edge: target at the window's right edge is outside -> nearest reachable instead (" + n3 + ")", n3 > 0);
        var n4 = Path.bfs(ce, 26, 30, 37, 30, out);        // (26,30)->(26,40)=10, ->(37,40)=11, ->(37,30)=10 -> 31
        check("chunk edge: length 31 through the gap at (32, 40) (" + n4 + ")", n4 == 31);
        check("chunk edge: path valid", validate(ce, 26, 30, 37, 30, out, n4) == "");
        var crosses = false;
        for (i in 0...n4) if (Cells.unpackX(out[i]) == 32 && Cells.unpackY(out[i]) == 40) crosses = true;
        check("chunk edge: path crosses x = 32 at the gap", crosses);
        // and in negative coordinates across the x = -32 / y = 0 edges
        var ng = new GridWorld(-44, -12, 24, 24, Cells.FLOOR);
        ng.border();
        var n5 = Path.bfs(ng, -33, 0, -30, -3, out);       // 3 right, 3 up -> 6
        check("negative coords across chunk edges: length 6 (" + n5 + ")", n5 == 6);
        check("negative coords: path valid and packed with sign", validate(ng, -33, 0, -30, -3, out, n5) == "" && Cells.unpackX(out[n5 - 1]) == -30 && Cells.unpackY(out[n5 - 1]) == -3);

        // ------------------------------------------------------------------
        // (c) walled off: -1, and a non-resident (off-grid = WALL) target: -1
        var wo = new GridWorld(0, 0, 24, 24, Cells.FLOOR);
        for (y in 0...24) wo.setCell(12, y, Cells.WALL);
        check("walled off: -1", Path.bfs(wo, 8, 12, 16, 12, out) == -1);
        check("walled off: expansions counted", Path.expansions > 0 && Path.expansions <= 12 * 24);
        check("target in a solid cell: -1", Path.bfs(wo, 8, 12, 12, 12, out) == -1);
        check("target in a non-resident chunk: -1", Path.bfs(wo, 8, 12, -2, 12, out) == -1);  // x = -2 is off-grid = WALL, inside the window [-4, 20)
        check("start == target: 0", Path.bfs(wo, 8, 12, 8, 12, out) == 0);

        // ------------------------------------------------------------------
        // (d) target outside the window: path to the reachable in-window cell nearest to it
        var ow = new GridWorld(0, 0, 40, 40, Cells.FLOOR);
        ow.border();
        var n6 = Path.bfs(ow, 15, 15, 38, 15, out);        // window x < 27 -> nearest reachable is (26, 15)
        check("outside target: reaches (26, 15), length 11 (" + n6 + ")", n6 == 11 && Cells.unpackX(out[n6 - 1]) == 26 && Cells.unpackY(out[n6 - 1]) == 15);
        check("outside target: path valid", validate(ow, 15, 15, 26, 15, out, n6) == "");
        var n7 = Path.bfs(ow, 15, 15, 38, 38, out);        // diagonal: nearest is the window corner (26, 26)
        check("outside target (diagonal): ends at (26, 26) (" + n7 + ")", n7 == 22 && Cells.unpackX(out[n7 - 1]) == 26 && Cells.unpackY(out[n7 - 1]) == 26);
        // hemmed in: nothing reachable is nearer than the start -> -1
        var hem = new GridWorld(0, 0, 40, 40, Cells.FLOOR);
        for (x in 0...40) { hem.setCell(x, 14, Cells.WALL); hem.setCell(x, 16, Cells.WALL); }
        hem.setCell(16, 15, Cells.WALL); hem.setCell(14, 15, Cells.WALL);
        check("outside target, only cells further away reachable: still moves to the nearest (" + Path.bfs(hem, 15, 15, 38, 15, out) + ")", Path.bfs(hem, 15, 15, 38, 15, out) == -1);
        hem.setCell(16, 15, Cells.FLOOR);
        hem.setCell(17, 15, Cells.WALL);               // exactly one reachable cell, one step nearer the target
        check("outside target, one cell nearer: length 1", Path.bfs(hem, 15, 15, 38, 15, out) == 1 && Cells.unpackX(out[0]) == 16);

        // ------------------------------------------------------------------
        // (e) MAX_LEN: a serpentine longer than 128 steps is truncated to the first 128
        var sp = new GridWorld(0, 0, 24, 24, Cells.FLOOR);
        for (y in 0...24) if ((y & 1) == 1) for (x in 0...24) sp.setCell(x, y, Cells.WALL);
        for (y in 0...24) if ((y & 1) == 1) sp.setCell(((y >> 1) & 1) == 0 ? 23 : 0, y, Cells.FLOOR);   // gaps alternate ends
        var refReach = new Array<Int>();
        for (i in 0...SIDE * SIDE) refReach.push(-1);
        var full = refBfs(sp, 0, 0, 12, 12, 12, 0, refReach);   // 6 serpentine rows up to row 0: 144 steps
        var n8 = Path.bfs(sp, 12, 12, 12, 0, out);
        check("MAX_LEN: serpentine of " + full + " steps truncated to 128 (" + n8 + ")", full > Path.MAX_LEN && n8 == Path.MAX_LEN);
        check("MAX_LEN: truncated prefix is a valid walk", prefixValid(sp, 12, 12, out, n8));
        var small = new haxe.ds.Vector<Int>(8);
        var n9 = Path.bfs(sp, 12, 12, 12, 0, small);
        check("out shorter than MAX_LEN: clamped to out.length (" + n9 + ")", n9 == 8 && prefixValid(sp, 12, 12, small, 8));

        // ------------------------------------------------------------------
        // (f) 200 random 24x24 grids against the reference BFS; the window is exactly the grid
        var badLen = 0, badPath = 0, badWin = 0, badNear = 0, badExp = 0, reachable = 0, outside = 0;
        var reach = new Array<Int>();
        for (i in 0...SIDE * SIDE) reach.push(-1);
        for (trial in 0...200) {
            var ox = rng.range(-70, 70), oy = rng.range(-70, 70);
            var g = new GridWorld(ox, oy, SIDE, SIDE, Cells.FLOOR);
            var density = 0.15 + rng.nextFloat() * 0.3;
            for (y in 0...SIDE) for (x in 0...SIDE) if (rng.chance(density)) g.setCell(ox + x, oy + y, rng.chance(0.5) ? Cells.WALL : Cells.PILLAR);
            // a few non-solid variants so walkable != FLOOR
            for (k in 0...10) g.setCell(ox + rng.range(0, SIDE), oy + rng.range(0, SIDE), rng.chance(0.5) ? Cells.WET : Cells.PIT);
            var sx = ox + Path.HALF, sy = oy + Path.HALF;   // window == grid
            g.setCell(sx, sy, Cells.FLOOR);
            var tx:Int, ty:Int;
            if (trial % 5 == 4) {
                // target outside the window
                tx = ox + (rng.chance(0.5) ? -rng.range(1, 30) : SIDE + rng.range(0, 30));
                ty = oy + rng.range(-10, SIDE + 10);
                outside++;
            } else {
                tx = ox + rng.range(0, SIDE); ty = oy + rng.range(0, SIDE);
            }
            var expect = refBfs(g, ox, oy, sx, sy, tx, ty, reach);
            var got = Path.bfs(g, sx, sy, tx, ty, out);
            if (!(tx == sx && ty == sy) && (Path.expansions <= 0 || Path.expansions > SIDE * SIDE)) badExp++;
            var inWin = tx >= ox && tx < ox + SIDE && ty >= oy && ty < oy + SIDE;
            if (inWin) {
                if (tx == sx && ty == sy) { if (got != 0) badLen++; continue; }
                var cap = expect > Path.MAX_LEN ? Path.MAX_LEN : expect;
                if (got != cap) badLen++;
                else if (got > 0) {
                    reachable++;
                    var r = expect > Path.MAX_LEN ? (prefixValid(g, sx, sy, out, got) ? "" : "bad prefix") : validate(g, sx, sy, tx, ty, out, got);
                    if (r != "") { badPath++; Sys.println("    " + r); }
                }
            } else {
                // nearest reachable cell to the target, Euclidean, over the reference reach set
                var bestD = -1.0; var startD = 0.0;
                for (idx in 0...SIDE * SIDE) if (reach[idx] >= 0) {
                    var cy = Std.int(idx / SIDE), cx = idx - cy * SIDE;
                    var ex:Float = ox + cx - tx, ey:Float = oy + cy - ty;
                    var d = ex * ex + ey * ey;
                    if (idx == Path.HALF * SIDE + Path.HALF) startD = d;
                    if (bestD < 0 || d < bestD) bestD = d;
                }
                if (bestD >= startD) { if (got != -1) badNear++; }
                else {
                    if (got <= 0) badNear++;
                    else {
                        var lx = Cells.unpackX(out[got - 1]), ly = Cells.unpackY(out[got - 1]);
                        var ex:Float = lx - tx, ey:Float = ly - ty;
                        if (ex * ex + ey * ey != bestD) badNear++;
                        var r = validate(g, sx, sy, lx, ly, out, got);
                        if (r != "") { badPath++; Sys.println("    " + r); }
                        // and the length is the BFS distance of that cell
                        if (reach[(ly - oy) * SIDE + (lx - ox)] != got) badNear++;
                    }
                }
            }
            // never outside the window (checked by validate above; recheck raw for -1/0 cases too)
            for (k in 0...(got > 0 ? got : 0)) {
                var x = Cells.unpackX(out[k]), y = Cells.unpackY(out[k]);
                if (x < sx - Path.HALF || x >= sx + Path.HALF || y < sy - Path.HALF || y >= sy + Path.HALF) badWin++;
            }
        }
        check("random grids: length equals reference BFS on 200 grids (" + reachable + " reachable, bad " + badLen + ")", badLen == 0 && reachable > 60);
        check("random grids: every path valid (bad " + badPath + ")", badPath == 0);
        check("random grids: never a cell outside the window (bad " + badWin + ")", badWin == 0);
        check("random grids: outside targets resolve to the nearest reachable cell (" + outside + " cases, bad " + badNear + ")", badNear == 0);
        check("random grids: expansions within 1..576 (bad " + badExp + ")", badExp == 0);

        // ------------------------------------------------------------------
        // (g) no allocation after construction: the scratch is static and allocated at class init;
        //     bfs uses only locals, the three static vectors and `out`. haxe --interp exposes no
        //     allocation counter, so this is checked by inspection (no `new`, closure, iterator or
        //     string in bfs) and observably: 1,000 calls with the stamp never needing a reset leave
        //     `out` the same object and the results stable.
        var before = out;
        var stable = true;
        for (k in 0...1000) if (Path.bfs(u, 10, 12, 14, 12, out) != 20) stable = false;
        check("no allocation: 1000 repeated calls stable, out unchanged as an object", stable && out == before);

        return fails;
    }

    // the first len cells form a valid walk from (sx, sy) (used for truncated paths)
    static function prefixValid(w:World, sx:Int, sy:Int, out:haxe.ds.Vector<Int>, len:Int):Bool {
        var px = sx, py = sy;
        for (i in 0...len) {
            var x = Cells.unpackX(out[i]), y = Cells.unpackY(out[i]);
            if (!Cells.walkable(w.cell(x, y))) return false;
            var d = (x - px < 0 ? px - x : x - px) + (y - py < 0 ? py - y : y - py);
            if (d != 1) return false;
            px = x; py = y;
        }
        return true;
    }
}
