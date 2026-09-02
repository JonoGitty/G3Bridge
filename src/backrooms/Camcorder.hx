// VHS post chain on the BitmapData (CONTRACT §2, DESIGN §3). fp class.
// SKELETON: constructor allocates every sheet, scratch and geometry object; apply() does nothing.
import flash.display.BitmapData;
import flash.filters.BlurFilter;
import flash.geom.ColorTransform;
import flash.geom.Point;
import flash.geom.Rectangle;

class Camcorder {
    public static inline var G_NONE = 0;
    public static inline var G_TEAR = 1;                // tracking bands this frame
    public static inline var G_ROLL = 2;                // vertical roll this frame (rollPx set)
    public static inline var G_GLITCH = 4;              // slice offsets + strip blur + chroma
    public static inline var G_DROPOUT = 8;
    public static inline var G_STROBE = 16;
    public static inline var G_BLACKOUT = 32;           // (renderer already black; adds heavy grain)
    public static inline var G_NOISE_FULL = 64;         // death: full alpha grain
    static inline var GRAIN_SHEETS = 4;
    static inline var GRAIN_SIZE = 512;
    public var dread:Float;                             // set per frame by Main
    public var flags:Int;
    public var rollPx:Int;
    public var tearBands:Int;                           // 1..4
    public var chromaPx:Int;                            // 0..5
    public var flickerBrightness:Float;                 // 0.85..1.05, per frame from Main (lightOffset-derived jitter)
    public var tPost:Int;

    // private — implementer may rename
    var tier:Int;
    var scan0:BitmapData; var scan1:BitmapData;         // scanline+vignette sheets per tier (normal)
    var scanTight0:BitmapData; var scanTight1:BitmapData; // tight-vignette variants
    var scratch0:BitmapData; var scratch1:BitmapData;   // whole-frame scratch per tier
    var grain:flash.Vector<BitmapData>;                 // GRAIN_SHEETS sheets of GRAIN_SIZE^2
    var grainFull:BitmapData;                           // full-alpha grain for G_NOISE_FULL
    var pt:Point;
    var pt2:Point;
    var rc:Rectangle;
    var rc2:Rectangle;
    var ct:ColorTransform;                              // tint x flicker
    var ctInvert:ColorTransform;                        // multipliers -1, offsets 255
    var blur:BlurFilter;                                // BlurFilter(3, 0, 1)

    // allocates sheets for BOTH tiers and 4 grain sheets 512x512, scratch BitmapData per tier, all Points/Rects/ColorTransforms
    public function new():Void {
        dread = 0.0;
        flags = 0;
        rollPx = 0;
        tearBands = 1;
        chromaPx = 0;
        flickerBrightness = 1.0;
        tPost = 0;
        tier = 1;
        scan0 = new BitmapData(Renderer.W0, Renderer.H0, true, 0x00000000);
        scan1 = new BitmapData(Renderer.W1, Renderer.H1, true, 0x00000000);
        scanTight0 = new BitmapData(Renderer.W0, Renderer.H0, true, 0x00000000);
        scanTight1 = new BitmapData(Renderer.W1, Renderer.H1, true, 0x00000000);
        scratch0 = new BitmapData(Renderer.W0, Renderer.H0, false, 0xFF000000);
        scratch1 = new BitmapData(Renderer.W1, Renderer.H1, false, 0xFF000000);
        grain = new flash.Vector<BitmapData>(GRAIN_SHEETS, true);
        for (i in 0...GRAIN_SHEETS) grain[i] = new BitmapData(GRAIN_SIZE, GRAIN_SIZE, true, 0x00000000);
        grainFull = new BitmapData(GRAIN_SIZE, GRAIN_SIZE, true, 0x00000000);
        pt = new Point(0, 0);
        pt2 = new Point(0, 0);
        rc = new Rectangle(0, 0, Renderer.W1, Renderer.H1);
        rc2 = new Rectangle(0, 0, Renderer.W1, Renderer.H1);
        ct = new ColorTransform(1, 1, 1, 1, 0, 0, 0, 0);
        ctInvert = new ColorTransform(-1, -1, -1, 1, 255, 255, 255, 0);
        blur = new BlurFilter(3, 0, 1);
    }

    // grain alpha, tint ct, vignette variant; rebuilds the 4 grain sheets with noise(seed)
    public function buildForTape(t:Tape):Void {
        ct.redMultiplier = t.tintR; ct.greenMultiplier = t.tintG; ct.blueMultiplier = t.tintB;
        ct.redOffset = t.offR; ct.greenOffset = t.offG; ct.blueOffset = t.offB;
        // SKELETON: sheets not rebuilt
    }

    public function setTier(tier:Int):Void {
        this.tier = tier; // SKELETON
    }

    // the full post chain in DESIGN 3 order; reads dread/flags/rollPx/tearBands/chromaPx/flickerBrightness
    public function apply(bd:BitmapData, frameSeed:Int):Void {
        // SKELETON
    }

    // schedule a tear for the next apply (Main calls on events)
    public function tearNow(bands:Int):Void {
        tearBands = bands; // SKELETON
        flags |= G_TEAR;
    }

    public function glitchNow():Void {
        flags |= G_GLITCH; // SKELETON
    }
}
