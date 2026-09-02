// Walls, floor and ceiling into a Vector.<uint> frame buffer (CONTRACT §2, DESIGN §1). fp class.
// SKELETON: constructor allocates BOTH tiers' fb/bd/rect/tables; setTier swaps; present() is complete; render() does nothing.
import flash.display.BitmapData;
import flash.geom.Rectangle;

class Renderer {
    public static inline var W1 = 320; public static inline var H1 = 240;
    public static inline var W0 = 256; public static inline var H0 = 192;
    public var w:Int;
    public var h:Int;
    public var tier:Int;
    public var fb:flash.Vector<UInt>;                   // current tier's buffer, length w*h, fixed; index = y*w + x
    public var bd:BitmapData;                           // current tier's BitmapData (opaque, transparent = false)
    public var rect:Rectangle;                          // (0,0,w,h) for the current tier
    public var colShift:Int;                            // 0 when hits.count == w, 1 when hits.count == w/2 (2-px columns)
    public var textures:Textures;
    public var vignetteBias:flash.Vector<Int>;          // per column 0..2, rebuilt in setTier
    public var rowBand:flash.Vector<Int>;               // per row base band for floor/ceiling (distance-based), rebuilt in setTier
    public var rowDist:flash.Vector<Int>;               // 16.16 depth per row
    public var wallBand:flash.Vector<Int>;              // per column band used for the wall this frame (SpritePass reads it to keep the Watcher darker)
    public var tRay:Int; public var tWall:Int; public var tFloor:Int;   // getTimer brackets, ms, for telemetry (written by render)

    // per-tier storage — implementer may rename
    var fb0:flash.Vector<UInt>; var fb1:flash.Vector<UInt>;
    var bd0:BitmapData; var bd1:BitmapData;
    var rect0:Rectangle; var rect1:Rectangle;
    var vignetteBias0:flash.Vector<Int>; var vignetteBias1:flash.Vector<Int>;
    var rowBand0:flash.Vector<Int>; var rowBand1:flash.Vector<Int>;
    var rowDist0:flash.Vector<Int>; var rowDist1:flash.Vector<Int>;
    var wallBand0:flash.Vector<Int>; var wallBand1:flash.Vector<Int>;

    // allocates BOTH tiers' fb + bd up front
    public function new(textures:Textures):Void {
        this.textures = textures;
        fb0 = new flash.Vector<UInt>(W0 * H0, true);
        fb1 = new flash.Vector<UInt>(W1 * H1, true);
        bd0 = new BitmapData(W0, H0, false, 0xFF000000);
        bd1 = new BitmapData(W1, H1, false, 0xFF000000);
        rect0 = new Rectangle(0, 0, W0, H0);
        rect1 = new Rectangle(0, 0, W1, H1);
        vignetteBias0 = new flash.Vector<Int>(W0, true);
        vignetteBias1 = new flash.Vector<Int>(W1, true);
        wallBand0 = new flash.Vector<Int>(W0, true);
        wallBand1 = new flash.Vector<Int>(W1, true);
        rowBand0 = new flash.Vector<Int>(H0, true);
        rowBand1 = new flash.Vector<Int>(H1, true);
        rowDist0 = new flash.Vector<Int>(H0, true);
        rowDist1 = new flash.Vector<Int>(H1, true);
        colShift = 0;
        tRay = 0; tWall = 0; tFloor = 0;
        tier = -1;
        setTier(1);
    }

    // index swap only
    public function setTier(t:Int):Void {
        tier = t;
        if (t == 0) {
            w = W0; h = H0; fb = fb0; bd = bd0; rect = rect0;
            vignetteBias = vignetteBias0; rowBand = rowBand0; rowDist = rowDist0; wallBand = wallBand0;
        } else {
            w = W1; h = H1; fb = fb1; bd = bd1; rect = rect1;
            vignetteBias = vignetteBias1; rowBand = rowBand1; rowDist = rowDist1; wallBand = wallBand1;
        }
        // SKELETON: tables not rebuilt
    }

    // Draws walls, floor and ceiling into fb from hits. lightOffset 0..15; floorMode 0/1/2; camera (px,py,ang) and ray dir tables from rc.
    public function render(hits:RayHits, rc:Raycaster, px:Float, py:Float, lightOffset:Int, floorMode:Int, world:World):Void {
        colShift = hits.count == w ? 0 : 1; // SKELETON: nothing drawn
    }

    // bd.setVector(rect, fb)
    public function present():Void {
        bd.setVector(rect, fb);
    }
}
