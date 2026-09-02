// Procedural banded textures and sprite masks (CONTRACT §2, DESIGN §1). fp class.
//
// Fourteen 64x64 textures, each stored column-major with 16 pre-darkened shade bands in
// one flash.Vector<UInt> of 65,536 entries: index = (band << 12) | (tx << 6) | ty.
// Band b = base with every channel * (15 - b) / 15, blended toward the fog colour
// 0xFF0A0906 from band 12, band 15 exactly 0xFF000000. The per-band channel curves are
// three 16x256 lookup tables built once in the constructor, so banding a texture is
// three table reads per texel (the cheapest form of the 0.9 M banded writes; see Cost).
//
// Everything derives from Rng.hash3(tape.seed, TAG_TEX, id): the same tape gives the
// same bytes on every run. Derived textures (damaged wall, the three 15% dark-zone
// textures, wet and rim carpet) regenerate their parent's base from the parent's own
// seed before modifying it, so "variant 0 at 15%" is exactly variant 0.
//
// Allocation: the constructor allocates every vector (the 14 banks, the scratch base
// and noise fields, the lattice, the LUTs, the masks, noise256 and its band table);
// build() only fills them (plus the per-texture Rng objects) and runs under the tape card.
// Cost: ~0.9 M banded texel writes plus the base generation; expect 100-200 ms on the G4
// (the contract's 30-60 ms is optimistic for 14 x 16 bands); the card hides it.
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
    public static inline var T_CARPET_DARK = 13;        // carpet at 15% (the floor of DARK cells), mirroring T_WALL_DARK / T_CEIL_DARK
    public static inline var COUNT = 14;
    public static inline var BANDS = 16;
    public static inline var SIZE = 64;
    public static inline var BAND_SHIFT = 12;           // index = (band << 12) | (tx << 6) | ty
    static inline var TEX_LEN = 65536;                  // BANDS * SIZE * SIZE
    static inline var TEXELS = 4096;                    // SIZE * SIZE
    static inline var FOG_R = 0x0A;                     // fog colour 0xFF0A0906
    static inline var FOG_G = 0x09;
    static inline var FOG_B = 0x06;
    static inline var DARK_MUL = 38;                    // 15% of full (38 / 256 = 0.148)
    static inline var SEED_NOISE = 100;                 // hash3 stream ids beyond the texture ids
    static inline var SEED_SPRITE = 200;                // + kind
    static inline var MASK_BODY = 1;
    static inline var MASK_EYE = 2;
    static inline var W_W = 32;                         // Watcher mask size
    static inline var W_H = 64;
    static inline var H_W = 48;                         // Hound mask size
    static inline var H_H = 32;

    public var built:Bool;
    public var noise256:flash.Vector<UInt>;              // 256 dark greys 0xFF080808..0xFF282828 for the Watcher fill, rebuilt per tape
    public var noiseBands:flash.Vector<UInt>;            // 16 x 256: noise256[i] darkened by band b at index (b << 8) | i; band 15 = black. SpritePass reads it (same unit)
    public var avgCol:flash.Vector<UInt>;                // COUNT x 16: mean colour of texture id at band b, index (id << 4) | b. Renderer's F0 row colours (same unit)
    public var bank:flash.Vector<flash.Vector<UInt>>;    // COUNT entries of TEX_LEN, fixed; get(id) == bank[id]. Renderer hoists it once per frame (same unit)

    var watcherMasks:flash.Vector<flash.Vector<Int>>;    // spriteFrames(K_WATCHER) masks of 32*64
    var houndMasks:flash.Vector<flash.Vector<Int>>;      // spriteFrames(K_HOUND) masks of 48*32

    // scratch, allocated once
    var base:flash.Vector<UInt>;                         // one 64x64 base image, column-major (tx << 6) | ty, 0xFFRRGGBB
    var noiseA:flash.Vector<Int>;                        // 4096 signed noise field
    var noiseB:flash.Vector<Int>;                        // 4096 signed noise field
    var lattice:flash.Vector<Int>;                       // up to 32x32 lattice values for value noise
    var lutR:flash.Vector<Int>;                          // 16 x 256 per-band channel curves
    var lutG:flash.Vector<Int>;
    var lutB:flash.Vector<Int>;

    // allocates COUNT vectors of 65536 (fixed) once
    public function new():Void {
        built = false;
        bank = new flash.Vector<flash.Vector<UInt>>(COUNT, true);
        for (i in 0...COUNT) bank[i] = new flash.Vector<UInt>(TEX_LEN, true);
        noise256 = new flash.Vector<UInt>(256, true);
        noiseBands = new flash.Vector<UInt>(BANDS * 256, true);
        avgCol = new flash.Vector<UInt>(COUNT * BANDS, true);
        var wf = spriteFrames(Entity.K_WATCHER);
        watcherMasks = new flash.Vector<flash.Vector<Int>>(wf, true);
        for (i in 0...wf) watcherMasks[i] = new flash.Vector<Int>(W_W * W_H, true);
        var hf = spriteFrames(Entity.K_HOUND);
        houndMasks = new flash.Vector<flash.Vector<Int>>(hf, true);
        for (i in 0...hf) houndMasks[i] = new flash.Vector<Int>(H_W * H_H, true);
        base = new flash.Vector<UInt>(TEXELS, true);
        noiseA = new flash.Vector<Int>(TEXELS, true);
        noiseB = new flash.Vector<Int>(TEXELS, true);
        lattice = new flash.Vector<Int>(1024, true);
        lutR = new flash.Vector<Int>(BANDS * 256, true);
        lutG = new flash.Vector<Int>(BANDS * 256, true);
        lutB = new flash.Vector<Int>(BANDS * 256, true);
        buildLuts();
        // a fresh Textures is black everywhere and its masks are empty until build()
        for (i in 0...COUNT) {
            var v = bank[i];
            for (k in 0...TEX_LEN) v[k] = 0xFF000000;
            for (b in 0...BANDS) avgCol[(i << 4) | b] = 0xFF000000;
        }
        for (i in 0...256) noise256[i] = 0xFF080808;
        for (i in 0...(BANDS * 256)) noiseBands[i] = 0xFF000000;
    }

    // The contract's band law as three channel curves: c * (15 - b) / 15, a blend toward the fog colour for b >= 12, black at 15.
    function buildLuts():Void {
        for (b in 0...BANDS) {
            var mix = b >= 12 ? (b - 11) / 4.0 : 0.0;   // 12: .25, 13: .5, 14: .75
            for (c in 0...256) {
                var r:Int; var g:Int; var bl:Int;
                if (b == 15) { r = 0; g = 0; bl = 0; }
                else {
                    var v = Std.int((c * (15 - b)) / 15);   // exact c at b == 0
                    r = v; g = v; bl = v;
                    if (b >= 12) {
                        r = Std.int(v + (FOG_R - v) * mix + 0.5);
                        g = Std.int(v + (FOG_G - v) * mix + 0.5);
                        bl = Std.int(v + (FOG_B - v) * mix + 0.5);
                    }
                }
                var k = (b << 8) | c;
                lutR[k] = r; lutG[k] = g; lutB[k] = bl;
            }
        }
    }

    static inline function clamp255(v:Int):Int return v < 0 ? 0 : (v > 255 ? 255 : v);
    static inline function rgb(r:Int, g:Int, b:Int):UInt return (0xFF000000 | (clamp255(r) << 16) | (clamp255(g) << 8) | clamp255(b));
    static inline function chR(c:UInt):Int return (c >> 16) & 0xFF;
    static inline function chG(c:UInt):Int return (c >> 8) & 0xFF;
    static inline function chB(c:UInt):Int return c & 0xFF;

    static function texRng(seed:Int, id:Int):Rng return new Rng(Rng.hash3(seed, Rng.TAG_TEX, id));

    // fills all textures from Rng.hash3(tape.seed, TAG_TEX, id); ~30-60 ms; may be called per tape
    public function build(tape:Tape):Void {
        var seed = tape.seed;
        // wallpaper variants 0..3
        for (v in 0...4) {
            genWall(seed, v, tape);
            bandOut(T_WALL0 + v, true);
        }
        // damaged: variant 0 torn to the plaster
        genWall(seed, 0, tape);
        tearWall(texRng(seed, T_WALL_DAMAGED));
        bandOut(T_WALL_DAMAGED, true);
        // dark-zone wall: variant 0 at 15%
        genWall(seed, 0, tape);
        scaleBase(DARK_MUL);
        bandOut(T_WALL_DARK, true);
        // carpet family
        genCarpet(seed);
        bandOut(T_CARPET, false);
        genCarpet(seed);
        scaleBase(179);                                  // 70%
        wetSpeckle(texRng(seed, T_CARPET_WET));
        bandOut(T_CARPET_WET, false);
        genCarpet(seed);
        scaleBase(320);                                  // 125%
        bandOut(T_CARPET_RIM, false);
        genCarpet(seed);
        scaleBase(DARK_MUL);
        bandOut(T_CARPET_DARK, false);
        // ceiling family
        genCeiling(seed);
        bandOut(T_CEIL, false);
        genPanel(seed);
        bandOut(T_CEIL_PANEL, false);
        genCeiling(seed);
        scaleBase(DARK_MUL);
        bandOut(T_CEIL_DARK, false);
        // pit: pure black in every band
        var pit = bank[T_PIT];
        for (k in 0...TEX_LEN) pit[k] = 0xFF000000;
        for (b in 0...BANDS) avgCol[(T_PIT << 4) | b] = 0xFF000000;
        // Watcher fill noise and its band table
        var nr = texRng(seed, SEED_NOISE);
        for (i in 0...256) {
            var g = 8 + nr.range(0, 33);                 // 0x08..0x28
            noise256[i] = rgb(g, g, g);
        }
        for (b in 0...BANDS) {
            var bb = b << 8;
            for (i in 0...256) {
                var g = chG(noise256[i]);
                noiseBands[bb | i] = rgb(lutR[bb | g], lutG[bb | g], lutB[bb | g]);
            }
        }
        // sprite masks
        buildWatcherMasks(texRng(seed, SEED_SPRITE + Entity.K_WATCHER));
        buildHoundMasks(texRng(seed, SEED_SPRITE + Entity.K_HOUND));
        built = true;
    }

    public inline function get(id:Int):flash.Vector<UInt> return bank[id];

    // Variant-bit conventions set by ChunkGen: WALL/PILLAR cells in a DARK chunk carry variant 7; floor cells ringing a pit carry variant 1; all other floor cells variant 0.
    // variant 7 => T_WALL_DARK; DAMAGED bit => T_WALL_DAMAGED; else T_WALL0 + (variant & 3)
    public static inline function wallId(cell:Int):Int {
        return Cells.variant(cell) == 7 ? T_WALL_DARK : ((cell & Cells.DAMAGED) != 0 ? T_WALL_DAMAGED : T_WALL0 + (Cells.variant(cell) & 3));
    }

    // type WET => T_CARPET_WET; PIT => T_PIT; DARK => T_CARPET_DARK; variant 1 => T_CARPET_RIM; else T_CARPET
    public static inline function floorId(cell:Int):Int {
        return Cells.type(cell) == Cells.WET ? T_CARPET_WET : (Cells.type(cell) == Cells.PIT ? T_PIT : (Cells.type(cell) == Cells.DARK ? T_CARPET_DARK : (Cells.variant(cell) == 1 ? T_CARPET_RIM : T_CARPET)));
    }

    // type DARK => T_CEIL_DARK; LIGHT bit => T_CEIL_PANEL; else T_CEIL
    public static inline function ceilId(cell:Int):Int {
        return Cells.type(cell) == Cells.DARK ? T_CEIL_DARK : (Cells.hasLight(cell) ? T_CEIL_PANEL : T_CEIL);
    }

    // sprite masks: column-major flash.Vector<Int>, w*h entries, 0 transparent, 1 body, 2 eye
    public function sprite(kind:Int, frame:Int):flash.Vector<Int> {
        if (kind == Entity.K_HOUND) {
            if (frame < 0) frame = 0; else if (frame >= 3) frame = 2;
            return houndMasks[frame];
        }
        if (frame < 0) frame = 0; else if (frame >= 2) frame = 1;
        return watcherMasks[frame];
    }

    // Watcher 32, Hound 48
    public static function spriteW(kind:Int):Int {
        return kind == Entity.K_HOUND ? H_W : W_W;
    }

    // Watcher 64, Hound 32
    public static function spriteH(kind:Int):Int {
        return kind == Entity.K_HOUND ? H_H : W_H;
    }

    // 2, 3
    public static function spriteFrames(kind:Int):Int {
        return kind == Entity.K_HOUND ? 3 : 2;
    }

    // ---------------------------------------------------------------- noise

    // Adds one octave of tileable value noise (lattice period `period` texels, a power of two) into `out`, centred on 0 with amplitude +/- amp/2.
    function addNoise(rng:Rng, out:flash.Vector<Int>, period:Int, amp:Int):Void {
        var ps = shiftOf(period);
        var n = SIZE >> ps;                              // lattice cells per axis
        var lat = lattice;
        var cells = n * n;
        for (i in 0...cells) lat[i] = rng.range(0, 256);
        var pm = period - 1;
        var mask = n - 1;
        for (tx in 0...SIZE) {
            var lx = tx >> ps;
            var lx1 = (lx + 1) & mask;
            var u = ((tx & pm) << 8) >> ps;              // 0..255 across the lattice cell
            var su = (u * u * (768 - 2 * u)) >> 16;      // smoothstep, 0..256
            var iu = 256 - su;
            var col = tx << 6;
            for (ty in 0...SIZE) {
                var ly = ty >> ps;
                var ly1 = (ly + 1) & mask;
                var v = ((ty & pm) << 8) >> ps;
                var sv = (v * v * (768 - 2 * v)) >> 16;
                var a = lat[ly * n + lx];
                var b = lat[ly * n + lx1];
                var c = lat[ly1 * n + lx];
                var d = lat[ly1 * n + lx1];
                var top = a * iu + b * su;
                var bot = c * iu + d * su;
                var val = (top * (256 - sv) + bot * sv) >> 16;   // 0..255
                out[col | ty] += ((val - 128) * amp) >> 8;
            }
        }
    }

    static function shiftOf(period:Int):Int {
        var s = 0;
        while ((1 << s) < period) s++;
        return s;
    }

    function clearNoise(v:flash.Vector<Int>):Void {
        for (i in 0...TEXELS) v[i] = 0;
    }

    // ---------------------------------------------------------------- bases

    // Wallpaper variant v: base #C9B160 nudged per variant and by the tape tint, two-octave stains, a darker seam every 16 texels, a faint 4-texel stripe.
    function genWall(seed:Int, v:Int, tape:Tape):Void {
        var rng = texRng(seed, T_WALL0 + v);
        var br = 0xC9 + rng.range(-10, 11);
        var bg = 0xB1 + rng.range(-10, 11);
        var bb = 0x60 + rng.range(-8, 9);
        br = Std.int(br * tape.tintR);
        bg = Std.int(bg * tape.tintG);
        bb = Std.int(bb * tape.tintB);
        clearNoise(noiseA);
        addNoise(rng, noiseA, 16, 44);                   // broad tone
        addNoise(rng, noiseA, 8, 22);                    // grain
        clearNoise(noiseB);
        addNoise(rng, noiseB, 32, 160);                  // stains: a slow field, thresholded
        var stainR = 0x8A; var stainG = 0x6E; var stainB = 0x30;
        var seamShift = rng.range(0, 16);
        var out = base;
        for (tx in 0...SIZE) {
            var col = tx << 6;
            var sx = (tx + seamShift) & 15;
            var seamMul = sx == 0 ? 222 : (sx == 1 ? 244 : 256);      // 87%, 95%, 100%: the seam plus the red shift is the permanent chroma fringe
            var stripe = (tx & 3) == 0 ? -4 : 0;
            for (ty in 0...SIZE) {
                var k = col | ty;
                var shade = 256 + noiseA[k];
                var r = ((br + stripe) * shade) >> 8;
                var g = ((bg + stripe) * shade) >> 8;
                var b = ((bb + stripe) * shade) >> 8;
                var st = noiseB[k] - 30;                  // stain strength above the threshold
                if (st > 0) {
                    if (st > 64) st = 64;
                    r += ((stainR - r) * st) >> 7;        // up to half way to the stain colour
                    g += ((stainG - g) * st) >> 7;
                    b += ((stainB - b) * st) >> 7;
                }
                r = (r * seamMul) >> 8; g = (g * seamMul) >> 8; b = (b * seamMul) >> 8;
                out[k] = rgb(r, g, b);
            }
        }
    }

    // Torn-paper reveal over the current base: a slow field thresholded into plaster, with a lighter paper edge around the tear.
    function tearWall(rng:Rng):Void {
        clearNoise(noiseA);
        addNoise(rng, noiseA, 16, 150);
        addNoise(rng, noiseA, 8, 60);
        clearNoise(noiseB);
        addNoise(rng, noiseB, 8, 50);                    // plaster grain
        var out = base;
        for (k in 0...TEXELS) {
            var t = noiseA[k];
            if (t > 34) {
                var g = 0x5C + noiseB[k];                 // plaster, greyish
                out[k] = rgb(g + 6, g, g - 10);
            } else if (t > 24) {
                var c = out[k];                           // curled paper edge, lighter
                out[k] = rgb(chR(c) + 40, chG(c) + 36, chB(c) + 30);
            } else if (t > 20) {
                var c = out[k];                           // shadow under the curl
                out[k] = rgb((chR(c) * 3) >> 2, (chG(c) * 3) >> 2, (chB(c) * 3) >> 2);
            }
        }
    }

    // Carpet: mustard-brown low-contrast speckle with a faint weave.
    function genCarpet(seed:Int):Void {
        var rng = texRng(seed, T_CARPET);
        var br = 0x7A + rng.range(-6, 7);
        var bg = 0x64 + rng.range(-6, 7);
        var bb = 0x32 + rng.range(-4, 5);
        clearNoise(noiseA);
        addNoise(rng, noiseA, 8, 28);
        addNoise(rng, noiseA, 4, 18);
        var out = base;
        for (tx in 0...SIZE) {
            var col = tx << 6;
            for (ty in 0...SIZE) {
                var k = col | ty;
                var sp = rng.range(-9, 10);               // per-texel speckle
                var weave = ((tx + ty) & 1) == 0 ? 3 : -3;
                var shade = 256 + noiseA[k] + sp + weave;
                out[k] = rgb((br * shade) >> 8, (bg * shade) >> 8, (bb * shade) >> 8);
            }
        }
    }

    // Sparse specular speckles on the (already darkened) wet carpet.
    function wetSpeckle(rng:Rng):Void {
        var out = base;
        for (k in 0...TEXELS) {
            if (rng.range(0, 24) == 0) {
                var c = out[k];
                var lift = 50 + rng.range(0, 40);
                out[k] = rgb(chR(c) + lift, chG(c) + lift, chB(c) + lift - 8);
            }
        }
    }

    // Ceiling tile: off-white grid every 32 texels with grime and pinholes.
    function genCeiling(seed:Int):Void {
        var rng = texRng(seed, T_CEIL);
        var br = 0xA8 + rng.range(-6, 7);
        var bg = 0xA0 + rng.range(-6, 7);
        var bb = 0x8C + rng.range(-6, 7);
        clearNoise(noiseA);
        addNoise(rng, noiseA, 16, 40);
        addNoise(rng, noiseA, 8, 14);
        var out = base;
        for (tx in 0...SIZE) {
            var col = tx << 6;
            var gx = tx & 31;
            for (ty in 0...SIZE) {
                var k = col | ty;
                var gy = ty & 31;
                var mul = 256;
                if (gx == 0 || gy == 0) mul = 150;                    // the T-bar shadow line
                else if (gx == 31 || gy == 31) mul = 218;             // the tile edge
                else if (rng.range(0, 12) == 0) mul = 208;            // acoustic pinholes
                var shade = 256 + noiseA[k];
                var r = (((br * shade) >> 8) * mul) >> 8;
                var g = (((bg * shade) >> 8) * mul) >> 8;
                var b = (((bb * shade) >> 8) * mul) >> 8;
                out[k] = rgb(r, g, b);
            }
        }
    }

    // Ceiling light panel: a dark frame around a bright diffuser with a faint grid.
    function genPanel(seed:Int):Void {
        var rng = texRng(seed, T_CEIL_PANEL);
        clearNoise(noiseA);
        addNoise(rng, noiseA, 16, 12);
        var out = base;
        for (tx in 0...SIZE) {
            var col = tx << 6;
            for (ty in 0...SIZE) {
                var k = col | ty;
                var dx = tx < 32 ? tx : 63 - tx;                       // distance to the nearest edge
                var dy = ty < 32 ? ty : 63 - ty;
                var d = dx < dy ? dx : dy;
                if (d < 5) {
                    var g = d < 4 ? 0x50 : 0x70;                       // frame, a lighter inner lip
                    out[k] = rgb(g + 4, g + 2, g - 4);
                } else {
                    var shade = 256 + noiseA[k];
                    var r = 0xF2; var g = 0xEE; var b = 0xDA;
                    if ((tx & 3) == 0 || (ty & 3) == 0) { r -= 18; g -= 18; b -= 16; }   // diffuser grid
                    var fall = d < 12 ? (12 - d) * 2 : 0;              // slightly dimmer toward the frame
                    r = ((r - fall) * shade) >> 8; g = ((g - fall) * shade) >> 8; b = ((b - fall) * shade) >> 8;
                    out[k] = rgb(r, g, b);
                }
            }
        }
    }

    // Multiplies every channel of the current base by mul / 256.
    function scaleBase(mul:Int):Void {
        var out = base;
        for (k in 0...TEXELS) {
            var c = out[k];
            out[k] = rgb((chR(c) * mul) >> 8, (chG(c) * mul) >> 8, (chB(c) * mul) >> 8);
        }
    }

    // Writes the current base into bank[id] as 16 shade bands and records its per-band mean colour. redShift: the red channel of column tx comes from column (tx + 1) & 63.
    function bandOut(id:Int, redShift:Bool):Void {
        var src = base;
        var dst = bank[id];
        var lr = lutR; var lg = lutG; var lb = lutB;
        var sumR = 0; var sumG = 0; var sumB = 0;
        for (k in 0...TEXELS) {
            var c = src[k];
            sumR += chR(c); sumG += chG(c); sumB += chB(c);
        }
        var meanR = sumR >> 12; var meanG = sumG >> 12; var meanB = sumB >> 12;
        for (b in 0...BANDS) {
            var bb = b << 8;
            var dstBase = b << BAND_SHIFT;
            for (tx in 0...SIZE) {
                var col = tx << 6;
                var rcol = redShift ? (((tx + 1) & 63) << 6) : col;
                var o = dstBase | col;
                for (ty in 0...SIZE) {
                    var c = src[col | ty];
                    var r = (src[rcol | ty] >> 16) & 0xFF;
                    dst[o | ty] = 0xFF000000 | (lr[bb | r] << 16) | (lg[bb | ((c >> 8) & 0xFF)] << 8) | lb[bb | (c & 0xFF)];
                }
            }
            avgCol[(id << 4) | b] = 0xFF000000 | (lr[bb | meanR] << 16) | (lg[bb | meanG] << 8) | lb[bb | meanB];
        }
    }

    // ---------------------------------------------------------------- sprite masks

    static function clearMask(m:flash.Vector<Int>, n:Int):Void {
        for (i in 0...n) m[i] = 0;
    }

    // Filled ellipse into a column-major mask of height mh.
    static function ellipse(m:flash.Vector<Int>, mw:Int, mh:Int, cx:Int, cy:Int, rx:Int, ry:Int, val:Int):Void {
        if (rx < 1) rx = 1;
        if (ry < 1) ry = 1;
        var rx2 = rx * rx; var ry2 = ry * ry;
        var lim = rx2 * ry2;
        for (x in (cx - rx)...(cx + rx + 1)) {
            if (x < 0 || x >= mw) continue;
            var dx = x - cx;
            for (y in (cy - ry)...(cy + ry + 1)) {
                if (y < 0 || y >= mh) continue;
                var dy = y - cy;
                if (dx * dx * ry2 + dy * dy * rx2 <= lim) m[x * mh + y] = val;
            }
        }
    }

    // Filled rectangle x0..x1, y0..y1 inclusive.
    static function box(m:flash.Vector<Int>, mw:Int, mh:Int, x0:Int, y0:Int, x1:Int, y1:Int, val:Int):Void {
        if (x0 > x1) { var t = x0; x0 = x1; x1 = t; }
        if (y0 > y1) { var t = y0; y0 = y1; y1 = t; }
        for (x in x0...(x1 + 1)) {
            if (x < 0 || x >= mw) continue;
            for (y in y0...(y1 + 1)) {
                if (y < 0 || y >= mh) continue;
                m[x * mh + y] = val;
            }
        }
    }

    // A limb segment from (x0,y0) down to (x1,y1), `thick` texels wide, walked per row (limbs are mostly vertical).
    static function limb(m:flash.Vector<Int>, mw:Int, mh:Int, x0:Int, y0:Int, x1:Int, y1:Int, thick:Int, val:Int):Void {
        if (y1 < y0) { var t = x0; x0 = x1; x1 = t; t = y0; y0 = y1; y1 = t; }
        var dy = y1 - y0;
        for (y in y0...(y1 + 1)) {
            if (y < 0 || y >= mh) continue;
            var x = dy == 0 ? x0 : x0 + Std.int(((x1 - x0) * (y - y0)) / dy);
            for (k in 0...thick) {
                var xx = x + k;
                if (xx >= 0 && xx < mw) m[xx * mh + y] = val;
            }
        }
    }

    // Tall, thin, no face, slightly too many joints. Frame 1 twitches the limbs.
    function buildWatcherMasks(rng:Rng):Void {
        var mw = W_W; var mh = W_H;
        var lean = rng.range(-1, 2);
        // joint jitter, fixed per tape so the two frames are the same creature
        var la1 = 9 + rng.range(-1, 2); var la2 = 10 + rng.range(-1, 2); var la3 = 8 + rng.range(-1, 2);
        var ra1 = 21 + rng.range(-1, 2); var ra2 = 20 + rng.range(-1, 2); var ra3 = 22 + rng.range(-1, 2);
        var lk = 13 + rng.range(-1, 2); var rk = 18 + rng.range(-1, 2);
        for (f in 0...2) {
            var m = watcherMasks[f];
            clearMask(m, mw * mh);
            var j = f == 0 ? 0 : 1;                                   // frame twitch
            // head and neck
            ellipse(m, mw, mh, 16 + lean, 6, 3, 4, MASK_BODY);
            box(m, mw, mh, 15 + lean, 9, 16 + lean, 13, MASK_BODY);
            // torso: 8 wide at the shoulders tapering to 4 at the hips
            for (y in 13...35) {
                var half = 4 - (((y - 13) * 3) >> 4);                  // 4 .. 1
                if (half < 2) half = 2;
                box(m, mw, mh, 16 - half, y, 15 + half, y, MASK_BODY);
            }
            // arms: three segments each, reaching past the hips
            limb(m, mw, mh, 12, 14, la1 - j, 24, 2, MASK_BODY);
            limb(m, mw, mh, la1 - j, 24, la2, 34 + j, 2, MASK_BODY);
            limb(m, mw, mh, la2, 34 + j, la3 + j, 47, 2, MASK_BODY);
            limb(m, mw, mh, 18, 14, ra1 + j, 25, 2, MASK_BODY);
            limb(m, mw, mh, ra1 + j, 25, ra2, 35 - j, 2, MASK_BODY);
            limb(m, mw, mh, ra2, 35 - j, ra3 - j, 48, 2, MASK_BODY);
            // legs: hip to knee to foot, the knee a joint too many
            limb(m, mw, mh, 14, 34, lk - j, 47, 2, MASK_BODY);
            limb(m, mw, mh, lk - j, 47, 13 + j, 63, 2, MASK_BODY);
            limb(m, mw, mh, 17, 34, rk + j, 46, 2, MASK_BODY);
            limb(m, mw, mh, rk + j, 46, 18 - j, 63, 2, MASK_BODY);
        }
    }

    // Low, wide, quadruped-ish, two 2-px eyes. Three gait frames.
    function buildHoundMasks(rng:Rng):Void {
        var mw = H_W; var mh = H_H;
        var earL = rng.range(0, 2);
        var earR = rng.range(0, 2);
        for (f in 0...3) {
            var m = houndMasks[f];
            clearMask(m, mw * mh);
            // body and haunches
            ellipse(m, mw, mh, 24, 18, 18, 7, MASK_BODY);
            ellipse(m, mw, mh, 9, 19, 6, 6, MASK_BODY);
            ellipse(m, mw, mh, 39, 19, 6, 6, MASK_BODY);
            // head, raised, with ears
            ellipse(m, mw, mh, 24, 11, 7, 5, MASK_BODY);
            box(m, mw, mh, 21, 14, 27, 17, MASK_BODY);                // muzzle
            box(m, mw, mh, 17 + earL, 5, 19 + earL, 8, MASK_BODY);
            box(m, mw, mh, 29 - earR, 5, 31 - earR, 8, MASK_BODY);
            // legs: four 3-px columns, alternate pairs lifted per frame
            var lift1 = f == 1 ? 3 : 0;
            var lift2 = f == 2 ? 3 : 0;
            box(m, mw, mh, 7, 22, 9, 31 - lift1, MASK_BODY);
            box(m, mw, mh, 15, 22, 17, 31 - lift2, MASK_BODY);
            box(m, mw, mh, 30, 22, 32, 31 - lift1, MASK_BODY);
            box(m, mw, mh, 38, 22, 40, 31 - lift2, MASK_BODY);
            // eyes: two 2-px pale pixels, drawn last so they sit on the head
            box(m, mw, mh, 20, 10, 21, 10, MASK_EYE);
            box(m, mw, mh, 27, 10, 28, 10, MASK_EYE);
        }
    }
}
