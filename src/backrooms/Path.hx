// Windowed BFS for the Hound (CONTRACT §1). Core class: no flash.* imports.
// SKELETON: signatures exact; static scratch allocated; bfs() reports unreachable.
class Path {
    public static inline var HALF = 12;                // window is (2*HALF)^2 = 576 cells around the start
    public static inline var MAX_LEN = 128;
    static inline var WINDOW = 576;             // (2 * HALF)^2
    public static var expansions:Int = 0;              // nodes expanded by the last call (telemetry/tests)

    // static scratch, stamp-based so no clearing per call — implementer may rename
    static var visited:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(WINDOW);
    static var queue:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(WINDOW);
    static var parent:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(WINDOW);
    static var stamp:Int = 0;

    // BFS over walkable cells inside the window centred on (sx, sy), clamped to resident chunks. out receives the path as packed cells
    // from the first step to the target (start excluded), at most MAX_LEN. Returns path length, 0 if start == target, -1 if unreachable.
    public static function bfs(world:World, sx:Int, sy:Int, tx:Int, ty:Int, out:haxe.ds.Vector<Int>):Int {
        expansions = 0;
        if (sx == tx && sy == ty) return 0;
        return -1; // SKELETON
    }
}
