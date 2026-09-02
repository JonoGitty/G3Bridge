// Base class for the two dangers (CONTRACT §1). Core class: no flash.* imports.
// SKELETON: signatures exact; update() does nothing (subclasses call super first).
class Entity {
    public static inline var K_WATCHER = 1;
    public static inline var K_HOUND = 2;
    public static inline var TELEGRAPH_SECS = 3.0;
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
        width = kind == K_HOUND ? 0.6 : 0.5;            // SKELETON default widths; implementer sets the real ones
    }

    // alive && telegraph >= TELEGRAPH_SECS
    public function canKill():Bool {
        return alive && telegraph >= TELEGRAPH_SECS;
    }

    // base: refresh dist/bearing/inView via d; subclasses call super first
    public function update(dt:Float, d:Director):Void {
        // SKELETON
    }

    // alive = true, telegraph = 0, state = initial
    public function spawnAt(x:Float, y:Float):Void {
        this.x = x;
        this.y = y;
        alive = true;
        telegraph = 0.0;
        state = 0;
    }

    public function despawn():Void {
        alive = false;
    }
}
