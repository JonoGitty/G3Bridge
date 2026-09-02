// Unit tests for Hound (CONTRACT §1). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
// The Hound is driven directly (hound.update / hear with a hand-set Director) so the Director's
// own spawn logic never interferes; the Director supplies the geometry, the Rng and requestKill.
// Path.bfs is whatever the build provides (the real BFS, or the stub that reports unreachable, in
// which case the Hound's greedy fallback moves it): every check here holds under both.
//   standalone: haxe -cp src/backrooms -cp stubs/sim -cp tests/backrooms -main TestHound --interp

import TestPlayer.SimGrid;

class TestHound {
    static var fails:Int = 0;
    static inline var DT = 0.05;

    static function check(name:String, ok:Bool):Void {
        Sys.println("  " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok) fails++;
    }

    static inline function absf(v:Float):Float return v < 0 ? -v : v;

    static function tick(d:Director, h:Hound):Void {
        d.events = 0;
        d.tapeTime += DT;
        h.update(DT, d);
    }

    // the 0.2 entity box never touches a solid cell (Entity's private BOX)
    static function boxClear(g:World, x:Float, y:Float):Bool {
        var r = 0.2;
        return !g.solid(Math.floor(x - r), Math.floor(y - r)) && !g.solid(Math.floor(x + r), Math.floor(y - r))
            && !g.solid(Math.floor(x - r), Math.floor(y + r)) && !g.solid(Math.floor(x + r), Math.floor(y + r));
    }

