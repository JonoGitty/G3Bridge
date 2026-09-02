// What the camera has seen, per cell (CONTRACT §1). Core class: no flash.* imports.
// SKELETON: signatures exact; constructor allocates the map and the ring queue; bodies return defaults.
class MapMemory {
    public static inline var F_N = 1;
    public static inline var F_E = 2;
    public static inline var F_S = 4;
    public static inline var F_W = 8;
    public static inline var VISITED = 16;
    public static inline var WET_SEEN = 32;
    public static inline var DARK_SEEN = 64;
    public static inline var PIT_SEEN = 128;
    public static inline var MAX_CHUNKS = 256;
    public static inline var INK_DIST = 10;            // cells; faces beyond this are not recorded (16.16 compare against INK_DIST << 16)
    public static inline var QUEUE_SIZE = 4096;

    // private storage — implementer may rename
    var chunks:Map<Int, haxe.ds.Vector<Int>>;         // 1024 flags per chunk, key = World.key
    var queueCell:haxe.ds.Vector<Int>;                 // ring: packed cell
    var queueKind:haxe.ds.Vector<Int>;                 // ring: kind 0..7
    var queueHead:Int;
    var queueLen:Int;
    var nChunks:Int;

    public function new():Void {
        chunks = new Map<Int, haxe.ds.Vector<Int>>();
        queueCell = new haxe.ds.Vector<Int>(QUEUE_SIZE);
        queueKind = new haxe.ds.Vector<Int>(QUEUE_SIZE);
        queueHead = 0;
        queueLen = 0;
        nChunks = 0;
    }

    // 0 if the chunk is unknown
    public function flags(x:Int, y:Int):Int {
        return 0; // SKELETON
    }

    // sets F_* bit; true if it was newly set (and then queued)
    public function seeFace(x:Int, y:Int, face:Int):Bool {
        return false; // SKELETON
    }

    // sets VISITED (+ WET/DARK/PIT_SEEN from the cell type); true if new
    public function visit(x:Int, y:Int, cellValue:Int):Bool {
        return false; // SKELETON
    }

    // for every column with hit == 1 and dist < INK_DIST << 16: seeFace(cellX, cellY, face); returns newly set count
    public function recordHits(h:RayHits):Int {
        return 0; // SKELETON
    }

    public function chunkCount():Int {
        return 0; // SKELETON
    }

    // while chunkCount() > MAX_CHUNKS drop the chunk with the largest Chebyshev distance; returns dropped count
    public function evictFarthest(px:Int, py:Int):Int {
        return 0; // SKELETON
    }

    // queue of newly inked items for MapPaper: packed cell (Cells.pack) with the face or flag in a parallel vector
    public function queueLength():Int {
        return 0; // SKELETON
    }

    // i in 0..queueLength()-1, packed x,y
    public function queuePeekCell(i:Int):Int {
        return 0; // SKELETON
    }

    // 0..3 = face N/E/S/W; 4 = visited; 5 = wet; 6 = dark; 7 = pit
    public function queuePeekKind(i:Int):Int {
        return 0; // SKELETON
    }

    // remove the first n items
    public function queueDrop(n:Int):Void {
        // SKELETON
    }

    // re-ink support for a sheet: iterate all known cells in a rectangle; fills packed cells + flags, returns count
    public function forEachKnown(x0:Int, y0:Int, x1:Int, y1:Int, out:haxe.ds.Vector<Int>, outFlags:haxe.ds.Vector<Int>, max:Int):Int {
        return 0; // SKELETON
    }
}
