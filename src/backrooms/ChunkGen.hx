// Procedural chunk generation (CONTRACT §1, DESIGN §2). Core class: no flash.* imports.
//
// A chunk is a pure function of (tapeSeed, cx, cy): the four edge profiles are hashed from the
// unordered pair of chunk coordinates (so both neighbours stamp the same 32 entries), the zone is
// sampled from low-frequency value noise, and everything inside comes from one Rng seeded with
// hash3(hash2(tapeSeed, TAG_CHUNK), cx, cy) ^ altSeed.  The steps inside generate() follow
// DESIGN §2: profiles -> spines -> zone carve -> wet -> sightline -> pits -> feel rules ->
// connectivity repair -> variant/light/damage bits (the bits are stamped last so no layout step
// can clobber them; the layout they decorate is exactly the one DESIGN's order produces).
// Spine cells (and the hub) are recorded in `prot` and no later step ever turns them back into
// WALL, so every border opening stays connected to the hub; repair only ever has to deal with
// interior pockets the zone carve left behind.
//
// Border cells (x or y == 0 or 31) are the profile and nothing else: no step writes a type into
// them after the stamp (only the variant / light / damage bits are added), which is what keeps
// the seam between two chunks consistent.  Profile entries 0 and 31 (the corners) are always
// wall so the two profiles meeting at a corner never disagree.
//
// Variant-bit conventions (Textures depends on them): WALL/PILLAR in a DARK chunk carry variant 7,
// other walls 0..3; floor cells ringing a pit carry variant 1, every other floor cell 0.
//
// Scratch vectors and the two Rng instances are static and allocated once; generate() allocates
// nothing (an Rng is reseeded through its public state, never re-created).
class ChunkGen {
    public static inline var Z_HALL = 0;
    public static inline var Z_WARREN = 1;
    public static inline var Z_ROOMS = 2;
    public static inline var Z_DARK = 3;
    public static var opsCounter:Int = 0;             // incremented by inner loops; tests assert < 200000 per chunk

    static inline var SZ = 32;                        // Chunk.SIZE
    static inline var LAST = 31;
    static inline var P_SPINE = 1;                    // prot bits
    static inline var P_RIM = 2;
    static inline var NOISE_STEPS = 64;               // CDF table resolution
    static inline var MAX_REGIONS = 16;               // DESIGN §2 step 9
    static inline var MAX_CARVE = 1024;
    static inline var MAZE_N = 15;                    // WARREN lattice nodes per axis (odd coords 1..29)
    static inline var MAX_ROOMS = 63;                 // BSP leaves (<= 49 on a 30x30 interior)
    static inline var PAIR_DIM = 64;
    static inline var M_REACHED = 1;                  // mark values used by repair
    static inline var M_REGION = 2;

