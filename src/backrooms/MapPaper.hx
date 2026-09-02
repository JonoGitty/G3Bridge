// Hand-drawn paper map sheets (CONTRACT §2, DESIGN §4). fp class.
// SKELETON: constructor allocates the Shape, Matrix, geometry, paper master and scratch vectors; nothing is inked or composed.
import flash.display.BitmapData;
import flash.display.Shape;
import flash.geom.Matrix;
import flash.geom.Point;
import flash.geom.Rectangle;

class MapPaper {
    public static inline var CELL_PX = 6;
    public static inline var SHEET_CELLS = 64;
    public static inline var SHEET_PX = 384;
    public static inline var MAX_SHEETS = 9;
    public static inline var INK_PER_FRAME = 64;
    public static inline var REINK_PER_FRAME = 256;
    static inline var PAPER_PX = 512;            // paper master size
    static inline var REINK_SCRATCH = 4096;      // SHEET_CELLS^2 cells per sheet
    public var open:Bool;
    public var viewX:Int;                               // world-pixel (cell*6) coordinate of the view's top-left
    public var viewY:Int;
    public var sheets:Int;                              // resident sheet count (telemetry)
    public var tMap:Int;

    // private — implementer may rename
    var shape:Shape;
    var mtx:Matrix;
    var pt:Point;
    var rc:Rectangle;
    var paper:BitmapData;                               // 512x512 paper master
    var sheetMap:Map<Int, BitmapData>;                  // key = World.key(x >> 6, y >> 6)
    var pendingReink:haxe.ds.Vector<Int>;               // sheet keys waiting for a re-ink
    var pendingCount:Int;
    var reinkCells:haxe.ds.Vector<Int>;                 // forEachKnown scratch
    var reinkFlags:haxe.ds.Vector<Int>;

    // allocates the Shape, Matrix, Points/Rects, the 512x512 paper master, the reink scratch vectors
    public function new():Void {
        open = false;
        viewX = 0;
        viewY = 0;
        sheets = 0;
        tMap = 0;
        shape = new Shape();
        mtx = new Matrix();
        pt = new Point(0, 0);
        rc = new Rectangle(0, 0, SHEET_PX, SHEET_PX);
        paper = new BitmapData(PAPER_PX, PAPER_PX, false, 0xFFE8E0C8);
        sheetMap = new Map<Int, BitmapData>();
        pendingReink = new haxe.ds.Vector<Int>(MAX_SHEETS);
        pendingCount = 0;
        reinkCells = new haxe.ds.Vector<Int>(REINK_SCRATCH);
        reinkFlags = new haxe.ds.Vector<Int>(REINK_SCRATCH);
    }

    // paper master (noise fibre, grid, creases, coffee ring), disposes all sheets
    public function buildForTape(t:Tape):Void {
        // SKELETON
    }

    // drains up to INK_PER_FRAME queued items into ONE Shape and ONE draw per sheet touched; re-inks a pending sheet up to REINK_PER_FRAME; evicts sheets beyond the 3x3 around the player; returns items inked
    public function pump(mem:MapMemory, px:Int, py:Int):Int {
        return 0; // SKELETON
    }

    // centres the view on the player
    public function openAt(px:Float, py:Float):Void {
        open = true; // SKELETON
    }

    public function close():Void {
        open = false;
    }

    // pixels
    public function pan(dx:Int, dy:Int):Void {
        viewX += dx;
        viewY += dy;
    }

    // Composites the visible sheet window into bd (2-4 copyPixels), then the player arrowhead at (px,py,ang) via one Shape draw, with the hand wobble offset.
    public function compose(bd:BitmapData, w:Int, h:Int, px:Float, py:Float, ang:Float, wobbleX:Int, wobbleY:Int):Void {
        // SKELETON
    }
}
