// The stalker (CONTRACT §1, DESIGN §5). Core class: no flash.* imports.
//
// Lives at a post targetRadius cells from the player and relocates every 4-9 s to a
// walkable cell in the R +/- 1 annulus that is NOT in the view cone, preferring dead ends
// aligned with the facing so that when the player turns, it is there. Frozen while in view
// within 8 cells. Ignored for > 20 s it creeps closer one cell per relocation; at R <= 2 it
// walks in and kills on contact, subject to the fairness law (Entity.canKill).
class Watcher extends Entity {
    public static inline var S_IDLE = 0;                // standing at its post
    public static inline var S_APPROACH = 1;            // R <= 2, walking in at 0.6 cells/s
    // private tuning
    static inline var FREEZE_DIST = 8.0;                // no movement while in view within this
    static inline var CUE_DIST = 10.0;                  // telegraph accumulates inside this
    static inline var CONTACT = 0.6;
    static inline var APPROACH_SPEED = 0.6;             // cells/s
    static inline var APPROACH_R = 2.0;                 // targetRadius at or below this -> S_APPROACH
    static inline var LOOK_ANG = 0.17453292519943295;   // 10 deg: "looked at"
    static inline var LOOK_SECS = 1.5;
    static inline var ALIGN_ANG = 0.5235987755982988;   // 30 deg: post aligned with the facing
    static inline var UNSEEN_SHRINK_SECS = 20.0;
    static inline var SAMPLES = 64;                     // candidate cells per relocate (budget: no BFS)
    static inline var RETRY_SECS = 1.0;                 // after a failed relocation
    static inline var TWO_PI = 6.283185307179586;

    public var targetRadius:Float;                      // R = lerp(14, 4, d.D), minus the unseen shrink, floor 3 at D > 0.9
    public var relocateTimer:Float;                     // counts down; relocation when <= 0 (4..9 s, halved in DARK)
    public var unseenSeconds:Float;
    public var lookedAtSeconds:Float;                   // within 10 deg of centre
    public var relocations:Int;
    public var relocated:Bool;                          // true for exactly the update() in which it relocated

    var shrink:Float;                                   // cells taken off the radius by being ignored

    public function new():Void {
        super(Entity.K_WATCHER);
        height = 0.95;
        width = 0.45;
        targetRadius = 14.0;
        relocateTimer = 0.0;
        unseenSeconds = 0.0;
        lookedAtSeconds = 0.0;
        relocations = 0;
        relocated = false;
        shrink = 0.0;
    }

    override public function spawnAt(x:Float, y:Float):Void {
        super.spawnAt(x, y);
        state = S_IDLE;
        relocateTimer = 5.0;
        unseenSeconds = 0.0;
        lookedAtSeconds = 0.0;
        relocated = false;
        shrink = 0.0;
    }

    override public function update(dt:Float, d:Director):Void {
        super.update(dt, d);
        relocated = false;
        if (!alive) return;

        updateRadius(d);

        // fairness clock: the presence loops / grain / hum cues are active inside CUE_DIST
        tickTelegraph(dt, dist < CUE_DIST);

        // seen / stared at
        if (inView) {
            unseenSeconds = 0.0;
            var ab = bearing < 0.0 ? -bearing : bearing;
            if (ab <= LOOK_ANG) lookedAtSeconds += dt; else lookedAtSeconds = 0.0;
        } else {
            unseenSeconds += dt;
            lookedAtSeconds = 0.0;
        }

        var frozen = inView && dist <= FREEZE_DIST;
        var valve = d.tapeTime < d.noRelocateUntil;     // relief valve after a lost Hound
        relocateTimer -= dt;

        // relocation: stared at -> on the next flicker; otherwise on the timer, never while frozen
        var jumped = false;
        if (!valve) {
            if (lookedAtSeconds > LOOK_SECS && (d.events & Director.EV_FLICKER) != 0) {
                jumped = relocate(d, false);
                if (jumped) lookedAtSeconds = 0.0;
            } else if (relocateTimer <= 0.0 && !frozen) {
                jumped = relocate(d, false);
                if (!jumped) relocateTimer = RETRY_SECS;
            }
        }
        if (jumped) d.events |= Director.EV_WATCHER_RELOCATED;

        // the walk-in
        if (state == S_APPROACH && !jumped && !frozen) {
            var p = d.player;
            stepToward(d.world, p.x, p.y, APPROACH_SPEED * dt);
            if (moved > 0.0) refresh(d);
        }

        // contact
        if (dist < CONTACT && canKill()) d.requestKill(Entity.K_WATCHER);

        frame = state;
    }

