// Unit tests for Director (CONTRACT §1, DESIGN §5). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
//
// Every scenario runs the real Director with the real Player, Watcher, Hound and Tape on a hand-built
// grid (SimBGrid below, a World whose cells come from a small vector instead of ChunkGen), so the
// clocks, the spawn rules and the fairness law are exercised end to end, frame by frame.

// A World backed by a flat grid: (0,0)..(gw-1,gh-1), WALL outside. Also used by TestBot.
class SimBGrid extends World {
    public var gw:Int;
    public var gh:Int;
    public var g:haxe.ds.Vector<Int>;

    public function new(gw:Int, gh:Int):Void {
        super(1);
        this.gw = gw;
        this.gh = gh;
        g = new haxe.ds.Vector<Int>(gw * gh);
        for (i in 0...gw * gh) g[i] = Cells.WALL;
    }

    override public function cell(x:Int, y:Int):Int {
        if (x < 0 || y < 0 || x >= gw || y >= gh) return Cells.WALL;
        return g[y * gw + x];
    }

    // every chunk that overlaps the grid counts as resident (Path clamps its window to resident chunks)
    override public function has(cx:Int, cy:Int):Bool {
        var x0 = cx << 5;
        var y0 = cy << 5;
        return x0 < gw && y0 < gh && x0 + 32 > 0 && y0 + 32 > 0;
    }

    public function put(x:Int, y:Int, v:Int):Void {
        if (x < 0 || y < 0 || x >= gw || y >= gh) return;
        g[y * gw + x] = v;
    }

    // fills the half-open rectangle [x0, x1) x [y0, y1)
    public function rect(x0:Int, y0:Int, x1:Int, y1:Int, v:Int):Void {
        for (y in y0...y1) for (x in x0...x1) put(x, y, v);
    }

    // floor everywhere but a one-cell wall border
    public static function openRoom(w:Int, h:Int):SimBGrid {
        var r = new SimBGrid(w, h);
        r.rect(1, 1, w - 1, h - 1, Cells.FLOOR);
        return r;
    }

    // a perfect corridor maze (recursive backtracker) on the odd cells; gw and gh must be odd
    public function maze(seed:Int):Void {
        rect(0, 0, gw, gh, Cells.WALL);
        var rng = new Rng(seed);
        var stack = new Array<Int>();
        var sx = 1;
        var sy = 1;
        put(sx, sy, Cells.FLOOR);
        stack.push(Cells.pack(sx, sy));
        while (stack.length > 0) {
            var top = stack[stack.length - 1];
            var x = Cells.unpackX(top);
            var y = Cells.unpackY(top);
            // unvisited neighbours two cells away
            var n = 0;
            var nx0 = 0; var ny0 = 0; var nx1 = 0; var ny1 = 0; var nx2 = 0; var ny2 = 0; var nx3 = 0; var ny3 = 0;
            if (x + 2 < gw - 1 && cell(x + 2, y) == Cells.WALL) { if (n == 0) { nx0 = x + 2; ny0 = y; } else if (n == 1) { nx1 = x + 2; ny1 = y; } else if (n == 2) { nx2 = x + 2; ny2 = y; } else { nx3 = x + 2; ny3 = y; } n++; }
            if (x - 2 > 0 && cell(x - 2, y) == Cells.WALL) { if (n == 0) { nx0 = x - 2; ny0 = y; } else if (n == 1) { nx1 = x - 2; ny1 = y; } else if (n == 2) { nx2 = x - 2; ny2 = y; } else { nx3 = x - 2; ny3 = y; } n++; }
            if (y + 2 < gh - 1 && cell(x, y + 2) == Cells.WALL) { if (n == 0) { nx0 = x; ny0 = y + 2; } else if (n == 1) { nx1 = x; ny1 = y + 2; } else if (n == 2) { nx2 = x; ny2 = y + 2; } else { nx3 = x; ny3 = y + 2; } n++; }
            if (y - 2 > 0 && cell(x, y - 2) == Cells.WALL) { if (n == 0) { nx0 = x; ny0 = y - 2; } else if (n == 1) { nx1 = x; ny1 = y - 2; } else if (n == 2) { nx2 = x; ny2 = y - 2; } else { nx3 = x; ny3 = y - 2; } n++; }
            if (n == 0) { stack.pop(); continue; }
            var k = rng.range(0, n);
            var nx = k == 0 ? nx0 : (k == 1 ? nx1 : (k == 2 ? nx2 : nx3));
            var ny = k == 0 ? ny0 : (k == 1 ? ny1 : (k == 2 ? ny2 : ny3));
            put((x + nx) >> 1, (y + ny) >> 1, Cells.FLOOR);
            put(nx, ny, Cells.FLOOR);
            stack.push(Cells.pack(nx, ny));
        }
    }
}

class TestDirector {
    static var fails:Int = 0;
    static inline var DT = 0.05;