    // private scratch (allocated once, static)
    static var prot:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);       // P_SPINE / P_RIM flags per cell
    static var mark:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);       // flood marks / room ids / maze visited
    static var par:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);        // BFS parents (repair)
    static var dist:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);       // BFS distances (repair)
    static var queue:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);      // BFS ring
    static var stack:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);      // DFS / BSP stack
    static var edgeN:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);
    static var edgeE:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);
    static var edgeS:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);
    static var edgeW:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);
    static var roomFlag:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(PAIR_DIM);     // bit 0 = closed (three walls); bits 8+ = doors so far
    static var pairCnt:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(PAIR_DIM * PAIR_DIM);
    static var pairSel:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(PAIR_DIM * PAIR_DIM);
    static var pairList:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(PAIR_DIM * 4);
    static var pairCount:Int = 0;
    static var rngChunk:Rng = new Rng(1);             // the chunk stream (reseeded per generate)
    static var rngEdge:Rng = new Rng(1);              // the edge stream (reseeded per edgeProfile)
    static var tablesReady:Bool = false;

    // Quantiles of the raw two-octave value noise at i/64 (calibrated over 1M samples of rawNoise;
    // the distribution does not depend on the seed): openness() maps the raw value through this
    // table so it is uniform on [0, 1) and the zone shares below are exact thresholds.
    static var cdf:haxe.ds.Vector<Float> = buildCdf();

    static function buildCdf():haxe.ds.Vector<Float> {
        var v = new haxe.ds.Vector<Float>(NOISE_STEPS + 1);
        var a = [
            0.0000, 0.1694, 0.2036, 0.2275, 0.2467, 0.2630, 0.2775, 0.2908, 0.3030, 0.3144,
            0.3251, 0.3352, 0.3449, 0.3543, 0.3633, 0.3721, 0.3805, 0.3888, 0.3968, 0.4048,
            0.4126, 0.4203, 0.4279, 0.4353, 0.4427, 0.4500, 0.4573, 0.4646, 0.4717, 0.4788,
            0.4859, 0.4930, 0.5000, 0.5070, 0.5141, 0.5212, 0.5284, 0.5356, 0.5428, 0.5500,
            0.5573, 0.5647, 0.5722, 0.5797, 0.5874, 0.5952, 0.6032, 0.6114, 0.6196, 0.6282,
            0.6370, 0.6460, 0.6552, 0.6648, 0.6749, 0.6856, 0.6970, 0.7092, 0.7225, 0.7370,
            0.7533, 0.7726, 0.7964, 0.8302, 1.0000
        ];
        for (i in 0...NOISE_STEPS + 1) v[i] = a[i];
        return v;
    }

    // Vector<Int> entries are null until written on the interpreter: zero every scratch once.
    static function initTables():Void {
        if (tablesReady) return;
        tablesReady = true;
        for (i in 0...PAIR_DIM * PAIR_DIM) { pairCnt[i] = 0; pairSel[i] = 0; }
        for (i in 0...PAIR_DIM) roomFlag[i] = 0;
        for (i in 0...Chunk.AREA) { prot[i] = 0; mark[i] = 0; par[i] = 0; dist[i] = 0; queue[i] = 0; stack[i] = 0; }
        for (i in 0...Chunk.SIZE) { edgeN[i] = 0; edgeE[i] = 0; edgeS[i] = 0; edgeW[i] = 0; }
    }

    // the Rng constructor's seeding, applied to an existing instance (no allocation per chunk)
    static inline function reseed(r:Rng, seed:Int):Rng {
        var s = Rng.mix(seed);
        r.state = s == 0 ? 0x9E3779B9 : s;
        return r;
    }

    // ------------------------------------------------------------------------------------------
    // zone noise
    // ------------------------------------------------------------------------------------------

    static inline function ifloor(v:Float):Int { var i = Std.int(v); return v < i ? i - 1 : i; }

    // one octave of smoothstep-interpolated value noise on the integer lattice, in [0, 1)
    static function lattice(seed:Int, u:Float, v:Float):Float {
        var ix = ifloor(u);
        var iy = ifloor(v);
        var tx = u - ix;
        var ty = v - iy;
        tx = tx * tx * (3.0 - 2.0 * tx);
        ty = ty * ty * (3.0 - 2.0 * ty);
        var a = Rng.unit(Rng.hash3(seed, ix, iy));
        var b = Rng.unit(Rng.hash3(seed, ix + 1, iy));
        var c = Rng.unit(Rng.hash3(seed, ix, iy + 1));
        var d = Rng.unit(Rng.hash3(seed, ix + 1, iy + 1));
        var top = a + (b - a) * tx;
        var bot = c + (d - c) * tx;
        return top + (bot - top) * ty;
    }

    // two octaves (periods 4 and 2 chunks) of the field `field` (1 = openness, 2 = darkness)
    static function rawNoise(tapeSeed:Int, field:Int, fx:Float, fy:Float):Float {
        var s1 = Rng.hash3(tapeSeed, Rng.TAG_ZONE, field);
        var s2 = Rng.hash3(tapeSeed, Rng.TAG_ZONE, field + 16);
        return 0.7 * lattice(s1, fx * 0.25, fy * 0.25) + 0.3 * lattice(s2, fx * 0.5 + 0.37, fy * 0.5 + 0.71);
    }

    // raw noise value -> uniform [0, 1) through the calibrated quantile table
    static function uniformise(v:Float):Float {
        var t = cdf;
        if (v <= t[0]) return 0.0;
        if (v >= t[NOISE_STEPS]) return 0.999999;
        var lo = 0;
        var hi = NOISE_STEPS;
        while (hi - lo > 1) {
            var mid = (lo + hi) >> 1;
            if (t[mid] <= v) lo = mid; else hi = mid;
        }
        var span = t[hi] - t[lo];
        var frac = span > 0.0 ? (v - t[lo]) / span : 0.0;
        var u = (lo + frac) / NOISE_STEPS;
        return u >= 1.0 ? 0.999999 : u;
    }

    // openness 0..1 of the low-frequency zone noise at a point in chunk units (used by edgeProfile); pure
    public static function openness(tapeSeed:Int, fx:Float, fy:Float):Float {
        return uniformise(rawNoise(tapeSeed, 1, fx, fy));
    }

    static function darkness(tapeSeed:Int, fx:Float, fy:Float):Float {
        return uniformise(rawNoise(tapeSeed, 2, fx, fy));
    }

    // distance-from-origin shift 0..1 over the first 20 chunks (DARK and WARREN rise +10 points each)
    static inline function shiftAt(d:Float):Float {
        return d >= 20.0 ? 1.0 : (d < 0.0 ? 0.0 : d / 20.0);
    }

    static inline function darkShare(s:Float):Float return 0.08 + 0.10 * s;

    // HALL / ROOMS / WARREN from a uniform openness value at distance shift s (DESIGN §2 zone table:
    // 55 / 25 / 12 / 8 at the origin, 39 / 35 / 8 / 18 twenty chunks out)
    static function classify(o:Float, s:Float):Int {
        var nd = 1.0 - darkShare(s);
        var pHall = (0.55 - 0.16 * s) / nd;
        var pWarren = (0.25 + 0.10 * s) / nd;
        if (o >= 1.0 - pHall) return Z_HALL;
        if (o < pWarren) return Z_WARREN;
        return Z_ROOMS;
    }

    static inline function chebF(fx:Float, fy:Float):Float {
        var ax = fx < 0 ? -fx : fx;
        var ay = fy < 0 ? -fy : fy;
        return ax > ay ? ax : ay;
    }

    public static function zoneAt(tapeSeed:Int, cx:Int, cy:Int):Int {
        var fx = cx + 0.5;
        var fy = cy + 0.5;
        var s = shiftAt(chebF(fx, fy));
        if (darkness(tapeSeed, fx, fy) >= 1.0 - darkShare(s)) return Z_DARK;
        return classify(openness(tapeSeed, fx, fy), s);
    }

    // the layout style a DARK chunk uses underneath its dark floor (hash only, so it is pure)
    static function darkStyle(tapeSeed:Int, cx:Int, cy:Int):Int {
        var u = Rng.unit(Rng.hash3(Rng.hash2(tapeSeed, Rng.TAG_ZONE + 32), cx, cy));
        return u < 0.5 ? Z_HALL : (u < 0.8 ? Z_WARREN : Z_ROOMS);
    }

    // ------------------------------------------------------------------------------------------
    // hub and edge profiles
    // ------------------------------------------------------------------------------------------

    // packed LOCAL (y << 5) | x of the hub cell — the same encoding as the Chunk.cells index, so cells[hubOf(...)] is the hub; middle third
    public static function hubOf(tapeSeed:Int, cx:Int, cy:Int):Int {
        var h = Rng.hash3(Rng.hash2(tapeSeed, Rng.TAG_CHUNK + 64), cx, cy);
        var x = 11 + ((h >>> 4) % 11);          // 11..21
        var y = 11 + ((h >>> 12) % 11);
        return (y << 5) | x;
    }

    // 32-entry profile (1 = open, 0 = wall) of the edge shared by 4-adjacent chunks a and b, identical for (a,b) and (b,a).
    // Entry i runs along the edge in increasing x (horizontal edge) or increasing y (vertical edge). At least one 1.
    public static function edgeProfile(tapeSeed:Int, ax:Int, ay:Int, bx:Int, by:Int, out:haxe.ds.Vector<Int>):Void {
        // order the pair so (a, b) and (b, a) hash the same
        var x0 = ax, y0 = ay, x1 = bx, y1 = by;
        if (x1 < x0 || (x1 == x0 && y1 < y0)) { x0 = bx; y0 = by; x1 = ax; y1 = ay; }
        var rng = reseed(rngEdge, Rng.hash3(Rng.hash3(tapeSeed, Rng.TAG_EDGE, x0), y0, Rng.hash2(x1, y1)));
        // edge midpoint in chunk units: a vertical edge (x differs) lies at x = x1; a horizontal one at y = y1
        var mx:Float;
        var my:Float;
        if (x0 != x1) { mx = x1; my = y0 + 0.5; } else { mx = x0 + 0.5; my = y1; }
        var s = shiftAt(chebF(mx, my));
        var kind = classify(openness(tapeSeed, mx, my), s);
        if (kind == Z_HALL) {
            // mostly open (60-90%) with wall runs 2-6 long; corners always wall
            for (i in 0...SZ) out[i] = 1;
            out[0] = 0;
            out[LAST] = 0;
            var wallTarget = Std.int((1.0 - (0.6 + 0.3 * rng.nextFloat())) * 30.0);
            var walls = 0;
            var tries = 0;
            while (walls < wallTarget && tries < 12) {
                tries++;
                var len = rng.range(2, 7);
                var st = rng.range(1, LAST - len);
                for (i in st...st + len) {
                    if (out[i] == 1) { out[i] = 0; walls++; }
                }
            }
        } else {
            // mostly wall with 1-3 door runs, 1-3 cells wide (ROOMS: 1-2)
            for (i in 0...SZ) out[i] = 0;
            var doors = rng.range(1, 4);
            var wmax = kind == Z_ROOMS ? 3 : 4;
            for (d in 0...doors) {
                var w = rng.range(1, wmax);
                var st = rng.range(1, LAST - w);
                for (i in st...st + w) out[i] = 1;
            }
        }
        // at least one opening (neither branch can fail, but the contract promises it)
        var any = 0;
        for (i in 1...LAST) any |= out[i];
        if (any == 0) out[16] = 1;
        opsCounter += SZ * 2;
    }

    // ------------------------------------------------------------------------------------------
    // generate
    // ------------------------------------------------------------------------------------------

    static var gCells:haxe.ds.Vector<Int>;      // the chunk being generated (hoisted for the helpers)
    static var gRng:Rng;
    static var gHubX:Int;
    static var gHubY:Int;
    static var gDark:Bool;
    static var gFloor:Int;                      // FLOOR, or DARK in a dark chunk

    // Fully generates `out` (cx, cy, zone, cells, generation++) as a pure function of (tapeSeed, cx, cy). altSeed != 0 XORs the chunk seed (error recovery).
    public static function generate(tapeSeed:Int, cx:Int, cy:Int, out:Chunk, altSeed:Int = 0):Void {
        initTables();
        var zone = zoneAt(tapeSeed, cx, cy);
        var style = zone == Z_DARK ? darkStyle(tapeSeed, cx, cy) : zone;
        var seed = Rng.hash3(Rng.hash2(tapeSeed, Rng.TAG_CHUNK), cx, cy) ^ altSeed;
        var rng = gRng = reseed(rngChunk, seed);
        var cells = gCells = out.cells;
        out.cx = cx;
        out.cy = cy;
        out.zone = zone;
        gDark = zone == Z_DARK;
        gFloor = gDark ? Cells.DARK : Cells.FLOOR;
        var hub = hubOf(tapeSeed, cx, cy);
        gHubX = hub & 31;
        gHubY = hub >> 5;
        opsCounter += Chunk.AREA;

        // 1. fill WALL, stamp the four edge profiles onto the border cells
        for (i in 0...Chunk.AREA) { cells[i] = Cells.WALL; prot[i] = 0; }
        edgeProfile(tapeSeed, cx, cy, cx, cy - 1, edgeN);
        edgeProfile(tapeSeed, cx, cy, cx, cy + 1, edgeS);
        edgeProfile(tapeSeed, cx, cy, cx - 1, cy, edgeW);
        edgeProfile(tapeSeed, cx, cy, cx + 1, cy, edgeE);
        var floor = gFloor;
        for (i in 0...SZ) {
            if (edgeN[i] == 1) cells[i] = floor;
            if (edgeS[i] == 1) cells[(LAST << 5) | i] = floor;
            if (edgeW[i] == 1) cells[i << 5] = floor;
            if (edgeE[i] == 1) cells[(i << 5) | LAST] = floor;
        }

        // 2. spines: a random-walk corridor from the centre of every open run on every edge to the hub
        cells[hub] = floor;
        prot[hub] |= P_SPINE;
        var wide = style == Z_WARREN ? 0.15 : 0.35;
        carveSpines(edgeN, 0, wide);
        carveSpines(edgeS, 1, wide);
        carveSpines(edgeW, 2, wide);
        carveSpines(edgeE, 3, wide);

        // 3. zone carving (never overwriting spine cells with WALL)
        switch (style) {
            case Z_WARREN: carveWarren();
            case Z_ROOMS: carveRooms();
            default: carveHall();
        }

        // 4. wet patches: 1-3 blobs of radius 2-4 in 30% of chunks (plain FLOOR only, so never in DARK)
        if (rng.chance(0.30)) {
            var blobs = rng.range(1, 4);
            for (b in 0...blobs) {
                var r = rng.range(2, 5);
                var bx = rng.range(3, 29);
                var by = rng.range(3, 29);
                var r2 = r * r;
                for (y in by - r...by + r + 1) {
                    if (y < 1 || y > 30) continue;
                    for (x in bx - r...bx + r + 1) {
                        if (x < 1 || x > 30) continue;
                        var dx = x - bx, dy = y - by;
                        if (dx * dx + dy * dy > r2) continue;
                        var i = (y << 5) | x;
                        if (cells[i] == Cells.FLOOR) cells[i] = Cells.WET;
                    }
                }
                opsCounter += (2 * r + 1) * (2 * r + 1);
            }
        }

        // 5. long sightline in 1-in-6 chunks: a straight 20-32-cell corridor, stopping at the border profile
        if (rng.chance(1.0 / 6.0)) {
            var len = rng.range(20, 33);
            var pos = rng.range(3, 29);
            var st = len >= 30 ? 1 : rng.range(1, 32 - len);
            var en = st + len - 1;
            if (en > 30) en = 30;
            var horizontal = rng.chance(0.5);
            for (t in st...en + 1) {
                var i = horizontal ? ((pos << 5) | t) : ((t << 5) | pos);
                if (Cells.solid(cells[i])) cells[i] = floor;
            }
            opsCounter += len;
        }

        // 6. pits: HALL or ROOMS only (never DARK), p 0.04, one 1x1 PIT on a floor cell with all 8 neighbours floor
        if ((zone == Z_HALL || zone == Z_ROOMS) && rng.chance(0.04)) {
            for (tries in 0...16) {
                var px = rng.range(3, 29);
                var py = rng.range(3, 29);
                if (px == gHubX && py == gHubY) continue;
                var ok = true;
                for (dy in -1...2) {
                    for (dx in -1...2) {
                        if (cells[((py + dy) << 5) | (px + dx)] != Cells.FLOOR) ok = false;
                    }
                }
                if (!ok) continue;
                cells[(py << 5) | px] = Cells.PIT;
                for (dy in -1...2) {
                    for (dx in -1...2) {
                        if (dx != 0 || dy != 0) prot[((py + dy) << 5) | (px + dx)] |= P_RIM;
                    }
                }
                break;
            }
        }

        // 8. feel rules: pillars away from doors, an alcove every 12 corridor cells, no 1x1 pockets
        removePillarsNearDoors();
        carveAlcoves();
        fillPockets();

        // 9. connectivity repair: everything walkable reaches the hub, or becomes WALL
        repairConnectivity(out, gHubX, gHubY);
        fillPockets();

        // 7. texture variant, light and damage bits (stamped last so nothing overwrites them)
        applyBits(cx, cy, seed);

        out.generation++;
        gCells = null;
        gRng = null;
    }

    // ---- spines ----------------------------------------------------------------------------------

    // side: 0 = N (y = 0), 1 = S (y = 31), 2 = W (x = 0), 3 = E (x = 31)
    static function carveSpines(profile:haxe.ds.Vector<Int>, side:Int, wideP:Float):Void {
        var i = 1;
        while (i < LAST) {
            if (profile[i] == 0) { i++; continue; }
            var i0 = i;
            while (i < LAST && profile[i] == 1) i++;
            var c = (i0 + i - 1) >> 1;
            var sx:Int, sy:Int;
            switch (side) {
                case 0: sx = c; sy = 1;
                case 1: sx = c; sy = 30;
                case 2: sx = 1; sy = c;
                default: sx = 30; sy = c;
            }
            walkSpine(sx, sy, gRng.chance(wideP) ? 2 : 1);
        }
    }

    static inline function carveSpineCell(x:Int, y:Int):Void {
        var i = (y << 5) | x;
        gCells[i] = gFloor;
        prot[i] |= P_SPINE;
    }

    // random walk from (x, y) to the hub, 70% of steps toward it, confined to the interior 1..30,
    // then a straight L-shaped finish so the hub is always reached
    static function walkSpine(x:Int, y:Int, width:Int):Void {
        var rng = gRng;
        var hx = gHubX, hy = gHubY;
        carveSpineCell(x, y);
        var steps = 0;
        while ((x != hx || y != hy) && steps < 160) {
            steps++;
            var mx = 0, my = 0;
            if (rng.chance(0.7)) {
                var dx = hx - x, dy = hy - y;
                var adx = dx < 0 ? -dx : dx;
                var ady = dy < 0 ? -dy : dy;
                var alongX = adx > ady || (adx == ady && rng.chance(0.5));
                if (alongX) mx = dx < 0 ? -1 : 1; else my = dy < 0 ? -1 : 1;
            } else {
                var d = rng.range(0, 4);
                switch (d) {
                    case 0: my = -1;
                    case 1: mx = 1;
                    case 2: my = 1;
                    default: mx = -1;
                }
            }
            var nx = x + mx, ny = y + my;
            if (nx < 1 || nx > 30 || ny < 1 || ny > 30) continue;
            x = nx; y = ny;
            carveSpineCell(x, y);
            if (width == 2) {
                var wx = x + my, wy = y + mx;       // perpendicular neighbour
                if (wx >= 1 && wx <= 30 && wy >= 1 && wy <= 30) carveSpineCell(wx, wy);
            }
        }
        opsCounter += steps;
        // straight finish: x first, then y
        while (x != hx) { x += hx > x ? 1 : -1; carveSpineCell(x, y); opsCounter++; }
        while (y != hy) { y += hy > y ? 1 : -1; carveSpineCell(x, y); opsCounter++; }
    }

    // ---- HALL ------------------------------------------------------------------------------------

    // true when an open border cell lies within Chebyshev 2 of the interior cell (x, y)
    static function nearDoor(x:Int, y:Int):Bool {
        var lo:Int, hi:Int;
        if (y <= 2) {
            lo = x - 2 < 0 ? 0 : x - 2; hi = x + 2 > LAST ? LAST : x + 2;
            for (i in lo...hi + 1) if (edgeN[i] == 1) return true;
        }
        if (y >= 29) {
            lo = x - 2 < 0 ? 0 : x - 2; hi = x + 2 > LAST ? LAST : x + 2;
            for (i in lo...hi + 1) if (edgeS[i] == 1) return true;
        }
        if (x <= 2) {
            lo = y - 2 < 0 ? 0 : y - 2; hi = y + 2 > LAST ? LAST : y + 2;
            for (i in lo...hi + 1) if (edgeW[i] == 1) return true;
        }
        if (x >= 29) {
            lo = y - 2 < 0 ? 0 : y - 2; hi = y + 2 > LAST ? LAST : y + 2;
            for (i in lo...hi + 1) if (edgeE[i] == 1) return true;
        }
        return false;
    }

    static function carveHall():Void {
        var cells = gCells;
        var rng = gRng;
        var floor = gFloor;
        // open floor over the whole interior
        for (y in 1...LAST) {
            var row = y << 5;
            for (x in 1...LAST) cells[row | x] = floor;
        }
        opsCounter += 900;
        // pillars every 4 cells with +-1 jitter, p 0.7, never on a spine, never within 2 cells of a door
        for (gy in 0...8) {
            for (gx in 0...8) {
                var px = 2 + gx * 4 + rng.range(-1, 2);
                var py = 2 + gy * 4 + rng.range(-1, 2);
                if (!rng.chance(0.7)) continue;
                if (px < 1 || px > 30 || py < 1 || py > 30) continue;
                var i = (py << 5) | px;
                if (prot[i] != 0) continue;
                if (nearDoor(px, py)) continue;
                cells[i] = Cells.PILLAR;
            }
        }
        opsCounter += 64;
        // wall slabs 6-10 cells long, 1 thick, never over a spine
        var slabs = rng.range(3, 7);
        for (s in 0...slabs) {
            var len = rng.range(6, 11);
            var horizontal = rng.chance(0.5);
            var a = rng.range(2, 31 - len);       // start along the slab
            var b = rng.range(2, 30);             // the fixed coordinate
            for (t in a...a + len) {
                var i = horizontal ? ((b << 5) | t) : ((t << 5) | b);
                if (prot[i] == 0 && cells[i] != Cells.PILLAR) cells[i] = Cells.WALL;
            }
            opsCounter += len;
        }
    }

    // ---- WARREN ----------------------------------------------------------------------------------

    static inline function mazeCarve(x:Int, y:Int):Void {
        var i = (y << 5) | x;
        if (Cells.solid(gCells[i])) gCells[i] = gFloor;
    }

    // randomised DFS maze on the 2-cell lattice: node (nx, ny) is cell (1 + 2nx, 1 + 2ny), passages
    // are the even cells between nodes; 25% of passages are widened to 2; 65% of dead ends are joined
    // to a neighbouring corridor (35% kept as Watcher cover)
    static function carveWarren():Void {
        var rng = gRng;
        var cells = gCells;
        var n = MAZE_N;
        for (i in 0...n * n) mark[i] = 0;
        var sx = (gHubX - 1) >> 1; if (sx > n - 1) sx = n - 1;
        var sy = (gHubY - 1) >> 1; if (sy > n - 1) sy = n - 1;
        var sp = 0;
        stack[sp++] = sy * n + sx;
        mark[sy * n + sx] = 1;
        mazeCarve(1 + 2 * sx, 1 + 2 * sy);
        var ops = 0;
        while (sp > 0) {
            var cur = stack[sp - 1];
            var cxn = cur % n;
            var cyn = Std.int(cur / n);
            var upOk = cyn > 0 && mark[cur - n] == 0;
            var rightOk = cxn < n - 1 && mark[cur + 1] == 0;
            var downOk = cyn < n - 1 && mark[cur + n] == 0;
            var leftOk = cxn > 0 && mark[cur - 1] == 0;
            var cnt = (upOk ? 1 : 0) + (rightOk ? 1 : 0) + (downOk ? 1 : 0) + (leftOk ? 1 : 0);
            ops++;
            if (cnt == 0) { sp--; continue; }
            var pick = rng.range(0, cnt);
            var dx = 0, dy = 0;
            var k = 0;
            if (upOk) { if (k == pick) dy = -1; k++; }
            if (rightOk) { if (k == pick) dx = 1; k++; }
            if (downOk) { if (k == pick) dy = 1; k++; }
            if (leftOk) { if (k == pick) dx = -1; k++; }
            var ni = (cyn + dy) * n + (cxn + dx);
            mark[ni] = 1;
            var ax = 1 + 2 * cxn, ay = 1 + 2 * cyn;
            var px = ax + dx, py = ay + dy;          // passage cell
            var bx = ax + 2 * dx, by = ay + 2 * dy;  // neighbour node cell
            mazeCarve(px, py);
            mazeCarve(bx, by);
            if (rng.chance(0.25)) {
                var wx = dy != 0 ? 1 : 0, wy = dx != 0 ? 1 : 0;   // perpendicular offset
                mazeCarve(ax + wx, ay + wy);
                mazeCarve(px + wx, py + wy);
                mazeCarve(bx + wx, by + wy);
            }
            stack[sp++] = ni;
        }
        opsCounter += ops;
        // dead ends: keep 35%, connect the rest to a neighbouring corridor (a loop)
        for (ny in 0...n) {
            for (nx in 0...n) {
                var ax = 1 + 2 * nx, ay = 1 + 2 * ny;
                var deg = 0;
                if (ny > 0 && !Cells.solid(cells[((ay - 1) << 5) | ax])) deg++;
                if (nx < n - 1 && !Cells.solid(cells[(ay << 5) | (ax + 1)])) deg++;
                if (ny < n - 1 && !Cells.solid(cells[((ay + 1) << 5) | ax])) deg++;
                if (nx > 0 && !Cells.solid(cells[(ay << 5) | (ax - 1)])) deg++;
                if (deg != 1) continue;
                if (rng.chance(0.35)) continue;
                var d = rng.range(0, 4);
                for (k in 0...4) {
                    var dd = (d + k) & 3;
                    var dx = dd == 1 ? 1 : (dd == 3 ? -1 : 0);
                    var dy = dd == 0 ? -1 : (dd == 2 ? 1 : 0);
                    var tx = nx + dx, ty = ny + dy;
                    if (tx < 0 || ty < 0 || tx >= n || ty >= n) continue;
                    var pi = ((ay + dy) << 5) | (ax + dx);
                    if (!Cells.solid(cells[pi])) continue;
                    cells[pi] = gFloor;
                    break;
                }
            }
        }
        opsCounter += n * n;
    }

    // ---- ROOMS -----------------------------------------------------------------------------------

    // BSP of the 30x30 interior into 3-7-cell rooms separated by 1-cell walls; one doorway per shared
    // wall (p 0.8, sometimes two); 12% of rooms take a single door only (walled on three sides)
    static function carveRooms():Void {
        var cells = gCells;
        var rng = gRng;
        var floor = gFloor;
        for (i in 0...Chunk.AREA) mark[i] = 0;
        opsCounter += Chunk.AREA;
        // rects packed as x0 | y0 << 8 | x1 << 16 | y1 << 24 (x1, y1 exclusive)
        var sp = 0;
        stack[sp++] = 1 | (1 << 8) | (31 << 16) | (31 << 24);
        var rooms = 0;
        while (sp > 0) {
            var r = stack[--sp];
            var x0 = r & 0xFF, y0 = (r >> 8) & 0xFF, x1 = (r >> 16) & 0xFF, y1 = (r >> 24) & 0xFF;
            var w = x1 - x0, h = y1 - y0;
            var canX = w >= 7, canY = h >= 7;
            var must = w > 7 || h > 7;
            var split = (canX || canY) && (must || rng.chance(0.35)) && rooms + sp < MAX_ROOMS - 1;
            if (split) {
                var alongX = (canX && canY) ? (w > h || (w == h && rng.chance(0.5))) : canX;
                if (alongX) {
                    var s = rng.range(x0 + 3, x1 - 2);      // wall column at s; both sides >= 3
                    stack[sp++] = x0 | (y0 << 8) | (s << 16) | (y1 << 24);
                    stack[sp++] = (s + 1) | (y0 << 8) | (x1 << 16) | (y1 << 24);
                } else {
                    var s = rng.range(y0 + 3, y1 - 2);
                    stack[sp++] = x0 | (y0 << 8) | (x1 << 16) | (s << 24);
                    stack[sp++] = x0 | ((s + 1) << 8) | (x1 << 16) | (y1 << 24);
                }
                continue;
            }
            rooms++;
            roomFlag[rooms] = rng.chance(0.12) ? 1 : 0;
            for (y in y0...y1) {
                var row = y << 5;
                for (x in x0...x1) {
                    var i = row | x;
                    mark[i] = rooms;
                    cells[i] = floor;
                }
            }
            opsCounter += w * h;
        }
        // doorway candidates: interior wall cells between two different rooms; reservoir-sample one per pair
        pairCount = 0;
        for (y in 1...LAST) {
            var row = y << 5;
            for (x in 1...LAST) {
                var i = row | x;
                if (mark[i] != 0 || !Cells.solid(cells[i])) continue;
                var a = mark[i - 1], b = mark[i + 1];
                if (a == 0 || b == 0 || a == b) {
                    a = mark[i - SZ]; b = mark[i + SZ];
                    if (a == 0 || b == 0 || a == b) continue;
                }
                var lo = a < b ? a : b, hi = a < b ? b : a;
                var p = (lo << 6) | hi;
                var c = pairCnt[p];
                if (c == 0) pairList[pairCount++] = p;
                c++;
                pairCnt[p] = c;
                if (rng.range(0, c) == 0) pairSel[p] = i;
            }
        }
        opsCounter += 900;
        // one doorway per shared wall (p 0.8), sometimes two
        for (k in 0...pairCount) {
            var p = pairList[k];
            var lo = p >> 6, hi = p & 63;
            var i = pairSel[p];
            pairCnt[p] = 0;
            var fl = roomFlag[lo], fh = roomFlag[hi];
            var closedLo = (fl & 1) != 0 && (fl >> 8) > 0;
            var closedHi = (fh & 1) != 0 && (fh >> 8) > 0;
            if (closedLo || closedHi) continue;
            if (!rng.chance(0.8)) continue;
            cells[i] = floor;
            roomFlag[lo] = fl + 256;
            roomFlag[hi] = fh + 256;
            if (rng.chance(0.25)) {
                // a second cell along the same wall, if it separates the same pair
                var vertical = mark[i - 1] != 0 && mark[i + 1] != 0;
                var j = vertical ? i + SZ : i + 1;
                var jx = j & 31, jy = j >> 5;
                if (jx >= 1 && jx <= 30 && jy >= 1 && jy <= 30 && mark[j] == 0 && Cells.solid(cells[j])) {
                    var a = vertical ? mark[j - 1] : mark[j - SZ];
                    var b = vertical ? mark[j + 1] : mark[j + SZ];
                    if ((a == lo && b == hi) || (a == hi && b == lo)) cells[j] = floor;
                }
            }
        }
        opsCounter += pairCount;
        for (r in 0...rooms + 1) roomFlag[r] = 0;
    }

    // ---- feel rules -------------------------------------------------------------------------------

    static function removePillarsNearDoors():Void {
        var cells = gCells;
        for (y in 1...LAST) {
            for (x in 1...LAST) {
                if (x > 2 && x < 29 && y > 2 && y < 29) continue;
                var i = (y << 5) | x;
                if (Cells.type(cells[i]) == Cells.PILLAR && nearDoor(x, y)) cells[i] = gFloor;
            }
        }
        opsCounter += 232;
    }

    // an alcove (1-cell side notch) within every 12 straight corridor cells
    static function carveAlcoves():Void {
        var cells = gCells;
        var run = 0;
        for (y in 1...LAST) {
            var row = y << 5;
            for (x in 1...LAST) {
                var i = row | x;
                if (Cells.solid(cells[i])) continue;
                var n = !Cells.solid(cells[i - SZ]);
                var s = !Cells.solid(cells[i + SZ]);
                var e = !Cells.solid(cells[i + 1]);
                var w = !Cells.solid(cells[i - 1]);
                var straightX = e && w && !n && !s;
                var straightY = n && s && !e && !w;
                if (!straightX && !straightY) continue;
                run++;
                if (run < 12) continue;
                var j1 = straightX ? i - SZ : i - 1;
                var j2 = straightX ? i + SZ : i + 1;
                if (tryNotch(j1) || tryNotch(j2)) run = 0;
            }
        }
        opsCounter += 900;
    }

    // carve wall cell j into a notch if it is interior and exactly one of its neighbours is open
    static function tryNotch(j:Int):Bool {
        var cells = gCells;
        var x = j & 31, y = j >> 5;
        if (x < 1 || x > 30 || y < 1 || y > 30) return false;
        if (!Cells.solid(cells[j])) return false;
        var open = 0;
        if (!Cells.solid(cells[j - SZ])) open++;
        if (!Cells.solid(cells[j + SZ])) open++;
        if (!Cells.solid(cells[j - 1])) open++;
        if (!Cells.solid(cells[j + 1])) open++;
        if (open != 1) return false;
        cells[j] = gFloor;
        return true;
    }

    // fill every 1x1 floor pocket (interior walkable cell with four solid neighbours)
    static function fillPockets():Void {
        var cells = gCells;
        for (y in 1...LAST) {
            var row = y << 5;
            for (x in 1...LAST) {
                var i = row | x;
                if (Cells.solid(cells[i])) continue;
                if (Cells.solid(cells[i - SZ]) && Cells.solid(cells[i + SZ]) && Cells.solid(cells[i - 1]) && Cells.solid(cells[i + 1]))
                    cells[i] = Cells.WALL;
            }
        }
        opsCounter += 900;
    }

    // ---- bits ------------------------------------------------------------------------------------

    // wall variant 0..3 (7 in DARK chunks), damaged 1-in-40 walls, light panels on the world lattice
    // (wx % 3 == 1 && wy % 3 == 1, none in DARK), pit rim variant 1 on the eight cells round a pit
    static function applyBits(cx:Int, cy:Int, seed:Int):Void {
        var cells = gCells;
        var rng = reseed(rngChunk, Rng.hash3(seed, Rng.TAG_TEX, 0));
        var dark = gDark;
        var lx0 = (((cx << 5) % 3) + 3) % 3;      // world lattice phase of this chunk's origin
        var ly0 = (((cy << 5) % 3) + 3) % 3;
        for (y in 0...SZ) {
            var row = y << 5;
            var lightRow = !dark && ((ly0 + y) % 3) == 1;
            for (x in 0...SZ) {
                var i = row | x;
                var t = cells[i] & Cells.TYPE_MASK;
                var r = rng.nextInt();
                var c:Int;
                if (t == Cells.WALL || t == Cells.PILLAR) {
                    c = t | ((dark ? 7 : (r & 3)) << Cells.VAR_SHIFT);
                    if (t == Cells.WALL && ((r >>> 8) % 40) == 0) c |= Cells.DAMAGED;
                } else {
                    c = t;
                    if ((prot[i] & P_RIM) != 0) c |= (1 << Cells.VAR_SHIFT);
                    if (lightRow && ((lx0 + x) % 3) == 1) c |= Cells.LIGHT;
                }
                cells[i] = c;
            }
        }
        opsCounter += Chunk.AREA;
    }

    // ------------------------------------------------------------------------------------------
    // connectivity
    // ------------------------------------------------------------------------------------------

    // 4-connected flood over walkable cells from (sx, sy), marking `mark` with `tag`; returns the count.
    static function flood(cells:haxe.ds.Vector<Int>, sx:Int, sy:Int, tag:Int):Int {
        var start = (sy << 5) | sx;
        if (Cells.solid(cells[start]) || mark[start] == tag) return 0;
        var head = 0, tail = 0;
        queue[tail++] = start;
        mark[start] = tag;
        var count = 0;
        while (head < tail) {
            var i = queue[head++];
            count++;
            var x = i & 31, y = i >> 5;
            if (y > 0) { var j = i - SZ; if (mark[j] != tag && !Cells.solid(cells[j])) { mark[j] = tag; queue[tail++] = j; } }
            if (y < LAST) { var j = i + SZ; if (mark[j] != tag && !Cells.solid(cells[j])) { mark[j] = tag; queue[tail++] = j; } }
            if (x > 0) { var j = i - 1; if (mark[j] != tag && !Cells.solid(cells[j])) { mark[j] = tag; queue[tail++] = j; } }
            if (x < LAST) { var j = i + 1; if (mark[j] != tag && !Cells.solid(cells[j])) { mark[j] = tag; queue[tail++] = j; } }
        }
        opsCounter += count;
        return count;
    }

    // Test helper: number of floor cells reachable from (sx, sy) inside the chunk (4-connected, walkable cells).
    public static function floodCount(c:Chunk, sx:Int, sy:Int):Int {
        initTables();
        for (i in 0...Chunk.AREA) mark[i] = 0;
        return flood(c.cells, sx, sy, M_REACHED);
    }

    // Flood-fill from the hub; carve tunnels to unreached regions; fill the rest WALL. Returns cells carved. Called by generate; public for tests.
    public static function repairConnectivity(c:Chunk, hubX:Int, hubY:Int):Int {
        initTables();
        var cells = c.cells;
        var hubI = (hubY << 5) | hubX;
        // the floor type to carve with: the generator's while generating, else read off the hub
        var floor = (gCells == cells) ? gFloor : (Cells.type(cells[hubI]) == Cells.DARK ? Cells.DARK : Cells.FLOOR);
        for (i in 0...Chunk.AREA) mark[i] = 0;
        if (Cells.solid(cells[hubI])) cells[hubI] = floor;
        flood(cells, hubX, hubY, M_REACHED);

        // distance field from the reached set through every interior cell (walls included); parents in `par`
        var head = 0, tail = 0;
        for (i in 0...Chunk.AREA) {
            par[i] = -1;
            dist[i] = -1;
            if (mark[i] == M_REACHED) { par[i] = i; dist[i] = 0; queue[tail++] = i; }
        }
        while (head < tail) {
            var i = queue[head++];
            var x = i & 31, y = i >> 5;
            var d = dist[i] + 1;
            if (y > 1) { var j = i - SZ; if (par[j] < 0) { par[j] = i; dist[j] = d; queue[tail++] = j; } }
            if (y < 30) { var j = i + SZ; if (par[j] < 0) { par[j] = i; dist[j] = d; queue[tail++] = j; } }
            if (x > 1) { var j = i - 1; if (par[j] < 0) { par[j] = i; dist[j] = d; queue[tail++] = j; } }
            if (x < 30) { var j = i + 1; if (par[j] < 0) { par[j] = i; dist[j] = d; queue[tail++] = j; } }
        }
        opsCounter += Chunk.AREA + tail;

        var carved = 0;
        var regions = 0;
        for (i in 0...Chunk.AREA) {
            if (mark[i] != 0 || Cells.solid(cells[i])) continue;
            if (regions >= MAX_REGIONS || carved >= MAX_CARVE) break;
            regions++;
            // flood the region, tracking its cell nearest the reached set
            var rh = 0, rt = 0;
            queue[rt++] = i;
            mark[i] = M_REGION;
            var best = -1;
            var bestD = 0x7FFFFFFF;
            while (rh < rt) {
                var k = queue[rh++];
                var dk = dist[k];
                if (dk >= 0 && dk < bestD) { bestD = dk; best = k; }
                var x = k & 31, y = k >> 5;
                if (y > 0) { var j = k - SZ; if (mark[j] == 0 && !Cells.solid(cells[j])) { mark[j] = M_REGION; queue[rt++] = j; } }
                if (y < LAST) { var j = k + SZ; if (mark[j] == 0 && !Cells.solid(cells[j])) { mark[j] = M_REGION; queue[rt++] = j; } }
                if (x > 0) { var j = k - 1; if (mark[j] == 0 && !Cells.solid(cells[j])) { mark[j] = M_REGION; queue[rt++] = j; } }
                if (x < LAST) { var j = k + 1; if (mark[j] == 0 && !Cells.solid(cells[j])) { mark[j] = M_REGION; queue[rt++] = j; } }
            }
            opsCounter += rt;
            if (best < 0) continue;          // only border cells with a walled inward neighbour: sealBorder handles those
            // carve the tunnel from `best` back along the parents to the reached set
            var w = par[best];
            var hops = 0;
            while (w >= 0 && mark[w] != M_REACHED && hops < 128 && carved < MAX_CARVE) {
                if (Cells.solid(cells[w])) { cells[w] = floor; carved++; }
                w = par[w];
                hops++;
            }
            opsCounter += hops;
            // grow the reached set through the tunnel and the region
            flood(cells, best & 31, best >> 5, M_REACHED);
        }
        // anything still unreached becomes WALL (interior only: border cells are the shared profile)
        for (y in 1...LAST) {
            var row = y << 5;
            for (x in 1...LAST) {
                var k = row | x;
                if (mark[k] != M_REACHED && !Cells.solid(cells[k])) cells[k] = Cells.WALL;
            }
        }
        opsCounter += 900;
        // a border opening that is still cut off gets a straight tunnel inward to the reached set
        for (i in 1...LAST) {
            carved += sealBorder(cells, i, 0, 0, 1, floor, hubX, hubY);
            carved += sealBorder(cells, i, LAST, 0, -1, floor, hubX, hubY);
            carved += sealBorder(cells, 0, i, 1, 0, floor, hubX, hubY);
            carved += sealBorder(cells, LAST, i, -1, 0, floor, hubX, hubY);
        }
        return carved;
    }

    // walk inward from an unreached border opening, carving, until a reached cell is met (at worst an
    // L-path all the way to the hub); then flood from the opening so the reached set absorbs the tunnel
    static function sealBorder(cells:haxe.ds.Vector<Int>, x:Int, y:Int, dx:Int, dy:Int, floor:Int, hubX:Int, hubY:Int):Int {
        var i = (y << 5) | x;
        if (Cells.solid(cells[i]) || mark[i] == M_REACHED) return 0;
        var carved = 0;
        var cx = x + dx, cy = y + dy;
        var j = (cy << 5) | cx;
        if (Cells.solid(cells[j])) { cells[j] = floor; carved++; }
        var steps = 1;
        while (mark[j] != M_REACHED && (cx != hubX || cy != hubY) && steps < 64) {
            steps++;
            if (cx != hubX) cx += hubX > cx ? 1 : -1; else cy += hubY > cy ? 1 : -1;
            j = (cy << 5) | cx;
            if (Cells.solid(cells[j])) { cells[j] = floor; carved++; }
        }
        opsCounter += steps;
        flood(cells, x, y, M_REACHED);
        return carved;
    }
}
