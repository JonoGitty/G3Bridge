// One tape = one seed + one camcorder look (CONTRACT §1, DESIGN §7). Core class: no flash.* imports.
// Every field is a pure function of (index, salt): make() seeds one Rng from hash3(seed, TAG_TAPE, 0)
// and draws the fields in a fixed order, so the same tape is identical across runs and machines.
class Tape {
    public var index:Int;                               // 1-based tape number
    public var seed:Int;                                // Rng.hash3(salt, TAG_TAPE, index)
    public var salt:Int;
    public var name:String;                             // e.g. "BASEMENT LEVEL - DANNY" (ASCII only; PixelFont has no accents)
    public var camName:String;                          // e.g. "VX-200"
    public var dateStr:String;                          // "DD.MM.YYYY", years 1987..1999
    public var dateSeconds:Float;                       // seconds since midnight for the HUD clock start, 0..86399
    public var tintR:Float;                             // ColorTransform multipliers 0.92..1.08
    public var tintG:Float;
    public var tintB:Float;
    public var offR:Int;                                // ColorTransform offsets -8..8
    public var offG:Int;
    public var offB:Int;
    public var grainAlpha:Int;                          // 24..40
    public var fov:Float;                               // radians, 60..72 deg
    public var dOffset:Float;                           // 0..0.1 initial D
    public var batteryStart:Float;                      // 0.6..1.0
    public var hudSkin:Int;                             // 0..2
    public var badTape:Bool;                            // 1 in 10
    public var startX:Float;                            // 16.5, 16.5 with a walkable guarantee left to Main (Main nudges to the nearest walkable cell of chunk 0,0)
    public var startY:Float;
    public var startAng:Float;

    // tint families (DESIGN §7): warm / cool / green-sick / faded
    public static inline var TINT_WARM = 0;
    public static inline var TINT_COOL = 1;
    public static inline var TINT_SICK = 2;
    public static inline var TINT_FADED = 3;

    // word lists, built once: ASCII only, places <= 14 chars, names <= 8 chars, so "PLACE - NAME" <= 25 chars
    static var NAMES:Array<String> = [
        "DANNY", "MARK", "LISA", "TOM", "ANDY", "SARAH", "PETE", "KAREN", "GARY", "JULIE",
        "STEVE", "DAWN", "KEV", "NICOLA", "ROB", "TRACY", "DEAN", "CLAIRE", "IAN", "WENDY",
        "PAUL", "JO", "DARREN", "MICHELLE", "LEE", "SHARON", "NEIL", "BECKY", "CRAIG", "TINA",
        "WAYNE", "GEMMA", "STUART", "DONNA", "RICHARD", "HELEN", "COLIN", "MANDY", "TERRY", "JEN"
    ];
    static var PLACES:Array<String> = [
        "BASEMENT LEVEL", "SUB LEVEL 2", "OFFICE FLOOR", "STOREROOM", "EAST WING", "LEVEL 0",
        "ANNEX", "OLD OFFICES", "SERVICE FLOOR", "UNIT 4", "WEST STAIRS", "BACK ROOMS",
        "FLOOR 3", "THE HALLS", "SITE B", "LOWER FLOOR"
    ];
    static var CAMS:Array<String> = [
        "VX-200", "VHS-C 8", "HI8 CCD-TR", "PV-L600", "GR-AX400", "VM-E110", "CCD-F340", "VL-C750",
        "HR-S2", "E-8 HANDYCAM", "VX-1000", "M9000"
    ];
    static var DAYS_IN_MONTH:Array<Int> = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

    function new():Void {}

