// Base class for the two dangers (CONTRACT §1, DESIGN §5). Core class: no flash.* imports.
//
// Holds everything both dangers share: the per-frame refresh of dist / bearing / inView
// through the Director, the fairness-law telegraph clock (canKill() is false until the
// entity has spent TELEGRAPH_SECS with its audio+picture cues active), and a small
// axis-separated box mover so subclasses never step into a solid cell.
class Entity {
    public static inline var K_WATCHER = 1;
    public static inline var K_HOUND = 2;
    public static inline var TELEGRAPH_SECS = 3.0;
    // the telegraph clock never runs away: a cue that has been active for a minute is
    // still "fully telegraphed" and decays back below the threshold in a few seconds
    static inline var TELEGRAPH_CAP = 8.0;
    // collision box half-size for entity movement (smaller than the player's 0.22 so a
    // cell-centre-to-cell-centre step between two walkable cells never touches a third)
    static inline var BOX = 0.2;

    public var kind:Int;
    public var alive:Bool;                              // false = not spawned / despawned; update() is still called (cheap no-op)
    public var x:Float;
    public var y:Float;
    public var state:Int;                               // subclass constants
    public var frame:Int;                               // sprite frame index
    public var dist:Float;                              // to the player, updated each update()
    public var bearing:Float;                           // relative to the player's facing, (-pi, pi]
    public var inView:Bool;                             // inside the view cone AND line of sight, updated each update()
    public var telegraph:Float;                         // seconds of active audio+picture cue accumulated (decays at 1/s when inactive)
    public var height:Float;                            // sprite height in cells (Watcher 0.95, Hound 0.45)
    public var width:Float;                             // sprite width in cells

    // scratch for the last move: how far the entity actually travelled (cells)
    var moved:Float;

    public function new(kind:Int):Void {
        this.kind = kind;
        alive = false;
        x = 0.0;
        y = 0.0;
        state = 0;
        frame = 0;
        dist = 99.0;
        bearing = 0.0;
        inView = false;
        telegraph = 0.0;
        height = kind == K_HOUND ? 0.45 : 0.95;
        width = kind == K_HOUND ? 0.7 : 0.45;           // low and wide vs tall and thin
        moved = 0.0;
    }

    // alive && telegraph >= TELEGRAPH_SECS — the fairness law (DESIGN §5)
    public function canKill():Bool {
        return alive && telegraph >= TELEGRAPH_SECS;
    }

    // base: refresh dist/bearing/inView via d; subclasses call super first
    public function update(dt:Float, d:Director):Void {
        moved = 0.0;
        if (!alive) {
            dist = 99.0;
            bearing = 0.0;
            inView = false;
            if (telegraph > 0.0) {
                telegraph -= dt;
                if (telegraph < 0.0) telegraph = 0.0;
            }
            return;
        }
        refresh(d);
    }

    // alive = true, telegraph = 0, state = initial
    public function spawnAt(x:Float, y:Float):Void {
        this.x = x;
        this.y = y;
        alive = true;
        telegraph = 0.0;
        state = 0;
        frame = 0;
        dist = 99.0;
        bearing = 0.0;
        inView = false;
        moved = 0.0;
    }

    public function despawn():Void {
        alive = false;
        inView = false;
        dist = 99.0;
        telegraph = 0.0;
    }

    // ---- shared helpers for the subclasses ----

    // dist / bearing / inView relative to the player, through the Director's geometry
    function refresh(d:Director):Void {
        var p = d.player;
        var dx = x - p.x;
        var dy = y - p.y;
        dist = Math.sqrt(dx * dx + dy * dy);
        bearing = d.bearingTo(x, y);
        inView = d.inViewCone(x, y);
    }

    // the telegraph clock: accumulates while the cue is active, decays at 1/s otherwise
    function tickTelegraph(dt:Float, active:Bool):Void {
        if (active) {
            telegraph += dt;
            if (telegraph > TELEGRAPH_CAP) telegraph = TELEGRAPH_CAP;
        } else if (telegraph > 0.0) {
            telegraph -= dt;
            if (telegraph < 0.0) telegraph = 0.0;
        }
    }

    // true when a BOX-radius box centred at (cx, cy) touches no solid cell
    function fits(world:World, cx:Float, cy:Float):Bool {
        var x0 = Math.floor(cx - BOX);
        var x1 = Math.floor(cx + BOX);
        var y0 = Math.floor(cy - BOX);
        var y1 = Math.floor(cy + BOX);
        if (world.solid(x0, y0)) return false;
        if (world.solid(x1, y0)) return false;
        if (world.solid(x0, y1)) return false;
        if (world.solid(x1, y1)) return false;
        return true;
    }

    // move by (dx, dy), x then y, each axis rejected if the box would land in a solid cell (slide).
    // Sets `moved` to the distance actually travelled. An entity that is already embedded in a
    // solid cell (placed there by a caller, or a chunk regenerated under it) cannot be made worse:
    // it moves freely, so a walk toward a walkable cell centre always gets it out.
    function slide(world:World, dx:Float, dy:Float):Void {
        var ox = x;
        var oy = y;
        var free = !fits(world, x, y);
        if (dx != 0.0) {
            var nx = x + dx;
            if (free || fits(world, nx, y)) x = nx;
        }
        if (dy != 0.0) {
            var ny = y + dy;
            if (free || fits(world, x, ny)) y = ny;
        }
        var mx = x - ox;
        var my = y - oy;
        moved = Math.sqrt(mx * mx + my * my);
    }

    // step `len` cells toward (tx, ty) without overshooting; sliding along walls
    function stepToward(world:World, tx:Float, ty:Float, len:Float):Void {
        var dx = tx - x;
        var dy = ty - y;
        var dd = Math.sqrt(dx * dx + dy * dy);
        if (dd < 1e-9) { moved = 0.0; return; }
        if (len > dd) len = dd;
        var k = len / dd;
        slide(world, dx * k, dy * k);
    }
}
