// Adaptive quality rungs (CONTRACT §1, DESIGN §1). Core class: no flash.* imports.
// Two EMAs (alpha 0.1) over busy ms (t_ours + presentEstimate) and wall ms (ENTER_FRAME to ENTER_FRAME).
// Drop after DROP_FRAMES consecutive frames with either EMA > 1.15 x budget: never blocked by anything but the
// 5 s spacing (a chase must be allowed to overrun a rung the bench proved without sprites).
// Raise after RAISE_FRAMES consecutive frames with the busy EMA < 0.70 x budget, and only when nothing blocks it:
// wall time is never consulted for a raise because stage.frameRate pins it at >= 1000/frameRate.
class Quality {
    public static inline var RUNGS = 6;
    public static inline var DROP_FRAMES = 60;
    public static inline var RAISE_FRAMES = 300;
    public static inline var DROP_MUL = 1.15;
    public static inline var RAISE_MUL = 0.70;
    public static inline var SPACING_SECS = 5.0;
    public static inline var ALPHA = 0.1;
    static inline var EPS = 1e-6;                       // the clocks are sums of frame deltas: 100 x 0.05 is not exactly 5
    public var rung:Int;
    public var maxRung:Int;                             // ceiling for the CURRENT display mode (Bench maxRungWin or maxRungFs, via setMaxRung); rung <= maxRung always
    public var presentEstimate:Float;                   // ms; Bench presentW (windowed) or presentFsRect/presentFs (fullscreen, fsHw-aware) for the current tier; set by Main on tier/mode change
    public var emaBusy:Float;                           // EMA of busy ms = t_ours + presentEstimate; the ONLY input to the raise test; also drops
    public var emaFrame:Float;                          // EMA of ENTER_FRAME-to-ENTER_FRAME ms; pinned at >= 1000/frameRate by the player, so it can only ever DROP (an overrun there is real), never raise
    public var lastChange:Float;                        // seconds since the last change
    public var lockUntil:Float;                         // seconds of remaining explicit raise-lock (locks never block a drop)

    var slowFrames:Int;                                 // consecutive frames over the drop threshold
    var fastFrames:Int;                                 // consecutive unblocked frames under the raise threshold
    var primed:Bool;                                    // first sample seeds both EMAs (no 30-frame warm-up from zero)

    public function new(rung:Int, maxRung:Int):Void {
        this.maxRung = maxRung < 0 ? 0 : (maxRung >= RUNGS ? RUNGS - 1 : maxRung);
        this.rung = rung > this.maxRung ? this.maxRung : rung;
        if (this.rung < 0) this.rung = 0;
        presentEstimate = 0.0;
        emaBusy = 0.0;
        emaFrame = 0.0;
        lastChange = SPACING_SECS;                      // a change is allowed as soon as the hysteresis says so
        lockUntil = 0.0;
        slowFrames = 0;
        fastFrames = 0;
        primed = false;
    }

    // 0 => 0 (256x192); else 1 (320x240)
    public static function tier(rung:Int):Int {
        return rung == 0 ? 0 : 1;
    }

    // rung 0,1 => 0; 2,3,4 => 1; 5 => 2
    public static function floorMode(rung:Int):Int {
        return rung <= 1 ? 0 : (rung <= 4 ? 1 : 2);
    }

    // 0 => 128; 1,2 => 160; 3,4,5 => 320
    public static function rays(rung:Int):Int {
        return rung == 0 ? 128 : (rung <= 2 ? 160 : 320);
    }

    // 0..3 => 20; 4,5 => 30
    public static function frameRate(rung:Int):Int {
        return rung <= 3 ? 20 : 30;
    }

    // 50 or 33.3
    public static function budgetMs(rung:Int):Float {
        return rung <= 3 ? 50.0 : 33.3;
    }

    // Feed one frame: busyMs = getTimer bracket around the whole handler + presentEstimate (never wall time); frameMs = ENTER_FRAME to ENTER_FRAME.
    // entityActive/dying/mapOpen block RAISES only; drops stay allowed under them (with the 60-frame hysteresis). Returns -1 (drop), +1 (raise) or 0; the caller applies the change.
    // noteFrame never writes rung itself: Main does quality.set(rung + change) (a -1 here would otherwise land two rungs down).
    public function noteFrame(busyMs:Float, frameMs:Float, entityActive:Bool, dying:Bool, mapOpen:Bool):Int {
        if (busyMs < 0.0) busyMs = 0.0;
        if (frameMs < 0.0) frameMs = 0.0;
        if (primed) {
            emaBusy += ALPHA * (busyMs - emaBusy);
            emaFrame += ALPHA * (frameMs - emaFrame);
        } else {
            emaBusy = busyMs;
            emaFrame = frameMs;
            primed = true;
        }
        // clocks: wall time, clamped like Main's dt
        var dt = frameMs * 0.001;
        if (dt > 0.1) dt = 0.1;
        lastChange += dt;
        if (lockUntil > 0.0) {
            lockUntil -= dt;
            if (lockUntil < EPS) lockUntil = 0.0;
        }
        var spaced = lastChange >= SPACING_SECS - EPS;

        var budget = budgetMs(rung);
        var dropAt = budget * DROP_MUL;
        var raiseAt = budget * RAISE_MUL;

        // drop test: either EMA over the line
        if (emaBusy > dropAt || emaFrame > dropAt) {
            slowFrames++;
            fastFrames = 0;
            if (slowFrames >= DROP_FRAMES && spaced && rung > 0) {
                // verdict only: the caller applies it through set(), the one rung writer; the counters and the
                // spacing clock reset here so the same verdict is not repeated next frame
                resetCounters();
                return -1;
            }
            return 0;
        }
        slowFrames = 0;

        // raise test: busy EMA only, and nothing blocking; a blocked frame restarts the count so a raise
        // needs RAISE_FRAMES clean frames after the chase / map / death / lock ends
        var blocked = entityActive || dying || mapOpen || lockUntil > 0.0 || rung >= maxRung;
        if (blocked || emaBusy >= raiseAt) {
            fastFrames = 0;
            return 0;
        }
        fastFrames++;
        if (fastFrames >= RAISE_FRAMES && spaced) {
            resetCounters();
            return 1;
        }
        return 0;
    }

    // raise-lock, e.g. 2 s after a glitch frame
    public function lock(seconds:Float):Void {
        if (seconds > lockUntil) lockUntil = seconds;
        fastFrames = 0;
    }

    // Main calls after Bench and on Display.onFullscreenChange: maxRung = m; rung = min(rung, m); resets the raise counter
    public function setMaxRung(m:Int):Void {
        maxRung = m < 0 ? 0 : (m >= RUNGS ? RUNGS - 1 : m);
        if (rung > maxRung) {
            rung = maxRung;
            lastChange = 0.0;
        }
        fastFrames = 0;
    }

    // render error: rung = max(0, rung - 1), resets counters
    public function forceDrop():Void {
        rung = rung > 0 ? rung - 1 : 0;
        resetCounters();
    }

    // override (debug keys, rc)
    public function set(rung:Int):Void {
        this.rung = rung < 0 ? 0 : (rung > maxRung ? maxRung : rung);
        resetCounters();
    }

    function resetCounters():Void {
        slowFrames = 0;
        fastFrames = 0;
        lastChange = 0.0;
    }
}
