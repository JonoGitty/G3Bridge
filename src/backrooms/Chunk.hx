// One 32x32 block of cells (CONTRACT §1). Core class: no flash.* imports.
// Bodies are complete: the contract fully specifies them.
class Chunk {
    public static inline var SIZE = 32;
    public static inline var AREA = 1024;
    public var cx:Int;
    public var cy:Int;
    public var zone:Int;                              // ChunkGen.Z_HALL..Z_DARK
    public var cells:haxe.ds.Vector<Int>;             // AREA entries, index = (y << 5) | x with x,y in 0..31
    public var generation:Int;                        // incremented by ChunkGen.generate; 0 = never generated

    // allocates cells once; reused by World's pool
    public function new():Void {
        cx = 0;
        cy = 0;
        zone = 0;
        generation = 0;
        cells = new haxe.ds.Vector<Int>(AREA);
        fill(Cells.WALL);
    }

    // x,y local 0..31, no bounds check
    public inline function get(x:Int, y:Int):Int return cells[(y << 5) | x];

    public inline function set(x:Int, y:Int, v:Int):Void cells[(y << 5) | x] = v;

    public function fill(v:Int):Void {
        var c = cells;
        for (i in 0...AREA) c[i] = v;
    }
}
