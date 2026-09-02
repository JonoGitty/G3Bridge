// DDA raycaster (CONTRACT §1). Core class: no flash.* imports.
//
// One Lode-style DDA per column over World.cell. The per-column set-up (two delta
// distances, two initial side distances) is computed once in Float and rounded to
// 16.16 Int; the grid-stepping loop itself is pure 16.16 Int arithmetic with every
// field hoisted into locals. The hit is finished per column with one Float divide: the
// perpendicular distance is recomputed exactly from the hit cell and the ray direction
// (Lode's (mapX - posX + (1 - stepX) / 2) / rayDirX), so the stored 16.16 distance is
// exact to one unit however many grid lines the Int DDA stepped across, and the texture
// coordinate comes from the same exact value. 320 divides per frame cost nothing.
//
// Near-parallel rays: a delta or initial side distance that would not fit 16.16
// (|component| below 1/16384) is clamped to FAR, each from its own unclamped Float, so
// the first crossing on that axis is never brought nearer than it is; an axis is stepped
// only when the ray really crosses it inside the window. Every side distance stays
// below 2^31: a value is only ever incremented when it was the smaller of the two, i.e.
// at most the exit distance of the 33x33 window (~24 cells), plus one delta (<= FAR).
//
// Allocation: castRays and setColumns touch only locals and the vectors built in
// new(). No `new`, no closure, no iterator, no string after construction.
//
// Camera model (contract): dir = (cos ang, sin ang); plane = (-sin ang, cos ang) *
// tan(fov/2); ray(i) = dir + plane * camX[i], camX[i] = -1 at the left edge and +1 at
// the right edge (column centres, so the table is symmetric). Because |dir| = 1 and
// plane is perpendicular to dir, the ray parameter t of a crossing is exactly the
// perpendicular (fisheye-free) distance.
class Raycaster {
    public static inline var MAX_DIST = 16;            // cells
    public static inline var MAX_STEPS = 48;
    static inline var ONE = 65536;                     // Cells.ONE
    static inline var MIN_DIST = 4096;                 // ONE >> 4: floor for the perpendicular distance
    static inline var FAR = 0x3FFFFFFF;                // delta / side distance cap for a ray (nearly) parallel to an axis
    static inline var FAR_F = 1073741823.0;            // FAR as a Float, for the clamp compare

    public var cols:Int;                               // current column count
    public var fov:Float;                              // radians
    public var dirX:haxe.ds.Vector<Float>;             // per-column ray direction (unit-plane form: dir + plane * camX), length maxCols
    public var dirY:haxe.ds.Vector<Float>;
    public var camX:haxe.ds.Vector<Float>;             // per-column camera-plane coordinate in [-1, 1]

    var maxCols:Int;
    var lastAng:Float;                                 // angle the dir tables were built for
    var dirsValid:Bool;                                // false after setColumns until castRays rebuilds

    public function new(maxCols:Int):Void {
        if (maxCols < 1) maxCols = 1;
        this.maxCols = maxCols;
        cols = 0;
        fov = 0.0;
        lastAng = 0.0;
        dirsValid = false;
        dirX = new haxe.ds.Vector<Float>(maxCols);
        dirY = new haxe.ds.Vector<Float>(maxCols);
        camX = new haxe.ds.Vector<Float>(maxCols);
        for (i in 0...maxCols) { dirX[i] = 0.0; dirY[i] = 0.0; camX[i] = 0.0; }
    }

    // rebuilds camX only; dirX/dirY are rebuilt by castRays() when ang changes
    public function setColumns(cols:Int, fov:Float):Void {
        if (cols > maxCols) cols = maxCols;
        if (cols < 0) cols = 0;
        this.cols = cols;
        this.fov = fov;
        var cx = camX;
        if (cols > 0) {
            var inv = 1.0 / cols;
            for (i in 0...cols) cx[i] = (2 * i + 1) * inv - 1.0;   // column centres, symmetric about 0
        }
        dirsValid = false;
    }

    // dir + plane * camX for every column; plane = (-sin, cos) * tan(fov / 2)
    function rebuildDirs(ang:Float):Void {
        var c = Math.cos(ang);
        var s = Math.sin(ang);
        var t = Math.tan(fov * 0.5);
        var plx = -s * t;
        var ply = c * t;
        var n = cols;
        var cx = camX;
        var dx = dirX;
        var dy = dirY;
        for (i in 0...n) {
            var k = cx[i];
            dx[i] = c + plx * k;
            dy[i] = s + ply * k;
        }
        lastAng = ang;
        dirsValid = true;
    }

