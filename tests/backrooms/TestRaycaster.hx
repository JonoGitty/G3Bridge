// Unit tests for Raycaster (CONTRACT §1). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
//
// GridWorld (second class in this module, shared with TestPath as TestRaycaster.GridWorld)
// overrides World.cell with a flat grid at an arbitrary world origin, so grids can sit
// across chunk edges and in negative coordinates; anything off the grid reads WALL, as
// a non-resident chunk does.

class GridWorld extends World {
    public var ox:Int;
    public var oy:Int;
    public var gw:Int;
    public var gh:Int;
    public var grid:haxe.ds.Vector<Int>;

    public function new(ox:Int, oy:Int, gw:Int, gh:Int, fill:Int):Void {
        super(1);
        this.ox = ox; this.oy = oy; this.gw = gw; this.gh = gh;
        grid = new haxe.ds.Vector<Int>(gw * gh);
        for (i in 0...gw * gh) grid[i] = fill;
    }

    override public function cell(x:Int, y:Int):Int {
        var lx = x - ox;
        var ly = y - oy;
        if (lx < 0 || ly < 0 || lx >= gw || ly >= gh) return Cells.WALL;
        return grid[ly * gw + lx];
    }

    override public function has(cx:Int, cy:Int):Bool {
        var x0 = cx << 5, y0 = cy << 5;
        return x0 + 31 >= ox && x0 < ox + gw && y0 + 31 >= oy && y0 < oy + gh;
    }

    public function setCell(x:Int, y:Int, v:Int):Void {
        var lx = x - ox, ly = y - oy;
        if (lx < 0 || ly < 0 || lx >= gw || ly >= gh) return;
        grid[ly * gw + lx] = v;
    }

    // world-coordinate walls all round the outside ring
    public function border():Void {
        for (i in 0...gw) { setCell(ox + i, oy, Cells.WALL); setCell(ox + i, oy + gh - 1, Cells.WALL); }
        for (j in 0...gh) { setCell(ox, oy + j, Cells.WALL); setCell(ox + gw - 1, oy + j, Cells.WALL); }
    }
}

class TestRaycaster {
    static var fails:Int = 0;
    static inline var ONE = 65536;
    static inline var TOL = 66;                        // 1e-3 * ONE, rounded up

    static function check(name:String, ok:Bool):Void {
        Sys.println("  " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok) fails++;
    }

    static inline function ifloor(v:Float):Int { var i = Std.int(v); return v < i ? i - 1 : i; }

    // ---- brute-force reference: march along the ray in 0.001 steps of the ray parameter ----
    // Results in the static fields below. `ambiguous` flags a ray that clips within ~0.003 of a
    // grid corner (or stepped over one), where a 0.001 marcher and any DDA can legitimately
    // disagree on the cell; such rays are only distance-checked loosely.
    static var mHit:Int; static var mDist:Float; static var mCellX:Int; static var mCellY:Int;
    static var mSide:Int; static var mAmb:Bool;

