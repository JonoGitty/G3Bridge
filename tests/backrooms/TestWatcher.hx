// Unit tests for Watcher (CONTRACT §1). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
// The Watcher is driven directly (watcher.update / relocate with a hand-set Director), so the
// Director's own spawn logic, blackouts and flicker never interfere; the Director supplies the
// geometry (view cone, line of sight, dead ends), the Rng and requestKill.
//   standalone: haxe -cp src/backrooms -cp stubs/sim -cp tests/backrooms -main TestWatcher --interp

import TestPlayer.SimGrid;

class TestWatcher {
    static var fails:Int = 0;
    static inline var DT = 0.05;

    static function check(name:String, ok:Bool):Void {
        Sys.println("  " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok) fails++;
    }

    static inline function absf(v:Float):Float return v < 0 ? -v : v;

    static function dist(a:Float, b:Float, c:Float, d:Float):Float {
        var dx = a - c, dy = b - d;
        return Math.sqrt(dx * dx + dy * dy);
    }

    // one entity frame with the Director's per-frame bookkeeping the entity expects
    static function tick(d:Director, w:Watcher):Void {
        d.events = 0;
        d.tapeTime += DT;
        w.update(DT, d);
    }

    // the 0.2 entity box never touches a solid cell (Entity's private BOX)
    static function boxClear(g:World, x:Float, y:Float):Bool {
        var r = 0.2;
        return !g.solid(Math.floor(x - r), Math.floor(y - r)) && !g.solid(Math.floor(x + r), Math.floor(y - r))
            && !g.solid(Math.floor(x - r), Math.floor(y + r)) && !g.solid(Math.floor(x + r), Math.floor(y + r));
    }

