// The hunter (CONTRACT §1, DESIGN §5). Core class: no flash.* imports.
//
// DORMANT -> HOWL -> CHASE -> LOST -> DORMANT. It hears (Director.hear calls), howls for
// 2-3 s without moving (the telegraph), then chases the last heard/seen cell along
// Path.bfs, re-pathed every 0.5 s, at 1.35 x walk for 12 s and 0.9 x walk after. Six
// seconds without sight or sound and it is LOST: it wanders for 30 s (the Director
// raises the snarls), then goes dormant. Contact kills only under the fairness law
// (Entity.canKill): the telegraph clock runs from the start of the howl.
//
// Budget: Path.bfs runs on the 0.5 s repath timer only (a dropped or blocked path
// brings the next call forward to 0.25 s, never to the next frame); everything else is
// a few Float ops. No allocation after the constructor.
class Hound extends Entity {
    public static inline var S_DORMANT = 0;
    public static inline var S_HOWL = 1;
    public static inline var S_CHASE = 2;
    public static inline var S_LOST = 3;
    public static inline var HEAR_RUN = 24.0;
    public static inline var HEAR_SPLASH = 32.0;
    public static inline var HEAR_WALK = 10.0;
    public static inline var HEAR_BLACKOUT = 40.0;
    public static inline var CHASE_MUL = 1.35;          // x Player.WALK
    public static inline var TIRED_MUL = 0.9;
    public static inline var STAMINA_SECS = 12.0;
    public static inline var LOSE_SECS = 6.0;
    public static inline var WANDER_SECS = 30.0;
    // private tuning
    static inline var CONTACT = 0.6;
    static inline var SEE_DIST = 10.0;                  // it sees the player inside this with line of sight
    static inline var REPATH_SECS = 0.5;
    static inline var REPATH_SOON = 0.25;               // after a fresh sound or a dropped path
    static inline var DORMANT_MUL = 0.3;                // wander speed while dormant
    static inline var LOST_MUL = 0.5;                   // wander speed while lost
    static inline var STEP_LEN = 0.5;                   // cells between the slapping footsteps
    static inline var WANDER_RANGE = 4;                 // cells: random wander targets within +/- this
    static inline var RELIEF_SECS = 45.0;               // the Watcher stands down after a lost chase
    static inline var ARRIVE = 1e-4;                    // cells: close enough to a waypoint centre
    static inline var MAX_WAYPOINTS_PER_FRAME = 4;      // a frame step (<= 0.11 cells) never crosses more
    static inline var WANDER_RETRY_SECS = 0.5;          // after a BFS that found no route (Path: at most two calls per second)

    public var howlTimer:Float;
    public var chaseSeconds:Float;
    public var silentSeconds:Float;                     // seconds since last seen or heard
    public var targetX:Int;                             // last heard/seen cell (world cell coordinates)
    public var targetY:Int;
    public var repathTimer:Float;                       // 0.5 s
    public var pathLen:Int;
    public var pathPos:Int;
    public var path:haxe.ds.Vector<Int>;                // Path.MAX_LEN packed WORLD cells (Cells.pack), exactly as Path.bfs writes them
    public var stepEvent:Bool;                          // true on the update() in which a footstep sound should fire

    var dir:Director;                                   // the Director of the last update() (hear() has no parameter for it)
    var pendingHowl:Bool;                               // a hear() started the howl before any update(): finish it (rng length, EV_HOWL) on the next one
    var wanderTimer:Float;                              // LOST: seconds of wandering left
    var pickTimer:Float;                                // wander: seconds until the next random target
    var stepAccum:Float;
    var animT:Float;

    public function new():Void {
        super(Entity.K_HOUND);
        height = 0.45;
        width = 0.7;
        howlTimer = 0.0;
        chaseSeconds = 0.0;
        silentSeconds = 0.0;
        targetX = 0;
        targetY = 0;
        repathTimer = 0.0;
        pathLen = 0;
        pathPos = 0;
        path = new haxe.ds.Vector<Int>(Path.MAX_LEN);
        for (i in 0...Path.MAX_LEN) path[i] = 0;
        stepEvent = false;
        dir = null;
        pendingHowl = false;
        wanderTimer = 0.0;
        pickTimer = 0.0;
        stepAccum = 0.0;
        animT = 0.0;
    }

    override public function spawnAt(x:Float, y:Float):Void {
        super.spawnAt(x, y);
        state = S_DORMANT;
        howlTimer = 0.0;
        chaseSeconds = 0.0;
        silentSeconds = 0.0;
        targetX = Math.floor(x);
        targetY = Math.floor(y);
        repathTimer = 0.0;
        pathLen = 0;
        pathPos = 0;
        stepEvent = false;
        pendingHowl = false;
        wanderTimer = 0.0;
        pickTimer = 0.0;
        stepAccum = 0.0;
        animT = 0.0;
    }