    // fills out for cols columns, out.count = cols. Named castRays: `cast` is a Haxe keyword.
    public function castRays(world:World, px:Float, py:Float, ang:Float, out:RayHits):Void {
        var n = cols;
        if (!dirsValid || ang != lastAng) rebuildDirs(ang);

        // hoisted tables
        var dx = dirX;
        var dy = dirY;
        var oDist = out.dist;
        var oTex = out.texX;
        var oSide = out.side;
        var oCellX = out.cellX;
        var oCellY = out.cellY;
        var oCell = out.cell;
        var oFace = out.face;
        var oHit = out.hit;

        // start cell and the fractional position inside it (floor, correct for negatives)
        var mapX0 = Std.int(px); if (px < mapX0) mapX0--;
        var mapY0 = Std.int(py); if (py < mapY0) mapY0--;
        var fracX = px - mapX0;                        // [0, 1)
        var fracY = py - mapY0;
        var minX = mapX0 - MAX_DIST;
        var maxX = mapX0 + MAX_DIST;
        var minY = mapY0 - MAX_DIST;
        var maxY = mapY0 + MAX_DIST;
        var noHitDist = ONE * MAX_DIST;

        for (i in 0...n) {
            var rdx = dx[i];
            var rdy = dy[i];

            // ---- per-column set-up (Float once, then 16.16 Int) ----
            // delta = 65536 / |component|; side = fraction of the cell left to the crossing * delta.
            // Both are clamped to FAR from the unclamped Float (a +-0.0 component gives +-Infinity
            // or NaN, and every comparison below sends those to FAR too), so a clamped delta never
            // shortens the first crossing and a parallel axis is never stepped.
            var stepX:Int; var ddx:Int; var sdx:Int;
            if (rdx < 0) {
                stepX = -1;
                var d = -65536.0 / rdx;
                var s = fracX * d;
                ddx = (d < FAR_F && d > 0.0) ? Std.int(d + 0.5) : FAR;
                sdx = (s < FAR_F && s >= 0.0) ? Std.int(s + 0.5) : FAR;
            } else {
                stepX = 1;
                var d = 65536.0 / rdx;
                var s = (1.0 - fracX) * d;
                ddx = (d < FAR_F && d > 0.0) ? Std.int(d + 0.5) : FAR;
                sdx = (s < FAR_F && s >= 0.0) ? Std.int(s + 0.5) : FAR;
            }
            var stepY:Int; var ddy:Int; var sdy:Int;
            if (rdy < 0) {
                stepY = -1;
                var d = -65536.0 / rdy;
                var s = fracY * d;
                ddy = (d < FAR_F && d > 0.0) ? Std.int(d + 0.5) : FAR;
                sdy = (s < FAR_F && s >= 0.0) ? Std.int(s + 0.5) : FAR;
            } else {
                stepY = 1;
                var d = 65536.0 / rdy;
                var s = (1.0 - fracY) * d;
                ddy = (d < FAR_F && d > 0.0) ? Std.int(d + 0.5) : FAR;
                sdy = (s < FAR_F && s >= 0.0) ? Std.int(s + 0.5) : FAR;
            }

            // ---- the DDA: pure Int ----
            var mx = mapX0;
            var my = mapY0;
            var side = 0;
            var hit = 0;
            var c = 0;
            var steps = 0;
            while (steps < MAX_STEPS) {
                if (sdx < sdy) { sdx += ddx; mx += stepX; side = 0; }
                else           { sdy += ddy; my += stepY; side = 1; }
                steps++;
                if (mx < minX || mx > maxX || my < minY || my > maxY) break;   // beyond MAX_DIST (Chebyshev)
                c = world.cell(mx, my);
                if (Cells.solid(c)) { hit = 1; break; }
            }

            // ---- finish the column: exact perpendicular distance from the hit cell ----
            var perp:Int;
            var tx = 0;
            if (hit == 1) {
                var pf:Float;
                var wx:Float;
                if (side == 0) {
                    pf = (stepX > 0 ? mx - px : mx + 1.0 - px) / rdx;
                    wx = py + pf * rdy;
                } else {
                    pf = (stepY > 0 ? my - py : my + 1.0 - py) / rdy;
                    wx = px + pf * rdx;
                }
                perp = Std.int(pf * 65536.0);
                if (perp < MIN_DIST) perp = MIN_DIST;
                var wi = Std.int(wx); if (wx < wi) wi--;
                wx -= wi;                              // [0, 1) along the wall
                tx = Std.int(wx * 64.0) & 63;
                if ((side == 0 && rdx > 0) || (side == 1 && rdy < 0)) tx = 63 - tx;
            } else {
                perp = noHitDist;
            }
            oDist[i] = perp;
            oTex[i] = tx;
            oSide[i] = side;
            oCellX[i] = mx;
            oCellY[i] = my;
            oCell[i] = c;
            oFace[i] = side == 0 ? (stepX > 0 ? Cells.W : Cells.E) : (stepY > 0 ? Cells.N : Cells.S);
            oHit[i] = hit;
        }
        out.count = n;
    }
}
