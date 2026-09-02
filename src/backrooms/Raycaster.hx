// DDA raycaster (CONTRACT §1). Core class: no flash.* imports.
// SKELETON: signatures exact; constructor allocates the per-column tables; cast() reports "nothing hit".
class Raycaster {
    public static inline var MAX_DIST = 16;            // cells
    public static inline var MAX_STEPS = 48;
    public var cols:Int;                               // current column count
    public var fov:Float;                              // radians
    public var dirX:haxe.ds.Vector<Float>;             // per-column ray direction (unit-plane form: dir + plane * camX), length maxCols
    public var dirY:haxe.ds.Vector<Float>;
    public var camX:haxe.ds.Vector<Float>;             // per-column camera-plane coordinate in [-1, 1]

    public function new(maxCols:Int):Void {
        cols = 0;
        fov = 0.0;
        dirX = new haxe.ds.Vector<Float>(maxCols);
        dirY = new haxe.ds.Vector<Float>(maxCols);
        camX = new haxe.ds.Vector<Float>(maxCols);
        for (i in 0...maxCols) { dirX[i] = 0.0; dirY[i] = 0.0; camX[i] = 0.0; }
    }

    // rebuilds camX only; dirX/dirY are rebuilt by castRays() when ang changes
    public function setColumns(cols:Int, fov:Float):Void {
        this.cols = cols;   // SKELETON: camX not rebuilt
        this.fov = fov;
    }

    // fills out for cols columns, out.count = cols. DEVIATION: the contract names this `cast`, a Haxe keyword; it is `castRays`.
    public function castRays(world:World, px:Float, py:Float, ang:Float, out:RayHits):Void {
        // SKELETON: every column reports no hit at MAX_DIST
        var n = cols;
        var dist = out.dist;
        var hit = out.hit;
        for (i in 0...n) { dist[i] = Cells.ONE * MAX_DIST; hit[i] = 0; }
        out.count = n;
    }
}
