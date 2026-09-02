// Unit tests for Player (CONTRACT §1). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
// Also hosts SimGrid, the flat-grid World the sim-a tests (Player, Watcher, Hound) share.
//   standalone: haxe -cp src/backrooms -cp stubs/sim -cp tests/backrooms -main TestPlayer --interp

// A World whose cell() reads a flat grid placed at any world origin; everything outside is WALL.
// Works against the real World and the stub alike (only cell/has are overridden).
class SimGrid extends World {
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

    // open a (2r+1)^2 block of FLOOR around a cell
    public function clearAround(x:Int, y:Int, r:Int):Void {
        for (j in -r...r + 1) for (i in -r...r + 1) setCell(x + i, y + j, Cells.FLOOR);
    }

    // random maze: each cell WALL with probability p (a few PILLARs among them), bordered
    public static function maze(seed:Int, ox:Int, oy:Int, gw:Int, gh:Int, p:Float):SimGrid {
        var g = new SimGrid(ox, oy, gw, gh, Cells.FLOOR);
        var rng = new Rng(seed);
        for (j in 0...gh) for (i in 0...gw) {
            if (rng.chance(p)) g.grid[j * gw + i] = rng.chance(0.1) ? Cells.PILLAR : Cells.WALL;
        }
        g.border();
        return g;
    }

    // a random walkable cell within +/- r of (cx, cy) whose 4 neighbours include a walkable one; (-1, -1) packed if none found
    public function randomWalkable(rng:Rng, cx:Int, cy:Int, r:Int):Int {
        for (i in 0...2000) {
            var x = cx + rng.range(-r, r + 1);
            var y = cy + rng.range(-r, r + 1);
            if (!Cells.walkable(cell(x, y))) continue;
            if (Cells.type(cell(x, y)) == Cells.PIT) continue;
            return Cells.pack(x, y);
        }
        return Cells.pack(-1, -1);
    }
}

class TestPlayer {
    static var fails:Int = 0;
    static inline var TWO_PI = 6.283185307179586;

    static function check(name:String, ok:Bool):Void {
        Sys.println("  " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok) fails++;
    }

    static inline function absf(v:Float):Float return v < 0 ? -v : v;

    // true when the player's RADIUS box touches no solid cell
    static function boxClear(w:World, p:Player):Bool {
        var r = Player.RADIUS;
        if (w.solid(Math.floor(p.x - r), Math.floor(p.y - r))) return false;
        if (w.solid(Math.floor(p.x + r), Math.floor(p.y - r))) return false;
        if (w.solid(Math.floor(p.x - r), Math.floor(p.y + r))) return false;
        if (w.solid(Math.floor(p.x + r), Math.floor(p.y + r))) return false;
        return true;
    }

    // a straight corridor along y = 0 from x = 0..len-1 of the given cell type, walls everywhere else
    static function corridor(len:Int, type:Int):SimGrid {
        var g = new SimGrid(-2, -2, len + 4, 5, Cells.WALL);
        for (x in 0...len) g.setCell(x, 0, type);
        return g;
    }

