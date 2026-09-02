// Per-column raycast results (CONTRACT §1). Core class: no flash.* imports.
// Complete: the constructor is the whole contract (all vectors length maxCols).
class RayHits {
    public var count:Int;                              // columns valid this frame
    public var dist:haxe.ds.Vector<Int>;               // perpendicular distance, 16.16; ONE * Raycaster.MAX_DIST when nothing hit
    public var texX:haxe.ds.Vector<Int>;               // 0..63 texel column
    public var side:haxe.ds.Vector<Int>;               // 0 = crossed a vertical grid line (x step), 1 = horizontal (y step)
    public var cellX:haxe.ds.Vector<Int>;
    public var cellY:haxe.ds.Vector<Int>;
    public var cell:haxe.ds.Vector<Int>;               // the cell value hit (World.cell)
    public var face:haxe.ds.Vector<Int>;               // Cells.N/E/S/W: side==0 ? (stepX > 0 ? W : E) : (stepY > 0 ? N : S)
    public var hit:haxe.ds.Vector<Int>;                // 1 if a solid cell was hit within MAX_DIST, else 0

    // all vectors length maxCols
    public function new(maxCols:Int):Void {
        count = 0;
        dist = new haxe.ds.Vector<Int>(maxCols);
        texX = new haxe.ds.Vector<Int>(maxCols);
        side = new haxe.ds.Vector<Int>(maxCols);
        cellX = new haxe.ds.Vector<Int>(maxCols);
        cellY = new haxe.ds.Vector<Int>(maxCols);
        cell = new haxe.ds.Vector<Int>(maxCols);
        face = new haxe.ds.Vector<Int>(maxCols);
        hit = new haxe.ds.Vector<Int>(maxCols);
        for (i in 0...maxCols) {
            dist[i] = Cells.ONE * Raycaster.MAX_DIST;
            texX[i] = 0; side[i] = 0; cellX[i] = 0; cellY[i] = 0; cell[i] = 0; face[i] = 0; hit[i] = 0;
        }
    }
}