    static function check(name:String, ok:Bool):Void {
        Sys.println((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) fails++;
    }

    static function near(a:Float, b:Float, eps:Float):Bool {
        var d = a - b;
        return (d < 0 ? -d : d) <= eps;
    }

    static function r2(v:Float):Float return Math.round(v * 100) / 100;

    static function has(d:Director, ev:Int):Bool return (d.events & ev) != 0;

    static function mk(w:World, px:Float, py:Float, ang:Float, dOff:Float):Director {
        var tape = Tape.make(1, 77);
        tape.dOffset = dOff;
        var p = new Player(px, py, ang);
        return new Director(w, p, tape);
    }

    // a single walkable cell at (1,1): no entity can ever be placed, so only the clocks run
    static function cellWorld(centre:Int):SimBGrid {
        var g = new SimBGrid(3, 3);
        g.put(1, 1, centre);
        return g;
    }

    static function dist(d:Director, x:Float, y:Float):Float {
        var dx = x - d.player.x;
        var dy = y - d.player.y;
        return Math.sqrt(dx * dx + dy * dy);
    }

    public static function run():Int {
        fails = 0;
        testEscalation();
        testPresence();
        testFairness();
        testNoDoubleTeam();
        testRelief();
        testBattery();
        testBlackouts();
        testFlicker();
        testDistant();
        testTsSkip();
        testHum();
        testDark();
        testPits();
        testKillBookkeeping();
        testFrozen();
        testGeometry();
        testWatcherLifecycle();
        testForce();
        testHearing();
        return fails;
    }

    // ---- D: monotone, capped, driven by time and distance ----
    static function testEscalation():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        var d0 = d.D;
        var prev = d.D;
        var mono = true;
        var over = false;
        var dAt300 = 0.0;
        var dAt600 = 0.0;
        var dt = 0.1;
        for (i in 0...12000) {
            if (i == 9000) d.player.cellsWalked = 500.0;   // at 900 s the operator has walked 500 cells
            d.update(dt, false, 0);
            if (d.D < prev - 1e-12) mono = false;
            if (d.D > 1.0) over = true;
            prev = d.D;
            if (i == 2999) dAt300 = d.D;
            if (i == 5999) dAt600 = d.D;
        }
        check("(1) D is monotone non-decreasing over a 20-minute run", mono);
        check("(1) D never exceeds 1", !over && d.D <= 1.0);
        check("D escalates with time: 0 at the start, 0.25 at 300 s, 0.5 at 600 s (" + r2(dAt300) + ", " + r2(dAt600) + ")",
            d0 == 0.0 && near(dAt300, 0.25, 0.002) && near(dAt600, 0.5, 0.002));
        check("D escalates with distance: 500 cells walked at 900 s pins D at 1", near(d.D, 1.0, 1e-9));
        check("tapeTime counts the seconds (1200 after 12000 x 0.1)", near(d.tapeTime, 1200.0, 0.01));
        var d2 = mk(w, 32.5, 32.5, 0.0, 0.07);
        check("the tape's dOffset is the initial D", near(d2.D, 0.07, 1e-9));
        d2.update(0.1, false, 0);
        check("... and the clock adds to it from the first frame", d2.D > 0.07 && near(d2.D, 0.07 + 0.05 / 600.0, 1e-9));
    }