    override public function update(dt:Float, d:Director):Void {
        super.update(dt, d);
        stepEvent = false;
        dir = d;
        if (!alive) return;

        var p = d.player;
        var w = d.world;

        // a howl started by a hear() before the first update() (Director.forceSpawnHound on a Hound that
        // has never seen a Director): now that one is known, roll the real howl length and flag the howl
        // (a bit the Director may already carry this frame; OR-ing it again is harmless)
        if (pendingHowl) {
            pendingHowl = false;
            if (state == S_HOWL) {
                howlTimer = 2.0 + d.rng.nextFloat();
                d.events |= Director.EV_HOWL;
            }
        }

        // sight: the player's cone sees it (CONTRACT), or it has a short clear line to the player
        // (DESIGN §5 "loses you after 6 s without line of sight"): both reset the silence clock
        var sees = inView || (dist <= SEE_DIST && d.lineOfSight(x, y, p.x, p.y));
        if (sees) {
            silentSeconds = 0.0;
            if (state == S_CHASE || state == S_LOST) {
                targetX = p.cellX();
                targetY = p.cellY();
            }
        } else if (state == S_HOWL) {
            silentSeconds = 0.0;                        // the howl answers a sound: silence is counted from the chase
        } else {
            silentSeconds += dt;
        }

        // fairness clock: the howl and the chase footsteps are the cues
        tickTelegraph(dt, state == S_HOWL || state == S_CHASE);

        switch (state) {
            case S_HOWL:
                howlTimer -= dt;                        // rooted to the spot
                if (howlTimer <= 0.0) beginChase();
            case S_CHASE:
                chaseSeconds += dt;
                if (silentSeconds >= LOSE_SECS) {
                    state = S_LOST;
                    wanderTimer = WANDER_SECS;
                    pickTimer = 0.0;
                    pathLen = 0;
                    pathPos = 0;
                    d.events |= Director.EV_HOUND_LOST;
                    var until = d.tapeTime + RELIEF_SECS;
                    if (until > d.noRelocateUntil) d.noRelocateUntil = until;
                } else {
                    var sp = Player.WALK * (chaseSeconds < STAMINA_SECS ? CHASE_MUL : TIRED_MUL);
                    repathTimer -= dt;
                    if (repathTimer <= 0.0) repath(w);
                    follow(w, sp * dt);
                    if (moved > 0.0) { refresh(d); footstep(d); }
                }
            case S_LOST:
                if (sees) {
                    beginChase();                       // it has you again
                } else {
                    wanderTimer -= dt;
                    wander(d, dt, Player.WALK * LOST_MUL);
                    if (wanderTimer <= 0.0) {
                        state = S_DORMANT;
                        pathLen = 0;
                        pathPos = 0;
                        pickTimer = 0.0;
                    }
                }
            default:
                wander(d, dt, Player.WALK * DORMANT_MUL);   // dormant: slow, silent
        }

        // contact
        if (dist < CONTACT && canKill()) d.requestKill(Entity.K_HOUND);

        // sprite: a 4-frame gait while moving, frame 0 standing
        if (moved > 0.0) {
            animT += dt;
            frame = Math.floor(animT * 8.0) & 3;
        } else {
            frame = 0;
        }
    }

    // if dist to (x,y) <= radius (scaled by d.hearingMul): set target, DORMANT -> HOWL, CHASE/LOST -> CHASE; returns true if it reacted
    public function hear(x:Int, y:Int, radius:Float):Bool {
        if (!alive) return false;
        var d = dir;
        var r = radius * (d != null ? d.hearingMul : 1.0);
        var dx = (x + 0.5) - this.x;
        var dy = (y + 0.5) - this.y;
        if (dx * dx + dy * dy > r * r) return false;
        targetX = x;
        targetY = y;
        silentSeconds = 0.0;
        switch (state) {
            case S_DORMANT:
                state = S_HOWL;
                pathLen = 0;
                pathPos = 0;
                if (d != null) {
                    howlTimer = 2.0 + d.rng.nextFloat();
                    d.events |= Director.EV_HOWL;
                } else {
                    howlTimer = 2.5;                    // provisional: the first update() rolls the real length and flags the howl
                    pendingHowl = true;
                }
            case S_LOST:
                beginChase();
            case S_CHASE:
                if (repathTimer > REPATH_SOON) repathTimer = REPATH_SOON;   // fresh target: re-path soon
            default:
                // S_HOWL: keeps howling, target updated
        }
        return true;
    }

    // ---- movement ----

    function beginChase():Void {
        state = S_CHASE;
        chaseSeconds = 0.0;
        silentSeconds = 0.0;
        repathTimer = 0.0;
        pathLen = 0;
        pathPos = 0;
    }

    // BFS toward the target; falls back to one greedy step when the window has no route
    function repath(w:World):Void {
        repathTimer = REPATH_SECS;
        var sx = Math.floor(x);
        var sy = Math.floor(y);
        var n = Path.bfs(w, sx, sy, targetX, targetY, path);
        if (n > 0) {
            pathLen = n;
            pathPos = 0;
        } else if (n == 0) {
            pathLen = 0;
            pathPos = 0;
        } else {
            greedyStep(w, sx, sy);
        }
    }