    static function march(w:World, px:Float, py:Float, rdx:Float, rdy:Float):Void {
        var step = 0.001;
        var lx = ifloor(px), ly = ifloor(py);
        var sx = lx, sy = ly;
        var t = 0.0;
        mHit = 0; mDist = Raycaster.MAX_DIST; mAmb = false; mSide = 0; mCellX = lx; mCellY = ly;
        while (t < 40.0) {
            t += step;
            var x = px + t * rdx;
            var y = py + t * rdy;
            var cx = ifloor(x), cy = ifloor(y);
            if (cx == lx && cy == ly) continue;
            var both = (cx != lx) && (cy != ly);
            if (both) {
                // stepped over a corner: the DDA visits one of the two intermediate cells first
                mAmb = true;
                if (Cells.solid(w.cell(lx, cy)) || Cells.solid(w.cell(cx, ly))) { mHit = 1; mCellX = cx; mCellY = cy; mDist = t; return; }
            }
            var ex = cx - sx; if (ex < 0) ex = -ex;
            var ey = cy - sy; if (ey < 0) ey = -ey;
            if (ex > Raycaster.MAX_DIST || ey > Raycaster.MAX_DIST) { mHit = 0; mDist = Raycaster.MAX_DIST; return; }
            var c = w.cell(cx, cy);
            if (Cells.solid(c)) {
                mHit = 1; mCellX = cx; mCellY = cy;
                if (cx != lx) {
                    mSide = 0;
                    var gx = rdx > 0 ? cx : cx + 1;
                    var te = (gx - px) / rdx;
                    var yc = py + te * rdy;
                    var fy = yc - ifloor(yc);
                    if (fy < 0.003 || fy > 0.997) mAmb = true;
                    mDist = te;
                } else {
                    mSide = 1;
                    var gy = rdy > 0 ? cy : cy + 1;
                    var te = (gy - py) / rdy;
                    var xc = px + te * rdx;
                    var fx = xc - ifloor(xc);
                    if (fx < 0.003 || fx > 0.997) mAmb = true;
                    mDist = te;
                }
                if (mDist < 1.0 / 16.0) mDist = 1.0 / 16.0;
                return;
            }
            lx = cx; ly = cy;
        }
        mHit = 0; mDist = Raycaster.MAX_DIST;
    }

    // ---- the six hand-built 16x16 grids ----
    static function grid(kind:Int, rng:Rng):GridWorld {
        var ox = 0, oy = 0;
        if (kind == 5) { ox = -40; oy = -8; }          // negative coords, across the x = -32 and y = 0 chunk edges
        if (kind == 3) { ox = 24; oy = 24; }           // across the x = 32 / y = 32 chunk edges
        var w = new GridWorld(ox, oy, 16, 16, Cells.FLOOR);
        w.border();
        switch (kind) {
            case 0: // empty room
            case 1: // pillar field
                for (y in 0...16) for (x in 0...16) if ((x & 3) == 2 && (y & 3) == 2) w.setCell(ox + x, oy + y, Cells.PILLAR);
            case 2: // corridors
                for (y in 0...16) for (x in 0...16) if ((y & 3) == 0 && (x & 7) != 4) w.setCell(ox + x, oy + y, Cells.WALL);
            case 3: // diagonal staircase
                for (i in 1...15) { w.setCell(ox + i, oy + i, Cells.WALL); if (i + 1 < 15) w.setCell(ox + i + 1, oy + i, Cells.WALL); }
            case 4: // random 30% walls with texture variant bits set
                for (y in 1...15) for (x in 1...15) if (rng.chance(0.3)) w.setCell(ox + x, oy + y, Cells.WALL | (rng.range(0, 8) << Cells.VAR_SHIFT));
            case 5: // single central pillar, offset origin
                w.setCell(ox + 7, oy + 7, Cells.PILLAR); w.setCell(ox + 8, oy + 7, Cells.PILLAR);
                w.setCell(ox + 7, oy + 8, Cells.PILLAR);
        }
        return w;
    }

    static function expectedFace(side:Int, rdx:Float, rdy:Float):Int {
        return side == 0 ? (rdx > 0 ? Cells.W : Cells.E) : (rdy > 0 ? Cells.N : Cells.S);
    }