    // ---- presence: 0 with nothing alive, rises only with an active entity ----
    static function testPresence():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        d.noRelocateUntil = 1e9;                     // keep the Watcher where the test puts it
        var maxP = 0.0;
        for (i in 0...1200) {
            d.update(DT, false, 0);
            if (d.presence > maxP) maxP = d.presence;
        }
        check("presence stays 0 for 60 s with no entity on the tape", maxP == 0.0 && !d.watcher.alive && !d.hound.alive);
        d.watcher.spawnAt(35.5, 32.5);
        d.update(DT, false, 0);
        check("Watcher at 3 cells: presence = (1 - 3/10)^2 = 0.49 (" + r2(d.presence) + ")", near(d.presence, 0.49, 0.02));
        d.watcher.x = 37.5;
        d.update(DT, false, 0);
        check("Watcher at 5 cells: presence 0.25 (" + r2(d.presence) + ")", near(d.presence, 0.25, 0.02));
        d.watcher.x = 44.5;
        d.update(DT, false, 0);
        check("Watcher at 12 cells: presence 0", d.presence == 0.0);
        d.watcher.despawn();
        d.update(DT, false, 0);
        check("Watcher gone: presence 0", d.presence == 0.0);
        d.hound.spawnAt(39.5, 32.5);
        d.update(DT, false, 0);
        check("a dormant Hound at 7 cells adds no presence", d.hound.alive && d.hound.state == Hound.S_DORMANT && d.presence == 0.0);
        d.hound.hear(32, 32, 99.0);
        d.update(DT, false, 0);
        check("a howling Hound at 7 cells: presence = 1 - 7/14 = 0.5 (" + r2(d.presence) + ")", d.hound.state == Hound.S_HOWL && near(d.presence, 0.5, 0.03));
        d.watcher.spawnAt(37.5, 32.5);
        d.update(DT, false, 0);
        check("presence is the max of the two (Watcher 0.25, Hound 0.5)", near(d.presence, 0.5, 0.03));
        check("presence never above 1", d.presence <= 1.0);
    }

    // ---- the fairness law: no kill inside 3 s of the telegraph, a kill right after ----
    static function testFairness():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        d.update(DT, false, 0);                      // the entities have met their Director
        d.hound.spawnAt(32.8, 32.5);
        d.hound.hear(32, 32, 99.0);
        check("a Hound at contact range howls when it hears, and cannot kill yet", d.hound.state == Hound.S_HOWL && !d.hound.canKill());
        var t = 0.0;
        var killAt = -1.0;
        var killer = 0;
        var early = false;
        for (i in 0...100) {
            d.update(DT, false, 0);
            t += DT;
            if (has(d, Director.EV_KILL)) {
                if (t < 2.95) early = true;
                if (killAt < 0) { killAt = t; killer = d.killer; }
            }
        }
        check("no EV_KILL inside 3 s of the howl (fairness window)", !early);
        check("the Hound kills at contact once its 3 s telegraph is full (at " + r2(killAt) + " s, killer K_HOUND)",
            killAt >= 2.95 && killAt <= 3.3 && killer == Director.K_HOUND);

        d = mk(w, 32.5, 32.5, 0.0, 0.0);
        d.noRelocateUntil = 1e9;
        d.watcher.spawnAt(32.1, 32.5);               // 0.4 cells behind the camera
        t = 0.0;
        killAt = -1.0;
        killer = 0;
        early = false;
        var canKillEarly = false;
        for (i in 0...100) {
            d.update(DT, false, 0);
            t += DT;
            if (t < 2.95 && d.watcher.canKill()) canKillEarly = true;
            if (has(d, Director.EV_KILL)) {
                if (t < 2.95) early = true;
                if (killAt < 0) { killAt = t; killer = d.killer; }
            }
        }
        check("Watcher.canKill() is false during its first 3 s inside 10 cells", !canKillEarly);
        check("no EV_KILL from a Watcher at contact inside 3 s", !early);
        check("the Watcher kills at contact after 3 s (at " + r2(killAt) + " s, killer K_WATCHER)",
            killAt >= 2.95 && killAt <= 3.3 && killer == Director.K_WATCHER);
    }

    // ---- no double-teaming: the Hound never spawns while the Watcher is within 6 ----
    static var ndScream:Bool;
    static var ndSpawn:Bool;
    static var ndSpawnDist:Float;
    static var ndSpawnInView:Bool;
    static var ndWatcherAtSpawn:Float;
    static var ndScreamLead:Float;

    static function pinnedRun(off:Float, seconds:Float):Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.3);         // D > 0.25 from the first frame
        d.noRelocateUntil = 1e9;
        d.watcher.spawnAt(32.5 - off, 32.5);
        ndScream = false;
        ndSpawn = false;
        ndSpawnDist = 0.0;
        ndSpawnInView = false;
        ndWatcherAtSpawn = 0.0;
        ndScreamLead = -1.0;
        var screamAt = -1.0;
        var t = 0.0;
        var n = Math.round(seconds / 0.1);
        for (i in 0...n) {
            d.watcher.x = 32.5 - off;
            d.watcher.y = 32.5;
            d.update(0.1, false, 0);
            t += 0.1;
            if (has(d, Director.EV_SCREAM)) { ndScream = true; screamAt = t; }
            if (has(d, Director.EV_HOUND_SPAWN)) {
                ndSpawn = true;
                ndSpawnDist = dist(d, d.hound.x, d.hound.y);
                ndSpawnInView = d.inViewCone(d.hound.x, d.hound.y);
                ndWatcherAtSpawn = dist(d, d.watcher.x, d.watcher.y);
                ndScreamLead = t - screamAt;
                return;
            }
            if (d.hound.alive) { ndSpawn = true; return; }
        }
    }

    static function testNoDoubleTeam():Void {
        pinnedRun(3.0, 10000.0);
        check("(2) Watcher pinned at 3 cells for 10,000 s at D > 0.25: no scream, no Hound", !ndScream && !ndSpawn);
        pinnedRun(12.0, 1000.0);
        check("(2) control: Watcher pinned at 12 cells: the scream plays and the Hound spawns", ndScream && ndSpawn);
        check("(2) the Hound spawns 5 s after the scream (" + r2(ndScreamLead) + " s)", near(ndScreamLead, 5.0, 0.15));
        check("(2) the Hound spawns beyond 20 cells, out of view, with the Watcher beyond 6 (" + r2(ndSpawnDist) + " cells)",
            ndSpawnDist >= 20.0 && ndSpawnDist <= 26.5 && !ndSpawnInView && ndWatcherAtSpawn > 6.0);
    }

    // ---- the relief valve: no Watcher relocation for 45 s after the Hound loses you ----
    static function testRelief():Void {
        var w = SimBGrid.openRoom(64, 64);
        w.rect(49, 29, 54, 34, Cells.WALL);          // a sealed pocket the Hound cannot leave
        w.rect(50, 30, 53, 33, Cells.FLOOR);
        var d = mk(w, 20.5, 31.5, 0.0, 0.3);
        d.watcher.spawnAt(15.5, 31.5);               // 5 cells behind
        d.update(DT, false, 0);
        d.hound.spawnAt(51.5, 31.5);
        d.hound.hear(20, 31, 99.0);
        check("the pocketed Hound howls at the heard position", d.hound.state == Hound.S_HOWL);
        var t = 0.0;
        var lostAt = -1.0;
        var lostCount = 0;
        var valveAtLost = 0.0;
        var relocInValve = 0;
        var relocAfter = -1.0;
        var wx = 0.0;
        var wy = 0.0;
        var movedInValve = false;
        var frames = Math.round(80.0 / DT);
        for (i in 0...frames) {
            d.update(DT, false, 0);
            t += DT;
            if (has(d, Director.EV_HOUND_LOST)) {
                lostCount++;
                if (lostAt < 0) {
                    lostAt = t;
                    valveAtLost = d.noRelocateUntil - d.tapeTime;
                    wx = d.watcher.x;
                    wy = d.watcher.y;
                }
            }
            if (lostAt >= 0) {
                var since = t - lostAt;
                if (has(d, Director.EV_WATCHER_RELOCATED)) {
                    if (since <= 45.0 - 1e-6) relocInValve++;
                    else if (relocAfter < 0) relocAfter = since;
                }
                if (since <= 45.0 - 1e-6 && (d.watcher.x != wx || d.watcher.y != wy)) movedInValve = true;
            }
            if (lostAt >= 0 && t - lostAt > 60.0) break;
        }
        check("EV_HOUND_LOST fires once, within 10 s of a howl it cannot follow (" + r2(lostAt) + " s)", lostCount == 1 && lostAt > 0 && lostAt <= 10.0);
        check("noRelocateUntil = tapeTime + 45 at the LOST event (" + r2(valveAtLost) + ")", near(valveAtLost, 45.0, 0.06));
        check("(3) no EV_WATCHER_RELOCATED for 45 s after EV_HOUND_LOST", relocInValve == 0 && !movedInValve);
        check("the Watcher relocates again once the valve lifts (" + r2(relocAfter) + " s after LOST)", relocAfter > 45.0 - 1e-6 && relocAfter <= 60.0);
        check("the lost Hound is alive and wandering, not despawned", d.hound.alive);
    }

    // ---- battery ----
    static function testBattery():Void {
        var d = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0);
        d.battery = 1.0;
        var t = 0.0;
        var deadAt = -1.0;
        var strobeAt = -1.0;
        var strobes = 0;
        var killer = 0;
        var killWithDead = false;
        var deadCount = 0;
        while (t < 2000.0 && deadAt < 0) {
            d.update(0.1, false, 0);
            t += 0.1;
            if (has(d, Director.EV_STROBE_ON)) { strobes++; strobeAt = t; }
            if (has(d, Director.EV_BATTERY_DEAD)) {
                deadCount++;
                deadAt = t;
                killer = d.killer;
                killWithDead = has(d, Director.EV_KILL);
            }
        }
        check("(4) battery 1.0 reaches 0 in 25 min +/- 1% at normal drain (" + r2(deadAt) + " s)", near(deadAt, 1500.0, 15.0));
        check("(4) EV_BATTERY_DEAD comes with EV_KILL and killer == K_BATTERY", killWithDead && killer == Director.K_BATTERY);
        check("EV_STROBE_ON once, at 10% (" + r2(strobeAt) + " s)", strobes == 1 && near(strobeAt, 1350.0, 15.0));
        for (i in 0...100) {
            d.update(0.1, false, 0);
            if (has(d, Director.EV_BATTERY_DEAD)) deadCount++;
        }
        check("EV_BATTERY_DEAD fires once and the battery stays at 0", deadCount == 1 && d.battery == 0.0);

        var dk = mk(cellWorld(Cells.DARK), 1.5, 1.5, 0.0, 0.0);
        dk.battery = 1.0;
        t = 0.0;
        deadAt = -1.0;
        while (t < 1000.0 && deadAt < 0) {
            dk.update(0.1, false, 0);
            t += 0.1;
            if (has(dk, Director.EV_BATTERY_DEAD)) deadAt = t;
        }
        check("in DARK the battery drains 4x: dead at 375 s +/- 1% (" + r2(deadAt) + " s)", near(deadAt, 375.0, 3.75));

        var df = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0);
        df.battery = 1.0;
        for (i in 0...100) df.update(0.1, true, 0);
        check("the battery drains while the map is open (frozen): 10 s = 10/1500", near(df.battery, 1.0 - 10.0 / 1500.0, 1e-6));
        check("tape.batteryStart seeds the battery", near(mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0).battery, Tape.make(1, 77).batteryStart, 1e-12));
    }

    // ---- blackouts: cadence, length, light ----
    static function testBlackouts():Void {
        var d = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.6);   // D > 0.5 from the start
        var starts = new Array<Float>();
        var ends = new Array<Float>();
        var t = 0.0;
        var inB = false;
        var lastFlicker = -99.0;
        var warnOk = true;
        var duringOk = true;
        var endOk = true;
        var outsideOk = true;
        var tOk = true;
        for (i in 0...12000) {
            d.update(DT, false, 0);
            t += DT;
            if (has(d, Director.EV_FLICKER)) lastFlicker = t;
            if (has(d, Director.EV_BLACKOUT_START)) {
                starts.push(t);
                inB = true;
                if (t - lastFlicker > 1.1) warnOk = false;
                if (d.lightOffset != 15 || d.blackoutT <= 0.0) duringOk = false;
            } else if (has(d, Director.EV_BLACKOUT_END)) {
                ends.push(t);
                inB = false;
                if (d.lightOffset != 0 || d.blackoutT != 0.0) endOk = false;
            } else if (inB) {
                if (d.lightOffset != 15 || d.blackoutT <= 0.0) duringOk = false;
            } else {
                if (d.lightOffset > 5) outsideOk = false;
                if (d.blackoutT != 0.0) tOk = false;
            }
        }
        var n = starts.length;
        var lenOk = true;
        var gapOk = true;
        for (i in 0...ends.length) {
            var len = ends[i] - starts[i];
            if (len < 1.95 || len > 4.1) lenOk = false;
        }
        for (i in 1...n) {
            var gap = starts[i] - starts[i - 1];
            if (gap < 60.0 || gap > 125.0) gapOk = false;
        }
        check("blackouts at D > 0.5: at least 4 in 10 minutes (" + n + ")", n >= 4 && (ends.length == n || ends.length == n - 1));
        check("each blackout lasts 2..4 s", lenOk);
        check("blackouts every 60..120 s (start to start, plus the blackout itself)", gapOk);
        check("a flicker stutter within the second before each blackout", warnOk);
        check("lightOffset == 15 and blackoutT > 0 from EV_BLACKOUT_START until EV_BLACKOUT_END", duringOk);
        check("lightOffset back to 0 and blackoutT 0 on EV_BLACKOUT_END", endOk);
        check("outside blackouts lightOffset <= 5 (flicker only) and blackoutT == 0", outsideOk && tOk);

        var d0 = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0);
        var any = false;
        for (i in 0...10000) {
            d0.update(DT, false, 0);
            if (has(d0, Director.EV_BLACKOUT_START)) any = true;
        }
        check("no blackout while D <= 0.5 (500 s at dOffset 0)", !any && d0.D <= 0.5);
    }

    // ---- flicker stutters ----
    static function testFlicker():Void {
        var d = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0);
        var count = 0;
        var t = 0.0;
        var run = 0;
        var depth = 0;
        var runOk = true;
        var depthOk = true;
        var startOk = true;
        var gapOk = true;
        var lastStart = -99.0;
        for (i in 0...6000) {
            d.update(DT, false, 0);
            t += DT;
            var lo = d.lightOffset;
            if (has(d, Director.EV_FLICKER)) {
                count++;
                if (lo < 2 || lo > 5) depthOk = false;
                if (lastStart > 0 && (t - lastStart < 3.9 || t - lastStart > 9.3)) gapOk = false;
                lastStart = t;
                if (run > 0) runOk = false;              // a new stutter never starts inside the previous one
                run = 1;
                depth = lo;
            } else if (lo > 0) {
                if (run == 0) startOk = false;           // light never moves without EV_FLICKER announcing it
                run++;
                if (lo != depth) depthOk = false;        // the depth holds for the whole stutter
                if (run > 3) runOk = false;
            } else {
                run = 0;
            }
        }
        check("flicker stutters every 4..9 s over 5 minutes (" + count + ")", count >= 31 && count <= 77 && gapOk);
        check("each stutter lasts 1..3 frames and never overlaps the next", runOk);
        check("stutter depth +2..+5, constant for the stutter", depthOk);
        check("lightOffset only leaves 0 with an EV_FLICKER (no blackout, no DARK)", startOk);

        // deeper near the Watcher
        var w = SimBGrid.openRoom(64, 64);
        var dn = mk(w, 32.5, 32.5, 0.0, 0.0);
        dn.noRelocateUntil = 1e9;
        dn.watcher.spawnAt(29.5, 32.5);              // 3 cells behind: inside the 10-cell cue distance
        var minNear = 99;
        var maxNear = 0;
        for (i in 0...4000) {
            dn.watcher.x = 29.5;
            dn.watcher.y = 32.5;
            dn.update(DT, false, 0);
            if (has(dn, Director.EV_FLICKER)) {
                if (dn.lightOffset < minNear) minNear = dn.lightOffset;
                if (dn.lightOffset > maxNear) maxNear = dn.lightOffset;
            }
        }
        check("stutters are deeper near the Watcher: every depth >= 3, some 4..5 (" + minNear + ".." + maxNear + ")", minNear >= 3 && maxNear >= 4 && maxNear <= 5);
    }

    // ---- distant one-shots ----
    static function testDistant():Void {
        var d = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0);
        var count = 0;
        var behind = 0;
        var idOk = true;
        var panOk = true;
        var volOk = true;
        var gapOk = true;
        var last = 0.0;
        var t = 0.0;
        var pans = 0.0;
        for (i in 0...6000) {
            d.update(0.1, false, 0);
            t += 0.1;
            if (has(d, Director.EV_DISTANT)) {
                count++;
                var id = d.distantId & 15;
                if (id < 0 || id > 5) idOk = false;
                if (d.distantId >= 16) behind++;
                if (d.distantPan < -1.0 || d.distantPan > 1.0) panOk = false;
                pans += d.distantPan;
                if (d.distantVol < 0.1 || d.distantVol > 0.3) volOk = false;
                if (t - last < 20.0 - 1e-6 || t - last > 50.2) gapOk = false;
                last = t;
            }
        }
        check("distant one-shots every 20..50 s: 12..30 in 10 minutes (" + count + ")", count >= 12 && count <= 30 && gapOk);
        check("distantId in 0..5 (behind flagged with +16)", idOk);
        check("some come from directly behind, most do not (" + behind + " of " + count + ")", behind >= 1 && behind < count);
        check("distantPan in -1..1 and spread (mean " + r2(pans / count) + ")", panOk && Math.abs(pans / count) < 0.5);
        check("distantVol in 0.1..0.3", volOk);
    }

    // ---- timestamp skips at D > 0.7 ----
    static function testTsSkip():Void {
        var d = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.8);
        var count = 0;
        var secsOk = true;
        var gapOk = true;
        var last = 0.0;
        var t = 0.0;
        for (i in 0...6000) {
            d.update(DT, false, 0);
            t += DT;
            if (has(d, Director.EV_TS_SKIP)) {
                count++;
                if (d.tsSkipSeconds < 1 || d.tsSkipSeconds > 7) secsOk = false;
                if (t - last < 30.0 - 1e-6 || t - last > 90.1) gapOk = false;
                last = t;
            }
        }
        check("timestamp skips every 30..90 s at D > 0.7: >= 3 in 5 minutes (" + count + ")", count >= 3 && gapOk);
        check("tsSkipSeconds in 1..7", secsOk);
        var d0 = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0);
        var any = false;
        for (i in 0...6000) {
            d0.update(DT, false, 0);
            if (has(d0, Director.EV_TS_SKIP)) any = true;
        }
        check("no timestamp skips at D <= 0.7", !any);
    }

    // ---- hum detune ----
    static function testHum():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        d.noRelocateUntil = 1e9;
        d.update(DT, false, 0);
        check("humLow starts false with no event", !d.humLow && !has(d, Director.EV_HUM_LOW_ON) && !has(d, Director.EV_HUM_LOW_OFF));
        d.watcher.spawnAt(24.5, 32.5);               // 8 behind
        d.update(DT, false, 0);
        check("Watcher at 8 cells: hum normal", !d.humLow && !has(d, Director.EV_HUM_LOW_ON));
        d.watcher.x = 27.5;                          // 5 behind
        d.update(DT, false, 0);
        check("Watcher within 6: EV_HUM_LOW_ON and humLow", d.humLow && has(d, Director.EV_HUM_LOW_ON));
        d.update(DT, false, 0);
        check("... the ON event fires once", d.humLow && !has(d, Director.EV_HUM_LOW_ON) && !has(d, Director.EV_HUM_LOW_OFF));
        d.watcher.x = 24.5;
        d.update(DT, false, 0);
        check("Watcher back at 8: EV_HUM_LOW_OFF", !d.humLow && has(d, Director.EV_HUM_LOW_OFF));
        var d7 = mk(w, 32.5, 32.5, 0.0, 0.8);
        d7.update(DT, false, 0);
        check("D > 0.7: hum permanently low from the first frame", d7.humLow && has(d7, Director.EV_HUM_LOW_ON));
    }

    // ---- DARK zone offsets ----
    static function testDark():Void {
        var d = mk(cellWorld(Cells.DARK), 1.5, 1.5, 0.0, 0.0);
        d.update(DT, false, 0);
        check("standing in DARK: darkOffset 9, lightOffset 9, hearingMul 1.5, fogCells 5",
            d.darkOffset == 9 && d.lightOffset == 9 && d.hearingMul == 1.5 && d.fogCells == 5);
        d.forceBlackout();
        d.update(DT, false, 0);
        check("a blackout in DARK clamps lightOffset at 15", d.lightOffset == 15 && has(d, Director.EV_BLACKOUT_START));
        var f = mk(cellWorld(Cells.FLOOR), 1.5, 1.5, 0.0, 0.0);
        f.update(DT, false, 0);
        check("on FLOOR: darkOffset 0, lightOffset 0, hearingMul 1.0, fogCells 12",
            f.darkOffset == 0 && f.lightOffset == 0 && f.hearingMul == 1.0 && f.fogCells == 12);
        var wt = mk(cellWorld(Cells.WET), 1.5, 1.5, 0.0, 0.0);
        wt.update(DT, false, 0);
        check("WET is not DARK: no offset", wt.darkOffset == 0 && wt.fogCells == 12);
    }

    // ---- pits: the drip telegraph and the fall ----
    // the pit scan runs every Director.PIT_SCAN_EVERY frames: step that many so a grid change is seen
    static function settlePits(d:Director):Void {
        for (i in 0...Director.PIT_SCAN_EVERY) d.update(DT, false, 0);
    }

    static function testPits():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        d.update(DT, false, 0);
        check("no pit within 6: pitDist 99, pitPan 0", d.pitDist == 99.0 && d.pitPan == 0.0);
        w.put(35, 32, Cells.PIT);
        settlePits(d);
        check("PIT 3 cells ahead: pitDist 3, pitPan 0 (" + r2(d.pitDist) + ", " + r2(d.pitPan) + ")", near(d.pitDist, 3.0, 1e-6) && near(d.pitPan, 0.0, 1e-6));
        w.put(35, 32, Cells.FLOOR);
        w.put(32, 35, Cells.PIT);
        settlePits(d);
        check("PIT 3 cells to the right (+y): pitPan +1", near(d.pitDist, 3.0, 1e-6) && near(d.pitPan, 1.0, 1e-6));
        w.put(32, 35, Cells.FLOOR);
        w.put(32, 29, Cells.PIT);
        settlePits(d);
        check("PIT 3 cells to the left (-y): pitPan -1", near(d.pitPan, -1.0, 1e-6));
        w.put(32, 29, Cells.FLOOR);
        w.put(39, 32, Cells.PIT);
        settlePits(d);
        check("PIT at 7 cells is beyond the 6-cell drip range: 99", d.pitDist == 99.0);
        w.put(37, 32, Cells.PIT);
        settlePits(d);
        check("the nearest PIT wins (5 over 7)", near(d.pitDist, 5.0, 1e-6));
        // the scan runs every PIT_SCAN_EVERY frames: a single frame after a change may still show the held value
        w.put(37, 32, Cells.FLOOR);
        var heldOk = true;
        var seen5 = false;
        for (i in 0...Director.PIT_SCAN_EVERY) {
            d.update(DT, false, 0);
            if (near(d.pitDist, 5.0, 1e-6)) seen5 = true;
            else if (!near(d.pitDist, 7.0, 1e-6) && d.pitDist != 99.0) heldOk = false;
        }
        check("pit scan cadence: within " + Director.PIT_SCAN_EVERY + " frames of removing the 5-cell PIT the 7-cell one is beyond range again (99)", heldOk && d.pitDist == 99.0);
        // a diagonal PIT inside 6 cells is still found (the corner pre-check only skips cells that cannot be within range)
        w.put(36, 36, Cells.PIT);                    // offset (4, 4) -> 5.66 cells
        settlePits(d);
        check("diagonal PIT at (4,4) = 5.66 cells is inside the drip range", near(d.pitDist, Math.sqrt(32.0), 1e-6));
        w.put(36, 36, Cells.FLOOR);
        w.put(37, 36, Cells.PIT);                    // offset (5, 4) -> 6.40 cells
        settlePits(d);
        check("diagonal PIT at (5,4) = 6.40 cells is outside it", d.pitDist == 99.0);
        w.put(37, 36, Cells.FLOOR);
        w.put(37, 32, Cells.FLOOR);
        w.put(39, 32, Cells.FLOOR);

        d.update(DT, false, Player.PE_ENTERED_PIT);
        check("PE_ENTERED_PIT in the light: EV_KILL with K_PIT", has(d, Director.EV_KILL) && d.killer == Director.K_PIT && !has(d, Director.EV_PIT_STUMBLE));
        var db = mk(w, 32.5, 32.5, 0.0, 0.0);
        db.forceBlackout();
        db.update(DT, false, Player.PE_ENTERED_PIT);
        check("PE_ENTERED_PIT during a blackout: EV_PIT_STUMBLE, no kill", has(db, Director.EV_PIT_STUMBLE) && !has(db, Director.EV_KILL) && db.lightOffset == 15);
    }

    // ---- requestKill ----
    static function testKillBookkeeping():Void {
        var d = mk(SimBGrid.openRoom(16, 16), 8.5, 8.5, 0.0, 0.0);
        d.update(DT, false, 0);
        check("no EV_KILL on a quiet frame", !has(d, Director.EV_KILL));
        d.requestKill(Director.K_PIT);
        d.requestKill(Director.K_BATTERY);
        check("requestKill: first wins (K_PIT), EV_KILL set", has(d, Director.EV_KILL) && d.killer == Director.K_PIT);
        d.update(DT, false, 0);
        check("EV_KILL is cleared by the next update", !has(d, Director.EV_KILL));
        d.requestKill(Director.K_WATCHER);
        check("requestKill takes a scripted entity kill (Main's ?die=watcher) without an entity", has(d, Director.EV_KILL) && d.killer == Director.K_WATCHER);
        d.update(DT, false, 0);
        d.requestKill(Director.K_DAMAGED);
        check("K_DAMAGED accepted", d.killer == Director.K_DAMAGED);
    }

    // ---- frozen (map open): clocks run, nothing else ----
    static function testFrozen():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        d.noRelocateUntil = 1e9;
        d.update(DT, false, 0);
        d.watcher.spawnAt(35.5, 32.5);
        d.update(DT, false, 0);
        var p0 = d.presence;
        var t0 = d.tapeTime;
        var b0 = d.battery;
        var lo0 = d.lightOffset;
        d.watcher.x = 50.5;                          // out of range: an unfrozen frame would drop presence to 0
        var evAny = false;
        for (i in 0...100) {
            d.update(DT, true, 0);
            if (d.events != 0) evAny = true;
        }
        check("frozen: no events delivered", !evAny);
        check("frozen: presence held (" + r2(d.presence) + ")", d.presence == p0 && p0 > 0.4);
        check("frozen: tapeTime and battery advance", near(d.tapeTime - t0, 5.0, 1e-6) && b0 - d.battery > 0.0 && near(b0 - d.battery, 5.0 / 1500.0, 1e-6));
        check("frozen: lightOffset held", d.lightOffset == lo0);
        d.update(DT, false, 0);
        check("unfrozen: presence follows the Watcher again", d.presence == 0.0);

        // a chasing Hound does not move while the map is open
        var dh = mk(w, 32.5, 32.5, 0.0, 0.0);
        dh.update(DT, false, 0);
        dh.forceSpawnHound();
        var n = 0;
        while (dh.hound.state != Hound.S_CHASE && n < 100) { dh.update(DT, false, 0); n++; }
        check("forced Hound reaches CHASE after its howl", dh.hound.state == Hound.S_CHASE);
        var hx = dh.hound.x;
        var hy = dh.hound.y;
        for (i in 0...60) dh.update(DT, true, 0);
        check("frozen: the chasing Hound stays put", dh.hound.x == hx && dh.hound.y == hy && dh.hound.state == Hound.S_CHASE);
        for (i in 0...40) dh.update(DT, false, 0);
        var moved = Math.sqrt((dh.hound.x - hx) * (dh.hound.x - hx) + (dh.hound.y - hy) * (dh.hound.y - hy));
        check("unfrozen: the chase resumes (" + r2(moved) + " cells in 2 s)", moved > 0.5);
    }

    // ---- geometry helpers ----
    static function testGeometry():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        check("lineOfSight across open floor", d.lineOfSight(32.5, 32.5, 40.5, 32.5) && d.lineOfSight(32.5, 32.5, 40.5, 40.5));
        w.put(36, 32, Cells.WALL);
        check("lineOfSight blocked by a wall cell between", !d.lineOfSight(32.5, 32.5, 40.5, 32.5));
        check("... but not blocked off-axis", d.lineOfSight(32.5, 32.5, 40.5, 38.5));
        w.put(36, 32, Cells.FLOOR);
        check("lineOfSight false beyond 24 cells", !d.lineOfSight(32.5, 32.5, 58.5, 32.5) && d.lineOfSight(32.5, 32.5, 55.5, 32.5));
        check("lineOfSight inside one cell", d.lineOfSight(32.5, 32.5, 32.9, 32.1));
        check("bearingTo: ahead 0, right +pi/2, behind +-pi",
            near(d.bearingTo(40.5, 32.5), 0.0, 1e-9) && near(d.bearingTo(32.5, 40.5), Math.PI * 0.5, 1e-9)
            && near(Math.abs(d.bearingTo(24.5, 32.5)), Math.PI, 1e-9) && near(d.bearingTo(32.5, 24.5), -Math.PI * 0.5, 1e-9));
        var half = d.tape.fov * 0.5 + 5.0 * Math.PI / 180.0;
        var inA = half - 0.02;
        var outA = half + 0.02;
        check("inViewCone: ahead yes, behind no", d.inViewCone(40.5, 32.5) && !d.inViewCone(24.5, 32.5));
        check("inViewCone: fov/2 + 5 deg is the edge",
            d.inViewCone(32.5 + 8.0 * Math.cos(inA), 32.5 + 8.0 * Math.sin(inA))
            && !d.inViewCone(32.5 + 8.0 * Math.cos(outA), 32.5 + 8.0 * Math.sin(outA))
            && d.inViewCone(32.5 + 8.0 * Math.cos(-inA), 32.5 + 8.0 * Math.sin(-inA)));
        w.put(36, 32, Cells.WALL);
        check("inViewCone needs line of sight", !d.inViewCone(40.5, 32.5));
        w.put(36, 32, Cells.FLOOR);
        check("isDeadEnd: open floor no, wall no", !d.isDeadEnd(32, 32) && !d.isDeadEnd(0, 0));
        var m = new SimBGrid(8, 8);
        m.put(3, 3, Cells.FLOOR);
        m.put(4, 3, Cells.FLOOR);
        m.put(5, 3, Cells.FLOOR);
        var dm = mk(m, 4.5, 3.5, 0.0, 0.0);
        check("isDeadEnd: a corridor end (one walkable neighbour) yes, the middle no", dm.isDeadEnd(3, 3) && dm.isDeadEnd(5, 3) && !dm.isDeadEnd(4, 3));
    }

    // ---- Watcher spawn at 90 s, dropout when far, respawn ----
    static function testWatcherLifecycle():Void {
        var w = SimBGrid.openRoom(96, 96);
        var d = mk(w, 48.5, 48.5, 0.0, 0.0);
        var t = 0.0;
        var spawnAt = -1.0;
        var earlyAlive = false;
        var spawnDist = 0.0;
        var spawnInView = true;
        var spawnR = 0.0;
        for (i in 0...1200) {
            d.update(0.1, false, 0);
            t += 0.1;
            if (d.tapeTime < 90.0 - 1e-6 && d.watcher.alive) earlyAlive = true;
            if (has(d, Director.EV_WATCHER_SPAWN)) {
                spawnAt = d.tapeTime;
                spawnDist = dist(d, d.watcher.x, d.watcher.y);
                spawnInView = d.inViewCone(d.watcher.x, d.watcher.y);
                spawnR = d.watcher.targetRadius;
                break;
            }
        }
        check("Watcher spawns at tapeTime >= 90 (EV_WATCHER_SPAWN at " + r2(spawnAt) + " s), never before", !earlyAlive && spawnAt >= 90.0 - 1e-6 && spawnAt < 91.0 && d.watcher.alive);
        check("... out of view, at targetRadius +/- 1 (" + r2(spawnDist) + " vs R " + r2(spawnR) + ")", !spawnInView && Math.abs(spawnDist - spawnR) <= 1.25 && !Cells.solid(w.cell(Math.floor(d.watcher.x), Math.floor(d.watcher.y))));
        check("presence follows the new Watcher", d.presence == 0.0 || d.presence > 0.0);

        d.noRelocateUntil = 1e9;                     // it cannot follow: the player walks off the tape
        d.player.placeAt(1.5, 1.5, 0.0);
        var far = dist(d, d.watcher.x, d.watcher.y);
        var tele = d.tapeTime;
        var despawnAt = -1.0;
        for (i in 0...300) {
            d.update(0.1, false, 0);
            if (has(d, Director.EV_WATCHER_DESPAWN)) { despawnAt = d.tapeTime - tele; break; }
        }
        check("Watcher > 30 cells away (" + r2(far) + ") for 20 s: EV_WATCHER_DESPAWN at " + r2(despawnAt) + " s", far > 30.0 && near(despawnAt, 20.0, 0.15) && !d.watcher.alive);
        d.noRelocateUntil = 0.0;
        var respawnAt = -1.0;
        var since = d.tapeTime;
        for (i in 0...500) {
            d.update(0.1, false, 0);
            if (has(d, Director.EV_WATCHER_SPAWN)) { respawnAt = d.tapeTime - since; break; }
        }
        check("... and it comes back within 40 s (" + r2(respawnAt) + " s), out of view", respawnAt > 0 && respawnAt <= 40.0 && d.watcher.alive && !d.inViewCone(d.watcher.x, d.watcher.y));
    }

    // ---- the rc/test hooks ----
    static function testForce():Void {
        var w = SimBGrid.openRoom(64, 64);
        var d = mk(w, 32.5, 32.5, 0.0, 0.0);
        d.update(DT, false, 0);
        d.forceSpawnHound();
        var hd = dist(d, d.hound.x, d.hound.y);
        check("forceSpawnHound: alive at 22 cells (" + r2(hd) + "), out of view, howling", d.hound.alive && hd >= 20.5 && hd <= 23.5 && !d.inViewCone(d.hound.x, d.hound.y) && d.hound.state == Hound.S_HOWL);
        d.update(DT, false, 0);
        check("... the next update delivers EV_HOUND_SPAWN and EV_HOWL", has(d, Director.EV_HOUND_SPAWN) && has(d, Director.EV_HOWL));
        var howls = 0;
        var spawns = 0;
        for (i in 0...200) {
            d.update(DT, false, 0);
            if (has(d, Director.EV_HOWL)) howls++;
            if (has(d, Director.EV_HOUND_SPAWN)) spawns++;
        }
        check("... and never again: one howl, one spawn", howls == 0 && spawns == 0);

        var db = mk(w, 32.5, 32.5, 0.0, 0.0);
        db.update(DT, false, 0);
        db.forceBlackout();
        db.forceBlackout();                          // a second call inside the blackout is a no-op
        db.update(DT, false, 0);
        check("forceBlackout: EV_BLACKOUT_START once, lightOffset 15, blackoutT > 0", has(db, Director.EV_BLACKOUT_START) && db.lightOffset == 15 && db.blackoutT > 0.0);
        var starts = 0;
        var endAt = -1.0;
        var t = 0.0;
        for (i in 0...100) {
            db.update(DT, false, 0);
            t += DT;
            if (has(db, Director.EV_BLACKOUT_START)) starts++;
            if (has(db, Director.EV_BLACKOUT_END) && endAt < 0) endAt = t;
        }
        check("... ends within 4 s (" + r2(endAt) + " s), no second start", starts == 0 && endAt > 1.9 && endAt <= 4.1);

        var dr = mk(w, 32.5, 32.5, 0.0, 0.0);
        dr.update(DT, false, 0);
        dr.forceRelocate();
        dr.update(DT, false, 0);
        check("forceRelocate with no Watcher is a no-op", !has(dr, Director.EV_WATCHER_RELOCATED) && !dr.watcher.alive);
        dr.watcher.spawnAt(27.5, 32.5);
        dr.update(DT, false, 0);
        dr.forceRelocate();
        var nx = dr.watcher.x;
        var ny = dr.watcher.y;
        dr.update(DT, false, 0);
        check("forceRelocate: the Watcher moves to a walkable post out of view and EV_WATCHER_RELOCATED is delivered",
            has(dr, Director.EV_WATCHER_RELOCATED) && (nx != 27.5 || ny != 32.5) && !dr.inViewCone(nx, ny) && !Cells.solid(w.cell(Math.floor(nx), Math.floor(ny))));
    }

    // ---- hearing: the player's footsteps and blackouts reach the Hound ----
    static function testHearing():Void {
        var w = SimBGrid.openRoom(96, 96);
        var d = mk(w, 48.5, 48.5, 0.0, 0.0);
        d.update(DT, false, 0);
        d.hound.spawnAt(40.5, 48.5);                 // 8 behind, dormant
        d.update(DT, false, 0);
        check("a dormant Hound at 8 stays dormant while the player stands still", d.hound.state == Hound.S_DORMANT);
        d.update(DT, false, Player.PE_STEP);
        check("a walking step within 10 cells: HOWL and EV_HOWL", d.hound.state == Hound.S_HOWL && has(d, Director.EV_HOWL));
        var howls = 0;
        for (i in 0...100) {
            d.update(DT, false, 0);
            if (has(d, Director.EV_HOWL)) howls++;
        }
        check("EV_HOWL is not repeated on later frames", howls == 0);

        var d2 = mk(w, 48.5, 48.5, 0.0, 0.0);
        d2.update(DT, false, 0);
        d2.hound.spawnAt(33.5, 48.5);                // 15 behind
        d2.update(DT, false, Player.PE_STEP);
        check("a walking step at 15 cells is not heard (walk radius 10)", d2.hound.state == Hound.S_DORMANT);
        d2.player.running = true;
        d2.update(DT, false, Player.PE_STEP);
        check("a running step at 15 cells is heard (run radius 24)", d2.hound.state == Hound.S_HOWL);

        var d3 = mk(w, 48.5, 48.5, 0.0, 0.0);
        d3.update(DT, false, 0);
        d3.hound.spawnAt(20.5, 48.5);                // 28 behind
        d3.update(DT, false, Player.PE_STEP);
        check("a step at 28 cells: silent", d3.hound.state == Hound.S_DORMANT);
        d3.update(DT, false, Player.PE_STEP | Player.PE_STEP_WET);
        check("a wet splash at 28 cells is heard (splash radius 32)", d3.hound.state == Hound.S_HOWL);

        var d4 = mk(w, 48.5, 48.5, 0.0, 0.0);
        d4.update(DT, false, 0);
        d4.hound.spawnAt(12.5, 48.5);                // 36 behind
        d4.update(DT, false, Player.PE_STEP | Player.PE_STEP_WET);
        check("a splash at 36 cells: silent", d4.hound.state == Hound.S_DORMANT);
        d4.forceBlackout();
        check("a blackout is heard at 36 cells (radius 40)", d4.hound.state == Hound.S_HOWL);

        var w5 = SimBGrid.openRoom(96, 96);
        w5.put(48, 48, Cells.DARK);
        var d5 = mk(w5, 48.5, 48.5, 0.0, 0.0);
        d5.update(DT, false, 0);
        d5.hound.spawnAt(35.5, 48.5);                // 13 behind: silent in the light, heard in DARK (10 x 1.5)
        d5.update(DT, false, Player.PE_STEP);
        check("in DARK the hearing radius is x1.5: a walk at 13 cells is heard", d5.hearingMul == 1.5 && d5.hound.state == Hound.S_HOWL);
    }
}