    public static function run():Int {
        fails = 0;
        var rng = new Rng(5);

        // ------------------------------------------------------------------
        // (1) 100k random inputs in a random maze: never inside a solid cell, never a box corner in one
        var m = SimGrid.maze(11, -32, -32, 64, 64, 0.28);
        m.clearAround(0, 0, 1);
        var p = new Player(0.5, 0.5, 0.0);
        var badCentre = 0;
        var badBox = 0;
        var maxStep = 0.0;
        var walked = 0.0;
        for (i in 0...100000) {
            var fwd = rng.range(-1, 2);
            var turn = rng.range(-1, 2);
            var strafe = rng.range(-1, 2);
            var run = rng.chance(0.3);
            var dt = 0.01 + rng.nextFloat() * 0.09;
            var ox = p.x, oy = p.y;
            p.update(dt, fwd, turn, strafe, run, m);
            if (m.solid(p.cellX(), p.cellY())) badCentre++;
            if (!boxClear(m, p)) badBox++;
            var dx = p.x - ox, dy = p.y - oy;
            var st = Math.sqrt(dx * dx + dy * dy);
            if (st > maxStep) maxStep = st;
            walked += st;
        }
        check("100k random inputs: centre never in a solid cell (" + badCentre + ")", badCentre == 0);
        check("100k random inputs: radius box never touches a solid cell (" + badBox + ")", badBox == 0);
        check("100k random inputs: it actually moved (" + Math.round(walked) + " cells)", walked > 50.0);
        check("100k random inputs: no step above run speed x 0.1 s (" + maxStep + ")", maxStep <= Player.WALK * Player.RUN_MUL * 0.1 + 1e-9);
        check("cellsWalked tracks the distance moved", absf(p.cellsWalked - walked) < 1e-6);
        p.placeAt(-3.2, 2.7, 0.0);
        check("cellX/cellY are floor(x)/floor(y) for negatives (-4, 2)", p.cellX() == -4 && p.cellY() == 2);

        // ------------------------------------------------------------------
        // (2) sliding: walking diagonally into a corridor wall keeps the along-wall component
        var c = corridor(21, Cells.FLOOR);
        p = new Player(2.5, 0.5, Math.PI / 4.0);
        var blocked = false;
        for (i in 0...40) if ((p.update(0.05, 1, 0, 0, false, c) & Player.PE_BLOCKED) != 0) blocked = true;
        check("slide: x advanced along the wall (x=" + p.x + ")", p.x > 3.5 && p.x < 3.7);
        check("slide: y pressed against the wall, never past RADIUS (y=" + p.y + ")", p.y > 0.7 && p.y <= 1.0 - Player.RADIUS + 1e-9);
        check("slide: a sliding frame is not PE_BLOCKED", !blocked);
        check("slide: box stays clear", boxClear(c, p));

        // (3) cannot enter a solid cell: walking straight at the corridor's end wall
        p = new Player(18.5, 0.5, 0.0);
        var blockedFrames = 0;
        for (i in 0...100) if ((p.update(0.05, 1, 0, 0, true, c) & Player.PE_BLOCKED) != 0) blockedFrames++;
        check("wall: stops at RADIUS from the wall (x=" + p.x + ")", p.x <= 21.0 - Player.RADIUS + 1e-9 && p.x > 20.5);
        check("wall: PE_BLOCKED while pushing (" + blockedFrames + " frames)", blockedFrames > 50);
        check("wall: speed is 0 while blocked", p.speed == 0.0);
        check("wall: not running while blocked", !p.running);

        // ------------------------------------------------------------------
        // (4) WET carpet: WET_MUL speed and PE_STEP_WET on every step; FLOOR: WALK and plain steps every STEP_LEN
        var wet = corridor(40, Cells.WET);
        p = new Player(1.5, 0.5, 0.0);
        var wetSteps = 0, plainSteps = 0, wrongSpeed = 0;
        for (i in 0...100) {
            var ev = p.update(0.05, 1, 0, 0, false, wet);
            if (absf(p.speed - Player.WALK * Player.WET_MUL) > 1e-6) wrongSpeed++;
            if ((ev & Player.PE_STEP) != 0) { if ((ev & Player.PE_STEP_WET) != 0) wetSteps++; else plainSteps++; }
        }
        check("wet: speed is WALK * WET_MUL every frame (" + wrongSpeed + " wrong)", wrongSpeed == 0);
        check("wet: onWet set", p.onWet);
        // 5 s at 0.48 cells/s = 2.4 cells -> 3 steps, all wet
        check("wet: every footstep carries PE_STEP_WET (" + wetSteps + " wet, " + plainSteps + " plain)", wetSteps == 3 && plainSteps == 0);
        var dry = corridor(40, Cells.FLOOR);
        p = new Player(1.5, 0.5, 0.0);
        wetSteps = 0; plainSteps = 0; wrongSpeed = 0;
        for (i in 0...200) {                            // 10 s at 0.8 = 8 cells -> 11 steps (0.7 spacing)
            var ev = p.update(0.05, 1, 0, 0, false, dry);
            if (absf(p.speed - Player.WALK) > 1e-6) wrongSpeed++;
            if ((ev & Player.PE_STEP) != 0) { if ((ev & Player.PE_STEP_WET) != 0) wetSteps++; else plainSteps++; }
        }
        check("floor: speed is WALK every frame (" + wrongSpeed + " wrong)", wrongSpeed == 0);
        check("floor: a step every STEP_LEN cells (" + plainSteps + " of 11), none wet", plainSteps == 11 && wetSteps == 0);
        check("floor: onWet clear", !p.onWet);
        // wet also slows running
        p = new Player(1.5, 0.5, 0.0);
        p.update(0.05, 1, 0, 0, true, wet);
        check("wet: running speed is WALK * RUN_MUL * WET_MUL", absf(p.speed - Player.WALK * Player.RUN_MUL * Player.WET_MUL) < 1e-6);

        // ------------------------------------------------------------------
        // (5) stamina: drains to 0 in STAMINA_SECS while running, recovers to 1 in RECOVER_SECS; 0 stamina = walking
        var room = new SimGrid(0, 0, 80, 80, Cells.FLOOR);
        room.border();
        p = new Player(40.5, 40.5, 0.0);
        var t = 0.0;
        var tEmpty = -1.0;
        var runStarts = 0;
        var runSpeedBad = 0;
        var wasRunningAtStart = false;
        while (t < 6.0) {
            var ev = p.update(0.05, 1, 1, 0, true, room);    // running in a circle
            t += 0.05;
            if ((ev & Player.PE_RUN_START) != 0) runStarts++;
            if (t < 3.9) {
                if (!p.running) wasRunningAtStart = true;
                if (absf(p.speed - Player.WALK * Player.RUN_MUL) > 1e-6) runSpeedBad++;
            }
            if (tEmpty < 0.0 && p.stamina <= 0.0) tEmpty = t;
        }
        check("stamina: running for " + tEmpty + " s empties it (STAMINA_SECS 4)", tEmpty > 3.9 && tEmpty < 4.11);
        check("stamina: PE_RUN_START fires exactly once (" + runStarts + ")", runStarts == 1);
        check("stamina: running flag and run speed hold until empty", !wasRunningAtStart && runSpeedBad == 0);
        check("stamina: with 0 stamina and Shift held it walks (speed " + p.speed + ")", !p.running && absf(p.speed - Player.WALK) < 1e-6);
        check("stamina: runSeconds reset when not running", p.runSeconds == 0.0);
        // stand still: recovery
        t = 0.0;
        var tFull = -1.0;
        p.update(0.05, 0, 0, 0, false, room);
        var s0 = p.stamina;
        while (t < 14.0) {
            p.update(0.05, 0, 0, 0, false, room);
            t += 0.05;
            if (tFull < 0.0 && p.stamina >= 1.0) tFull = t;
        }
        var expect = (1.0 - s0) * Player.RECOVER_SECS;
        check("stamina: recovers in " + tFull + " s (expected " + expect + ")", tFull > 0.0 && absf(tFull - expect) < 0.11);
        check("stamina: speed 0 and not running while standing", p.speed == 0.0 && !p.running);

        // ------------------------------------------------------------------
        // (6) PIT: PE_ENTERED_PIT exactly once on entering, again on a later re-entry
        var pc = corridor(30, Cells.FLOOR);
        pc.setCell(10, 0, Cells.PIT);
        p = new Player(8.5, 0.5, 0.0);
        var pits = 0;
        for (i in 0...60) if ((p.update(0.05, 1, 0, 0, false, pc) & Player.PE_ENTERED_PIT) != 0) pits++;   // 2.4 cells -> ends inside the pit
        check("pit: entered once (" + pits + ") and standing in it", pits == 1 && p.cellX() == 10);
        for (i in 0...20) if ((p.update(0.05, 0, 0, 0, false, pc) & Player.PE_ENTERED_PIT) != 0) pits++;   // standing in it: no repeat
        check("pit: no repeat while standing in it", pits == 1);
        for (i in 0...40) if ((p.update(0.05, 1, 0, 0, false, pc) & Player.PE_ENTERED_PIT) != 0) pits++;   // walk out to x ~ 12.5
        check("pit: left it (x=" + p.x + ")", p.cellX() == 12 && pits == 1);
        for (i in 0...60) if ((p.update(0.05, -1, 0, 0, false, pc) & Player.PE_ENTERED_PIT) != 0) pits++;  // back in
        check("pit: re-entry fires again (" + pits + ")", pits == 2 && p.cellX() == 10);
        check("pit: PIT is walkable", Cells.walkable(pc.cell(10, 0)));

        // ------------------------------------------------------------------
        // (7) turning: +1 is right (angle increases), eased in over 0.15 s; -1 wraps below 0
        p = new Player(40.5, 40.5, 0.0);
        for (i in 0...20) p.update(0.05, 0, 1, 0, false, room);     // 1 s
        var ideal = Player.TURN * (1.0 - 0.075);                     // ease-in costs half of 0.15 s
        check("turn: +1 for 1 s gives " + p.ang + " rad (ideal " + ideal + ")", absf(p.ang - ideal) < 0.08);
        var a1 = p.ang;
        p.update(0.05, 0, 1, 0, false, room);
        check("turn: at full rate after the ramp", absf((p.ang - a1) - Player.TURN * 0.05) < 1e-9);
        p = new Player(40.5, 40.5, 0.0);
        p.update(0.05, 0, -1, 0, false, room);
        check("turn: -1 decreases the angle and wraps into [0, 2pi)", p.ang > Math.PI && p.ang < TWO_PI);
        p = new Player(40.5, 40.5, 0.0);
        for (i in 0...19) p.update(0.05, 0, 1, 0, false, room);     // ~pi/2 (right)
        for (i in 0...20) p.update(0.05, 1, 0, 0, false, room);
        check("turn: after turning right, forward moves +y (screen down)", p.y > 41.2 && absf(p.x - 40.5) < 0.2);

        // (8) strafe: +1 moves along (cos(ang + pi/2), sin(ang + pi/2)); back is -facing
        p = new Player(40.5, 40.5, 0.0);
        for (i in 0...20) p.update(0.05, 0, 0, 1, false, room);
        check("strafe: +1 at ang 0 moves +y only (y=" + p.y + ")", absf(p.y - 41.3) < 1e-6 && absf(p.x - 40.5) < 1e-9);
        p = new Player(40.5, 40.5, 0.0);
        for (i in 0...20) p.update(0.05, -1, 0, 0, false, room);
        check("back: -1 at ang 0 moves -x only (x=" + p.x + ")", absf(p.x - 39.7) < 1e-6 && absf(p.y - 40.5) < 1e-9);
        p = new Player(40.5, 40.5, 0.0);
        p.update(0.05, 1, 0, 1, false, room);
        check("diagonal: forward + strafe is normalised to WALK", absf(p.speed - Player.WALK) < 1e-6);

        // (9) ground flags and teleport
        var dark = corridor(10, Cells.DARK);
        p = new Player(3.5, 0.5, 0.0);
        p.update(0.05, 0, 0, 0, false, dark);
        check("dark: onDark set on a DARK cell, onWet clear", p.onDark && !p.onWet);
        p.placeAt(7.25, 0.5, 7.0);
        check("placeAt: teleports and normalises the angle", p.x == 7.25 && p.ang >= 0.0 && p.ang < TWO_PI && absf(p.ang - (7.0 - TWO_PI)) < 1e-9);
        check("placeAt: ground flags cleared until the next update", !p.onDark && !p.onWet);

        // (10) placeAt is the tape start: a fresh operator every tape (Main reuses the one Player and the
        // Director reads D from cellsWalked, so nothing may carry over)
        p = new Player(40.5, 40.5, 0.0);
        for (i in 0...82) p.update(0.05, 1, 1, 0, true, room);       // 4.1 s of running: exhausted, distance banked
        p.update(0.05, 1, 0, 0, true, room);                          // Shift still held: it walks (exhaustion hysteresis)
        check("placeAt: precondition — walked (" + p.cellsWalked + "), stamina spent (" + p.stamina + "), run refused", p.cellsWalked > 3.0 && p.stamina < 0.1 && !p.running);
        p.placeAt(40.5, 40.5, 0.0);
        check("placeAt: cellsWalked reset to 0", p.cellsWalked == 0.0);
        check("placeAt: stamina back to 1, not running, speed 0", p.stamina == 1.0 && !p.running && p.speed == 0.0 && p.runSeconds == 0.0);
        var ev0 = p.update(0.05, 1, 0, 0, true, room);
        check("placeAt: exhaustion cleared — the first run frame of the new tape is at run speed", p.running && absf(p.speed - Player.WALK * Player.RUN_MUL) < 1e-6 && (ev0 & Player.PE_RUN_START) != 0);

        return fails;
    }

    public static function main():Void {
        var f = run();
        Sys.println("TestPlayer: " + (f == 0 ? "pass" : f + " failed"));
        if (f > 0) Sys.exit(1);
    }
}