    public static function run():Int {
        fails = 0;
        var tape = Tape.make(1, 1);

        // ------------------------------------------------------------------
        // (1) HOWL: hearing from DORMANT starts a 2..3 s howl with zero movement; canKill false inside 3 s
        var room = new SimGrid(0, 0, 61, 61, Cells.FLOOR);
        room.border();
        var p = new Player(30.5, 30.5, 0.0);
        var d = new Director(room, p, tape);
        var h = d.hound;
        h.spawnAt(38.5, 30.5);                          // 8 cells ahead, in view
        tick(d, h);
        check("spawn: DORMANT, alive, not lethal", h.state == Hound.S_DORMANT && h.alive && !h.canKill());
        d.events = 0;
        var heard = h.hear(p.cellX(), p.cellY(), Hound.HEAR_WALK);
        check("hear: within HEAR_WALK -> reacted, DORMANT -> HOWL, EV_HOWL, howlTimer in 2..3 (" + h.howlTimer + ")",
            heard && h.state == Hound.S_HOWL && (d.events & Director.EV_HOWL) != 0 && h.howlTimer >= 2.0 && h.howlTimer <= 3.0);
        check("hear: target is the player's cell", h.targetX == 30 && h.targetY == 30);
        var howlSecs = 0.0;
        var howlMoved = false;
        var hx = h.x, hy = h.y;                         // where the howl started (a dormant Hound wanders, so not the spawn point)
        var earlyKill = false;
        var t = 0.0;
        while (h.state == Hound.S_HOWL && howlSecs < 5.0) {
            tick(d, h);
            t += DT;
            howlSecs += DT;
            if (h.x != hx || h.y != hy) howlMoved = true;
            if (t < 3.0 - 1e-9 && h.canKill()) earlyKill = true;
        }
        check("howl: no movement during the howl", !howlMoved);
        check("howl: lasted " + howlSecs + " s (>= 2, <= 3 + dt) then CHASE", howlSecs >= 2.0 - 1e-9 && howlSecs <= 3.0 + DT + 1e-9 && h.state == Hound.S_CHASE);
        while (t < 3.0 - 1e-9) {
            tick(d, h);
            t += DT;
            if (t < 3.0 - 1e-9 && h.canKill()) earlyKill = true;
        }
        check("fairness: canKill false throughout the first 3 s after the hear", !earlyKill);
        tick(d, h);
        check("fairness: canKill true after 3 s (telegraph " + h.telegraph + ")", h.canKill());

        // ------------------------------------------------------------------
        // (2) LOST after LOSE_SECS with no sight and no sound; then DORMANT after WANDER_SECS
        var split = new SimGrid(0, 0, 41, 41, Cells.FLOOR);
        split.border();
        for (y in 0...41) split.setCell(20, y, Cells.WALL);     // a full wall: no line of sight, no route
        p = new Player(10.5, 20.5, Math.PI);            // facing away, on the west side
        d = new Director(split, p, tape);
        h = d.hound;
        h.spawnAt(30.5, 20.5);                          // east side, 20 cells
        tick(d, h);
        h.hear(p.cellX(), p.cellY(), 99.0);
        check("lost: heard at 20 cells with a big radius -> HOWL", h.state == Hound.S_HOWL);
        while (h.state == Hound.S_HOWL) tick(d, h);
        var chaseSecs = 0.0;
        var lostEvent = false;
        var leftFloor = 0;
        var chased = 0.0;
        var hx0 = h.x;
        while (h.state == Hound.S_CHASE && chaseSecs < 20.0) {
            tick(d, h);
            chaseSecs += DT;
            if (!boxClear(split, h.x, h.y)) leftFloor++;
            if ((d.events & Director.EV_HOUND_LOST) != 0) lostEvent = true;
        }
        chased = hx0 - h.x;
        check("lost: CHASE moved it toward the last-heard cell (" + chased + " cells west) without crossing the wall", chased > 1.0 && h.x > 21.0 && leftFloor == 0);
        check("lost: LOST after " + chaseSecs + " s of chase without sight or sound (LOSE_SECS 6)", h.state == Hound.S_LOST && absf(chaseSecs - Hound.LOSE_SECS) <= DT + 1e-9);
        check("lost: EV_HOUND_LOST raised on that update", lostEvent);
        check("lost: relief valve set 45 s ahead (" + (d.noRelocateUntil - d.tapeTime) + ")", absf((d.noRelocateUntil - d.tapeTime) - 45.0) < 1e-6);
        var wanderSecs = 0.0;
        var wanderMoved = 0.0;
        while (h.state == Hound.S_LOST && wanderSecs < 40.0) {
            var ox = h.x, oy = h.y;
            tick(d, h);
            wanderSecs += DT;
            var dx = h.x - ox, dy = h.y - oy;
            wanderMoved += Math.sqrt(dx * dx + dy * dy);
            if (!boxClear(split, h.x, h.y)) leftFloor++;
        }
        check("lost: wanders (" + wanderMoved + " cells) then DORMANT after " + wanderSecs + " s (WANDER_SECS 30)", h.state == Hound.S_DORMANT && absf(wanderSecs - Hound.WANDER_SECS) <= DT + 1e-9);
        check("lost: never left the floor while wandering (" + leftFloor + ")", leftFloor == 0);
        check("lost: telegraph decayed to 0 while lost/dormant", h.telegraph == 0.0 && !h.canKill());
        // LOST -> CHASE on a new sound
        h.state = Hound.S_LOST;
        h.hear(p.cellX(), p.cellY(), 99.0);
        check("hear: LOST -> CHASE", h.state == Hound.S_CHASE && h.silentSeconds == 0.0);
        h.chaseSeconds = 0.0;
        h.silentSeconds = 0.0;
        // sight resets the silence: pull the wall down and look at it
        for (y in 0...41) split.setCell(20, y, Cells.FLOOR);
        h.x = 14.5; h.y = 20.5;                         // 4 cells east of the player, who faces west: not in the cone, but LOS within 10
        p.placeAt(10.5, 20.5, Math.PI);
        for (i in 0...160) tick(d, h);                  // 8 s > LOSE_SECS
        check("sight: with a clear line within 10 cells it keeps the chase (state " + h.state + ")", h.state == Hound.S_CHASE);

        // ------------------------------------------------------------------
        // (3) contact under the fairness law: no kill before 3 s after the hear, a kill after
        p = new Player(30.5, 30.5, 0.0);
        d = new Director(room, p, tape);
        h = d.hound;
        h.spawnAt(30.8, 30.5);                          // 0.3 cells: in contact from the start
        tick(d, h);
        h.hear(p.cellX(), p.cellY(), Hound.HEAR_WALK);
        t = 0.0;
        var killAt = -1.0;
        while (t < 6.0 && killAt < 0.0) {
            tick(d, h);
            t += DT;
            if ((d.events & Director.EV_KILL) != 0) killAt = t;
        }
        check("contact: in contact throughout (dist " + h.dist + ")", h.dist < 0.6);
        check("contact: no kill before 3 s; kill at " + killAt + " s with killer K_HOUND", killAt >= 3.0 && killAt < 3.2 && d.killer == Director.K_HOUND);

        // ------------------------------------------------------------------
        // (4) hearing radius scales with d.hearingMul (1.5 in DARK); out of range = no reaction
        h.spawnAt(42.5, 30.5);                          // 12 cells
        tick(d, h);
        d.hearingMul = 1.0;
        var far = h.hear(p.cellX(), p.cellY(), Hound.HEAR_WALK);
        check("hear: 12 cells > HEAR_WALK 10 -> no reaction, still DORMANT", !far && h.state == Hound.S_DORMANT);
        d.hearingMul = 1.5;
        var dark = h.hear(p.cellX(), p.cellY(), Hound.HEAR_WALK);
        check("hear: x1.5 in DARK -> 12 <= 15 reacts, HOWL", dark && h.state == Hound.S_HOWL);
        d.hearingMul = 1.0;
        h.despawn();
        check("hear: a despawned Hound never reacts", !h.hear(p.cellX(), p.cellY(), 99.0) && !h.canKill());

        // (4b) hear() before any update() (Director.forceSpawnHound on a Hound that has never seen a Director):
        // it howls provisionally, and the first update() rolls the real length from the Director's rng and raises EV_HOWL
        var d0 = new Director(room, p, tape);
        var h0 = d0.hound;
        h0.spawnAt(38.5, 30.5);
        d0.events = 0;
        var pre = h0.hear(p.cellX(), p.cellY(), 99.0);
        check("hear before update: reacts, DORMANT -> HOWL, howlTimer provisional in 2..3 (" + h0.howlTimer + ")", pre && h0.state == Hound.S_HOWL && h0.howlTimer >= 2.0 && h0.howlTimer <= 3.0);
        tick(d0, h0);
        check("hear before update: the first update raises EV_HOWL and keeps a 2..3 s howl (" + h0.howlTimer + ")",
            (d0.events & Director.EV_HOWL) != 0 && h0.state == Hound.S_HOWL && h0.howlTimer >= 2.0 - DT - 1e-9 && h0.howlTimer <= 3.0 - DT + 1e-9);
        var again = 0;
        for (i in 0...10) { tick(d0, h0); if ((d0.events & Director.EV_HOWL) != 0) again++; }
        check("hear before update: EV_HOWL not repeated on later frames (" + again + ")", again == 0 && h0.state == Hound.S_HOWL);
        // spawnAt clears a pending howl that never got its update
        var d1 = new Director(room, p, tape);
        var h1 = d1.hound;
        h1.spawnAt(38.5, 30.5);
        h1.hear(p.cellX(), p.cellY(), 99.0);
        h1.spawnAt(38.5, 30.5);                         // re-spawned before any update: DORMANT again
        tick(d1, h1);
        check("hear before update: a re-spawn drops the pending howl (state " + h1.state + ", events " + d1.events + ")", h1.state == Hound.S_DORMANT && (d1.events & Director.EV_HOWL) == 0);

        // ------------------------------------------------------------------
        // (5) chase speed: CHASE_MUL x WALK for STAMINA_SECS, TIRED_MUL after; footsteps every 0.5 cells
        p.placeAt(30.5, 30.5, Math.PI);                 // facing west
        h.spawnAt(55.5, 30.5);                          // 25 cells east, behind, a straight run of floor
        tick(d, h);
        h.x = 55.5; h.y = 30.5; h.pathLen = 0; h.pathPos = 0;   // undo the dormant wander step so the chase is a straight line
        h.hear(p.cellX(), p.cellY(), 99.0);
        while (h.state == Hound.S_HOWL) tick(d, h);
        var x0 = h.x;
        var steps = 0;
        var noise = 0.0;                                // the player keeps making sounds every second, so the chase never lapses
        for (i in 0...20) { tick(d, h); if (h.stepEvent) steps++; }          // 1 s of chase
        var v1 = (x0 - h.x) / 1.0;
        check("chase: fresh chase runs at CHASE_MUL x WALK (" + v1 + " cells/s)", absf(v1 - Player.WALK * Hound.CHASE_MUL) < 0.03 && absf(h.y - 30.5) < 1e-6);
        check("chase: footsteps about every 0.5 cells in the first second (" + steps + ")", steps >= 1 && steps <= 3);
        while (h.chaseSeconds < Hound.STAMINA_SECS + DT && h.state == Hound.S_CHASE) {
            tick(d, h);
            noise += DT;
            if (noise >= 1.0) { noise = 0.0; h.hear(p.cellX(), p.cellY(), 99.0); }
        }
        check("chase: still chasing at " + h.chaseSeconds + " s (heard every second)", h.state == Hound.S_CHASE);
        x0 = h.x;
        for (i in 0...20) tick(d, h);
        var v2 = (x0 - h.x) / 1.0;
        check("chase: tired after STAMINA_SECS -> TIRED_MUL x WALK (" + v2 + " cells/s)", absf(v2 - Player.WALK * Hound.TIRED_MUL) < 0.03);
        check("chase: chaseSeconds counted (" + h.chaseSeconds + ")", h.chaseSeconds > Hound.STAMINA_SECS + 1.0);
        check("chase: path cells are packed world cells (Cells.pack)", h.pathLen == 0 || (Cells.unpackY(h.path[0]) == 30 && Cells.unpackX(h.path[0]) < 56));

        // ------------------------------------------------------------------
        // (6) ten minutes of chase in a random maze with a random-walking player: never off the floor,
        //     never a teleport, never a move during a howl
        var m = SimGrid.maze(41, -40, -40, 80, 80, 0.25);
        m.clearAround(0, 0, 1);
        var rng = new Rng(9);
        p = new Player(0.5, 0.5, 0.0);
        d = new Director(m, p, tape);
        h = d.hound;
        var hc = m.randomWalkable(rng, 0, 0, 6);
        h.spawnAt(Cells.unpackX(hc) + 0.5, Cells.unpackY(hc) + 0.5);
        var offFloor = 0, teleports = 0, howlMoves = 0, frames = 0, kills = 0;
        var howls = 0, losts = 0, chaseFrames = 0, moveFrames = 0;
        var maxStep = Player.WALK * Hound.CHASE_MUL * DT + 1e-6;
        var fwd = 1, turn = 0, run = false;
        var pick = 0.0;
        var prev = h.state;
        var wake = 0.0;
        t = 0.0;
        while (t < 600.0) {
            pick -= DT;
            if (pick <= 0.0) { pick = 0.3 + rng.nextFloat() * 1.2; fwd = rng.range(-1, 2); turn = rng.range(-1, 2); run = rng.chance(0.3); }
            var pe = p.update(DT, fwd, turn, 0, run, m);
            var ox = h.x, oy = h.y;
            tick(d, h);
            t += DT;
            frames++;
            // what the Director does with the player's footsteps
            if ((pe & Player.PE_STEP_WET) != 0) h.hear(p.cellX(), p.cellY(), Hound.HEAR_SPLASH);
            else if ((pe & Player.PE_STEP) != 0) h.hear(p.cellX(), p.cellY(), p.running ? Hound.HEAR_RUN : Hound.HEAR_WALK);
            wake -= DT;
            if (wake <= 0.0) { wake = 20.0; if (h.state == Hound.S_DORMANT) h.hear(p.cellX(), p.cellY(), 99.0); }
            var dx = h.x - ox, dy = h.y - oy;
            var st = Math.sqrt(dx * dx + dy * dy);
            if (st > maxStep) teleports++;
            if (st > 0.0) moveFrames++;
            if (!boxClear(m, h.x, h.y) || m.solid(Math.floor(h.x), Math.floor(h.y))) offFloor++;
            if (prev == Hound.S_HOWL && h.state == Hound.S_HOWL && st > 0.0) howlMoves++;
            if (h.state == Hound.S_HOWL && prev != Hound.S_HOWL) howls++;
            if (h.state == Hound.S_LOST && prev != Hound.S_LOST) losts++;
            if (h.state == Hound.S_CHASE) chaseFrames++;
            if ((d.events & Director.EV_KILL) != 0) {
                // the tape would end here: put a fresh dormant Hound somewhere else, as the next tape does
                kills++;
                d.events = 0;
                var rc = m.randomWalkable(rng, p.cellX(), p.cellY(), 20);
                h.spawnAt(Cells.unpackX(rc) + 0.5, Cells.unpackY(rc) + 0.5);
                prev = h.state;
                continue;
            }
            prev = h.state;
        }
        check("soak: 10 min / " + frames + " frames: never off the floor (" + offFloor + ")", offFloor == 0);
        check("soak: no step above chase speed x dt (" + teleports + ")", teleports == 0);
        check("soak: no movement in any howl frame (" + howlMoves + ")", howlMoves == 0);
        check("soak: it hunted: " + howls + " howls, " + losts + " losses, " + chaseFrames + " chase frames, " + moveFrames + " moving frames, " + kills + " kills",
            howls >= 3 && kills >= 1 && chaseFrames > 200 && moveFrames > 500);
        check("soak: the player stayed on the floor too", !m.solid(p.cellX(), p.cellY()));

        return fails;
    }

    public static function main():Void {
        var f = run();
        Sys.println("TestHound: " + (f == 0 ? "pass" : f + " failed"));
        if (f > 0) Sys.exit(1);
    }
}