    // choose and move to a new post: a walkable cell at distance targetRadius +/- 1 not in view, preferring dead ends / corridor ends
    // aligned with the facing +/- 30 deg; closer = true forces distance <= current dist - 1 (blackout). Returns false if none found (stays).
    public function relocate(d:Director, closer:Bool):Bool {
        if (!alive) return false;
        var p = d.player;
        var w = d.world;
        var rng = d.rng;

        // being ignored: one cell closer per RELOCATION (never per attempt), so the ring is
        // sampled prospectively at the radius the post will have, and the shrink is committed
        // only once a post is found
        var nextShrink = shrink;
        if (unseenSeconds > UNSEEN_SHRINK_SECS) nextShrink += 1.0;
        var ringR = radiusFor(d.D, nextShrink);

        var minR = ringR - 1.0;
        var maxR = ringR + 1.0;
        if (closer) {
            var cap = dist - 1.0;
            if (maxR > cap) maxR = cap;
            if (minR > maxR - 1.0) minR = maxR - 1.0;
        }
        if (minR < 0.8) minR = 0.8;                     // never on top of the player
        if (maxR < minR) return false;

        var px = p.x;
        var py = p.y;
        var pcx = p.cellX();
        var pcy = p.cellY();
        var best = -1;
        var bestX = 0;
        var bestY = 0;
        var a0 = rng.nextFloat() * TWO_PI;
        var da = TWO_PI / SAMPLES;
        var span = maxR - minR;
        for (i in 0...SAMPLES) {
            var a = a0 + i * da;
            var r = minR + span * rng.nextFloat();
            var cx = Math.floor(px + Math.cos(a) * r);
            var cy = Math.floor(py + Math.sin(a) * r);
            if (cx == pcx && cy == pcy) continue;
            var c = w.cell(cx, cy);
            if (!Cells.walkable(c)) continue;
            if (Cells.type(c) == Cells.PIT) continue;
            var ex = cx + 0.5;
            var ey = cy + 0.5;
            var ddx = ex - px;
            var ddy = ey - py;
            var dd = Math.sqrt(ddx * ddx + ddy * ddy);
            if (dd < minR || dd > maxR) continue;
            if (d.inViewCone(ex, ey)) continue;
            var score = 1;
            if (d.isDeadEnd(cx, cy)) score += 2;
            var b = d.bearingTo(ex, ey);
            if (b < 0.0) b = -b;
            if (b <= ALIGN_ANG) score += 1;
            if (score > best) {
                best = score;
                bestX = cx;
                bestY = cy;
                if (best >= 4) break;                   // a dead end ahead: nothing beats it
            }
        }
        if (best < 0) return false;

        shrink = nextShrink;
        updateRadius(d);
        x = bestX + 0.5;
        y = bestY + 0.5;
        relocations++;
        relocated = true;
        refresh(d);
        var wait = 4.0 + rng.nextFloat() * 5.0;
        if (p.onDark) wait *= 0.5;
        relocateTimer = wait;
        return true;
    }

    // The one reading of "R = lerp(14, 4, D), floor 3 at D > 0.9" (CONTRACT §1): the post radius
    // BEFORE the unseen shrink, as a function of D alone. Above D = 0.9 the radius is pinned at 3
    // (the endgame milestone of DESIGN §5; a max(r, 3) floor would be a no-op since the lerp never
    // drops below 4). The Watcher is the authority: Director.watcherRadius should return this.
    public static function radiusAt(D:Float):Float {
        if (D < 0.0) D = 0.0;
        if (D > 1.0) D = 1.0;
        if (D > 0.9) return 3.0;
        return 14.0 + (4.0 - 14.0) * D;
    }

    // radiusAt minus a given shrink, never below the approach threshold (pure: writes nothing)
    static function radiusFor(D:Float, s:Float):Float {
        var r = radiusAt(D) - s;
        if (r < APPROACH_R) r = APPROACH_R;
        return r;
    }

    // targetRadius / state from D and the committed shrink
    function updateRadius(d:Director):Void {
        var r = radiusFor(d.D, shrink);
        targetRadius = r;
        state = r <= APPROACH_R ? S_APPROACH : S_IDLE;
    }
}
