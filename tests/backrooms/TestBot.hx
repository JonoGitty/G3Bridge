// Unit tests for Bot (CONTRACT §1). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
// Drives the real Player through the real Bot on hand-built grids (SimBGrid, defined in TestDirector.hx).
import TestDirector.SimBGrid;

class TestBot {
    static var fails:Int = 0;

    static function check(name:String, ok:Bool):Void {
        Sys.println((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) fails++;
    }

    // results of the last drive()
    static var walked:Float = 0.0;
    static var maxIdle:Float = 0.0;        // longest stretch with fwd == 0 && turn == 0
    static var blockedFrames:Int = 0;      // frames with PE_BLOCKED
    static var insideSolid:Int = 0;        // frames ending with the player's centre in a solid cell
    static var runFrames:Int = 0;
    static var bursts:Int = 0;
    static var longestBurst:Float = 0.0;
    static var opens:Array<Float> = [];    // times of the rising edges of wantMapToggle (Main opens the map here)
    static var closes:Array<Float> = [];   // times of the falling edges (Main closes it here)
    static var minHold:Float = 1e9;        // shortest / longest stretch with wantMapToggle held true
    static var maxHold:Float = 0.0;

    // run the bot + player for `seconds` at dt; the player is not moved while the map is "open" (Main's freeze).
    // wantMapToggle is a level: the map is open exactly while it is true, and Main keeps calling bot.update
    // in ST_MAP so the hold clock runs, which this loop mirrors.
    static function drive(bot:Bot, p:Player, w:SimBGrid, seconds:Float, dt:Float):Void {
        walked = 0.0;
        maxIdle = 0.0;
        blockedFrames = 0;
        insideSolid = 0;
        runFrames = 0;
        bursts = 0;
        longestBurst = 0.0;
        opens = [];
        closes = [];
        minHold = 1e9;
        maxHold = 0.0;
        var idle = 0.0;
        var burst = 0.0;
        var wasRun = false;
        var prevToggle = false;
        var hold = 0.0;
        var mapOpen = false;
        var t = 0.0;
        var start = p.cellsWalked;
        var n = Math.round(seconds / dt);
        for (i in 0...n) {
            bot.update(dt, p, w);
            if (bot.wantMapToggle && !prevToggle) { opens.push(t); hold = 0.0; }
            if (!bot.wantMapToggle && prevToggle) {
                closes.push(t);
                if (hold < minHold) minHold = hold;
                if (hold > maxHold) maxHold = hold;
            }
            if (bot.wantMapToggle) hold += dt;
            prevToggle = bot.wantMapToggle;
            mapOpen = bot.wantMapToggle;
            if (bot.fwd == 0 && bot.turn == 0) {
                idle += dt;
                if (idle > maxIdle) maxIdle = idle;
            } else {
                idle = 0.0;
            }
            if (bot.run) {
                runFrames++;
                burst += dt;
                if (!wasRun) bursts++;
                if (burst > longestBurst) longestBurst = burst;
            } else {
                burst = 0.0;
            }
            wasRun = bot.run;
            if (!mapOpen) {
                var pe = p.update(dt, bot.fwd, bot.turn, 0, bot.run, w);
                if ((pe & Player.PE_BLOCKED) != 0) blockedFrames++;
                if (Cells.solid(w.cell(p.cellX(), p.cellY()))) insideSolid++;
            }
            t += dt;
        }
        walked = p.cellsWalked - start;
    }

    public static function run():Int {
        fails = 0;
        var dt = 0.05;

        // ---- (1) open 40x40 room: > 20 cells per simulated minute ----
        var room = SimBGrid.openRoom(40, 40);
        var p = new Player(20.5, 20.5, 0.3);
        var bot = new Bot(1);
        check("bot starts with no map toggle pending", !bot.wantMapToggle);
        drive(bot, p, room, 180.0, dt);
        check("(1) 40x40 open room: cellsWalked grows by > 20 per minute over 3 minutes (" + Math.round(walked / 3.0) + "/min)", walked > 60.0);
        check("(2) never fwd == 0 && turn == 0 for more than 1 s (max idle " + Math.round(maxIdle * 100) / 100 + " s)", maxIdle <= 1.0);
        check("open room: the player's centre never ends a frame inside a solid cell", insideSolid == 0);
        check("open room: blocked frames are rare (" + blockedFrames + " of 3600)", blockedFrames < 3600 * 0.03);
        check("run bursts happen (" + bursts + " bursts, " + runFrames + " run frames)", bursts >= 3 && runFrames >= 60);
        check("a run burst never exceeds 2 s (longest " + Math.round(longestBurst * 100) / 100 + " s)", longestBurst <= 2.0 + dt + 1e-9);
        check("run fraction is a burst pattern, not a sprint (" + Math.round(runFrames / 36.0) + "%)", runFrames < 3600 * 0.4);
        var edgesOk = opens.length == 3 && closes.length == 3;
        if (edgesOk) {
            for (k in 0...3) {
                if (Math.abs(opens[k] - (45.0 + 48.0 * k)) > 0.11) edgesOk = false;
                if (Math.abs(closes[k] - (48.0 + 48.0 * k)) > 0.11) edgesOk = false;
            }
        }
        check("map toggles: rises at 45 s, falls 3 s later, repeats every 48 s (opens " + opens.join(",") + "; closes " + closes.join(",") + ")", edgesOk);
        check("wantMapToggle is a held level, not a one-frame pulse: true for 3 s each time (" + Math.round(minHold * 100) / 100 + ".." + Math.round(maxHold * 100) / 100 + " s)",
            minHold >= 3.0 - dt - 1e-9 && maxHold <= 3.0 + dt + 1e-9);
        check("... and false in between (the first 45 s are all false)", opens[0] >= 44.0);

        // ---- a random corridor maze: never into a wall, keeps moving ----
        var maze = SimBGrid.openRoom(63, 63);
        maze.maze(99);
        p = new Player(1.5, 1.5, 0.0);
        bot = new Bot(2);
        drive(bot, p, maze, 300.0, dt);
        check("maze: the player's centre never ends a frame inside a solid cell (" + insideSolid + ")", insideSolid == 0);
        check("maze: blocked frames < 5% (" + blockedFrames + " of 6000)", blockedFrames < 6000 * 0.05);
        check("maze: the bot keeps exploring, > 20 cells per minute (" + Math.round(walked / 5.0) + "/min)", walked > 100.0);
        check("maze: never idle for more than 1 s (max " + Math.round(maxIdle * 100) / 100 + " s)", maxIdle <= 1.0);

        // a second maze with a different seed and bot
        var maze2 = SimBGrid.openRoom(41, 41);
        maze2.maze(7);
        p = new Player(1.5, 1.5, Math.PI * 0.5);
        bot = new Bot(3);
        drive(bot, p, maze2, 300.0, dt);
        check("maze 2: centre never inside a solid cell", insideSolid == 0);
        check("maze 2: blocked frames < 5% (" + blockedFrames + " of 6000)", blockedFrames < 6000 * 0.05);
        check("maze 2: > 20 cells per minute (" + Math.round(walked / 5.0) + "/min)", walked > 100.0);

        // ---- wall avoidance turns toward the more open side ----
        // facing +x with the east wall 0.8 ahead; +y ("right", turn = +1) is open, -y is 1.5 cells away
        var r2 = SimBGrid.openRoom(40, 40);
        var pr = new Player(38.2, 2.5, 0.0);
        var br = new Bot(4);
        br.update(dt, pr, r2);
        check("wall ahead, more room to the right -> turn == +1 and no run", br.turn == 1 && !br.run);
        var pl = new Player(38.2, 37.5, 0.0);
        var bl = new Bot(4);
        bl.update(dt, pl, r2);
        check("wall ahead, more room to the left -> turn == -1", bl.turn == -1);
        var pc = new Player(38.7, 20.5, 0.0);
        var bc = new Bot(4);
        bc.update(dt, pc, r2);
        check("wall 0.3 ahead (inside the stop distance): fwd == 0 while turning", bc.fwd == 0 && bc.turn != 0);
        var po = new Player(20.5, 20.5, 0.0);
        var bo = new Bot(4);
        bo.update(dt, po, r2);
        check("open floor ahead: walks forward", bo.fwd == 1);

        // ---- dead end: it turns round and leaves ----
        var de = SimBGrid.openRoom(20, 20);
        de.rect(1, 1, 18, 18, Cells.WALL);
        for (x in 1...11) de.put(x, 10, Cells.FLOOR);   // corridor 1..10 on row 10, dead end at x = 1
        de.rect(10, 5, 18, 15, Cells.FLOOR);           // opens into a room at x >= 10
        var pd = new Player(2.5, 10.5, Math.PI);       // facing the dead end (-x)
        var bd = new Bot(5);
        drive(bd, pd, de, 30.0, dt);
        check("dead end: turns round and reaches the room within 30 s (x = " + Math.round(pd.x * 10) / 10 + ")", pd.x > 9.0 && insideSolid == 0);
        check("dead end: never idle > 1 s while turning round", maxIdle <= 1.0);

        // ---- determinism ----
        var wa = SimBGrid.openRoom(40, 40);
        wa.maze(5);
        var pa = new Player(1.5, 1.5, 0.0);
        var ba = new Bot(11);
        var pb = new Player(1.5, 1.5, 0.0);
        var bb = new Bot(11);
        var pcx = new Player(1.5, 1.5, 0.0);
        var bcx = new Bot(12);
        var sameSeq = true;
        var differs = false;
        for (i in 0...1200) {
            ba.update(dt, pa, wa);
            bb.update(dt, pb, wa);
            bcx.update(dt, pcx, wa);
            if (ba.fwd != bb.fwd || ba.turn != bb.turn || ba.run != bb.run || ba.wantMapToggle != bb.wantMapToggle) sameSeq = false;
            if (ba.fwd != bcx.fwd || ba.turn != bcx.turn || ba.run != bcx.run) differs = true;
            pa.update(dt, ba.fwd, ba.turn, 0, ba.run, wa);
            pb.update(dt, bb.fwd, bb.turn, 0, bb.run, wa);
            pcx.update(dt, bcx.fwd, bcx.turn, 0, bcx.run, wa);
        }
        check("same seed -> identical command sequence over 1,200 frames", sameSeq && pa.x == pb.x && pa.y == pb.y);
        check("different seed -> a different sequence", differs);

        return fails;
    }
}
