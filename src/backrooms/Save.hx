// SharedObject persistence (CONTRACT §2, DESIGN §7). fp class.
//
// SharedObject.getLocal("backrooms") holds { v, tapeCount, salt, deaths, bestSeconds,
// rung, maxRungWin, maxRungFs, benchDone, fsHw, qLow }. Everything is wrapped in
// try/catch: the plugin is installed per-user on the eMac with no admin password, and
// the Flash settings panel can refuse storage, so a throw anywhere (getLocal, a field
// read, flush) leaves `ok = false` and the game running on in-memory defaults. The
// Dynamic is confined to load()/flush() (the SharedObject's data Object); every
// caller sees the typed SaveData.
import flash.net.SharedObject;

typedef SaveData = { v:Int, tapeCount:Int, salt:Int, deaths:Int, bestSeconds:Int, rung:Int, maxRungWin:Int, maxRungFs:Int, benchDone:Bool, fsHw:Int, qLow:Int };

class Save {
    public static var ok:Bool = true;                   // false if SharedObject threw; the game runs in-memory
    static inline var NAME = "backrooms";
    static inline var VERSION = 1;
    static var so:SharedObject = null;

    static function defaults():SaveData {
        return {
            v: VERSION,
            tapeCount: 0,
            salt: Rng.mix(flash.Lib.getTimer() ^ 0x1234567),
            deaths: 0,
            bestSeconds: 0,
            rung: 2,
            maxRungWin: 2,
            maxRungFs: 2,
            benchDone: false,
            fsHw: -1,
            qLow: 0
        };
    }

    static function readInt(o:Dynamic, k:String, def:Int):Int {
        var v:Dynamic = Reflect.field(o, k);
        if (v == null) return def;
        if (Std.isOfType(v, Int)) return cast v;
        if (Std.isOfType(v, Float)) return Std.int(cast v);
        return def;
    }

    static function readBool(o:Dynamic, k:String, def:Bool):Bool {
        var v:Dynamic = Reflect.field(o, k);
        if (v == null) return def;
        if (Std.isOfType(v, Bool)) return cast v;
        if (Std.isOfType(v, Int)) return (cast(v, Int)) != 0;
        return def;
    }

    static inline function clampInt(v:Int, lo:Int, hi:Int):Int return v < lo ? lo : (v > hi ? hi : v);

    // defaults: v 1, tapeCount 0, salt = Rng.mix(getTimer() ^ 0x1234567), deaths 0, bestSeconds 0, rung 2, maxRungWin 2, maxRungFs 2, benchDone false, fsHw -1, qLow 0
    public static function load():SaveData {
        var d = defaults();
        try {
            so = SharedObject.getLocal(NAME);
            var data:Dynamic = so.data;
            ok = true;
            if (data != null && readInt(data, "v", 0) == VERSION) {
                d.tapeCount = clampInt(readInt(data, "tapeCount", d.tapeCount), 0, 1000000);
                d.salt = readInt(data, "salt", d.salt);
                d.deaths = clampInt(readInt(data, "deaths", d.deaths), 0, 1000000);
                d.bestSeconds = clampInt(readInt(data, "bestSeconds", d.bestSeconds), 0, 100000000);
                d.maxRungWin = clampInt(readInt(data, "maxRungWin", d.maxRungWin), 0, Quality.RUNGS - 1);
                d.maxRungFs = clampInt(readInt(data, "maxRungFs", d.maxRungFs), 0, Quality.RUNGS - 1);
                d.rung = clampInt(readInt(data, "rung", d.rung), 0, Quality.RUNGS - 1);
                d.benchDone = readBool(data, "benchDone", d.benchDone);
                d.fsHw = clampInt(readInt(data, "fsHw", d.fsHw), -1, 1);
                d.qLow = clampInt(readInt(data, "qLow", d.qLow), 0, 1);
            }
        } catch (e:Dynamic) {
            ok = false;
            so = null;
        }
        return d;
    }

    // try/catch; false on failure (and ok = false)
    public static function flush(d:SaveData):Bool {
        if (d == null) return false;
        try {
            if (so == null) so = SharedObject.getLocal(NAME);
            var data:Dynamic = so.data;
            Reflect.setField(data, "v", VERSION);
            Reflect.setField(data, "tapeCount", d.tapeCount);
            Reflect.setField(data, "salt", d.salt);
            Reflect.setField(data, "deaths", d.deaths);
            Reflect.setField(data, "bestSeconds", d.bestSeconds);
            Reflect.setField(data, "rung", d.rung);
            Reflect.setField(data, "maxRungWin", d.maxRungWin);
            Reflect.setField(data, "maxRungFs", d.maxRungFs);
            Reflect.setField(data, "benchDone", d.benchDone);
            Reflect.setField(data, "fsHw", d.fsHw);
            Reflect.setField(data, "qLow", d.qLow);
            so.flush();                                 // "flushed" or "pending" (permission dialog); a refusal throws
            ok = true;
            return true;
        } catch (e:Dynamic) {
            ok = false;
            return false;
        }
    }
}