    public static function make(index:Int, salt:Int):Tape {
        var t = new Tape();
        t.index = index;
        t.salt = salt;
        t.seed = Rng.hash3(salt, Rng.TAG_TAPE, index);
        var r = new Rng(Rng.hash3(t.seed, Rng.TAG_TAPE, 0));

        // label
        var place = PLACES[r.range(0, PLACES.length)];
        var who = NAMES[r.range(0, NAMES.length)];
        t.name = place + " - " + who;
        t.camName = CAMS[r.range(0, CAMS.length)];

        // date 1987..1999, a valid day for the month (leap years handled: every 4th year in that range)
        var year = r.range(1987, 2000);
        var month = r.range(1, 13);
        var dim = DAYS_IN_MONTH[month - 1];
        if (month == 2 && (year % 4) == 0) dim = 29;
        var day = r.range(1, dim + 1);
        t.dateStr = two(day) + "." + two(month) + "." + year;
        // clock start: biased toward evening and night (most of this footage is shot after hours)
        var hour = r.chance(0.7) ? r.range(18, 24) : r.range(0, 18);
        t.dateSeconds = hour * 3600.0 + r.range(0, 60) * 60.0 + r.range(0, 60);

        // tint family: multipliers stay inside 0.92..1.08, offsets inside -8..8
        var fam = r.range(0, 4);
        var jitter = (r.nextFloat() - 0.5) * 0.04;      // -0.02..0.02 per tape, shared by all three channels
        switch (fam) {
            case TINT_WARM:
                t.tintR = 1.04 + r.nextFloat() * 0.04;
                t.tintG = 0.99 + r.nextFloat() * 0.03;
                t.tintB = 0.92 + r.nextFloat() * 0.04;
                t.offR = r.range(0, 5); t.offG = r.range(-2, 2); t.offB = r.range(-8, -3);
            case TINT_COOL:
                t.tintR = 0.92 + r.nextFloat() * 0.04;
                t.tintG = 0.98 + r.nextFloat() * 0.03;
                t.tintB = 1.04 + r.nextFloat() * 0.04;
                t.offR = r.range(-6, -1); t.offG = r.range(-2, 2); t.offB = r.range(2, 7);
            case TINT_SICK:
                t.tintR = 0.96 + r.nextFloat() * 0.04;
                t.tintG = 1.04 + r.nextFloat() * 0.04;
                t.tintB = 0.93 + r.nextFloat() * 0.04;
                t.offR = r.range(-4, 1); t.offG = r.range(1, 6); t.offB = r.range(-6, -1);
            default:
                t.tintR = 0.96 + r.nextFloat() * 0.04;
                t.tintG = 0.96 + r.nextFloat() * 0.04;
                t.tintB = 0.96 + r.nextFloat() * 0.04;
                t.offR = r.range(4, 9); t.offG = r.range(4, 9); t.offB = r.range(3, 8);
        }
        t.tintR = clampF(t.tintR + jitter, 0.92, 1.08);
        t.tintG = clampF(t.tintG + jitter, 0.92, 1.08);
        t.tintB = clampF(t.tintB + jitter, 0.92, 1.08);

        t.grainAlpha = r.range(24, 41);
        t.fov = (60.0 + r.nextFloat() * 12.0) * Math.PI / 180.0;
        t.dOffset = r.nextFloat() * 0.1;
        t.batteryStart = 0.6 + r.nextFloat() * 0.4;
        t.hudSkin = r.range(0, 3);
        t.badTape = r.chance(0.1);
        if (t.badTape && t.grainAlpha < 34) t.grainAlpha = 34 + r.range(0, 7);   // a bad tape is grainy, whatever it drew

        t.startX = 16.5;
        t.startY = 16.5;
        t.startAng = r.range(0, 4) * (Math.PI * 0.5);
        return t;
    }

    // Rng.mix(salt ^ 0x5DEECE66)
    public static function nextSalt(salt:Int):Int {
        return Rng.mix(salt ^ 0x5DEECE66);
    }

    static function two(v:Int):String {
        return v < 10 ? "0" + v : "" + v;
    }

    static inline function clampF(v:Float, lo:Float, hi:Float):Float {
        return v < lo ? lo : (v > hi ? hi : v);
    }
}
