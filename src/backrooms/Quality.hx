// Adaptive quality rungs (CONTRACT §1, DESIGN §1). Core class: no flash.* imports.
// SKELETON: the static rung tables are complete (contract-specified); noteFrame() never changes rung.
class Quality {
    public static inline var RUNGS = 6;
    public var rung:Int;
    public var maxRung:Int;                             // from Bench or Save; rung <= maxRung always
    public var ema:Float;                               // frame ms
    public var lastChange:Float;                        // seconds since the last change
    public var lockUntil:Float;                         // seconds of remaining explicit lock

    public function new(rung:Int, maxRung:Int):Void {
        this.maxRung = maxRung;
        this.rung = rung > maxRung ? maxRung : rung;
        if (this.rung < 0) this.rung = 0;
        ema = 0.0;
        lastChange = 0.0;
        lockUntil = 0.0;
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

    // Feed one measured frame. entityActive/dying/mapOpen are locks. Returns -1 (drop), +1 (raise) or 0; the caller applies the change.
    public function noteFrame(ms:Float, dt:Float, entityActive:Bool, dying:Bool, mapOpen:Bool):Int {
        return 0; // SKELETON
    }

    // e.g. 2 s after a glitch frame
    public function lock(seconds:Float):Void {
        if (seconds > lockUntil) lockUntil = seconds;
    }

    // render error: rung = max(0, rung - 1), resets counters
    public function forceDrop():Void {
        rung = rung > 0 ? rung - 1 : 0;
        lastChange = 0.0; // SKELETON: counters reset (none yet)
    }

    // override (debug keys, rc)
    public function set(rung:Int):Void {
        this.rung = rung < 0 ? 0 : (rung > maxRung ? maxRung : rung);
    }
}