    public static function run():Int {
        fails = 0;
        var rng = new Rng(20260902);

        // ------------------------------------------------------------------
        // setColumns: camX symmetric, in [-1, 1], count clamped to maxCols
        var rc = new Raycaster(320);
        rc.setColumns(320, 66 * Math.PI / 180);
        var sym = true;
        for (i in 0...160) if (Math.abs(rc.camX[i] + rc.camX[319 - i]) > 1e-12) sym = false;
        check("setColumns camX symmetric", sym);
        check("setColumns camX within [-1, 1]", rc.camX[0] > -1.0 && rc.camX[0] < -0.99 && rc.camX[319] < 1.0 && rc.camX[319] > 0.99);
        rc.setColumns(1000, 1.0);
        check("setColumns clamps cols to maxCols", rc.cols == 320);
        rc.setColumns(160, 66 * Math.PI / 180);
        check("setColumns cols == 160", rc.cols == 160);

        // ------------------------------------------------------------------
        // (a) empty corridor: a 3-wide corridor along +x, wall at x = 12, player at x = 2.5
        var cw = new GridWorld(0, 0, 13, 5, Cells.WALL);
        for (x in 1...12) for (y in 1...4) cw.setCell(x, y, Cells.FLOOR);
        var hits = new RayHits(320);
        rc.setColumns(320, 66 * Math.PI / 180);
        rc.castRays(cw, 2.5, 2.5, 0.0, hits);
        var mid = 160;
        check("corridor: count == cols", hits.count == 320);
        check("corridor: centre column hits", hits.hit[mid] == 1);
        check("corridor: centre column distance 9.5 (dist=" + hits.dist[mid] + ")", Math.abs(hits.dist[mid] - Std.int(9.5 * ONE)) <= TOL);
        check("corridor: centre column face W (looking +x)", hits.face[mid] == Cells.W && hits.side[mid] == 0);
        check("corridor: centre column cell (12, 2)", hits.cellX[mid] == 12 && hits.cellY[mid] == 2);
        check("corridor: cell value is WALL", hits.cell[mid] == Cells.WALL);
        // the columns straight ahead that land on the far wall share the perpendicular distance (no fisheye)
        var okPerp = true;
        for (i in 0...320) if (hits.cellX[i] == 12 && hits.side[i] == 0 && Math.abs(hits.dist[i] - Std.int(9.5 * ONE)) > TOL) okPerp = false;
        check("corridor: every far-wall column reports the same perpendicular distance", okPerp);
        // side columns hit the corridor walls, not the far wall
        check("corridor: leftmost column hits the north wall (face S)", hits.hit[0] == 1 && hits.cellY[0] == 0 && hits.face[0] == Cells.S);
        check("corridor: rightmost column hits the south wall (face N)", hits.hit[319] == 1 && hits.cellY[319] == 4 && hits.face[319] == Cells.N);

        // ------------------------------------------------------------------
        // (b) fisheye: a flat wall across the whole FOV at perpendicular distance 3.5
        var fw = new GridWorld(0, 0, 40, 10, Cells.FLOOR);
        for (x in 0...40) fw.setCell(x, 0, Cells.WALL);
        rc.castRays(fw, 20.5, 4.5, -Math.PI / 2, hits);
        var flat = true; var maxErr = 0;
        for (i in 0...320) {
            var e = hits.dist[i] - Std.int(3.5 * ONE); if (e < 0) e = -e;
            if (e > maxErr) maxErr = e;
            if (hits.hit[i] != 1 || hits.cellY[i] != 0 || e > TOL) flat = false;
        }
        check("no fisheye: flat wall reads 3.5 in every column (max err " + maxErr + "/65536)", flat);
        check("no fisheye: looking north the wall shows its south face", hits.face[mid] == Cells.S && hits.side[mid] == 1);

        // ------------------------------------------------------------------
        // (c) the four face conventions, one axis-aligned ray each (centre column)
        var box = new GridWorld(0, 0, 9, 9, Cells.FLOOR);
        box.border();
        rc.castRays(box, 4.5, 4.5, -Math.PI / 2, hits);
        check("face: stepping -y (north) reports S", hits.face[mid] == Cells.S && hits.cellY[mid] == 0);
        rc.castRays(box, 4.5, 4.5, Math.PI / 2, hits);
        check("face: stepping +y (south) reports N", hits.face[mid] == Cells.N && hits.cellY[mid] == 8);
        rc.castRays(box, 4.5, 4.5, 0.0, hits);
        check("face: stepping +x (east) reports W", hits.face[mid] == Cells.W && hits.cellX[mid] == 8);
        rc.castRays(box, 4.5, 4.5, Math.PI, hits);
        check("face: stepping -x (west) reports E", hits.face[mid] == Cells.E && hits.cellX[mid] == 0);
        check("face: axis-aligned distance is 3.5", Math.abs(hits.dist[mid] - Std.int(3.5 * ONE)) <= TOL);

        // ------------------------------------------------------------------
        // (d) a corner: one pillar at (4, 4); from (2.5, 2.7) at 45 deg the ray crosses y = 4 at
        //     x = 3.8 (floor) then x = 4 at y = 4.2 -> the pillar's WEST face; mirrored -> NORTH face.
        var cg = new GridWorld(0, 0, 8, 8, Cells.FLOOR);
        cg.setCell(4, 4, Cells.PILLAR);
        rc.setColumns(1, 0.001);                       // a single centre ray (camX = 0)
        var one = new RayHits(1);
        rc.castRays(cg, 2.5, 2.7, Math.PI / 4, one);
        check("corner: ray passing below the corner sees the pillar's W face", one.hit[0] == 1 && one.cellX[0] == 4 && one.cellY[0] == 4 && one.face[0] == Cells.W && one.side[0] == 0);
        check("corner: W-face distance 1.5*sqrt(2) (dist=" + one.dist[0] + ")", Math.abs(one.dist[0] - Std.int(1.5 * Math.sqrt(2) * ONE)) <= TOL);
        rc.castRays(cg, 2.7, 2.5, Math.PI / 4, one);
        check("corner: ray passing above the corner sees the pillar's N face", one.hit[0] == 1 && one.cellX[0] == 4 && one.cellY[0] == 4 && one.face[0] == Cells.N && one.side[0] == 1);
        check("corner: N-face distance 1.5*sqrt(2)", Math.abs(one.dist[0] - Std.int(1.5 * Math.sqrt(2) * ONE)) <= TOL);
        // texX flip convention: a ray hitting the W face at wall y-fraction 0.2 reads texel 63 - 12
        rc.castRays(cg, 2.5, 2.7, Math.PI / 4, one);
        check("corner: W-face (dirX > 0) texX is flipped: 63 - int(0.2*64) = 51", one.texX[0] == 51);
        rc.castRays(cg, 2.7, 2.5, Math.PI / 4, one);
        check("corner: N-face (dirY > 0) texX not flipped: int(0.2*64) = 12", one.texX[0] == 12);

        // ------------------------------------------------------------------
        // (e) minimum distance: standing 0.001 from a wall reports ONE >> 4, never 0
        rc.castRays(cg, 3.999, 4.5, 0.0, one);
        check("min distance clamp ONE >> 4", one.hit[0] == 1 && one.dist[0] == (ONE >> 4));

        // ------------------------------------------------------------------
        // (e2) near-parallel rays: the x component is tiny, the camera stands a hair inside the
        //      grid line. A 16.16 delta cannot hold 65536 / 1e-7; the crossing must still land
        //      where the geometry puts it and never nearer.
        var tall = new GridWorld(0, 0, 8, 16, Cells.FLOOR);
        tall.border();
        // rdx = cos(pi/2 - 1e-7) ~ 1e-7, 1 - fracX = 1e-4: the x = 4 line is crossed at t ~ 1000,
        // far outside the window, so the ray must run down the corridor to the south wall (y = 15)
        rc.castRays(tall, 3.9999, 4.5, Math.PI / 2 - 1e-7, one);
        check("near-parallel: x line crossed at t ~ 1000 is never stepped; south wall at 10.5 (face N)",
            one.hit[0] == 1 && one.side[0] == 1 && one.cellY[0] == 15 && one.face[0] == Cells.N
            && Math.abs(one.dist[0] - Std.int(10.5 * ONE)) <= 2);
        // rdx ~ 2e-6, 1 - fracX ~ 1e-5: the x = 4 line is crossed at t ~ 5.0 (y ~ 9.5) -> a pillar
        // at (4, 9) is hit on its W face at 5.0, before the south wall
        tall.setCell(4, 9, Cells.PILLAR);
        rc.castRays(tall, 3.99999, 4.5, Math.PI / 2 - 2e-6, one);
        check("near-parallel: a real crossing inside the window is stepped; pillar (4, 9) W face at 5.0 (dist=" + one.dist[0] + ")",
            one.hit[0] == 1 && one.side[0] == 0 && one.cellX[0] == 4 && one.cellY[0] == 9 && one.face[0] == Cells.W
            && Math.abs(one.dist[0] - 5 * ONE) <= 8);
        // exactly axis-aligned from a grid line: no x step ever, and no y step at t = 0
        rc.castRays(tall, 4.0, 4.0, Math.PI / 2, one);
        check("axis-aligned from a grid corner: pillar (4, 9) N face at 5.0", one.hit[0] == 1 && one.side[0] == 1 && one.cellY[0] == 9 && one.face[0] == Cells.N && one.dist[0] == 5 * ONE);
        rc.castRays(tall, 4.0, 4.0, 0.0, one);
        check("axis-aligned +x from a grid corner: east wall (7, 4) W face at 3.0", one.hit[0] == 1 && one.side[0] == 0 && one.cellX[0] == 7 && one.cellY[0] == 4 && one.face[0] == Cells.W && one.dist[0] == 3 * ONE);

        // ------------------------------------------------------------------
        // (f) empty 40x40 room: nothing within MAX_DIST in any direction
        var room = new GridWorld(0, 0, 40, 40, Cells.FLOOR);
        room.border();
        rc.setColumns(320, 66 * Math.PI / 180);
        var empty = true;
        var a = 0.0;
        while (a < 6.3) {
            rc.castRays(room, 20.5, 20.5, a, hits);
            for (i in 0...320) if (hits.hit[i] != 0 || hits.dist[i] != ONE * Raycaster.MAX_DIST) empty = false;
            a += 0.7;
        }
        check("empty 40x40 room: hit == 0 and dist == ONE * MAX_DIST in every column, 9 headings", empty);
        // ... but a wall at Chebyshev 16 is still seen: player at (36.5, 20.5) sees x = 39 at 2.5 and x = 0 not at all
        rc.castRays(room, 36.5, 20.5, Math.PI, hits);
        check("far wall beyond MAX_DIST is not hit when looking -x from x = 36.5", hits.hit[mid] == 0);
        rc.castRays(room, 20.5, 20.5, 0.0, hits);
        check("MAX_DIST is Chebyshev: wall at 18.5 not hit", hits.hit[mid] == 0);
        rc.castRays(room, 22.5, 20.5, 0.0, hits);
        check("MAX_DIST is Chebyshev: wall at 16.5 (cell 39 from cell 22 = 17) not hit", hits.hit[mid] == 0);
        rc.castRays(room, 23.5, 20.5, 0.0, hits);
        check("MAX_DIST is Chebyshev: wall at 15.5 (cell 39 from cell 23 = 16) is hit", hits.hit[mid] == 1 && Math.abs(hits.dist[mid] - Std.int(15.5 * ONE)) <= TOL);

        // ------------------------------------------------------------------
        // (g) brute-force marcher on the 6 hand-built grids, 100 random views, 40 columns each
        var views = 0; var rays = 0; var amb = 0;
        var badDist = 0; var badCell = 0; var badSide = 0; var badFace = 0; var badTex = 0; var worst = 0;
        var v = new RayHits(64);
        while (views < 100) {
            var g = grid(views % 6, rng);
            // a random position inside a walkable cell, away from the cell edges
            var px = 0.0, py = 0.0; var tries = 0;
            do {
                px = g.ox + rng.range(1, g.gw - 1) + 0.1 + rng.nextFloat() * 0.8;
                py = g.oy + rng.range(1, g.gh - 1) + 0.1 + rng.nextFloat() * 0.8;
                tries++;
            } while (Cells.solid(g.cell(ifloor(px), ifloor(py))) && tries < 1000);
            if (tries >= 1000) { views++; continue; }
            var ang = rng.nextFloat() * Math.PI * 2 - Math.PI;
            var fov = (60 + rng.nextFloat() * 12) * Math.PI / 180;
            var ncol = 40;
            rc.setColumns(ncol, fov);
            rc.castRays(g, px, py, ang, v);
            if (v.count != ncol) badCell++;
            for (i in 0...ncol) {
                var rdx = rc.dirX[i], rdy = rc.dirY[i];
                march(g, px, py, rdx, rdy);
                rays++;
                if (mAmb) {
                    amb++;
                    // even a corner clip must agree on the distance to within a couple of cells' rounding
                    if (mHit == 1 && v.hit[i] == 1 && Math.abs(v.dist[i] - mDist * ONE) > ONE) badDist++;
                    continue;
                }
                var d = Std.int(mDist * ONE);
                var e = v.dist[i] - d; if (e < 0) e = -e;
                if (mHit == 1) {
                    if (v.hit[i] != 1 || e > TOL) badDist++;
                    if (e > worst) worst = e;
                    if (v.cellX[i] != mCellX || v.cellY[i] != mCellY) badCell++;
                    if (v.side[i] != mSide) badSide++;
                    if (v.face[i] != expectedFace(mSide, rdx, rdy)) badFace++;
                    // texture column from the reference hit point
                    var wx = mSide == 0 ? py + mDist * rdy : px + mDist * rdx;
                    wx -= ifloor(wx);
                    var tx = Std.int(wx * 64) & 63;
                    if ((mSide == 0 && rdx > 0) || (mSide == 1 && rdy < 0)) tx = 63 - tx;
                    var dt = v.texX[i] - tx; if (dt < 0) dt = -dt;
                    if (dt > 1 && dt < 63) badTex++;
                    if (v.cell[i] != g.cell(mCellX, mCellY)) badCell++;
                } else {
                    if (v.hit[i] != 0 || v.dist[i] != ONE * Raycaster.MAX_DIST) badDist++;
                }
            }
            views++;
        }
        check("marcher: " + rays + " rays over 100 views, " + amb + " corner clips skipped (< 5%)", amb * 20 < rays);
        check("marcher: distance within 1e-3 (worst " + worst + "/65536, bad " + badDist + ")", badDist == 0);
        check("marcher: distance exact to 2/65536 (the hit is finished with one exact Float divide)", worst <= 2);
        check("marcher: cellX/cellY/cell exact (bad " + badCell + ")", badCell == 0);
        check("marcher: side exact (bad " + badSide + ")", badSide == 0);
        check("marcher: face exact (bad " + badFace + ")", badFace == 0);
        check("marcher: texX within 1 texel (bad " + badTex + ")", badTex == 0);

        // ------------------------------------------------------------------
        // (h) no allocation after construction: haxe --interp has no allocation counter, so this
        //     checks what can be observed: the tables and output vectors are the same objects before
        //     and after 200 casts with changing angles and column counts (castRays never reallocates
        //     them), and by inspection castRays/setColumns/rebuildDirs contain no `new`, closure,
        //     iterator or string; tools/backrooms_check.py greps the `new` rule for cast*.
        var dX = rc.dirX, dY = rc.dirY, cX = rc.camX;
        var hD = v.dist, hT = v.texX;
        for (k in 0...200) {
            rc.setColumns(16 + (k & 31), 1.1 + (k & 3) * 0.05);
            rc.castRays(room, 20.5 + (k & 7) * 0.3, 20.5, k * 0.31, v);
        }
        check("no allocation: dir/cam tables and RayHits vectors are the same objects after 200 casts",
            rc.dirX == dX && rc.dirY == dY && rc.camX == cX && v.dist == hD && v.texX == hT);

        return fails;
    }
}
