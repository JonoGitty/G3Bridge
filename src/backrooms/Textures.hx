// Procedural banded textures and sprite masks (CONTRACT §2, DESIGN §1). fp class.
// SKELETON: constructor allocates every vector at contract size; the id helpers are complete; build() only sets built.
class Textures {
    public static inline var T_WALL0 = 0;   // ..3
    public static inline var T_WALL_DAMAGED = 4;
    public static inline var T_WALL_DARK = 5;
    public static inline var T_CARPET = 6;
    public static inline var T_CARPET_WET = 7;
    public static inline var T_CARPET_RIM = 8;
    public static inline var T_CEIL = 9;
    public static inline var T_CEIL_PANEL = 10;
    public static inline var T_CEIL_DARK = 11;
    public static inline var T_PIT = 12;
    public static inline var COUNT = 13;
    public static inline var BANDS = 16;
    public static inline var SIZE = 64;
    public static inline var BAND_SHIFT = 12;           // index = (band << 12) | (tx << 6) | ty
    static inline var TEX_LEN = 65536;           // BANDS * SIZE * SIZE
    public var built:Bool;
    public var noise256:flash.Vector<UInt>;              // 256 dark greys 0xFF080808..0xFF282828 for the Watcher fill, rebuilt per tape

    var tex:flash.Vector<flash.Vector<UInt>>;            // COUNT entries of TEX_LEN, fixed
    var watcherMasks:flash.Vector<flash.Vector<Int>>;    // spriteFrames(K_WATCHER) masks of 32*64
    var houndMasks:flash.Vector<flash.Vector<Int>>;      // spriteFrames(K_HOUND) masks of 48*32

    // allocates COUNT vectors of 65536 (fixed) once
    public function new():Void {
        built = false;
        tex = new flash.Vector<flash.Vector<UInt>>(COUNT, true);
        for (i in 0...COUNT) tex[i] = new flash.Vector<UInt>(TEX_LEN, true);
        noise256 = new flash.Vector<UInt>(256, true);
        var wf = spriteFrames(Entity.K_WATCHER);
        watcherMasks = new flash.Vector<flash.Vector<Int>>(wf, true);
        for (i in 0...wf) watcherMasks[i] = new flash.Vector<Int>(spriteW(Entity.K_WATCHER) * spriteH(Entity.K_WATCHER), true);
        var hf = spriteFrames(Entity.K_HOUND);
        houndMasks = new flash.Vector<flash.Vector<Int>>(hf, true);
        for (i in 0...hf) houndMasks[i] = new flash.Vector<Int>(spriteW(Entity.K_HOUND) * spriteH(Entity.K_HOUND), true);
    }

    // fills all textures from Rng.hash3(tape.seed, TAG_TEX, id); ~30-60 ms; may be called per tape
    public function build(tape:Tape):Void {
        built = true; // SKELETON: vectors stay zero (0x00000000)
    }

    public inline function get(id:Int):flash.Vector<UInt> return tex[id];

    // Variant-bit conventions set by ChunkGen: WALL/PILLAR cells in a DARK chunk carry variant 7; floor cells ringing a pit carry variant 1; all other floor cells variant 0.
    // variant 7 => T_WALL_DARK; DAMAGED bit => T_WALL_DAMAGED; else T_WALL0 + (variant & 3)
    public static inline function wallId(cell:Int):Int {
        return Cells.variant(cell) == 7 ? T_WALL_DARK : ((cell & Cells.DAMAGED) != 0 ? T_WALL_DAMAGED : T_WALL0 + (Cells.variant(cell) & 3));
    }

    // type WET => T_CARPET_WET; PIT => T_PIT; variant 1 => T_CARPET_RIM; else T_CARPET (DARK floor darkens via bands, not texture)
    public static inline function floorId(cell:Int):Int {
        return Cells.type(cell) == Cells.WET ? T_CARPET_WET : (Cells.type(cell) == Cells.PIT ? T_PIT : (Cells.variant(cell) == 1 ? T_CARPET_RIM : T_CARPET));
    }

    // type DARK => T_CEIL_DARK; LIGHT bit => T_CEIL_PANEL; else T_CEIL
    public static inline function ceilId(cell:Int):Int {
        return Cells.type(cell) == Cells.DARK ? T_CEIL_DARK : (Cells.hasLight(cell) ? T_CEIL_PANEL : T_CEIL);
    }

    // sprite masks: column-major flash.Vector<Int>, w*h entries, 0 transparent, 1 body, 2 eye
    public function sprite(kind:Int, frame:Int):flash.Vector<Int> {
        return kind == Entity.K_HOUND ? houndMasks[frame] : watcherMasks[frame]; // SKELETON: masks are all 0
    }

    // Watcher 32, Hound 48
    public static function spriteW(kind:Int):Int {
        return kind == Entity.K_HOUND ? 48 : 32;
    }

    // Watcher 64, Hound 32
    public static function spriteH(kind:Int):Int {
        return kind == Entity.K_HOUND ? 32 : 64;
    }

    // 2, 3
    public static function spriteFrames(kind:Int):Int {
        return kind == Entity.K_HOUND ? 3 : 2;
    }
}
