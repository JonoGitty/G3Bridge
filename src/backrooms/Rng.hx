// The seeded RNG everyone shares (CONTRACT §0). Core class: no flash.* imports.
// COMPLETE per the contract. Test vectors: mix(1) = 1364076727, mix(-1) = -2114883783,
// new Rng(1).nextInt() x3 = 524866043, -1417553088, -1914964556, hash3(1, 2, 3) = 973068298.
//
// The two multiplies in mix() are done as a 16-bit split so the low 32 bits are exact
// on every target (AVM2 promotes an overflowing Int*Int to Number and would lose the low
// bits; the split keeps every partial product below 2^48). Result is identical to the
// contract's `h *= 0x85EBCA6B` under 32-bit wrap.
class Rng {
    public var state:Int;

    public function new(seed:Int):Void {
        state = mix(seed);
        if (state == 0) state = 0x9E3779B9;
    }

    // xorshift32: x ^= x << 13; x ^= x >>> 17; x ^= x << 5; returns the new state (signed 32-bit)
    public function nextInt():Int {
        var x = state;
        x ^= x << 13;
        x ^= x >>> 17;
        x ^= x << 5;
        state = x;
        return x;
    }

    // (nextInt() >>> 8) / 16777216.0, in [0, 1)
    public function nextFloat():Float {
        return (nextInt() >>> 8) / 16777216.0;
    }

    // lo <= r < hi, uniform; requires hi > lo
    public function range(lo:Int, hi:Int):Int {
        return lo + Std.int(nextFloat() * (hi - lo));
    }

    // nextFloat() < p
    public function chance(p:Float):Bool {
        return nextFloat() < p;
    }

    // a * b modulo 2^32, exact on every target (see header)
    static inline function mul32(a:Int, b:Int):Int {
        return ((a & 0xFFFF) * b) + (((a >>> 16) * b) << 16);
    }

    // murmur3 fmix32: h ^= h>>>16; h *= 0x85EBCA6B; h ^= h>>>13; h *= 0xC2B2AE35; h ^= h>>>16
    public static function mix(h:Int):Int {
        h ^= h >>> 16;
        h = mul32(h, 0x85EBCA6B);
        h ^= h >>> 13;
        h = mul32(h, 0xC2B2AE35);
        h ^= h >>> 16;
        return h;
    }

    // mix(a ^ mix(b + 0x9E3779B9))
    public static function hash2(a:Int, b:Int):Int {
        return mix(a ^ mix(b + 0x9E3779B9));
    }

    // hash2(hash2(a, b), c)
    public static function hash3(a:Int, b:Int, c:Int):Int {
        return hash2(hash2(a, b), c);
    }

    // (h >>> 8) / 16777216.0
    public static function unit(h:Int):Float {
        return (h >>> 8) / 16777216.0;
    }

    // stream tags: every subsystem seeds its own Rng with hash3(tapeSeed, TAG, n) and never shares an instance
    public static inline var TAG_CHUNK = 1;
    public static inline var TAG_EDGE = 2;
    public static inline var TAG_ZONE = 3;
    public static inline var TAG_TEX = 4;
    public static inline var TAG_DIRECTOR = 5;
    public static inline var TAG_TAPE = 6;
    public static inline var TAG_PAPER = 7;
    public static inline var TAG_INK = 8;
    public static inline var TAG_GRAIN = 9;
    public static inline var TAG_BOT = 10;
    public static inline var TAG_DISTANT = 11;
}
