// Unit tests for ChunkGen (CONTRACT §1, DESIGN §11). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
class TestChunkGen {
    static var fails:Int = 0;

    static function check(name:String, ok:Bool):Void {
        Sys.println("  " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok) fails++;
    }

    static function sameCells(a:Chunk, b:Chunk):Bool {
        for (i in 0...Chunk.AREA) if (a.cells[i] != b.cells[i]) return false;
        return true;
    }

    static function walkableCount(c:Chunk):Int {
        var n = 0;
        for (i in 0...Chunk.AREA) if (Cells.walkable(c.cells[i])) n++;
        return n;
    }

    // a walkable cell whose in-chunk 4-neighbours are all solid (border cells count their 3)
    static function pocketCount(c:Chunk):Int {
        var n = 0;
        for (y in 0...32) {
            for (x in 0...32) {
                if (!Cells.walkable(c.get(x, y))) continue;
                var open = false;
                if (y > 0 && Cells.walkable(c.get(x, y - 1))) open = true;
                if (y < 31 && Cells.walkable(c.get(x, y + 1))) open = true;
                if (x > 0 && Cells.walkable(c.get(x - 1, y))) open = true;
                if (x < 31 && Cells.walkable(c.get(x + 1, y))) open = true;
                if (!open) n++;
            }
        }
        return n;
    }

    // "" when every pit obeys the rules, else a description
    static function pitCheck(c:Chunk):String {
        for (y in 0...32) {
            for (x in 0...32) {
                if (Cells.type(c.get(x, y)) != Cells.PIT) continue;
                if (c.zone != ChunkGen.Z_HALL && c.zone != ChunkGen.Z_ROOMS) return "pit in zone " + c.zone;
                if (x == 0 || y == 0 || x == 31 || y == 31) return "pit on the border";
                for (dy in -1...2) {
                    for (dx in -1...2) {
                        if (dx == 0 && dy == 0) continue;
                        var v = c.get(x + dx, y + dy);
                        if (!Cells.walkable(v)) return "pit neighbour solid at " + (x + dx) + "," + (y + dy);
                        if (Cells.variant(v) != 1) return "pit rim variant " + Cells.variant(v);
                    }
                }
            }
        }
        return "";
    }

    // border cells of chunk a's `side` against chunk b's opposite side: same walkability
    static function seamAgrees(a:Chunk, b:Chunk, horizontalNeighbour:Bool):Bool {
        for (i in 0...32) {
            var va = horizontalNeighbour ? a.get(31, i) : a.get(i, 31);
            var vb = horizontalNeighbour ? b.get(0, i) : b.get(i, 0);
            if (Cells.walkable(va) != Cells.walkable(vb)) return false;
        }
        return true;
    }

