// One tape = one seed + one camcorder look (CONTRACT §1, DESIGN §7). Core class: no flash.* imports.
// SKELETON: make() fills fixed placeholder values; nextSalt() is complete.
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

    function new():Void {}

    public static function make(index:Int, salt:Int):Tape {
        // SKELETON: deterministic placeholder values in range
        var t = new Tape();
        t.index = index;
        t.salt = salt;
        t.seed = Rng.hash3(salt, Rng.TAG_TAPE, index);
        t.name = "TAPE " + index;
        t.camName = "VX-200";
        t.dateStr = "01.01.1990";
        t.dateSeconds = 0.0;
        t.tintR = 1.0;
        t.tintG = 1.0;
        t.tintB = 1.0;
        t.offR = 0;
        t.offG = 0;
        t.offB = 0;
        t.grainAlpha = 32;
        t.fov = 66.0 * Math.PI / 180.0;
        t.dOffset = 0.0;
        t.batteryStart = 1.0;
        t.hudSkin = 0;
        t.badTape = false;
        t.startX = 16.5;
        t.startY = 16.5;
        t.startAng = 0.0;
        return t;
    }

    // Rng.mix(salt ^ 0x5DEECE66)
    public static function nextSalt(salt:Int):Int {
        return Rng.mix(salt ^ 0x5DEECE66);
    }
}
