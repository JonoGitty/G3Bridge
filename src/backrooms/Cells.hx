// Shared cell constants and bit helpers (CONTRACT §0). Core class: no flash.* imports.
// COMPLETE per the contract.
class Cells {
    // cell types (bits 0-2)
    public static inline var FLOOR = 0;
    public static inline var WALL = 1;
    public static inline var PILLAR = 2;
    public static inline var WET = 3;
    public static inline var DARK = 4;
    public static inline var PIT = 5;
    public static inline var TYPE_MASK = 7;
    public static inline var VAR_SHIFT = 3;        // bits 3-5: wall texture variant 0..7
    public static inline var VAR_MASK = 0x38;
    public static inline var LIGHT = 0x40;         // bit 6: light panel in the ceiling above
    public static inline var DAMAGED = 0x80;       // bit 7: damaged wall
    // faces of a cell (the side the camera sees)
    public static inline var N = 0;  // edge at y (toward y-1)
    public static inline var E = 1;  // edge at x+1
    public static inline var S = 2;  // edge at y+1
    public static inline var W = 3;  // edge at x (toward x-1)
    // fixed point
    public static inline var FP = 16;
    public static inline var ONE = 65536;
    public static inline function type(c:Int):Int return c & TYPE_MASK;
    public static inline function solid(c:Int):Bool { var t = c & TYPE_MASK; return t == WALL || t == PILLAR; }
    public static inline function walkable(c:Int):Bool return !solid(c);   // PIT is walkable (and lethal)
    public static inline function variant(c:Int):Int return (c & VAR_MASK) >> VAR_SHIFT;
    public static inline function hasLight(c:Int):Bool return (c & LIGHT) != 0;
    public static inline function pack(x:Int, y:Int):Int return ((x & 0xFFFF) << 16) | (y & 0xFFFF);
    public static inline function unpackX(p:Int):Int return p >> 16;            // sign-extended
    public static inline function unpackY(p:Int):Int return (p << 16) >> 16;    // sign-extended
    public static inline function chunkOf(v:Int):Int return v >> 5;             // floor division by 32, negatives correct
    public static inline function inChunk(v:Int):Int return v & 31;             // 0..31, negatives correct
}