    public static function run():Int {
        fails = 0;
        var a = new Chunk();
        var b = new Chunk();
        var rng = new Rng(777);

        // ---- Chunk: get/set round trip, fill ----
        a.fill(Cells.WALL);
        a.set(5, 7, 0x4B);
        check("Chunk get/set round trip", a.get(5, 7) == 0x4B && a.cells[(7 << 5) | 5] == 0x4B && a.get(6, 7) == Cells.WALL);
        a.fill(Cells.FLOOR);
        var allFloor = true;
        for (i in 0...Chunk.AREA) if (a.cells[i] != Cells.FLOOR) allFloor = false;
        check("Chunk fill sets all 1024", allFloor);

        // ---- (1) determinism: same (seed, cx, cy) twice -> identical cells; different seed -> different ----
        var detOk = true;
        var diffOk = true;
        var genOk = true;
        for (t in 0...24) {
            var seed = rng.nextInt();
            var cx = rng.range(-300, 300);
            var cy = rng.range(-300, 300);
            var g0 = a.generation;
            ChunkGen.generate(seed, cx, cy, a);
            ChunkGen.generate(seed, cx, cy, b);
            if (!sameCells(a, b) || a.zone != b.zone || a.cx != cx || a.cy != cy) detOk = false;
            if (a.generation != g0 + 1) genOk = false;
            ChunkGen.generate(seed ^ 0x5bd1e995, cx, cy, b);
            if (sameCells(a, b)) diffOk = false;
        }
        check("generate: same (seed, cx, cy) twice -> identical cells and zone", detOk);
        check("generate: generation counter increments", genOk);
        check("generate: a different seed changes the cells", diffOk);
        ChunkGen.generate(42, 3, -4, a);
        ChunkGen.generate(42, 3, -4, b, 1);
        check("generate: altSeed != 0 gives a different layout", !sameCells(a, b));
        check("generate: altSeed keeps the zone and the border profile",
            a.zone == b.zone && (function() {
                for (i in 0...32) {
                    if (Cells.walkable(a.get(i, 0)) != Cells.walkable(b.get(i, 0))) return false;
                    if (Cells.walkable(a.get(i, 31)) != Cells.walkable(b.get(i, 31))) return false;
                    if (Cells.walkable(a.get(0, i)) != Cells.walkable(b.get(0, i))) return false;
                    if (Cells.walkable(a.get(31, i)) != Cells.walkable(b.get(31, i))) return false;
                }
                return true;
            })());

        // ---- hubOf: middle third, same encoding as the cells index ----
        var hubOk = true;
        for (t in 0...200) {
            var h = ChunkGen.hubOf(rng.nextInt(), rng.range(-1000, 1000), rng.range(-1000, 1000));
            var hx = h & 31, hy = h >> 5;
            if (hx < 11 || hx > 21 || hy < 11 || hy > 21 || h < 0 || h >= Chunk.AREA) hubOk = false;
        }
        check("hubOf: packed (y << 5) | x in the middle third", hubOk);

        // ---- (2) edge profiles: symmetric, at least one opening, 1,000 random pairs ----
        var pa = new haxe.ds.Vector<Int>(32);
        var pb = new haxe.ds.Vector<Int>(32);
        var symOk = true;
        var oneOk = true;
        var binOk = true;
        var cornerOk = true;
        for (t in 0...1000) {
            var seed = rng.nextInt();
            var ax = rng.range(-2000, 2000);
            var ay = rng.range(-2000, 2000);
            var bx = ax, by = ay;
            switch (rng.range(0, 4)) {
                case 0: bx = ax + 1;
                case 1: bx = ax - 1;
                case 2: by = ay + 1;
                default: by = ay - 1;
            }
            ChunkGen.edgeProfile(seed, ax, ay, bx, by, pa);
            ChunkGen.edgeProfile(seed, bx, by, ax, ay, pb);
            var any = false;
            for (i in 0...32) {
                if (pa[i] != pb[i]) symOk = false;
                if (pa[i] != 0 && pa[i] != 1) binOk = false;
                if (pa[i] == 1) any = true;
            }
            if (!any) oneOk = false;
            if (pa[0] != 0 || pa[31] != 0) cornerOk = false;
        }
        check("edgeProfile: (a,b) == (b,a) over 1,000 random pairs", symOk);
        check("edgeProfile: every profile has at least one opening", oneOk);
        check("edgeProfile: entries are 0/1", binOk);
        check("edgeProfile: corner entries 0 and 31 are wall", cornerOk);

        // ---- openness / zoneAt are pure and in range ----
        var oOk = true;
        for (t in 0...200) {
            var seed = rng.nextInt();
            var fx = (rng.nextFloat() - 0.5) * 400.0;
            var fy = (rng.nextFloat() - 0.5) * 400.0;
            var o1 = ChunkGen.openness(seed, fx, fy);
            var o2 = ChunkGen.openness(seed, fx, fy);
            if (o1 != o2 || o1 < 0.0 || o1 >= 1.0) oOk = false;
            var z = ChunkGen.zoneAt(seed, Std.int(fx), Std.int(fy));
            if (z != ChunkGen.zoneAt(seed, Std.int(fx), Std.int(fy)) || z < 0 || z > 3) oOk = false;
        }
        check("openness in [0, 1) and zoneAt in 0..3, both pure", oOk);

        // ---- (3) + (4): 2,000 chunks: hub flood reaches every walkable cell; no 1x1 pocket; pits ringed; ops bounded ----
        var floodBad = 0;
        var pocketBad = 0;
        var pitBad = 0;
        var pitSeen = 0;
        var pitMsg = "";
        var opsMax = 0;
        var borderBad = 0;
        var darkBad = 0;
        var variantBad = 0;
        var hubBad = 0;
        var pillarBad = 0;
        var zoneCount = [0, 0, 0, 0];
        var zoneNear = [0, 0, 0, 0];
        var nearTotal = 0;
        for (t in 0...2000) {
            var seed = t < 1000 ? 1000 + (t >> 4) : rng.nextInt();
            var cx = t < 1000 ? ((t & 15) % 4) - 1 : rng.range(-200, 200);
            var cy = t < 1000 ? ((t & 15) >> 2) - 1 : rng.range(-200, 200);
            ChunkGen.opsCounter = 0;
            ChunkGen.generate(seed, cx, cy, a);
            if (ChunkGen.opsCounter > opsMax) opsMax = ChunkGen.opsCounter;
            var hub = ChunkGen.hubOf(seed, cx, cy);
            if (!Cells.walkable(a.cells[hub])) hubBad++;
            var reached = ChunkGen.floodCount(a, hub & 31, hub >> 5);
            if (reached != walkableCount(a)) floodBad++;
            if (pocketCount(a) != 0) pocketBad++;
            var pm = pitCheck(a);
            if (pm != "") { pitBad++; pitMsg = pm; }
            for (i in 0...Chunk.AREA) if (Cells.type(a.cells[i]) == Cells.PIT) pitSeen++;
            // pillars sit at least 2 cells from every door (open border cell)
            for (y in 1...31) {
                for (x in 1...31) {
                    if (Cells.type(a.get(x, y)) != Cells.PILLAR) continue;
                    for (dy in -2...3) {
                        for (dx in -2...3) {
                            var nx = x + dx, ny = y + dy;
                            if (nx < 0 || ny < 0 || nx > 31 || ny > 31) continue;
                            if ((nx == 0 || ny == 0 || nx == 31 || ny == 31) && Cells.walkable(a.get(nx, ny))) pillarBad++;
                        }
                    }
                }
            }
            // border cells are WALL or the chunk's floor type, never PILLAR / WET / PIT
            for (i in 0...32) {
                var t0 = Cells.type(a.get(i, 0)), t1 = Cells.type(a.get(i, 31)), t2 = Cells.type(a.get(0, i)), t3 = Cells.type(a.get(31, i));
                if (t0 == Cells.PILLAR || t0 == Cells.WET || t0 == Cells.PIT) borderBad++;
                if (t1 == Cells.PILLAR || t1 == Cells.WET || t1 == Cells.PIT) borderBad++;
                if (t2 == Cells.PILLAR || t2 == Cells.WET || t2 == Cells.PIT) borderBad++;
                if (t3 == Cells.PILLAR || t3 == Cells.WET || t3 == Cells.PIT) borderBad++;
            }
            // DARK chunks: every walkable cell is DARK, no light bit, walls variant 7; others: no DARK cells, wall variant 0..3, floor variant 0/1
            for (i in 0...Chunk.AREA) {
                var v = a.cells[i];
                var ty = Cells.type(v);
                if (a.zone == ChunkGen.Z_DARK) {
                    if (Cells.walkable(v) && ty != Cells.DARK) darkBad++;
                    if (Cells.hasLight(v)) darkBad++;
                    if (Cells.solid(v) && Cells.variant(v) != 7) darkBad++;
                } else {
                    if (ty == Cells.DARK) darkBad++;
                    if (Cells.solid(v) && Cells.variant(v) > 3) variantBad++;
                    if (Cells.walkable(v) && Cells.variant(v) > 1) variantBad++;
                }
            }
            zoneCount[a.zone]++;
            if (cx >= -1 && cx <= 2 && cy >= -1 && cy <= 2) { zoneNear[a.zone]++; nearTotal++; }
        }
        check("2,000 chunks: floodCount from the hub == walkable cells (bad " + floodBad + ")", floodBad == 0);
        check("2,000 chunks: the hub is walkable (bad " + hubBad + ")", hubBad == 0);
        check("2,000 chunks: no 1x1 floor pocket (bad " + pocketBad + ")", pocketBad == 0);
        check("2,000 chunks: no pillar within 2 cells of a door (bad " + pillarBad + ")", pillarBad == 0);
        check("2,000 chunks: pits only in HALL/ROOMS, ringed by 8 walkable rim cells (bad " + pitBad + " " + pitMsg + ", pits " + pitSeen + ")", pitBad == 0);
        check("2,000 chunks: opsCounter < 200,000 per chunk (max " + opsMax + ")", opsMax < 200000);
        check("2,000 chunks: border cells are only wall or floor (bad " + borderBad + ")", borderBad == 0);
        check("2,000 chunks: DARK chunks are dark floor / unlit / variant-7 walls; others never DARK (bad " + darkBad + ")", darkBad == 0);
        check("2,000 chunks: wall variants 0..3, floor variants 0..1 outside DARK (bad " + variantBad + ")", variantBad == 0);
        check("zones: all four occur over 2,000 chunks (" + zoneCount.join("/") + ")",
            zoneCount[0] > 0 && zoneCount[1] > 0 && zoneCount[2] > 0 && zoneCount[3] > 0);
        var hallShare = zoneNear[0] / nearTotal;
        var warrenShare = zoneNear[1] / nearTotal;
        var roomsShare = zoneNear[2] / nearTotal;
        var darkShare = zoneNear[3] / nearTotal;
        check("zone shares near the origin within tolerance of 55/25/12/8 (" + Std.int(hallShare * 100) + "/" + Std.int(warrenShare * 100) + "/"
            + Std.int(roomsShare * 100) + "/" + Std.int(darkShare * 100) + " over " + nearTotal + ")",
            hallShare > 0.45 && hallShare < 0.65 && warrenShare > 0.16 && warrenShare < 0.36 && roomsShare > 0.05 && roomsShare < 0.20 && darkShare > 0.02 && darkShare < 0.16);

        // ---- neighbours agree on the shared edge: 300 pairs, both orientations ----
        var seamBad = 0;
        for (t in 0...300) {
            var seed = rng.nextInt();
            var cx = rng.range(-100, 100);
            var cy = rng.range(-100, 100);
            ChunkGen.generate(seed, cx, cy, a);
            ChunkGen.generate(seed, cx + 1, cy, b);
            if (!seamAgrees(a, b, true)) seamBad++;
            ChunkGen.generate(seed, cx, cy + 1, b);
            if (!seamAgrees(a, b, false)) seamBad++;
        }
        check("neighbours agree on the shared edge (300 pairs x 2 sides, bad " + seamBad + ")", seamBad == 0);

        // ---- 3x3 chunk region is fully connected through the doors (the world-level flood) ----
        var regionBad = 0;
        for (t in 0...6) {
            var seed = 5000 + t;
            var w = new World(seed);
            for (cy in -1...2) for (cx in -1...2) w.generateNow(cx, cy);
            var hub = ChunkGen.hubOf(seed, 0, 0);
            var reached = worldFlood(w, hub & 31, hub >> 5, -32, -32, 96, 96);
            var walk = 0;
            for (y in -32...64) for (x in -32...64) if (Cells.walkable(w.cell(x, y))) walk++;
            if (reached != walk) regionBad++;
        }
        check("3x3 chunk region: flood from the centre hub reaches every walkable cell (bad " + regionBad + ")", regionBad == 0);

        // ---- repairConnectivity on a hand-built chunk: two sealed rooms, hub in one ----
        a.fill(Cells.WALL);
        for (y in 10...15) for (x in 10...15) a.set(x, y, Cells.FLOOR);
        for (y in 20...25) for (x in 20...25) a.set(x, y, Cells.FLOOR);
        a.set(3, 3, Cells.FLOOR);                       // a 1x1 pocket: unreachable, repair may tunnel to it or wall it
        var carved = ChunkGen.repairConnectivity(a, 12, 12);
        var wc = walkableCount(a);
        check("repairConnectivity: carved > 0 and every walkable cell reaches the hub (carved " + carved + ")",
            carved > 0 && ChunkGen.floodCount(a, 12, 12) == wc && wc >= 50);
        check("repairConnectivity: never touches the border ring", (function() {
            for (i in 0...32) if (a.get(i, 0) != Cells.WALL || a.get(i, 31) != Cells.WALL || a.get(0, i) != Cells.WALL || a.get(31, i) != Cells.WALL) return false;
            return true;
        })());
        // an isolated single cell beyond the region cap gets walled
        a.fill(Cells.WALL);
        a.set(16, 16, Cells.FLOOR);
        for (y in 0...20) a.set(2 + (y & 1) * 27, 2 + y, Cells.FLOOR);   // 20 scattered single cells (> 16 regions)
        ChunkGen.repairConnectivity(a, 16, 16);
        check("repairConnectivity: beyond 16 regions the rest becomes WALL, still fully connected",
            ChunkGen.floodCount(a, 16, 16) == walkableCount(a) && walkableCount(a) < Chunk.AREA);

        // floodCount on a sealed start returns 0
        a.fill(Cells.WALL);
        check("floodCount from a solid cell is 0", ChunkGen.floodCount(a, 4, 4) == 0);
        return fails;
    }

