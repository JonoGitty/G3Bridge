// The camera operator (CONTRACT §1). Core class: no flash.* imports.
// SKELETON: signatures exact; update() does nothing and returns no events.
class Player {
    public static inline var RADIUS = 0.22;
    public static inline var WALK = 0.8;                // cells/s
    public static inline var RUN_MUL = 1.6;
    public static inline var WET_MUL = 0.6;
    public static inline var TURN = 1.745;              // rad/s (100 deg/s)
    public static inline var STAMINA_SECS = 4.0;
    public static inline var RECOVER_SECS = 12.0;
    public static inline var STEP_LEN = 0.7;            // cells between footsteps
    public static inline var PE_STEP = 1;
    public static inline var PE_STEP_WET = 2;
    public static inline var PE_RUN_START = 4;
    public static inline var PE_ENTERED_PIT = 8;
    public static inline var PE_BLOCKED = 16;
    public var x:Float;
    public var y:Float;
    public var ang:Float;
    public var stamina:Float;                           // 0..1
    public var running:Bool;                            // true only while actually moving at run speed
    public var onWet:Bool;
    public var onDark:Bool;
    public var cellsWalked:Float;
    public var runSeconds:Float;                        // continuous seconds of running (reset when not running)
    public var speed:Float;                             // current cells/s (for audio/telemetry)

    public function new(x:Float, y:Float, ang:Float):Void {
        this.x = x;
        this.y = y;
        this.ang = ang;
        stamina = 1.0;
        running = false;
        onWet = false;
        onDark = false;
        cellsWalked = 0.0;
        runSeconds = 0.0;
        speed = 0.0;
    }

    public inline function cellX():Int return Math.floor(x);

    public inline function cellY():Int return Math.floor(y);

    // fwd/turn/strafe in {-1, 0, 1}; run = Shift held. Returns PE_* flags for this frame.
    public function update(dt:Float, fwd:Int, turn:Int, strafe:Int, run:Bool, world:World):Int {
        return 0; // SKELETON
    }

    // teleport (tape start)
    public function placeAt(x:Float, y:Float, ang:Float):Void {
        this.x = x;
        this.y = y;
        this.ang = ang;
    }
}
