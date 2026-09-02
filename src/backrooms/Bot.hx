// Soak-test auto-walker (CONTRACT §1). Core class: no flash.* imports.
// Walks forward; probes the facing line for solid cells; turns toward the more open side when a wall lies
// within LOOK cells; random turns every 3..8 s; 10% run bursts of 2 s; a map toggle every 45 s held 3 s.
// wantMapToggle is a LEVEL, not a pulse: true for the whole 3 s hold. Main opens the map on its rising edge
// (ST_PLAY) and closes it on the falling edge (ST_MAP), so Main must keep calling update() while the map is up.
// No allocation in update(): every probe is arithmetic on locals plus World.cell.
class Bot {
    public static inline var LOOK = 1.5;                // cells ahead that trigger avoidance
    public static inline var STOP = 0.6;                // cells ahead that stop forward motion while turning
    public static inline var PROBE_STEP = 0.1;          // probe spacing along a ray
    public static inline var SIDE_LOOK = 3.0;           // how far the side probes look
    public static inline var MAP_PERIOD = 45.0;
    public static inline var MAP_HOLD = 3.0;
    public static inline var RUN_SECS = 2.0;
    public static inline var TURN_ANG = 0.7853981634;   // 45 deg

    public var fwd:Int;
    public var turn:Int;
    public var run:Bool;
    public var wantMapToggle:Bool;                      // every 45 s, held open 3 s (a level: true throughout the hold)

    var rng:Rng;                                        // hash3(seed, TAG_BOT, 0)
    var turnTimer:Float;                                // seconds until the next random turn
    var turnLeft:Float;                                 // seconds of the current random turn still to go
    var turnDir:Int;                                    // direction of the current random / avoidance turn
    var avoidDir:Int;                                   // direction chosen when avoidance started (kept until clear)
    var avoiding:Bool;
    var runLeft:Float;                                  // seconds of the current run burst
    var runCheck:Float;                                 // seconds until the next run-burst roll
    var mapTimer:Float;                                 // seconds until the next map open
    var mapOpen:Bool;
    var mapHold:Float;

    public function new(seed:Int):Void {
        rng = new Rng(Rng.hash3(seed, Rng.TAG_BOT, 0));
        fwd = 0;
        turn = 0;
        run = false;
        wantMapToggle = false;
        turnTimer = 3.0 + rng.nextFloat() * 5.0;
        turnLeft = 0.0;
        turnDir = 1;
        avoidDir = 1;
        avoiding = false;
        runLeft = 0.0;
        runCheck = 1.0;
        mapTimer = MAP_PERIOD;
        mapOpen = false;
        mapHold = 0.0;
    }

    // sets fwd/turn/run/wantMapToggle for this frame
    public function update(dt:Float, player:Player, world:World):Void {
        // map cadence: the flag goes high when MAP_PERIOD runs out and stays high for MAP_HOLD (Main reads the edges:
        // rising = open, falling = close). Walking carries on underneath: Main freezes the player itself while the
        // paper is up, and a refused open (NO SIGNAL) costs nothing. The overshoot of one timer seeds the next so
        // the cadence never drifts a frame per cycle over a long soak.
        if (mapOpen) {
            mapHold -= dt;
            if (mapHold <= 0.0) {
                mapOpen = false;
                mapTimer = MAP_PERIOD + mapHold;
            }
        } else {
            mapTimer -= dt;
            if (mapTimer <= 0.0) {
                mapOpen = true;
                mapHold = MAP_HOLD + mapTimer;
            }
        }
        wantMapToggle = mapOpen;

        var px = player.x;
        var py = player.y;
        var a = player.ang;
        var ca = Math.cos(a);
        var sa = Math.sin(a);

        // distance along the facing line to the first solid cell, up to LOOK
        var ahead = clearance(world, px, py, ca, sa, LOOK);

        if (ahead < LOOK) {
            if (!avoiding) {
                // pick the more open side once, by probing +/-45 and +/-90; ties go to a coin flip
                var l45 = clearance(world, px, py, Math.cos(a - TURN_ANG), Math.sin(a - TURN_ANG), SIDE_LOOK);
                var r45 = clearance(world, px, py, Math.cos(a + TURN_ANG), Math.sin(a + TURN_ANG), SIDE_LOOK);
                var l90 = clearance(world, px, py, sa, -ca, SIDE_LOOK);     // ang - 90 deg = (sin, -cos)
                var r90 = clearance(world, px, py, -sa, ca, SIDE_LOOK);     // ang + 90 deg = (-sin, cos)
                var left = l45 + l90;
                var right = r45 + r90;
                if (left > right + 0.05) avoidDir = -1;
                else if (right > left + 0.05) avoidDir = 1;
                else avoidDir = rng.chance(0.5) ? 1 : -1;
                avoiding = true;
            }
            turn = avoidDir;
            fwd = ahead > STOP ? 1 : 0;
            run = false;
            runLeft = 0.0;
            turnLeft = 0.0;
            return;
        }
        avoiding = false;

        // random turns every 3..8 s, each 0.3..1.2 s long, walking on through them
        if (turnLeft > 0.0) {
            turnLeft -= dt;
            turn = turnDir;
        } else {
            turn = 0;
            turnTimer -= dt;
            if (turnTimer <= 0.0) {
                turnTimer = 3.0 + rng.nextFloat() * 5.0;
                turnLeft = 0.3 + rng.nextFloat() * 0.9;
                turnDir = rng.chance(0.5) ? 1 : -1;
                turn = turnDir;
            }
        }
        fwd = 1;

        // run bursts: rolled once a second, 10% chance, 2 s long
        if (runLeft > 0.0) {
            runLeft -= dt;
            run = runLeft > 0.0;
        } else {
            run = false;
            runCheck -= dt;
            if (runCheck <= 0.0) {
                runCheck = 1.0;
                if (rng.chance(0.1)) {
                    runLeft = RUN_SECS;
                    run = true;
                }
            }
        }
    }

    // distance along (dx, dy) from (x, y) to the first solid cell, in PROBE_STEP steps; maxD if none
    static function clearance(world:World, x:Float, y:Float, dx:Float, dy:Float, maxD:Float):Float {
        var d = PROBE_STEP;
        while (d <= maxD) {
            var cx = Math.floor(x + dx * d);
            var cy = Math.floor(y + dy * d);
            if (Cells.solid(world.cell(cx, cy))) return d - PROBE_STEP;
            d += PROBE_STEP;
        }
        return maxD;
    }
}