    // BFS over world cells inside the rectangle [x0, x0+w) x [y0, y0+h), from world cell (sx, sy)
    static function worldFlood(w:World, sx:Int, sy:Int, x0:Int, y0:Int, wd:Int, ht:Int):Int {
        var n = wd * ht;
        var seen = new haxe.ds.Vector<Bool>(n);
        for (i in 0...n) seen[i] = false;
        var q = new haxe.ds.Vector<Int>(n);
        var head = 0, tail = 0;
        var si = (sy - y0) * wd + (sx - x0);
        if (!Cells.walkable(w.cell(sx, sy))) return 0;
        seen[si] = true;
        q[tail++] = si;
        var count = 0;
        while (head < tail) {
            var i = q[head++];
            count++;
            var lx = i % wd, ly = Std.int(i / wd);
            var x = x0 + lx, y = y0 + ly;
            if (ly > 0 && !seen[i - wd] && Cells.walkable(w.cell(x, y - 1))) { seen[i - wd] = true; q[tail++] = i - wd; }
            if (ly < ht - 1 && !seen[i + wd] && Cells.walkable(w.cell(x, y + 1))) { seen[i + wd] = true; q[tail++] = i + wd; }
            if (lx > 0 && !seen[i - 1] && Cells.walkable(w.cell(x - 1, y))) { seen[i - 1] = true; q[tail++] = i - 1; }
            if (lx < wd - 1 && !seen[i + 1] && Cells.walkable(w.cell(x + 1, y))) { seen[i + 1] = true; q[tail++] = i + 1; }
        }
        return count;
    }
}