    public static function run():Int {
        fails = 0;
        var rng = new Rng(21);
        var tape = Tape.make(1, 1);

        // ------------------------------------------------------------------
        // (1) 1,000 relocations in a random maze: never in view, never solid, R +/- 1
        var m = SimGrid.maze(31, -40, -40, 80, 80, 0.25);
        var p = new Player(0.5, 0.5, 0.0);
        var d = new Director(m, p, tape);
        var w = d.watcher;
        var done = 0, tries = 0, inView = 0, solid = 0, badR = 0, onPlayer = 0, pits = 0, notFlagged = 0;
        var minSeen = 99.0, maxSeen = 0.0;
        while (done < 1000 && tries < 1400) {
            tries++;
            var cellP = m.randomWalkable(rng, 0, 0, 28);
            p.placeAt(Cells.unpackX(cellP) + 0.5, Cells.unpackY(cellP) + 0.5, rng.nextFloat() * Math.PI * 2.0);
            d.D = rng.nextFloat();
            d.noRelocateUntil = 0.0;
            w.spawnAt(p.x + 3.0, p.y);
            w.unseenSeconds = 0.0;
            var before = w.relocations;
            tick(d, w);                                 // refresh dist/inView (relocateTimer is 5 s after a spawn: no jump here)
            if (w.relocations != before) notFlagged++;
            if (!w.relocate(d, false)) continue;
            done++;
            if (!w.relocated || w.relocations != before + 1) notFlagged++;
            if (d.inViewCone(w.x, w.y)) inView++;
            var c = m.cell(Math.floor(w.x), Math.floor(w.y));
            if (Cells.solid(c) || !boxClear(m, w.x, w.y)) solid++;
            if (Cells.type(c) == Cells.PIT) pits++;
            var r = dist(w.x, w.y, p.x, p.y);
            if (r < w.targetRadius - 1.0 - 1e-9 || r > w.targetRadius + 1.0 + 1e-9) badR++;
            if (Math.floor(w.x) == p.cellX() && Math.floor(w.y) == p.cellY()) onPlayer++;
            if (r < minSeen) minSeen = r;
            if (r > maxSeen) maxSeen = r;
        }
        check("relocate: 1000 relocations found in " + tries + " tries", done == 1000);
        check("relocate: never lands in the view cone (" + inView + ")", inView == 0);
        check("relocate: never lands in or against a solid cell (" + solid + ")", solid == 0);
        check("relocate: never on the player's cell or a pit (" + onPlayer + ", " + pits + ")", onPlayer == 0 && pits == 0);
        check("relocate: distance within targetRadius +/- 1 (" + badR + " outside; seen " + minSeen + ".." + maxSeen + ")", badR == 0);
        check("relocate: relocated flag and counter on exactly the relocating call (" + notFlagged + ")", notFlagged == 0);
        check("relocate: targetRadius spans lerp(14, 4, D) (" + minSeen + ".." + maxSeen + ")", minSeen < 5.0 && maxSeen > 12.0);

        // ------------------------------------------------------------------
        // (2) a 30 s stare: in view within 8, timer expired, no flicker -> it does not move
        var room = new SimGrid(0, 0, 61, 61, Cells.FLOOR);
        room.border();
        p = new Player(30.5, 30.5, 0.0);
        d = new Director(room, p, tape);
        w = d.watcher;
        d.D = 0.5;                                      // R = 9 -> S_IDLE
        w.spawnAt(35.5, 30.5);                          // 5 cells dead ahead
        w.relocateTimer = 0.0;
        var moved = false, jumped = false, killed = false;
        var t = 0.0;
        while (t < 30.0) {
            tick(d, w);
            t += DT;
            if (w.x != 35.5 || w.y != 30.5) moved = true;
            if (w.relocated || (d.events & Director.EV_WATCHER_RELOCATED) != 0) jumped = true;
            if ((d.events & Director.EV_KILL) != 0) killed = true;
        }
        check("stare: in view within 8 for 30 s: zero movement", !moved);
        check("stare: no relocation, no event, no kill", !jumped && w.relocations == 0 && !killed);
        check("stare: inView, frozen state is S_IDLE, lookedAtSeconds > 1.5 (" + w.lookedAtSeconds + ")", w.inView && w.state == Watcher.S_IDLE && w.lookedAtSeconds > 1.5);
        check("stare: telegraph accumulated inside 10 cells -> canKill after 3 s", w.canKill() && w.telegraph >= Entity.TELEGRAPH_SECS);
        // stared at + a flicker -> it relocates, and never into view
        d.events = Director.EV_FLICKER;
        d.tapeTime += DT;
        w.update(DT, d);
        check("stare: relocates on the next EV_FLICKER (relocated=" + w.relocated + ")", w.relocated && w.relocations == 1 && (d.events & Director.EV_WATCHER_RELOCATED) != 0);
        check("stare: the flicker jump lands out of view at R +/- 1 (dist " + w.dist + ")", !d.inViewCone(w.x, w.y) && w.dist >= 8.0 - 1e-9 && w.dist <= 10.0 + 1e-9);
        check("stare: lookedAtSeconds reset by the jump", w.lookedAtSeconds == 0.0);
        // the relief valve after a lost Hound blocks relocation
        w.spawnAt(24.5, 30.5);                          // behind the player: out of view, not frozen
        w.relocateTimer = 0.0;
        d.noRelocateUntil = d.tapeTime + 45.0;
        var valveJumps = 0;
        for (i in 0...100) { tick(d, w); if (w.relocated) valveJumps++; }
        check("valve: no relocation while tapeTime < noRelocateUntil (" + valveJumps + ")", valveJumps == 0);
        d.noRelocateUntil = 0.0;
        tick(d, w);
        check("valve: relocates as soon as the valve lifts", w.relocated);

        // ------------------------------------------------------------------
        // (3) fairness: canKill false for the first 3 s inside 10 cells; decays when far
        p.placeAt(30.5, 30.5, 0.0);
        w.spawnAt(32.5, 30.5);
        var earlyKill = false;
        t = 0.0;
        while (t < 3.0 - 1e-9) {
            tick(d, w);
            t += DT;
            if (t < 3.0 - 1e-9 && w.canKill()) earlyKill = true;
        }
        check("fairness: canKill false throughout the first 3 s at 2 cells", !earlyKill);
        tick(d, w);
        check("fairness: canKill true after 3 s of cue (telegraph " + w.telegraph + ")", w.canKill());
        w.x = 46.5; w.y = 30.5;                         // 16 cells: no cue
        w.relocateTimer = 1000.0;                       // and no relocation back inside it
        for (i in 0...80) tick(d, w);                   // 4 s
        check("fairness: telegraph decays outside 10 cells (" + w.telegraph + ") -> canKill false", !w.canKill() && w.telegraph < 0.2);

        // contact under the fairness law: at D = 1 with the radius shrunk to 2 it walks in from behind and
        // may not kill before 3 s of telegraph; after that, contact kills through Director.requestKill
        d.D = 1.0;
        p.placeAt(30.5, 30.5, 0.0);
        w.spawnAt(24.5, 30.5);
        w.unseenSeconds = 21.0;                         // ignored for > 20 s: the next relocation shrinks R (3 -> 2)
        w.relocateTimer = 1000.0;
        w.relocate(d, false);
        check("approach: at D = 1 one unseen relocation takes R to 2 -> S_APPROACH (R " + w.targetRadius + ")", w.targetRadius == 2.0 && w.state == Watcher.S_APPROACH);
        w.x = 29.0; w.y = 30.5;                         // 1.5 cells directly behind (player faces +x)
        w.telegraph = 0.0;
        w.relocateTimer = 1000.0;
        t = 0.0;
        var killAt = -1.0;
        var contactAt = -1.0;
        var walkIn = 0.0;
        var dStart = dist(w.x, w.y, p.x, p.y);
        while (t < 6.0 && killAt < 0.0) {
            tick(d, w);
            t += DT;
            if (absf(t - 1.0) < 1e-9) walkIn = dStart - dist(w.x, w.y, p.x, p.y);
            if (contactAt < 0.0 && w.dist < 0.6) contactAt = t;
            if ((d.events & Director.EV_KILL) != 0) killAt = t;
        }
        check("approach: walks in at 0.6 cells/s while unseen (" + walkIn + " in 1 s)", absf(walkIn - 0.6) < 0.06);
        check("approach: contact at " + contactAt + " s, before the telegraph is complete", contactAt > 0.0 && contactAt < 3.0);
        check("approach: no kill before 3 s; kill at " + killAt + " s with killer K_WATCHER", killAt >= 3.0 && killAt < 3.2 && d.killer == Director.K_WATCHER);
        // frozen while approaching in view
        p.placeAt(30.5, 30.5, 0.0);
        w.x = 34.5; w.y = 30.5;                         // 4 cells ahead, in view
        var approachMoved = false;
        for (i in 0...100) { tick(d, w); if (w.x != 34.5 || w.y != 30.5) approachMoved = true; }
        check("approach: frozen while in view within 8 (5 s)", !approachMoved && w.state == Watcher.S_APPROACH);

        // ------------------------------------------------------------------
        // (4) closer = true (blackout): the new distance is strictly less than the old one
        p = new Player(0.5, 0.5, 0.0);
        d = new Director(m, p, tape);
        w = d.watcher;
        d.D = 0.5;
        var cdone = 0, ctries = 0, notCloser = 0, cInView = 0, cSolid = 0;
        while (cdone < 200 && ctries < 600) {
            ctries++;
            var cellP = m.randomWalkable(rng, 0, 0, 28);
            p.placeAt(Cells.unpackX(cellP) + 0.5, Cells.unpackY(cellP) + 0.5, rng.nextFloat() * Math.PI * 2.0);
            var cellW = m.randomWalkable(rng, p.cellX(), p.cellY(), 10);
            var wx = Cells.unpackX(cellW) + 0.5, wy = Cells.unpackY(cellW) + 0.5;
            if (dist(wx, wy, p.x, p.y) < 3.0) continue;
            w.spawnAt(wx, wy);
            w.unseenSeconds = 0.0;
            tick(d, w);
            var old = w.dist;
            if (!w.relocate(d, true)) continue;
            cdone++;
            if (!(w.dist < old - 1e-9)) notCloser++;
            if (d.inViewCone(w.x, w.y)) cInView++;
            if (m.solid(Math.floor(w.x), Math.floor(w.y))) cSolid++;
        }
        check("closer: 200 blackout relocations found in " + ctries + " tries", cdone == 200);
        check("closer: every one strictly nearer than before (" + notCloser + " not)", notCloser == 0);
        check("closer: still out of view and walkable (" + cInView + ", " + cSolid + ")", cInView == 0 && cSolid == 0);

        // ------------------------------------------------------------------
        // (5) timer: 4..9 s after a relocation, halved in DARK; unseen shrink one cell per relocation
        p.placeAt(0.5, 0.5, 0.0);
        m.clearAround(0, 0, 2);
        d.D = 0.2;                                      // R = 12
        var tMin = 99.0, tMax = 0.0, n = 0;
        p.onDark = false;
        for (i in 0...60) {
            w.spawnAt(3.5, 0.5);
            w.unseenSeconds = 0.0;
            tick(d, w);
            if (!w.relocate(d, false)) continue;
            n++;
            if (w.relocateTimer < tMin) tMin = w.relocateTimer;
            if (w.relocateTimer > tMax) tMax = w.relocateTimer;
        }
        check("timer: relocateTimer in 4..9 s after " + n + " relocations (" + tMin + ".." + tMax + ")", n > 30 && tMin >= 4.0 && tMax <= 9.0 && tMax > 6.0);
        p.onDark = true;
        tMin = 99.0; tMax = 0.0; n = 0;
        for (i in 0...60) {
            w.spawnAt(3.5, 0.5);
            w.unseenSeconds = 0.0;
            tick(d, w);
            if (!w.relocate(d, false)) continue;
            n++;
            if (w.relocateTimer < tMin) tMin = w.relocateTimer;
            if (w.relocateTimer > tMax) tMax = w.relocateTimer;
        }
        p.onDark = false;
        check("timer: halved in DARK, 2..4.5 s (" + tMin + ".." + tMax + ")", n > 30 && tMin >= 2.0 && tMax <= 4.5);
        w.spawnAt(3.5, 0.5);
        tick(d, w);
        var r0 = w.targetRadius;
        w.unseenSeconds = 25.0;
        w.relocate(d, false);
        var r1 = w.targetRadius;
        w.unseenSeconds = 25.0;
        w.relocate(d, false);
        check("shrink: unseen > 20 s takes one cell off R per relocation (" + r0 + " -> " + r1 + " -> " + w.targetRadius + ")", r1 == r0 - 1.0 && w.targetRadius == r0 - 2.0);
        w.spawnAt(3.5, 0.5);
        check("spawnAt: resets the shrink (R back to " + w.targetRadius + ")", true);
        tick(d, w);
        check("spawnAt: R back to lerp (" + w.targetRadius + ")", w.targetRadius == r0);
        // the shrink is per relocation: the ring is sampled at the shrunk radius, so the landing distance is
        // within the NEW R +/- 1 (the invariant of test 1 holds while shrinking too)
        var shrunkOk = 0, shrunkBad = 0;
        for (i in 0...20) {
            w.spawnAt(3.5, 0.5);
            tick(d, w);                                 // (3 cells ahead is in view: the unseen clock is set after the tick)
            w.unseenSeconds = 25.0;
            if (!w.relocate(d, false)) continue;
            shrunkOk++;
            var rr = dist(w.x, w.y, p.x, p.y);
            if (rr < w.targetRadius - 1.0 - 1e-9 || rr > w.targetRadius + 1.0 + 1e-9) shrunkBad++;
            if (w.targetRadius != r0 - 1.0) shrunkBad++;
        }
        check("shrink: a shrinking relocation lands within the shrunk R +/- 1 (" + shrunkBad + " bad of " + shrunkOk + ")", shrunkOk > 10 && shrunkBad == 0);

        // (5b) a FAILED attempt never shrinks R nor counts as a relocation: blackout `closer` at 1 cell has no ring
        // (maxR = dist - 1 < the 0.8 floor), and the 1 s retry loop while unseen must not creep in by itself
        w.spawnAt(-0.5, 0.5);                           // 1 cell behind the player (facing +x): out of view, unseen clock runs
        w.unseenSeconds = 25.0;
        tick(d, w);
        var rBefore = w.targetRadius;
        var nBefore = w.relocations;
        var failedOk = true;
        for (i in 0...5) if (w.relocate(d, true)) failedOk = false;
        check("failed closer x5 at 1 cell: all refused, R unchanged (" + rBefore + " -> " + w.targetRadius + "), relocations unchanged",
            failedOk && w.targetRadius == rBefore && w.relocations == nBefore && w.unseenSeconds > 20.0);
        // a walled-in post: the timer retries every second and none of the failures shrinks R
        var box = new SimGrid(0, 0, 9, 9, Cells.WALL);
        box.setCell(4, 4, Cells.FLOOR);
        box.setCell(5, 4, Cells.FLOOR);
        var bp = new Player(4.5, 4.5, Math.PI);         // facing -x: the Watcher at 5.5 is behind, out of view
        var bd = new Director(box, bp, tape);
        var bw = bd.watcher;
        bd.D = 0.5;                                     // R = 9: no walkable cell in 8..10
        bw.spawnAt(5.5, 4.5);
        bw.unseenSeconds = 25.0;
        bw.relocateTimer = 0.0;
        var boxRel = 0;
        for (i in 0...200) { bd.events = 0; bd.tapeTime += DT; bw.unseenSeconds = 25.0; bw.update(DT, bd); if (bw.relocated) boxRel++; }   // 10 s: ~10 failed timer attempts
        check("walled in for 10 s unseen: no relocation (" + boxRel + ") and R still " + bw.targetRadius + " (no shrink on failed attempts)", boxRel == 0 && bw.relocations == 0 && bw.targetRadius == 9.0);

        // (5c) radiusAt: the one reading of "lerp(14, 4, D), floor 3 at D > 0.9", shared with the Director
        check("radiusAt: 14 at D 0, 9 at 0.5, 5 at 0.9, 3 above 0.9, clamped outside 0..1",
            Watcher.radiusAt(0.0) == 14.0 && Watcher.radiusAt(0.5) == 9.0 && absf(Watcher.radiusAt(0.9) - 5.0) < 1e-9
            && Watcher.radiusAt(0.95) == 3.0 && Watcher.radiusAt(1.0) == 3.0 && Watcher.radiusAt(-1.0) == 14.0 && Watcher.radiusAt(2.0) == 3.0);
        w.spawnAt(3.5, 0.5);
        d.D = 0.95;
        tick(d, w);
        check("targetRadius follows radiusAt at D 0.95 (" + w.targetRadius + "), still S_IDLE above the approach threshold", w.targetRadius == 3.0 && w.state == Watcher.S_IDLE);
        d.D = 0.2;

        // (6) not alive: a cheap no-op that never relocates or kills
        w.despawn();
        d.events = 0;
        w.relocateTimer = 0.0;
        w.update(DT, d);
        check("despawned: no relocation, no events, dist 99", !w.relocated && d.events == 0 && w.dist == 99.0 && !w.canKill());
        check("despawned: relocate() refuses", !w.relocate(d, false));

        return fails;
    }

    public static function main():Void {
        var f = run();
        Sys.println("TestWatcher: " + (f == 0 ? "pass" : f + " failed"));
        if (f > 0) Sys.exit(1);
    }
}
