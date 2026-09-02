// The camera operator (CONTRACT §1, DESIGN §1/§5/§8). Core class: no flash.* imports.
//
// Movement with wall sliding (x then y, each axis rejected if any corner of the RADIUS
// box lands in a solid cell), eased turning, run/stamina with a short exhaustion
// hysteresis, wet-carpet slow, footstep events by distance, and a one-shot pit event.
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
    // private tuning
    static inline var TURN_EASE = 0.15;                 // seconds for angular velocity to ramp to TURN
    static inline var EXHAUST_RECOVER = 0.25;           // once stamina hits 0, no running until it is back to this
    static inline var INV_SQRT2 = 0.7071067811865476;
    static inline var TWO_PI = 6.283185307179586;

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

    var turnVel:Float;                                  // current angular speed magnitude (ease-in)
    var turnDir:Int;                                    // direction the ease-in was built up in
    var stepAccum:Float;                                // cells since the last footstep
    var inPit:Bool;                                     // standing in a PIT cell last frame
    var exhausted:Bool;                                 // stamina hit 0; running blocked until EXHAUST_RECOVER

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
        turnVel = 0.0;
        turnDir = 0;
        stepAccum = 0.0;
        inPit = false;
        exhausted = false;
    }

    public inline function cellX():Int return Math.floor(x);

    public inline function cellY():Int return Math.floor(y);

    // fwd/turn/strafe in {-1, 0, 1}; run = Shift held. Returns PE_* flags for this frame.
    // turn = +1 is RIGHT: ang += turn * TURN * dt (eased) — clockwise on screen (y down), increasing angle, consistent with
    // rule 9 (positive bearing = to the right of facing) and the raycaster's plane sign. strafe = +1 moves along (cos(ang + pi/2), sin(ang + pi/2)).
    public function update(dt:Float, fwd:Int, turn:Int, strafe:Int, run:Bool, world:World):Int {
        var ev = 0;

        // ---- turning with ease-in ----
        if (turn != 0) {
            if (turn != turnDir) { turnVel = 0.0; turnDir = turn; }
            turnVel += TURN * dt / TURN_EASE;
            if (turnVel > TURN) turnVel = TURN;
            ang += turn * turnVel * dt;
            if (ang >= TWO_PI || ang < 0.0) ang -= TWO_PI * Math.floor(ang / TWO_PI);
        } else {
            turnVel = 0.0;
            turnDir = 0;
        }

        // ---- ground under the feet (before the move: this frame's speed) ----
        var here = Cells.type(world.cell(cellX(), cellY()));
        onWet = here == Cells.WET;
        onDark = here == Cells.DARK;

        // ---- speed ----
        var moving = fwd != 0 || strafe != 0;
        if (exhausted && stamina >= EXHAUST_RECOVER) exhausted = false;
        var wantRun = run && moving && !exhausted && stamina > 0.0;
        var sp = 0.0;
        if (moving) {
            sp = WALK;
            if (wantRun) sp *= RUN_MUL;
            if (onWet) sp *= WET_MUL;
        }

        // ---- movement vector: forward along the facing, strafe along facing + 90 deg ----
        var mx = 0.0;
        var my = 0.0;
        if (moving) {
            var c = Math.cos(ang);
            var s = Math.sin(ang);
            mx = fwd * c - strafe * s;
            my = fwd * s + strafe * c;
            if (fwd != 0 && strafe != 0) { mx *= INV_SQRT2; my *= INV_SQRT2; }
        }

        // ---- collide and slide: x then y ----
        var ox = x;
        var oy = y;
        var step = sp * dt;
        if (mx != 0.0) {
            var nx = x + mx * step;
            if (fits(world, nx, y)) x = nx;
        }
        if (my != 0.0) {
            var ny = y + my * step;
            if (fits(world, x, ny)) y = ny;
        }
        var dx = x - ox;
        var dy = y - oy;
        var moved = Math.sqrt(dx * dx + dy * dy);
        speed = dt > 0.0 ? moved / dt : 0.0;
        if (moving && moved < 1e-9) ev |= PE_BLOCKED;

        // ---- run / stamina (running only while actually moving at run speed) ----
        var wasRunning = running;
        running = wantRun && moved > 1e-9;
        if (running) {
            if (!wasRunning) ev |= PE_RUN_START;
            runSeconds += dt;
            stamina -= dt / STAMINA_SECS;
            if (stamina <= 0.0) { stamina = 0.0; exhausted = true; }
        } else {
            runSeconds = 0.0;
            stamina += dt / RECOVER_SECS;
            if (stamina > 1.0) stamina = 1.0;
        }

        // ---- distance, footsteps ----
        cellsWalked += moved;
        stepAccum += moved;
        if (stepAccum >= STEP_LEN) {
            stepAccum -= STEP_LEN;
            if (stepAccum >= STEP_LEN) stepAccum = 0.0;   // dt is clamped, but never let a huge step queue several
            ev |= PE_STEP;
            if (onWet) ev |= PE_STEP_WET;
        }

        // ---- ground under the feet after the move: state for the rest of the frame ----
        var now = Cells.type(world.cell(cellX(), cellY()));
        onWet = now == Cells.WET;
        onDark = now == Cells.DARK;
        var pitNow = now == Cells.PIT;
        if (pitNow && !inPit) ev |= PE_ENTERED_PIT;
        inPit = pitNow;

        return ev;
    }

    // teleport (tape start): a fresh operator. Main reuses the one Player across tapes and the
    // Director derives D from cellsWalked, so the distance, stamina and ground flags start clean too.
    public function placeAt(x:Float, y:Float, ang:Float):Void {
        this.x = x;
        this.y = y;
        this.ang = ang;
        if (this.ang >= TWO_PI || this.ang < 0.0) this.ang -= TWO_PI * Math.floor(this.ang / TWO_PI);
        turnVel = 0.0;
        turnDir = 0;
        stepAccum = 0.0;
        inPit = false;
        running = false;
        runSeconds = 0.0;
        speed = 0.0;
        cellsWalked = 0.0;
        stamina = 1.0;
        exhausted = false;
        onWet = false;
        onDark = false;
    }

    // true when the RADIUS box centred at (cx, cy) touches no solid cell (all four corners checked)
    function fits(world:World, cx:Float, cy:Float):Bool {
        var x0 = Math.floor(cx - RADIUS);
        var x1 = Math.floor(cx + RADIUS);
        var y0 = Math.floor(cy - RADIUS);
        var y1 = Math.floor(cy + RADIUS);
        if (world.solid(x0, y0)) return false;
        if (world.solid(x1, y0)) return false;
        if (world.solid(x0, y1)) return false;
        if (world.solid(x1, y1)) return false;
        return true;
    }
}
