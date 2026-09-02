// SharedObject persistence (CONTRACT §2). fp class.
// SKELETON: load() returns the contract defaults without touching SharedObject; flush() is a no-op returning true.
typedef SaveData = { v:Int, tapeCount:Int, salt:Int, deaths:Int, bestSeconds:Int, rung:Int, maxRung:Int, benchDone:Bool, fsHw:Int };

class Save {
    public static var ok:Bool = true;                   // false if SharedObject threw; the game runs in-memory

    // defaults: v 1, tapeCount 0, salt = Rng.mix(getTimer() ^ 0x1234567), deaths 0, bestSeconds 0, rung 2, maxRung 2, benchDone false, fsHw -1
    public static function load():SaveData {
        // SKELETON: defaults only
        return {
            v: 1,
            tapeCount: 0,
            salt: Rng.mix(flash.Lib.getTimer() ^ 0x1234567),
            deaths: 0,
            bestSeconds: 0,
            rung: 2,
            maxRung: 2,
            benchDone: false,
            fsHw: -1
        };
    }

    // try/catch; false on failure (and ok = false)
    public static function flush(d:SaveData):Bool {
        return true; // SKELETON
    }
}