    // one 4-neighbour step that reduces the distance to the target, if any
    function greedyStep(w:World, sx:Int, sy:Int):Void {
        pathLen = 0;
        pathPos = 0;
        var tx = targetX + 0.5;
        var ty = targetY + 0.5;
        var cx = sx + 0.5;
        var cy = sy + 0.5;
        var best = (tx - cx) * (tx - cx) + (ty - cy) * (ty - cy);
        var bx = sx;
        var by = sy;
        for (k in 0...4) {
            var nx = sx + (k == 0 ? 1 : (k == 1 ? -1 : 0));
            var ny = sy + (k == 2 ? 1 : (k == 3 ? -1 : 0));
            if (!Cells.walkable(w.cell(nx, ny))) continue;
            var ex = nx + 0.5;
            var ey = ny + 0.5;
            var dd = (tx - ex) * (tx - ex) + (ty - ey) * (ty - ey);
            if (dd < best) { best = dd; bx = nx; by = ny; }
        }
        if (bx != sx || by != sy) {
            path[0] = Cells.pack(bx, by);
            pathLen = 1;
        }
    }

    // advance `len` cells along the path, waypoint centre to waypoint centre, spending the whole frame's
    // length across several waypoints when one is reached mid-frame. A waypoint that is no longer walkable
    // (chunk evicted) or a step that makes no progress drops the path; the re-path comes REPATH_SOON later.
    function follow(w:World, len:Float):Void {
        moved = 0.0;
        var total = 0.0;
        var hops = 0;
        while (len > ARRIVE && pathPos < pathLen && hops < MAX_WAYPOINTS_PER_FRAME) {
            hops++;
            var wp = path[pathPos];
            var wx = Cells.unpackX(wp);
            var wy = Cells.unpackY(wp);
            if (!Cells.walkable(w.cell(wx, wy))) {
                dropPath();
                break;
            }
            var tx = wx + 0.5;
            var ty = wy + 0.5;
            var dx = tx - x;
            var dy = ty - y;
            var dd = Math.sqrt(dx * dx + dy * dy);
            if (dd <= ARRIVE) {
                pathPos++;
                continue;
            }
            var step = len < dd ? len : dd;
            stepToward(w, tx, ty, step);
            if (moved < ARRIVE * 0.5) {
                dropPath();                             // wedged: try another route
                break;
            }
            total += moved;
            len -= moved;
            var rx = tx - x;
            var ry = ty - y;
            if (rx * rx + ry * ry <= ARRIVE * ARRIVE) pathPos++;
        }
        moved = total;
        if (pathPos >= pathLen) { pathLen = 0; pathPos = 0; }
    }

    function dropPath():Void {
        pathLen = 0;
        pathPos = 0;
        if (repathTimer > REPATH_SOON) repathTimer = REPATH_SOON;
    }

    // random short paths near the current cell (DORMANT and LOST). One candidate per update() while
    // no path is held, so a frame never runs Path.bfs more than once: a candidate that is not a floor
    // cell costs nothing and is retried next frame; a BFS that finds no route waits WANDER_RETRY_SECS;
    // the 1.5-4 s pause starts only once a path (or the greedy fallback step) is in hand.
    function wander(d:Director, dt:Float, sp:Float):Void {
        var w = d.world;
        pickTimer -= dt;
        if (pathPos >= pathLen) {
            pathLen = 0;
            pathPos = 0;
            if (pickTimer <= 0.0) {
                var sx = Math.floor(x);
                var sy = Math.floor(y);
                var tx = sx + d.rng.range(-WANDER_RANGE, WANDER_RANGE + 1);
                var ty = sy + d.rng.range(-WANDER_RANGE, WANDER_RANGE + 1);
                var ok = !(tx == sx && ty == sy);
                if (ok) {
                    var c = w.cell(tx, ty);
                    ok = Cells.walkable(c) && Cells.type(c) != Cells.PIT;
                }
                if (ok) {
                    var n = Path.bfs(w, sx, sy, tx, ty, path);
                    if (n > 0) {
                        pathLen = n;
                        pathPos = 0;
                    } else if (n < 0) {
                        targetX = tx;
                        targetY = ty;
                        greedyStep(w, sx, sy);
                    }
                    pickTimer = pathLen > 0 ? 1.5 + d.rng.nextFloat() * 2.5 : WANDER_RETRY_SECS;
                }
            }
        }
        if (pathLen > 0) {
            follow(w, sp * dt);
            if (moved > 0.0) refresh(d);
        }
    }

    // slapping footsteps every STEP_LEN cells while chasing
    function footstep(d:Director):Void {
        stepAccum += moved;
        if (stepAccum >= STEP_LEN) {
            stepAccum -= STEP_LEN;
            if (stepAccum >= STEP_LEN) stepAccum = 0.0;
            stepEvent = true;
            d.events |= Director.EV_HOUND_STEP;
        }
    }
}
