// The hunter (CONTRACT §1, DESIGN §5). Core class: no flash.* imports.
// SKELETON: signatures exact; path vector allocated; update()/hear() do nothing.
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
    public var howlTimer:Float;
    public var chaseSeconds:Float;
    public var silentSeconds:Float;                     // seconds since last seen or heard
    public var targetX:Int;                             // last heard/seen cell
    public var targetY:Int;
    public var repathTimer:Float;                       // 0.5 s
    public var pathLen:Int;
    public var pathPos:Int;
    public var path:haxe.ds.Vector<Int>;                // Path.MAX_LEN packed cells
    public var stepEvent:Bool;                          // true on the update() in which a footstep sound should fire

    public function new():Void {
        super(Entity.K_HOUND);
        height = 0.45;
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
    }

    override public function update(dt:Float, d:Director):Void {
        super.update(dt, d);
        stepEvent = false; // SKELETON
    }

    // if dist to (x,y) <= radius (scaled by d.hearingMul): set target, DORMANT -> HOWL, CHASE/LOST -> CHASE; returns true if it reacted
    public function hear(x:Int, y:Int, radius:Float):Bool {
        return false; // SKELETON
    }
}
