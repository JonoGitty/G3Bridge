// Procedural chunk generation (CONTRACT §1, DESIGN §2). Core class: no flash.* imports.
// SKELETON: signatures exact; bodies are placeholders (generate fills an all-FLOOR chunk).
class ChunkGen {
    public static inline var Z_HALL = 0;
    public static inline var Z_WARREN = 1;
    public static inline var Z_ROOMS = 2;
    public static inline var Z_DARK = 3;
    public static var opsCounter:Int = 0;             // incremented by inner loops; tests assert < 200000 per chunk

    // private scratch (allocated once, static) — implementer may resize/rename
    static var spine:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);
    static var scratch:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.AREA);
    static var edgeN:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);
    static var edgeE:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);
    static var edgeS:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);
    static var edgeW:haxe.ds.Vector<Int> = new haxe.ds.Vector<Int>(Chunk.SIZE);

    public static function zoneAt(tapeSeed:Int, cx:Int, cy:Int):Int {
        return Z_HALL; // SKELETON
    }

    // openness 0..1 of the low-frequency zone noise at a point in chunk units (used by edgeProfile); pure
    public static function openness(tapeSeed:Int, fx:Float, fy:Float):Float {
        return 0.5; // SKELETON
    }

    // 32-entry profile (1 = open, 0 = wall) of the edge shared by 4-adjacent chunks a and b, identical for (a,b) and (b,a).
    // Entry i runs along the edge in increasing x (horizontal edge) or increasing y (vertical edge). At least one 1.
    public static function edgeProfile(tapeSeed:Int, ax:Int, ay:Int, bx:Int, by:Int, out:haxe.ds.Vector<Int>):Void {
        for (i in 0...Chunk.SIZE) out[i] = 1; // SKELETON: fully open, symmetric by construction
    }

    // Fully generates `out` (cx, cy, zone, cells, generation++) as a pure function of (tapeSeed, cx, cy). altSeed != 0 XORs the chunk seed (error recovery).
    public static function generate(tapeSeed:Int, cx:Int, cy:Int, out:Chunk, altSeed:Int = 0):Void {
        // SKELETON: all floor
        out.cx = cx;
        out.cy = cy;
        out.zone = zoneAt(tapeSeed, cx, cy);
        out.fill(Cells.FLOOR);
        out.generation++;
    }

    // Flood-fill from the hub; carve tunnels to unreached regions; fill the rest WALL. Returns cells carved. Called by generate; public for tests.
    public static function repairConnectivity(c:Chunk, hubX:Int, hubY:Int):Int {
        return 0; // SKELETON
    }

    // Test helper: number of floor cells reachable from (sx, sy) inside the chunk (4-connected, walkable cells).
    public static function floodCount(c:Chunk, sx:Int, sy:Int):Int {
        return 0; // SKELETON
    }

    // packed local (x << 5) | y of the hub cell, middle third
    public static function hubOf(tapeSeed:Int, cx:Int, cy:Int):Int {
        return (16 << 5) | 16; // SKELETON
    }
}
