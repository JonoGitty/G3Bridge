# BACKROOMS TAPE — module contract

This is what parallel implementers code against without talking to each other. If a
signature here and a signature in a design document disagree, **this file wins**. If
something is not specified here, the implementer chooses, keeps it private, and does
not let another module depend on it.

Design rationale: `DESIGN.md`. Measurements: `BRIEF.md` and `run/telemetry.log`.

## 0. Ground rules

### Layout and packages

- **No package.** Every class is one file at `/mnt/c/AI/G3Bridge/src/backrooms/<Class>.hx`
  (Windows: `C:\AI\G3Bridge\src\backrooms\<Class>.hx`). `Png.hx` and `Telemetry.hx`
  already exist there in this form and are kept.
- Tests live at `/mnt/c/AI/G3Bridge/tests/backrooms/<Name>.hx`, also no package.
- Per-implementer dependency stubs live at `/mnt/c/AI/G3Bridge/stubs/<yourclass>/` and
  are never committed into `src/`.

### Two kinds of class

- **Core** classes: `Rng, Cells, Chunk, ChunkGen, World, RayHits, Raycaster, MapMemory,
  Path, Player, Entity, Watcher, Hound, Director, Tape, Quality, Bot`. They import
  **nothing** from `flash.*`, use `haxe.ds.Vector<T>` for every buffer, no `Dynamic`, no
  `Array` in per-frame paths, and compile under `haxe --interp`. `TestAll` references
  every one of them, so a stray `flash.` import fails the unit build.
- **fp** classes (Flash platform): `Main, Params, Display, Textures, Renderer,
  SpritePass, PixelFont, Hud, Cards, Camcorder, MapPaper, Sfx, LoopPlayer, AudioBus,
  Input, Save, Telemetry, Png, Bench`. They may import `flash.*`. Pixel buffers are
  `flash.Vector<UInt>` (AVM2 `Vector.<uint>`, the type `BitmapData.setVector` needs);
  integer tables are `flash.Vector<Int>` or `haxe.ds.Vector<Int>` (identical on flash).

### Coding rules (every class)

1. Haxe 4.3 syntax. `final` for constants where the value is known at compile time is
   allowed; `static inline var` for numeric constants that hot loops read.
2. Flash 10.1 API only. The compiler enforces `-swf-version 10.1`; nothing with
   `@:require(flash10_2)` or later exists. Known traps: no `BitmapData.encode`, no
   `copyPixelsToByteArray`, no Stage3D, no `Mouse.lock`, no Workers, no
   `Stage.color`. `Stage.fullScreenSourceRect` (9.0.115), `setVector` (10),
   `uncaughtErrorEvents` (10.1), `Sound.extract` (10) exist.
3. No haxelib. Standard library only.
4. **No allocation in the frame loop.** Nothing after `Main.start()` returns may
   execute `new`, an array literal, a string concatenation, a closure creation, or an
   iterator in the per-frame path, except: (a) `Hud` rebuilding its strings once per
   second, (b) `MapPaper` allocating a sheet on first visit (bounded, logged), (c)
   `Telemetry` building its query string at most twice per second, (d) `World`
   allocating a `Chunk` only when the resident count is below its cap (chunks are
   pooled and reused after eviction), (e) `MapMemory` allocating one 1024-entry
   `haxe.ds.Vector<Int>` on the first touch of a map chunk, bounded by
   `MapMemory.MAX_CHUNKS` (256, ~1 MB; a preallocated pool of 256 vectors is the
   equivalent alternative), logged. Every `Point`, `Rectangle`, `ColorTransform`,
   `Matrix` and `Shape` is a field created in the constructor. `for (i in a...b)` is
   allocation-free and allowed; `for (x in array)` is not. **`Map.keys()` and
   `Map.iterator()` allocate an iterator and are forbidden after `Main.start()`**:
   every class that must scan its resident set (`World.evictOutside` and the
   evict-farthest in `World.pump`, `MapMemory.evictFarthest`, `MapPaper.pump`'s sheet
   eviction) keeps a parallel `haxe.ds.Vector<Int>` of resident keys plus a count and
   scans that vector; `tools/backrooms_check.py` greps `src/backrooms` for `.keys()`
   and `.iterator()` and fails on any hit outside a constructor or `buildForTape`.
5. **No `Dynamic` in hot paths** (`Telemetry.ping` takes a `String`; `Params` returns
   `String`; `Save` uses a typedef, and its `Dynamic` is confined to `load`/`flush`).
6. Hot pixel loops: 16.16 fixed point `Int`, no `Float`, no `Math.*`, no field access
   inside the loop (hoist `this.fb` into a local `var fb = this.fb` before the loop),
   no function calls, no bounds-dependent branches that the loop bounds can absorb.
7. Every class compiles standalone: `haxe -cp src/backrooms -cp stubs/<unit>
   -swf-version 10.1 -swf run/check_<unit>.swf <Class>` must succeed with stubs of your
   dependencies that carry exactly the signatures in this file. Haxe resolves class
   paths LAST-match: the last class path wins, so list your stubs after
   `src/backrooms` (verified on Haxe 4.3.7; the reverse order silently compiles src
   against src and never touches the stubs).
8. No `trace` in shipped code paths; `Telemetry.ping` is the only output.
9. Angles are radians, `Float`, 0 = +x, increasing toward +y. Facing vector is
   `(Math.cos(a), Math.sin(a))`. Bearing of a point from the player is
   `atan2(dy, dx) − ang` normalised to (−π, π]; positive = to the right of facing.
10. Time: `dt` is seconds as `Float`, already clamped to 0.1 by `Main`. Nothing else
    reads `getTimer()` except `Main`, `Bench`, `Telemetry` and `LoopPlayer`.

### Shared constants (`Cells`)

```haxe
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
```

`pack` covers cell coordinates in ±32767 (11 hours of straight walking); chunk keys
(`World.key`) cover chunk coordinates in ±32767, i.e. cells in ±1,048,575.

### The seeded RNG everyone shares (`Rng`)

```haxe
class Rng {
    public var state:Int;
    public function new(seed:Int):Void;              // state = mix(seed); if that is 0, state = 0x9E3779B9
    public function nextInt():Int;                   // xorshift32: x ^= x << 13; x ^= x >>> 17; x ^= x << 5; returns the new state (signed 32-bit)
    public function nextFloat():Float;               // (nextInt() >>> 8) / 16777216.0, in [0, 1)
    public function range(lo:Int, hi:Int):Int;       // lo <= r < hi, uniform; requires hi > lo
    public function chance(p:Float):Bool;            // nextFloat() < p
    public static function mix(h:Int):Int;           // murmur3 fmix32: h ^= h>>>16; h *= 0x85EBCA6B; h ^= h>>>13; h *= 0xC2B2AE35; h ^= h>>>16
    public static function hash2(a:Int, b:Int):Int;  // mix(a ^ mix(b + 0x9E3779B9))
    public static function hash3(a:Int, b:Int, c:Int):Int; // hash2(hash2(a, b), c)
    public static function unit(h:Int):Float;        // (h >>> 8) / 16777216.0
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
```

Test vectors (verified in Python and under `haxe --interp`, which wraps at 32 bits):
`mix(0) = 0`, `mix(1) = 1364076727`, `mix(2) = 821347078`, `mix(-1) = -2114883783`,
`mix(0xDEADBEEF) = 233162409`; after `new Rng(1)`, three `nextInt()` calls return
`524866043, -1417553088, -1914964556`; `hash2(1, 2) = 230461417`,
`hash3(1, 2, 3) = 973068298`, `hash3(7, -3, 5) = 236163387`.

Rule: world generation, edge profiles, textures, paper and ink use only hash-derived
`Rng` instances (pure functions of the tape seed), so the same tape is byte-identical
across runs. `Director` and `Bot` own the only advancing streams.

## 1. Core classes

### `Chunk`

```haxe
class Chunk {
    public static inline var SIZE = 32;
    public static inline var AREA = 1024;
    public var cx:Int;
    public var cy:Int;
    public var zone:Int;                              // ChunkGen.Z_HALL..Z_DARK
    public var cells:haxe.ds.Vector<Int>;             // AREA entries, index = (y << 5) | x with x,y in 0..31
    public var generation:Int;                        // incremented by ChunkGen.generate; 0 = never generated
    public function new():Void;                       // allocates cells once; reused by World's pool
    public inline function get(x:Int, y:Int):Int;     // x,y local 0..31, no bounds check
    public inline function set(x:Int, y:Int, v:Int):Void;
    public function fill(v:Int):Void;
}
```
Owns: its cell vector. Touches nothing else. Budget: n/a. Tests: `get/set` round-trip;
`fill` sets all 1024.

### `ChunkGen`

```haxe
class ChunkGen {
    public static inline var Z_HALL = 0;
    public static inline var Z_WARREN = 1;
    public static inline var Z_ROOMS = 2;
    public static inline var Z_DARK = 3;
    public static var opsCounter:Int;                 // incremented by inner loops; tests assert < 200000 per chunk
    public static function zoneAt(tapeSeed:Int, cx:Int, cy:Int):Int;
    // openness 0..1 of the low-frequency zone noise at a point in chunk units (used by edgeProfile); pure
    public static function openness(tapeSeed:Int, fx:Float, fy:Float):Float;
    // 32-entry profile (1 = open, 0 = wall) of the edge shared by 4-adjacent chunks a and b, identical for (a,b) and (b,a).
    // Entry i runs along the edge in increasing x (horizontal edge) or increasing y (vertical edge). At least one 1.
    public static function edgeProfile(tapeSeed:Int, ax:Int, ay:Int, bx:Int, by:Int, out:haxe.ds.Vector<Int>):Void;
    // Fully generates `out` (cx, cy, zone, cells, generation++) as a pure function of (tapeSeed, cx, cy). altSeed != 0 XORs the chunk seed (error recovery).
    public static function generate(tapeSeed:Int, cx:Int, cy:Int, out:Chunk, altSeed:Int = 0):Void;
    // Flood-fill from the hub; carve tunnels to unreached regions; fill the rest WALL. Returns cells carved. Called by generate; public for tests.
    public static function repairConnectivity(c:Chunk, hubX:Int, hubY:Int):Int;
    // Test helper: number of floor cells reachable from (sx, sy) inside the chunk (4-connected, walkable cells).
    public static function floodCount(c:Chunk, sx:Int, sy:Int):Int;
    public static function hubOf(tapeSeed:Int, cx:Int, cy:Int):Int;   // packed LOCAL (y << 5) | x of the hub cell — the same encoding as the Chunk.cells index, so cells[hubOf(...)] is the hub; middle third
}
```
Order inside `generate` is fixed by DESIGN §2 (edge profiles → spines → zone carve → wet →
sightline → pits → variant/light/damage bits → feel rules → repair). Spine cells are
recorded in a private scratch vector so later steps never overwrite them with WALL.
Owns: private scratch vectors (allocated once, static). May touch: `Rng`, `Cells`,
`Chunk`. May not touch: `World`. Budget: ≤ 1.5 ms per chunk on the G4 (≤ 60k ops).
Tests: (1) same `(seed, cx, cy)` twice → identical `cells`; (2) `edgeProfile(a, b)` ==
`edgeProfile(b, a)` and contains a 1, over 1,000 random pairs; (3) `floodCount` from
the hub equals the number of walkable cells (after repair) for 2,000 chunks; (4) no
1×1 floor pocket, pits only in HALL/ROOMS with 8 walkable neighbours, `opsCounter` <
200,000.

### `World`

```haxe
class World {
    public static inline var RESIDENT_RADIUS = 1;     // 3x3 ensured around the player
    public static inline var EVICT_RADIUS = 2;        // beyond Chebyshev 2 is evicted
    public static inline var MAX_CHUNKS = 25;
    public var tapeSeed:Int;
    public var genErrors:Int;                         // incremented by Main when a generate throws; next attempt uses altSeed
    public var residentKeys:haxe.ds.Vector<Int>;      // MAX_CHUNKS entries, parallel to the Map: keys of resident chunks (eviction scans this, never Map.keys())
    public var residentCount:Int;
    public function new(tapeSeed:Int):Void;           // preallocates a pool of MAX_CHUNKS Chunk objects and residentKeys
    public static inline function key(cx:Int, cy:Int):Int return ((cx + 0x8000) << 16) | ((cy + 0x8000) & 0xFFFF);
    public function cell(x:Int, y:Int):Int;           // world coords; Cells.WALL if the chunk is not resident
    public inline function solid(x:Int, y:Int):Bool;  // Cells.solid(cell(x, y))
    public function has(cx:Int, cy:Int):Bool;
    public function chunkAt(cx:Int, cy:Int):Chunk;    // null if not resident
    public function ensureAround(cx:Int, cy:Int):Int; // queues every missing chunk in the (2R+1)^2 window, nearest first; returns queued count
    public function pump(maxChunks:Int):Int;          // generates up to maxChunks from the queue (pool or evict-farthest to make room, scanning residentKeys); returns generated count
    public function evictOutside(cx:Int, cy:Int, r:Int):Int; // returns evicted count; evicted chunks go back to the pool
    public function loadedCount():Int;
    public function pendingCount():Int;
    public function generateNow(cx:Int, cy:Int):Chunk;   // synchronous (used by tests and Bench)
}
```
Owns: the `Map<Int, Chunk>`, the parallel `residentKeys` vector (the farthest-chunk scan
in `evictOutside`/`pump` walks it; `Map.keys()` is never called after start — rule 4),
the pool, the pending ring (capacity 16). May touch:
`ChunkGen`, `Chunk`, `Cells`. May not touch: entities, player. Budget: `cell` is
called ~4,000 times per frame by the raycaster → must be a hash lookup on a
precomputed key plus two shifts; cache the last chunk looked up (hit rate > 90% along
a ray). `pump(1)` ≤ 1.5 ms. Tests: (1) `cell` matches `chunkAt(...).get(x & 31, y & 31)`
in all four sign quadrants; (2) 100k-step random walk with `ensureAround`/`pump`/
`evictOutside` every step never exceeds `MAX_CHUNKS` and every cell read at the
player's position is walkable-or-wall, never a null-chunk error; (3) an evicted chunk,
regenerated, is byte-identical; (4) unloaded cell → `WALL`.

### `RayHits`

```haxe
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
    public function new(maxCols:Int):Void;             // all vectors length maxCols
}
```
Owns: its vectors. Written only by `Raycaster`, read by `Renderer`, `SpritePass`,
`MapMemory.recordHits`, `Director` (line-of-sight uses its own DDA, not this).

### `Raycaster`

```haxe
class Raycaster {
    public static inline var MAX_DIST = 16;            // cells
    public static inline var MAX_STEPS = 48;
    public var cols:Int;                               // current column count
    public var fov:Float;                              // radians
    public var dirX:haxe.ds.Vector<Float>;             // per-column ray direction (unit-plane form: dir + plane * camX), length maxCols
    public var dirY:haxe.ds.Vector<Float>;
    public var camX:haxe.ds.Vector<Float>;             // per-column camera-plane coordinate in [-1, 1]
    public function new(maxCols:Int):Void;
    public function setColumns(cols:Int, fov:Float):Void;   // rebuilds camX only; dirX/dirY are rebuilt by castRays() when ang changes
    // named castRays, not cast: `cast` is a reserved Haxe keyword and cannot be a method name
    public function castRays(world:World, px:Float, py:Float, ang:Float, out:RayHits):Void;  // fills out for cols columns, out.count = cols
}
```
Standard DDA (Lode-style): `planeX = -sin(ang) * tan(fov/2)`, `planeY = cos(ang) *
tan(fov/2)`; ray = dir + plane × camX. Perpendicular distance
`side == 0 ? (sideDistX - deltaDistX) : (sideDistY - deltaDistY)`, stored as
`Std.int(d * 65536)` with a minimum of `ONE >> 4`. `texX = int(wallX * 64) & 63`,
flipped for `side == 0 && dirX > 0` and `side == 1 && dirY < 0` so textures read
consistently. Stops at `MAX_DIST` (Chebyshev cell distance) or `MAX_STEPS`. Float DDA is
allowed here (it is 320 × ~12 steps, not per pixel). Owns: nothing else. Budget:
≤ 2.0 ms at 320 columns. Tests: (1) against a brute-force 0.001-step marcher on 6
hand-built 16×16 grids and 100 random views: `dist` within 1e-3 × ONE, `cellX/Y`,
`side`, `face` exact; (2) face convention: a ray stepping −y (looking north) into a
wall reports `face == Cells.S` (the camera sees the wall's south face), stepping +y
reports `N`, stepping +x reports `W`, stepping −x reports `E`; (3) `hit == 0` and
`dist == ONE * MAX_DIST` in an empty 40×40 room looking at the far wall.

### `MapMemory`

```haxe
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
    public var residentKeys:haxe.ds.Vector<Int>;       // MAX_CHUNKS entries, parallel to the Map: keys of allocated chunks (evictFarthest scans this, never Map.keys())
    public var residentCount:Int;
    public function new():Void;                        // allocates the queue and residentKeys; chunk vectors are allocated on first touch (rule 4 exemption e)
    public function flags(x:Int, y:Int):Int;           // 0 if the chunk is unknown
    public function seeFace(x:Int, y:Int, face:Int):Bool;   // sets F_* bit; true if it was newly set (and then queued)
    public function visit(x:Int, y:Int, cellValue:Int):Bool; // sets VISITED (+ WET/DARK/PIT_SEEN from the cell type); true if new
    public function recordHits(h:RayHits):Int;         // for every column with hit == 1 and dist < INK_DIST << 16: seeFace(cellX, cellY, face); returns newly set count
    public function chunkCount():Int;
    public function evictFarthest(px:Int, py:Int):Int; // while chunkCount() > MAX_CHUNKS drop the chunk with the largest Chebyshev distance; returns dropped count
    // queue of newly inked items for MapPaper: packed WORLD cell (Cells.pack(x, y), never chunk-local) with the face or flag in a parallel vector
    public function queueLength():Int;
    public function queuePeekCell(i:Int):Int;          // i in 0..queueLength()-1, packed x,y
    public function queuePeekKind(i:Int):Int;          // 0..3 = face N/E/S/W; 4 = visited; 5 = wet; 6 = dark; 7 = pit
    public function queueDrop(n:Int):Void;             // remove the first n items
    // re-ink support for a sheet: iterate all known cells in a rectangle
    public function forEachKnown(x0:Int, y0:Int, x1:Int, y1:Int, out:haxe.ds.Vector<Int>, outFlags:haxe.ds.Vector<Int>, max:Int):Int; // fills packed cells + flags, returns count
}
```
Owns: `Map<Int, haxe.ds.Vector<Int>>` (1024 per chunk, key = `World.key`, each vector
allocated on the chunk's first touch — rule 4 exemption (e), bounded by `MAX_CHUNKS`),
the parallel `residentKeys` vector, the ring queue. May touch: `Cells`, `RayHits`. Budget: `recordHits` ≤ 0.2 ms (320 bit-ORs).
Tests: (1) face bits round-trip and `seeFace` returns true exactly once per face;
(2) `recordHits` ignores columns at ≥ `INK_DIST`; (3) cap: after touching 300 chunks,
`evictFarthest` leaves 256 and the nearest are kept; (4) the queue delivers each new
item once in order and drops the oldest when full (never throws).

### `Path`

```haxe
class Path {
    public static inline var HALF = 12;                // window is (2*HALF)^2 = 576 cells around the start
    public static inline var MAX_LEN = 128;
    // BFS over walkable cells inside the window centred on (sx, sy), clamped to resident chunks. sx/sy/tx/ty are WORLD cell coordinates;
    // out receives the path as packed WORLD cells (Cells.pack(x, y), never chunk-local) from the first step to the target (start excluded),
    // at most MAX_LEN. Returns path length, 0 if start == target, -1 if unreachable.
    public static function bfs(world:World, sx:Int, sy:Int, tx:Int, ty:Int, out:haxe.ds.Vector<Int>):Int;
    public static var expansions:Int;                  // nodes expanded by the last call (telemetry/tests)
}
```
Owns: static scratch vectors (visited stamp vector of 576 + queue of 576 + parent
vector), stamp-based so no clearing per call. May touch: `World`, `Cells`. Budget:
≤ 0.4 ms per call; called at most twice per second. Tests: (1) equals brute-force
shortest length on 200 random 24×24 grids; (2) never returns a cell outside the
window; (3) −1 when walled off; (4) a target outside the window returns the path to
the reachable in-window cell nearest to it (Euclidean), so the Hound still moves.

### `Player`

```haxe
class Player {
    public static inline var RADIUS = 0.22;
    public static inline var WALK = 0.8;                // cells/s
    public static inline var RUN_MUL = 1.6;
    public static inline var WET_MUL = 0.6;
    public static inline var TURN = 1.745;              // rad/s (100 deg/s)
    public static inline var STAMINA_SECS = 4.0;
    public static inline var RECOVER_SECS = 12.0;
    public static inline var STEP_LEN = 0.7;            // cells between footsteps
    public static inline var PE_STEP = 1;
    public static inline var PE_STEP_WET = 2;
    public static inline var PE_RUN_START = 4;
    public static inline var PE_ENTERED_PIT = 8;
    public static inline var PE_BLOCKED = 16;
    public var x:Float;
    public var y:Float;
    public var ang:Float;
    public var stamina:Float;                           // 0..1
    public var running:Bool;                            // true only while actually moving at run speed
    public var onWet:Bool;
    public var onDark:Bool;
    public var cellsWalked:Float;
    public var runSeconds:Float;                        // continuous seconds of running (reset when not running)
    public var speed:Float;                             // current cells/s (for audio/telemetry)
    public function new(x:Float, y:Float, ang:Float):Void;
    public inline function cellX():Int;                 // Math.floor(x)
    public inline function cellY():Int;
    // fwd/turn/strafe in {-1, 0, 1}; run = Shift held. Returns PE_* flags for this frame.
    // turn = +1 is RIGHT: ang += turn * TURN * dt (eased) — clockwise on screen (y down), increasing angle, consistent with
    // rule 9 (positive bearing = to the right of facing) and the raycaster's plane sign. strafe = +1 moves along (cos(ang + pi/2), sin(ang + pi/2)).
    public function update(dt:Float, fwd:Int, turn:Int, strafe:Int, run:Bool, world:World):Int;
    public function placeAt(x:Float, y:Float, ang:Float):Void;   // teleport (tape start)
}
```
Collision: move x then y separately; each axis is rejected if any of the four corners
of the radius box lands in a `Cells.solid` cell (slide). Turn ease-in: angular
velocity ramps to `TURN` over 0.15 s. Owns: nothing else. May touch: `World`, `Cells`.
Budget: 0.1 ms. Tests: (1) 100k random inputs in a random maze never end with the
player's centre inside a solid cell; (2) walking on WET yields `WET_MUL` speed and
`PE_STEP_WET`; (3) running drains stamina to 0 in `STAMINA_SECS` and recovers in
`RECOVER_SECS`; running with 0 stamina is walking; (4) `PE_ENTERED_PIT` fires exactly
once on entering a PIT cell.

### `Entity`

```haxe
class Entity {
    public static inline var K_WATCHER = 1;
    public static inline var K_HOUND = 2;
    public static inline var TELEGRAPH_SECS = 3.0;
    public var kind:Int;
    public var alive:Bool;                              // false = not spawned / despawned; update() is still called (cheap no-op)
    public var x:Float;
    public var y:Float;
    public var state:Int;                               // subclass constants
    public var frame:Int;                               // sprite frame index
    public var dist:Float;                              // to the player, updated each update()
    public var bearing:Float;                           // relative to the player's facing, (-pi, pi]
    public var inView:Bool;                             // inside the view cone AND line of sight, updated each update()
    public var telegraph:Float;                         // seconds of active audio+picture cue accumulated (decays at 1/s when inactive)
    public var height:Float;                            // sprite height in cells (Watcher 0.95, Hound 0.45)
    public var width:Float;                             // sprite width in cells
    public function new(kind:Int):Void;
    public function canKill():Bool;                     // alive && telegraph >= TELEGRAPH_SECS
    public function update(dt:Float, d:Director):Void;  // base: refresh dist/bearing/inView via d; subclasses call super first
    public function spawnAt(x:Float, y:Float):Void;     // alive = true, telegraph = 0, state = initial
    public function despawn():Void;
}
```

### `Watcher extends Entity`

```haxe
class Watcher extends Entity {
    public static inline var S_IDLE = 0;                // standing at its post
    public static inline var S_APPROACH = 1;            // R <= 2, walking in at 0.6 cells/s
    public var targetRadius:Float;                      // R = lerp(14, 4, d.D), minus the unseen shrink, floor 3 at D > 0.9
    public var relocateTimer:Float;                     // counts down; relocation when <= 0 (4..9 s, halved in DARK)
    public var unseenSeconds:Float;
    public var lookedAtSeconds:Float;                   // within 10 deg of centre
    public var relocations:Int;
    public var relocated:Bool;                          // true for exactly the update() in which it relocated
    public function new():Void;
    override public function update(dt:Float, d:Director):Void;
    // choose and move to a new post: a walkable cell at distance targetRadius +/- 1 not in view, preferring dead ends / corridor ends
    // aligned with the facing +/- 30 deg; closer = true forces distance <= current dist - 1 (blackout). Returns false if none found (stays).
    public function relocate(d:Director, closer:Bool):Bool;
}
```
Rules (DESIGN §5): frozen while `inView && dist <= 8`; `lookedAtSeconds > 1.5` →
relocate at the next `EV_FLICKER`; `unseenSeconds > 20` → `targetRadius -= 1` per
relocation; at `targetRadius <= 2` → `S_APPROACH`; contact (`dist < 0.6`) with
`canKill()` → `d.requestKill(K_WATCHER)`. `telegraph` accumulates while `dist < 10`.
Budget: 0.1 ms plus `relocate` ≤ 0.5 ms (samples ≤ 64 candidate cells, no BFS).
Tests: (1) 1,000 relocations never land in the view cone or in a solid cell; distance
within R ± 1 when any candidate exists; (2) zero movement while in view within 8 over
a 30 s simulated stare; (3) `canKill()` false during the first 3 s inside 10 cells;
(4) with `closer = true` the new distance is strictly less than the old one.

### `Hound extends Entity`

```haxe
class Hound extends Entity {
    public static inline var S_DORMANT = 0;
    public static inline var S_HOWL = 1;
    public static inline var S_CHASE = 2;
    public static inline var S_LOST = 3;
    public static inline var HEAR_RUN = 24.0;
    public static inline var HEAR_SPLASH = 32.0;
    public static inline var HEAR_WALK = 10.0;
    public static inline var HEAR_BLACKOUT = 40.0;
    public static inline var CHASE_MUL = 1.35;          // x Player.WALK
    public static inline var TIRED_MUL = 0.9;
    public static inline var STAMINA_SECS = 12.0;
    public static inline var LOSE_SECS = 6.0;
    public static inline var WANDER_SECS = 30.0;
    public var howlTimer:Float;
    public var chaseSeconds:Float;
    public var silentSeconds:Float;                     // seconds since last seen or heard
    public var targetX:Int;                             // last heard/seen cell (world cell coordinates)
    public var targetY:Int;
    public var repathTimer:Float;                       // 0.5 s
    public var pathLen:Int;
    public var pathPos:Int;
    public var path:haxe.ds.Vector<Int>;                // Path.MAX_LEN packed WORLD cells (Cells.pack), exactly as Path.bfs writes them
    public var stepEvent:Bool;                          // true on the update() in which a footstep sound should fire
    public function new():Void;
    override public function update(dt:Float, d:Director):Void;
    public function hear(x:Int, y:Int, radius:Float):Bool;   // if dist to (x,y) <= radius (scaled by d.hearingMul): set target, DORMANT -> HOWL, CHASE/LOST -> CHASE; returns true if it reacted
}
```
Rules: HOWL lasts `2 + rng*1` s with no movement; CHASE follows `Path.bfs` toward the
target at `CHASE_MUL × WALK` for `STAMINA_SECS`, then `TIRED_MUL × WALK`; `silentSeconds`
resets when `inView` (it sees you) or `hear` fires; ≥ `LOSE_SECS` → LOST; LOST wanders
along random short paths at 0.5 × WALK for `WANDER_SECS` then DORMANT; contact
(`dist < 0.6`) with `canKill()` → `d.requestKill(K_HOUND)`. `telegraph` accumulates from
HOWL start while HOWL or CHASE. Budget: 0.2 ms average (BFS amortised). Tests:
(1) no movement during HOWL and HOWL ≥ 2 s; (2) LOST after `LOSE_SECS` with no sight
and no `hear`; (3) `canKill()` false before 3 s after `hear`; (4) never leaves walkable
cells over a 10-minute simulated chase in a random maze.

### `Director`

```haxe
class Director {
    // event flags (cleared at the start of update)
    public static inline var EV_WATCHER_RELOCATED = 1;
    public static inline var EV_WATCHER_SPAWN = 2;
    public static inline var EV_WATCHER_DESPAWN = 4;
    public static inline var EV_WATCHER_LUNGE = 8;
    public static inline var EV_HOUND_SPAWN = 16;
    public static inline var EV_SCREAM = 32;
    public static inline var EV_HOWL = 64;
    public static inline var EV_HOUND_LOST = 128;
    public static inline var EV_SNARL = 256;
    public static inline var EV_HOUND_STEP = 512;
    public static inline var EV_BLACKOUT_START = 1024;
    public static inline var EV_BLACKOUT_END = 2048;
    public static inline var EV_FLICKER = 4096;
    public static inline var EV_KILL = 8192;
    public static inline var EV_DISTANT = 16384;
    public static inline var EV_TS_SKIP = 32768;
    public static inline var EV_HUM_LOW_ON = 65536;
    public static inline var EV_HUM_LOW_OFF = 131072;
    public static inline var EV_PIT_STUMBLE = 262144;
    public static inline var EV_STROBE_ON = 524288;
    public static inline var EV_BATTERY_DEAD = 1048576;
    public static inline var K_WATCHER = 1;
    public static inline var K_HOUND = 2;
    public static inline var K_PIT = 3;
    public static inline var K_BATTERY = 4;
    public static inline var K_DAMAGED = 5;
    public var world:World;
    public var player:Player;
    public var rng:Rng;                                 // hash3(tapeSeed, TAG_DIRECTOR, 0)
    public var tape:Tape;
    public var watcher:Watcher;                         // always non-null; alive toggles
    public var hound:Hound;
    public var tapeTime:Float;                          // seconds on this tape (runs while the map is open; not while paused)
    public var D:Float;                                 // 0..1 escalation
    public var presence:Float;                          // 0..1
    public var lightOffset:Int;                         // 0..15 added to every shade band = flicker/blackout part + darkOffset, clamped to 15; the Renderer only ever sees this one summed value
    public var darkOffset:Int;                          // 9 while the player's own cell type is DARK, else 0 (fog then lands at (15 - 9) / 1.25 ≈ 4.8 cells = fogCells 5)
    public var blackoutT:Float;                         // > 0 while a blackout is on (seconds left)
    public var battery:Float;                           // 0..1
    public var hearingMul:Float;                        // 1.0, 1.5 in DARK
    public var fogCells:Int;                            // 12 normally, 5 in DARK
    public var events:Int;
    public var killer:Int;                              // K_* when EV_KILL is set
    public var distantId:Int;                           // 0..5 when EV_DISTANT
    public var distantPan:Float;                        // -1..1
    public var distantVol:Float;
    public var pitDist:Float;                           // distance to the nearest PIT within 6 cells, else 99
    public var pitPan:Float;
    public var humLow:Bool;
    public var tsSkipSeconds:Int;                       // 1..7 when EV_TS_SKIP
    public var noRelocateUntil:Float;                   // tapeTime; relief valve after a lost Hound (+45 s)
    public function new(world:World, player:Player, tape:Tape):Void;
    // frozen = map open: clocks (tapeTime, battery) advance, entities and timers do not, presence is held.
    public function update(dt:Float, frozen:Bool, playerEvents:Int):Void;
    public function requestKill(kind:Int):Void;         // sets EV_KILL + killer once (first wins)
    public function inViewCone(x:Float, y:Float):Bool;  // |bearing| <= tape.fov / 2 + 5 deg (in radians; 35 deg at FOV 60 is the documented minimum, 41 deg at 72) AND lineOfSight — wider than the screen, so a relocated Watcher never pops in at the edge
    public function lineOfSight(x0:Float, y0:Float, x1:Float, y1:Float):Bool;  // DDA over World.solid, max 24 cells
    public function bearingTo(x:Float, y:Float):Float;
    public function isDeadEnd(cx:Int, cy:Int):Bool;     // walkable with exactly one walkable 4-neighbour
    public function forceBlackout():Void;               // test/rc
    public function forceSpawnHound():Void;             // test/rc: spawns at 22 cells out of view and immediately hears
    public function forceRelocate():Void;
}
```
Responsibilities: D and presence (DESIGN §5); Watcher spawn at `tapeTime ≥ 90`
(out of view at `targetRadius`), despawn/respawn at > 30 cells for 20 s; Hound spawn
when `D > 0.25`, not alive, Watcher not within 6, 5 s after `EV_SCREAM`; hearing calls
on `PE_STEP` (walk 10 / run 24 / wet 32) and blackouts (40); blackouts every 60–120 s at
`D > 0.5` for 2–4 s (`lightOffset = 15`, Watcher relocates closer once at start);
flicker stutters every 4–9 s for 1–3 frames (`lightOffset` +2..+5), deeper near the
Watcher; distant one-shots every 20–50 s with `distantId` in 0..5, `distantPan` in −1..1 and
`distantVol` in 0.1..0.3, and 1-in-5 from directly behind, flagged by `distantId + 16`
(`AudioBus` plays `id & 15` at `pan × 0.2`, since behind has no pan);
timestamp skips at `D > 0.7` every 30–90 s; `humLow` when Watcher within 6 or
`D > 0.7`; battery drain `1 / (25 × 60)` per second × 4 in DARK, `EV_STROBE_ON` at
< 0.10, `EV_BATTERY_DEAD` + `requestKill(K_BATTERY)` at 0; DARK: `darkOffset = 9`
while `Cells.type(world.cell(player.cellX(), player.cellY())) == DARK`, else 0, and
`lightOffset = min(15, flickerOrBlackout + darkOffset)` — the fog (band 15) then lands
at ≈ 4.8 cells, matching `fogCells = 5`, and walls, ceiling and floor in DARK
additionally use the 15% textures via `Textures.wallId/ceilId/floorId`; pit: on
`PE_ENTERED_PIT`, `requestKill(K_PIT)` unless `lightOffset >= 8` in which case
`EV_PIT_STUMBLE`. The +9 DARK offset cannot trip that threshold because pits never occur
in DARK zones (DESIGN §2 step 6) and the player's own cell is PIT, not DARK, on the frame
the event fires; if pits are ever allowed next to DARK, raise the stumble threshold to
`>= 12`. Owns:
both entities, its `Rng`. May touch: `World`, `Player`, `Path` (via Hound), `Cells`,
`Tape`. Budget: 0.4 ms average. Tests: (1) `D` is monotone non-decreasing in a
simulated 20-minute run and never exceeds 1; (2) the Hound never spawns while the
Watcher is within 6 cells (10,000 simulated seconds with the Watcher pinned near);
(3) after `EV_HOUND_LOST`, no `EV_WATCHER_RELOCATED` for 45 s; (4) battery reaches 0 in
25 min ± 1% at normal drain and `EV_BATTERY_DEAD` sets `killer == K_BATTERY`.

### `Tape`

```haxe
class Tape {
    public var index:Int;                               // 1-based tape number
    public var seed:Int;                                // Rng.hash3(salt, TAG_TAPE, index)
    public var salt:Int;
    public var name:String;                             // e.g. "BASEMENT LEVEL - DANNY" (ASCII only; PixelFont has no accents)
    public var camName:String;                          // e.g. "VX-200"
    public var dateStr:String;                          // "DD.MM.YYYY", years 1987..1999
    public var dateSeconds:Float;                       // seconds since midnight for the HUD clock start, 0..86399
    public var tintR:Float;                             // ColorTransform multipliers 0.92..1.08
    public var tintG:Float;
    public var tintB:Float;
    public var offR:Int;                                // ColorTransform offsets -8..8
    public var offG:Int;
    public var offB:Int;
    public var grainAlpha:Int;                          // 24..40
    public var fov:Float;                               // radians, 60..72 deg
    public var dOffset:Float;                           // 0..0.1 initial D
    public var batteryStart:Float;                      // 0.6..1.0
    public var hudSkin:Int;                             // 0..2
    public var badTape:Bool;                            // 1 in 10
    public var startX:Float;                            // 16.5, 16.5 with a walkable guarantee left to Main (Main nudges to the nearest walkable cell of chunk 0,0)
    public var startY:Float;
    public var startAng:Float;
    public static function make(index:Int, salt:Int):Tape;
    public static function nextSalt(salt:Int):Int;      // Rng.mix(salt ^ 0x5DEECE66)
}
```
Owns: the name/place/camera word lists (static arrays, built once). Tests:
(1) `make(i, s)` twice → identical fields; (2) over 1,000 tapes `badTape` rate within
7–13%, dates parse and are in range, `fov` in range; (3) `name` is ASCII 32..126 and
≤ 28 chars.

### `Quality`

```haxe
class Quality {
    public static inline var RUNGS = 6;
    public var rung:Int;
    public var maxRung:Int;                             // ceiling for the CURRENT display mode (Bench maxRungWin or maxRungFs, via setMaxRung); rung <= maxRung always
    public var presentEstimate:Float;                   // ms; Bench presentW (windowed) or presentFsRect/presentFs (fullscreen, fsHw-aware) for the current tier; set by Main on tier/mode change
    public var emaBusy:Float;                           // EMA of busy ms = t_ours + presentEstimate; the ONLY input to the raise test; also drops
    public var emaFrame:Float;                          // EMA of ENTER_FRAME-to-ENTER_FRAME ms; pinned at >= 1000/frameRate by the player, so it can only ever DROP (an overrun there is real), never raise
    public var lastChange:Float;                        // seconds since the last change
    public var lockUntil:Float;                         // seconds of remaining explicit raise-lock (locks never block a drop)
    public function new(rung:Int, maxRung:Int):Void;
    public static function tier(rung:Int):Int;          // 0 => 0 (256x192); else 1 (320x240)
    public static function floorMode(rung:Int):Int;     // rung 0,1 => 0; 2,3,4 => 1; 5 => 2
    public static function rays(rung:Int):Int;          // 0 => 128; 1,2 => 160; 3,4,5 => 320
    public static function frameRate(rung:Int):Int;     // 0..3 => 20; 4,5 => 30
    public static function budgetMs(rung:Int):Float;    // 50 or 33.3
    // Feed one frame: busyMs = getTimer bracket around the whole handler + presentEstimate (never wall time); frameMs = ENTER_FRAME to ENTER_FRAME.
    // entityActive/dying/mapOpen block RAISES only; drops stay allowed under them (with the 60-frame hysteresis). Returns -1 (drop), +1 (raise) or 0; the caller applies the change.
    public function noteFrame(busyMs:Float, frameMs:Float, entityActive:Bool, dying:Bool, mapOpen:Bool):Int;
    public function lock(seconds:Float):Void;           // raise-lock, e.g. 2 s after a glitch frame
    public function setMaxRung(m:Int):Void;             // Main calls after Bench and on Display.onFullscreenChange: maxRung = m; rung = min(rung, m); resets the raise counter
    public function forceDrop():Void;                   // render error: rung = max(0, rung - 1), resets counters
    public function set(rung:Int):Void;                 // override (debug keys, rc)
}
```
Thresholds per DESIGN §1: **drop** after 60 consecutive frames with `emaBusy > 1.15 ×
budget` OR `emaFrame > 1.15 × budget` — never blocked by a lock or by entity activity
(`maxRung` is estimated from a bench with no chase in it, so a rung that fits without
sprites must be allowed to fall exactly during a chase); **raise** after 300 consecutive
frames with `emaBusy < 0.70 × budget` — wall time is never consulted for a raise, because
with `stage.frameRate = 20` the frame interval is pinned at ≥ 50 ms whatever the work
costs; ≥ 5 s between changes, no raise while locked or while `entityActive` / `dying` /
`mapOpen`, never above `maxRung`, never below 0. Tests: (1) 60 slow frames → −1 once,
then 0 until 5 s pass; (2) 300 fast frames with `entityActive` → 0; without → +1;
(3) `rung == maxRung` never raises; (4) `forceDrop` at 0 stays 0; (5) 300 frames with
`frameMs = 50` (pinned by frameRate 20) and `busyMs = 20` at rung 2 → +1 (wall time never
blocks a raise); (6) 60 frames with `busyMs = 60` and `entityActive = true` → −1 (locks
never block a drop); (7) `setMaxRung(1)` at rung 3 → `rung == 1`.

### `Bot`

```haxe
class Bot {
    public var fwd:Int;
    public var turn:Int;
    public var run:Bool;
    public var wantMapToggle:Bool;                      // every 45 s, held open 3 s
    public function new(seed:Int):Void;
    public function update(dt:Float, player:Player, world:World):Void;   // sets fwd/turn/run/wantMapToggle for this frame
}
```
Walks forward; if a solid cell lies within 1.5 cells ahead, turns toward the more open
side (probe ±45°, ±90°); random turns every 3–8 s; 10% run bursts of 2 s. Tests:
(1) in a 40×40 open room the bot's `cellsWalked` grows by > 20 cells per simulated
minute; (2) never sets `fwd == 0 && turn == 0` for more than 1 s.

## 2. Flash platform classes

### `Params`

```haxe
class Params {
    public static function init(li:flash.display.LoaderInfo):Void;  // merges li.parameters (flashvars) and the query string of li.url; flashvars win
    public static function has(k:String):Bool;
    public static function get(k:String, def:String = ""):String;
    public static function int(k:String, def:Int):Int;
}
```
Recognised keys: `bench=1` (run the bench, then play), `soak=1` (Bot drives; telemetry
every 10 s; auto-dismiss cards), `rc=1` (poll `/rc`), `seed=N` (fixed salt), `tape=N`,
`die=watcher|hound|pit|battery` (scripted death at 8 s), `throw=1` (deliberate throw
at frame 100), `rung=N` (start rung override, also sets maxRungWin and maxRungFs),
`debug=1` (enable digit keys), `nosnap=1`, `auto=1` (dismiss cards automatically),
`fixeddt=N` (force `dt = N` ms every frame, ignoring `getTimer`, so golden screenshots
are deterministic — the card wobble/jitter and everything else time-driven), `nofs=1`
(skip the fullscreen bench arms and never enter fullscreen; `tools/ruffle_run.py` passes
it because Ruffle stubs the `fullScreenSourceRect` setter).

### `Display`

```haxe
class Display {
    public var bitmap:flash.display.Bitmap;
    public var tier:Int;
    public var fullscreen:Bool;
    public var hwRect:Bool;                             // use fullScreenSourceRect when entering fullscreen
    public var lowQuality:Bool;                         // false (default): stage.quality = MEDIUM; true: LOW — the fallback Bench picks only if MEDIUM+smoothing measured > 4 ms worse than LOW
    public var stageW:Int;
    public var stageH:Int;
    public function new(stage:flash.display.Stage):Void; // NO_SCALE, TOP_LEFT, quality MEDIUM (at LOW Flash ignores Bitmap.smoothing entirely and BitmapData.draw() is unantialiased; the only vector content is one Bitmap and the map draws, so AA costs nothing), listens to RESIZE and FULL_SCREEN
    public function setLowQuality(on:Bool):Void;        // stage.quality = on ? LOW : MEDIUM (smoothing is then ignored at LOW); lowQuality = on
    public function attach(bd:flash.display.BitmapData, tier:Int):Void;   // sets bitmapData, smoothing = true, relayouts
    public function layout():Void;                      // windowed: 4:3 letterbox centred; fullscreen+hwRect: scale 1 at (0,0); fullscreen software: scale to 1024x768
    // MUST be called synchronously inside the dispatch of the user's own MouseEvent/KeyboardEvent, i.e. from Input.onGesture. Flash Player throws
    // SecurityError #2152 for displayState = FULL_SCREEN from ENTER_FRAME, a Timer, a URLLoader callback or ExternalInterface — every time.
    public function enterFullscreen():Bool;             // sets fullScreenSourceRect first if hwRect; try/catch; returns false on SecurityError (pings bk=fs&on=0&why=nogesture|denied)
    public function exitFullscreen():Void;              // may be called from anywhere (no gesture needed)
    public function snapStage(tag:String):Void;         // draws the stage into a 1024x768 BitmapData and Telemetry.snap()s it (one-off, ~100 ms)
    public var onFullscreenChange:Bool->Void;           // Main hooks this (allocated once at start): quality.setMaxRung(fs ? maxRungFs : maxRungWin) and quality.presentEstimate for the new mode
}
```
Owns: the one `Bitmap`, its reused `Rectangle` for the source rect. May not touch:
game state. Budget: 0 per frame. Tests: (Ruffle) the letterbox rect is
`(101, 0, 822, 617)` on a 1024×617 stage; (eMac only — Ruffle stubs the
`fullScreenSourceRect` setter and `Capabilities.cpuArchitecture`, so a Ruffle pass proves
nothing here) fullscreen scale is 3.2 (T1) / 4.0 (T0) in software mode and `bk=fs&rect=1`
when the rect took.

### `Textures`

```haxe
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
    public var built:Bool;
    public function new():Void;                         // allocates COUNT vectors of 65536 (fixed) once
    public function build(tape:Tape):Void;              // fills all textures from Rng.hash3(tape.seed, TAG_TEX, id); ~30-60 ms; may be called per tape
    public inline function get(id:Int):flash.Vector<UInt>;
    // Variant-bit conventions set by ChunkGen: WALL/PILLAR cells in a DARK chunk carry variant 7; floor cells ringing a pit carry variant 1; all other floor cells variant 0.
    public static inline function wallId(cell:Int):Int;    // variant 7 => T_WALL_DARK; DAMAGED bit => T_WALL_DAMAGED; else T_WALL0 + (variant & 3)
    public static inline function floorId(cell:Int):Int;   // type WET => T_CARPET_WET; PIT => T_PIT; DARK => T_CARPET_DARK; variant 1 => T_CARPET_RIM; else T_CARPET
    public static inline function ceilId(cell:Int):Int;    // type DARK => T_CEIL_DARK; LIGHT bit => T_CEIL_PANEL; else T_CEIL
    // sprite masks: column-major flash.Vector<Int>, w*h entries, 0 transparent, 1 body, 2 eye
    public function sprite(kind:Int, frame:Int):flash.Vector<Int>;
    public static function spriteW(kind:Int):Int;        // Watcher 32, Hound 48
    public static function spriteH(kind:Int):Int;        // Watcher 64, Hound 32
    public static function spriteFrames(kind:Int):Int;   // 2, 3
    public var noise256:flash.Vector<UInt>;              // 256 dark greys 0xFF080808..0xFF282828 for the Watcher fill, rebuilt per tape
}
```
Band `b` of a texture is the base texture with every channel multiplied by
`(15 − b) / 15` and, for b ≥ 12, an additional blend toward the fog colour
`0xFF0A0906`; band 15 is exactly `0xFF000000`. Red-shift for wallpaper: the red channel
of column `tx` comes from column `(tx + 1) & 63` of the base. Owns: its vectors. May
touch: `Rng`, `Tape`. Tests (Ruffle or interp-free): (1) band 15 all black, band 0
equals the base; (2) `build` twice with the same tape → identical vectors; (3) every
texture vector has length 65536 and `fixed == true`.

### `Renderer`

```haxe
class Renderer {
    public static inline var W1 = 320; public static inline var H1 = 240;
    public static inline var W0 = 256; public static inline var H0 = 192;
    public var w:Int;
    public var h:Int;
    public var tier:Int;
    public var fb:flash.Vector<UInt>;                   // current tier's buffer, length w*h, fixed; index = y*w + x
    public var bd:flash.display.BitmapData;             // current tier's BitmapData (opaque, transparent = false)
    public var rect:flash.geom.Rectangle;               // (0,0,w,h) for the current tier
    public var colShift:Int;                            // 0 when hits.count == w, 1 when hits.count == w/2 (2-px columns)
    public var textures:Textures;
    public function new(textures:Textures):Void;        // allocates BOTH tiers' fb + bd up front
    public function setTier(t:Int):Void;                // index swap only
    // Draws walls, floor and ceiling into fb from hits. lightOffset 0..15; floorMode 0/1/2; camera (px,py,ang) and ray dir tables from rc.
    public function render(hits:RayHits, rc:Raycaster, px:Float, py:Float, lightOffset:Int, floorMode:Int, world:World):Void;
    public function present():Void;                     // bd.setVector(rect, fb) — the whole frame; NEVER called in ST_MAP (it would overwrite the composed map with the stale fb)
    public static inline var STRIP_H = 8;
    public var strip:flash.Vector<UInt>;                // current tier's w*STRIP_H opaque OSD strip (both tiers preallocated); Hud.drawStrip writes it
    public var stripRect:flash.geom.Rectangle;          // (0, y, w, STRIP_H), reused
    public function presentStrip(y:Int):Void;           // bd.setVector(stripRect at row y, strip): the ST_MAP OSD bar straight into bd; fb untouched, no allocation
    public static inline function bandOf(dist:Int):Int; // (dist * 5) >> 18 — the distance part of the shade band, exposed for the unit table below
    public var vignetteBias:flash.Vector<Int>;          // per column 0..2, rebuilt in setTier
    public var rowBand:flash.Vector<Int>;               // per row base band for floor/ceiling (distance-based), rebuilt in setTier
    public var rowDist:flash.Vector<Int>;               // 16.16 depth per row
    public var wallBand:flash.Vector<Int>;              // per column band used for the wall this frame (SpritePass reads it to keep the Watcher darker)
    public var tRay:Int; public var tWall:Int; public var tFloor:Int;   // getTimer brackets, ms, for telemetry (written by render)
}
```
Wall band = `clamp(((dist * 5) >> 18) + lightOffset + side + vignetteBias[x], 0, 15)`,
**exactly this integer form** (`dist` is 16.16, so `(dist * 5) >> 18` is
`int(cells × 1.25)`; `dist * 5` is at most 5 × 16 × 65536 = 5,242,880, no overflow;
band 15 = black at 12 cells, the fog distance everything else assumes). Unit-checkable
table with `lightOffset = side = vignetteBias = 0`: dist 1.0 → band 1, 4.0 → 5, 8.0 → 10,
12.0 → 15. Column loop per DESIGN §1. Floor/ceiling per DESIGN §1 with `rowBand[y] +
lightOffset` clamped. **Span rule for texture choice within a row (all floor modes)**:
each row is walked in 16.16 world coordinates from `rowDist[y]` and the ray-direction
tables (no `Float`, no per-pixel projection); every **8 px** the cell under the walk is
re-evaluated with one `world.cell` (hitting World's last-chunk cache) and the texture
base switches there (`Textures.floorId` / `ceilId`, so carpet / wet / rim / pit / dark
carpet and tile / panel / dark tile are all chosen per 8-px span). The 8-px granularity
is a feature (chroma smear) and is never refined to per-pixel; at F1 the walk is per 2×2
block, so the check is every 4 blocks. F0 uses two per-tier 240-entry colour tables for
the base rows and applies its WET (darker) / PIT (black) override with the same 8-px
stride, but **only on rows with `rowDist[y] <= 6 << 16`** (≤ ~4,000 cached lookups at
T1, ~0.8 ms); if `t_floor` at F0 ever exceeds F1's, the fallback is one projected marker
per hazard cell within 8 cells (≤ 20 projections) instead of the row walk. At
`colShift == 1` each wall column is written to `x` and `x + 1` from one fetch. Owns:
both tiers' buffers, strips and tables. May touch: `Textures`, `RayHits`, `Raycaster`
(dir tables), `World` (the 8-px span cell reads only), `Cells`. May not touch:
`Director`, `Player`. Budget: rung 2 ≤ 7 ms, rung 3 ≤ 8 ms, rung 5 ≤ 16 ms.
Tests (Ruffle screenshots + a pixel probe through `Telemetry`): (1) a wall at distance
1 straight ahead fills the centre column with band 1 texels of the right variant;
(2) the horizon row `h/2` is never written by floor/ceiling passes (walls only);
(3) `lightOffset = 15` gives an all-black frame; (4) `setTier` twice returns the same
`fb` object (no allocation); (5) `bandOf(ONE) == 1`, `bandOf(4 × ONE) == 5`,
`bandOf(8 × ONE) == 10`, `bandOf(12 × ONE) == 15`; (6) `presentStrip(h - STRIP_H)` after
`MapPaper.compose` leaves rows `0..h - 9` of `bd` untouched.

### `SpritePass`

```haxe
class SpritePass {
    public function new(textures:Textures):Void;
    // Draws alive entities as billboards into r.fb, sorted far to near, clipped per column against hits.dist. frameSeed re-noises the Watcher.
    public function draw(r:Renderer, hits:RayHits, rc:Raycaster, px:Float, py:Float, ang:Float, watcher:Watcher, hound:Hound, lightOffset:Int, frameSeed:Int, plain:Bool):Void;
    public var drawn:Int;                               // sprites drawn this frame (telemetry)
    public var tSpr:Int;
}
```
Projection: standard billboard (`transformY` = depth; screen x from the camera-plane
inverse; height = `h × entity.height / depth`; width = `h × entity.width / depth`).
Column visible if `depth × ONE < hits.dist[x >> colShift]`. Watcher band =
`clamp(max(6, r.wallBand[x] + 3), 6, 15)`; body pixels = `textures.noise256[(tx * 7 +
ty * 13 + frameSeed) & 255]` darkened by the band (precomputed 16 × 256 table built
per tape); band 15 → not drawn. Hound body = `0xFF0C0A08` darkened by band; eye pixels
= `0xFFD8D0B0` when `(frameSeed >> 3) & 7 != 0` (blink). `plain = true` (death frames)
draws the killer at band 0 with body `0xFF303030`. Budget: **~4 ms per near full-height
sprite, 8 ms for two** (BRIEF Bench2 measured 2 billboard sprites at +8 ms, 59 vs 51 ms;
the earlier 2.5 ms figure is withdrawn) until the `sprites_t1` bench arm says otherwise.
Tests (Ruffle): (1) a Watcher behind a wall is not drawn; (2) a Watcher at
distance 3 has no pixel brighter than the wall pixels of the same columns; (3) `drawn`
counts only alive entities in the frustum.

### `PixelFont`

```haxe
class PixelFont {
    // 5x7 glyphs for ASCII 32..126 plus 0x7F = REC dot, 0x80 = play triangle, 0x81 = pause bars, 0x82 = battery cell. Unknown chars draw as a box.
    public static function blit(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, colour:UInt, scale:Int):Void;  // clips to the buffer; advance = 6*scale
    public static function width(s:String, scale:Int):Int;
    public static function blitJitter(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, colour:UInt, scale:Int, seed:Int):Void; // per-glyph +/-1 px offsets from seed (card look)
}
```
No allocation (`charCodeAt` loop). Budget: ≤ 0.2 ms for 60 glyphs at scale 1. Tests:
(1) `width("REC", 1) == 18`; (2) blitting at `x = -3` and `x = w - 2` does not throw and
writes only in-bounds pixels; (3) glyph data for '0'..'9' and 'A'..'Z' is 7 rows of 5
bits and non-empty.

### `Hud`

```haxe
class Hud {
    public var recVisible:Bool;                         // Main clears it for one frame on EV_WATCHER_RELOCATED
    public var skin:Int;
    public function new():Void;
    public function setTape(t:Tape):Void;               // skin, date, camName
    public function tick(dt:Float, playSeconds:Float, tsSkip:Int):Void;   // advances the displayed clock; rebuilds strings once per second (the only allocation)
    public function draw(fb:flash.Vector<UInt>, w:Int, h:Int, battery:Float, strobeFrame:Bool):Void;  // REC dot (1 Hz), "SP", battery bars, timestamp, camName per skin
    public function drawPlayFade(fb:flash.Vector<UInt>, w:Int, h:Int, alpha01:Float):Void;  // "PLAY >" at tape start (alpha simulated by skipping pixels)
    // ST_MAP only: fills the preallocated w x Renderer.STRIP_H strip (opaque OSD bar in the skin colour) and blits REC dot + timestamp + battery into it. Never touches fb.
    public function drawStrip(strip:flash.Vector<UInt>, w:Int, battery:Float, strobeFrame:Bool):Void;
}
```
Owns: its strings and the clock. May touch: `PixelFont`, `Tape`. Budget: ≤ 0.3 ms.
Tests: (1) after `tick(1.0)` ×60 the timestamp seconds advanced by 60; (2) `tsSkip = 5`
advances the clock by 5 s at once; (3) `draw` writes nothing outside the buffer at
T0; (4) `drawStrip` writes every one of the `w × 8` strip entries (opaque) and nothing
else.

### `Cards`

```haxe
class Cards {
    public function new():Void;
    public function drawCard(fb:flash.Vector<UInt>, w:Int, h:Int, t:Tape, seconds:Float, firstRun:Bool):Void;  // black -> blue field 0.4 s -> label with jitter/wobble; "CLICK TO START" when firstRun
    public function drawEnds(fb:flash.Vector<UInt>, w:Int, h:Int, seconds:Float, caption:String):Void;          // "TAPE ENDS" / "TAPE DAMAGED" / "BATTERY", centred, scale 3
    public function drawPause(fb:flash.Vector<UInt>, w:Int, h:Int, windowed:Bool):Void;                       // dims the frame (every other pixel) and blits "|| PAUSE"; windowed adds "CLICK TO RESUME" (Safari 3 gives the plugin no keys until a click refocuses it)
    public function drawNoSignal(fb:flash.Vector<UInt>, w:Int, h:Int, frame:Int):Void;                          // blue field for frames 0-1, then "NO SIGNAL" top-left
}
```
Pure `fb` writers; the camcorder post still runs over them. Budget: ≤ 1 ms (full fills).
Tests (Ruffle screenshots): card at 1 s is blue-free and shows the tape number; ENDS
caption centred within ±2 px.

### `Camcorder`

```haxe
class Camcorder {
    public static inline var G_NONE = 0;
    public static inline var G_TEAR = 1;                // tracking bands this frame
    public static inline var G_ROLL = 2;                // vertical roll this frame (rollPx set)
    public static inline var G_GLITCH = 4;              // slice offsets + strip blur + chroma
    public static inline var G_DROPOUT = 8;
    public static inline var G_STROBE = 16;
    public static inline var G_BLACKOUT = 32;           // (renderer already black; adds heavy grain)
    public static inline var G_NOISE_FULL = 64;         // death: full alpha grain
    public var dread:Float;                             // set per frame by Main
    public var flags:Int;
    public var rollPx:Int;
    public var tearBands:Int;                           // 1..4
    public var chromaPx:Int;                            // 0..5
    public var flickerBrightness:Float;                 // 0.85..1.05, per frame from Main (lightOffset-derived jitter)
    public function new():Void;                         // allocates sheets for BOTH tiers and 4 grain sheets 512x512, scratch BitmapData per tier, all Points/Rects/ColorTransforms
    public function buildForTape(t:Tape):Void;          // grain alpha, tint ct, vignette variant; rebuilds the 4 grain sheets with noise(seed)
    public function setTier(tier:Int):Void;
    public function apply(bd:flash.display.BitmapData, frameSeed:Int):Void;   // the full post chain in DESIGN 3 order; reads dread/flags/rollPx/tearBands/chromaPx/flickerBrightness
    public function tearNow(bands:Int):Void;            // schedule a tear for the next apply (Main calls on events)
    public function glitchNow():Void;
    public var tPost:Int;
}
```
Order in `apply`: (1) scratch copy only if TEAR/GLITCH/CHROMA needed (`copyPixels`
whole frame); (2) glitch: `applyFilter` on one 32-row strip with the preallocated
`BlurFilter(3, 0, 1)`, 3–6 slice offsets, one inverted band via `colorTransform` with
multipliers −1 and offsets 255; chroma via two `copyChannel` calls; (3) tear bands;
(4) roll: `scroll(0, rollPx)` + wrap band from grain sheet; (5) scanline+vignette sheet
merge; (6) grain window merge (sheet `min(3, int(dread × 4))`, random offset from
`frameSeed`; full alpha sheet when `G_NOISE_FULL`); (7) head-switch bar; (8) dropout
streaks; (9) `colorTransform` tint × flicker (× 0.6 on strobe frames). Owns: every
sheet, scratch and geometry object. May not touch: `fb` (it works on `bd` only).
Budget: ≤ 4 ms typical, ≤ 6 ms on a glitch frame. Tests (Ruffle): (1) `apply` with
`flags = 0` and `dread = 0` changes fewer than 40% of pixels by more than 0x30 in any
channel (scanlines + light grain only); (2) `G_ROLL` with `rollPx = 20` moves a marker
pixel down 20 rows; (3) **eMac soak, not Ruffle** (Ruffle stubs `System.totalMemory` /
`totalMemoryNumber`, so this cannot fail there): `apply` allocates nothing — the soak's
`mem` series is flat across minutes 5–60, and statically `backrooms_check.py` finds no
`new`, literal or closure inside `apply`.

### `MapPaper`

```haxe
class MapPaper {
    public static inline var CELL_PX = 6;
    public static inline var SHEET_CELLS = 64;
    public static inline var SHEET_PX = 384;
    public static inline var MAX_SHEETS = 9;
    public static inline var INK_PER_FRAME = 64;
    public static inline var REINK_PER_FRAME = 256;
    public var open:Bool;
    public var viewX:Int;                               // world-pixel (cell*6) coordinate of the view's top-left
    public var viewY:Int;
    public var centreX:Int;                             // residency centre in cells: the player's cell while closed, the VIEW centre while open (openAt/pan update it)
    public var centreY:Int;
    public var sheets:Int;                              // resident sheet count (telemetry)
    public var residentKeys:haxe.ds.Vector<Int>;        // MAX_SHEETS entries parallel to the sheet Map (eviction scans this, never Map.keys())
    public function new():Void;                         // allocates the Shape, Matrix, Points/Rects, the 512x512 paper master, the reink scratch vectors, residentKeys
    public function buildForTape(t:Tape):Void;          // paper master (noise fibre, grid, creases, coffee ring), disposes all sheets
    // drains up to INK_PER_FRAME queued items into ONE Shape and ONE draw per sheet touched; re-inks a pending sheet up to REINK_PER_FRAME under the
    // "still wet" hatch; evicts sheets beyond the 3x3 around (centreX, centreY) — px,py (the player's cell) set the centre only while !open; returns items inked
    public function pump(mem:MapMemory, px:Int, py:Int):Int;
    public function openAt(px:Float, py:Float):Void;    // centres the view (and residency) on the player
    public function close():Void;                       // residency snaps back to the player
    public function pan(dx:Int, dy:Int):Void;           // pixels; moves the residency centre with the view, so sheets 200 cells back re-ink from MapMemory instead of showing bare paper
    // Composites the visible sheet window into bd (2-4 copyPixels), then the player arrowhead at (px,py,ang) via one Shape draw, with the hand wobble offset.
    public function compose(bd:flash.display.BitmapData, w:Int, h:Int, px:Float, py:Float, ang:Float, wobbleX:Int, wobbleY:Int):Void;
    public var tMap:Int;
}
```
Ink geometry: face N of cell (x, y) = segment (x, y)→(x+1, y) × 6 px; E = (x+1, y)→
(x+1, y+1); S = (x, y+1)→(x+1, y+1); W = (x, y)→(x, y+1); two strokes, `lineStyle(1,
0xFF1A2A5A, 0.85)`, jitter ±1 px from `Rng.hash3(TAG_INK, Cells.pack(x, y), face)`.
Visited = a 1-px pencil dot `0xFF777066` at the cell centre; wet = a 3-px `~`; dark =
a 4×4 hatch; pit = a 3-px filled circle + cross. Unknown area is bare paper. Sheet key
= `World.key(x >> 6, y >> 6)`; pixel in sheet = `((x & 63) × 6, (y & 63) × 6)`. Owns:
sheets (`Map<Int, BitmapData>`) with the parallel `residentKeys`, a "pending re-ink"
list. May touch: `MapMemory`,
`Rng`, `Cells`, `Tape`. May not touch: `World`, the frame buffer `fb`. Budget:
`pump` ≤ 1.5 ms when the queue is non-empty, 0 otherwise; `compose` ≤ 2 ms. Tests
(Ruffle): (1) inking a 10-cell corridor produces exactly 22 face segments across at
most 2 draws; (2) a sheet evicted and re-inked is pixel-identical to the original;
(3) `sheets` never exceeds 9 over a 3,000-cell walk, nor over a 200-cell pan with the map
open; (4) `pump` with an empty queue performs no `draw`; (5) after walking a 200-cell
corridor, opening the map and panning back to its start, the corridor's ink is visible
within `ceil(faces / REINK_PER_FRAME)` frames (re-inked, not bare paper).

### `Sfx`

One file holding the `@:sound` classes, all paths relative to `src/backrooms/`:

```haxe
@:sound("../../www/games/backrooms/sfx/hum.mp3") class SndHum extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/hum_low.mp3") class SndHumLow extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/hum_dark.mp3") class SndHumDark extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/drone.mp3") class SndDrone extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/presence.mp3") class SndPresenceLo extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/presence_hi.mp3") class SndPresenceHi extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/drip_loop.mp3") class SndDrip extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/step1.mp3") class SndStep1 extends flash.media.Sound {}   // ..step4
@:sound("../../www/games/backrooms/sfx/splash1.mp3") class SndSplash1 extends flash.media.Sound {} // ..splash2
@:sound("../../www/games/backrooms/sfx/distant1.mp3") class SndDistant1 extends flash.media.Sound {} // ..distant6 (distant5 = thud.mp3)
@:sound("../../www/games/backrooms/sfx/clicks1.mp3") class SndClicks1 extends flash.media.Sound {} // ..clicks2
@:sound("../../www/games/backrooms/sfx/howl1.mp3") class SndHowl1 extends flash.media.Sound {}     // ..howl2
@:sound("../../www/games/backrooms/sfx/snarl.mp3") class SndSnarl extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/hound_step.mp3") class SndHoundStep extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/screech.mp3") class SndScream extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/static.mp3") class SndStatic extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/tape.mp3") class SndTape extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/vcr_whirr.mp3") class SndVcr extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/flicker.mp3") class SndFlicker extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/paper.mp3") class SndPaper extends flash.media.Sound {}
class Sfx { public static function all():Array<flash.media.Sound>; }   // instantiates each once, in AudioBus id order
```

### `LoopPlayer`

```haxe
class LoopPlayer {
    public static inline var CROSS_MIN_MS = 120;        // floor for the lead / crossfade
    public static var latencyMs:Int;                    // measured once per run: getTimer at play() -> first non-zero SoundChannel.position; 0 until measured; pinged once as bk=audiolat&ms=
    public static var crossMs:Int;                      // runtime lead = max(CROSS_MIN_MS, 2 * latencyMs); MP3 play() latency in the browser plugin on this machine is typically 100-250 ms, so a fixed 120 ms could gap or overlap every loop point
    public var volume:Float;                            // 0..1 target, applied each update
    public var pan:Float;
    public var playing:Bool;
    public function new(snd:flash.media.Sound):Void;   // reads snd.length; allocates two SoundTransforms
    public function start():Void;                      // the first start() of the run records getTimer at play(); update() completes the measurement at the first non-zero position and sets crossMs
    public function stop():Void;
    public function update(dt:Float):Void;             // starts the second channel crossMs before the first ends (by getTimer), equal-power crossfade over crossMs, alternates; applies volume/pan
    public function channels():Int;                    // 1 or 2 currently active
}
```
Tests (Ruffle): (1) over a 60 s run `channels()` is never 0 while `playing`; (2) `stop`
then `start` does not leak channels (`channels()` ≤ 2); (3) `latencyMs > 0` and
`bk=audiolat` pinged within 2 s of the first `start()`. (eMac, the §11/§12 listening
test: hum and drone are gapless by ear at the `crossMs` that `audiolat` implies.)

### `AudioBus`

```haxe
class AudioBus {
    // ids (indices into Sfx.all())
    public static inline var HUM = 0; public static inline var HUM_LOW = 1; public static inline var HUM_DARK = 2; public static inline var DRONE = 3;
    public static inline var PRESENCE_LO = 4; public static inline var PRESENCE_HI = 5; public static inline var DRIP = 6;
    public static inline var STEP1 = 7;  // 7..10
    public static inline var SPLASH1 = 11; // 11..12
    public static inline var DISTANT1 = 13; // 13..18
    public static inline var CLICKS1 = 19; // 19..20
    public static inline var HOWL1 = 21; // 21..22
    public static inline var SNARL = 23; public static inline var HOUND_STEP = 24; public static inline var SCREAM = 25;
    public static inline var STATIC = 26; public static inline var TAPE = 27; public static inline var VCR = 28; public static inline var FLICKER = 29; public static inline var PAPER = 30;
    public static inline var MAX_ONESHOTS = 6;
    public var master:Float;
    public var muted:Bool;
    public function new():Void;                         // creates LoopPlayers for ids 0..6, SoundTransforms for one-shots
    public function startBed():Void;                    // hum 0.35, drone 0.25, others at 0
    public function stopAll():Void;
    public function setPresence(p:Float):Void;          // lo = p*p, hi = max(0, p - 0.5) * 1.2
    public function setHumLight(level:Float):Void;      // hum volume = 0.35 * level
    public function setHumLow(on:Bool):Void;            // crossfades HUM <-> HUM_LOW over 1 s
    public function setDark(on:Bool):Void;              // crossfades HUM(_LOW) <-> HUM_DARK over 1 s
    public function setDrip(dist:Float, pan:Float):Void; // falloff; dist >= 6 => 0
    public function footstep(wet:Bool):Void;            // alternates STEP1..4 / SPLASH1..2 at 0.5 / 0.8
    public function oneShot(id:Int, vol:Float, pan:Float):Void;   // dropped silently if MAX_ONESHOTS active
    public function houndStep(dist:Float, pan:Float):Void;
    public function pause():Void;                       // every volume to 0, loops keep running
    public function resume():Void;
    public function update(dt:Float):Void;              // LoopPlayer updates + crossfade ramps
    public function channels():Int;                     // active SoundChannels (telemetry)
    public static function falloff(d:Float):Float;      // clamp(1 / (1 + d/3)^2, 0, 1)
    public static function panOf(bearing:Float):Float;  // 0.7 * sin(bearing)
}
```
Owns: 7 `LoopPlayer`s, a pool of one-shot `SoundChannel` slots. Budget: 0.5 ms.
Tests: (1) `falloff(0) == 1`, `falloff(3) == 0.25`; (2) `channels()` ≤ 20 after
spamming `oneShot` 100 times in a frame; (3) `pause` then `resume` restores the
volumes set before.

### `Input`

```haxe
class Input {
    public static inline var K_UP = 38; public static inline var K_DOWN = 40; public static inline var K_LEFT = 37; public static inline var K_RIGHT = 39;
    public static inline var K_SHIFT = 16; public static inline var K_SPACE = 32; public static inline var K_TAB = 9; public static inline var K_ENTER = 13; public static inline var K_ESC = 27;
    public static inline var K_M = 77; public static inline var K_W = 87; public static inline var K_S = 83; public static inline var K_A = 65; public static inline var K_D = 68; public static inline var K_F = 70; public static inline var K_P = 80;
    public static inline var K_1 = 49;   // ..K_6 = 54
    public var fullscreen:Bool;                         // set by Main from Display
    public var clicked:Bool;                            // a mouse click happened since endFrame()
    public var anyKey:Bool;                             // any key went down since endFrame()
    public var lastKeyCode:Int;
    // Synchronous gesture hook: invoked INSIDE the KEY_DOWN and CLICK listeners, before they return, with the keyCode (or -1 for a click).
    // Flash only permits Stage.displayState = FULL_SCREEN during the dispatch of the user's own event, so this callback is the ONLY place
    // Display.enterFullscreen() / Bench.runFullscreenArm() may be called. Main assigns it once at start (no per-frame allocation).
    public var onGesture:Int->Void;
    public function new(stage:flash.display.Stage):Void;  // listens KEY_DOWN/KEY_UP/CLICK on the stage; DEACTIVATE/FOCUS_OUT/MOUSE_LEAVE call clear() — clear only, none of these pause (Main pauses on Event.DEACTIVATE alone)
    public function down(code:Int):Bool;
    public function pressed(code:Int):Bool;             // went down since the last endFrame()
    public function endFrame():Void;                    // clears edge flags
    public function clear():Void;                       // clears everything (stuck-key guard)
    public function fwd():Int;                          // up/W = 1, down/S = -1
    public function turn():Int;                         // right = 1, left = -1
    public function strafe():Int;                       // D = 1, A = -1 (windowed only; letters never arrive in fullscreen)
    public function run():Bool;                         // shift
    public function mapToggle():Bool;                   // pressed(TAB) || pressed(SPACE) || pressed(M)
    public function fullscreenKey():Bool;               // pressed(F) || pressed(ENTER) — an OSD/telemetry edge only; the fullscreen entry itself happens inside onGesture, never from the frame loop (SecurityError #2152)
    public function snapKey():Bool;                     // pressed(P)
    public function digit():Int;                        // 1..6 if pressed, else 0
    public function injectKey(code:Int, holdMs:Int):Void;   // rc/test: sets down for holdMs (Main ticks it via update(dt))
    public function update(dt:Float):Void;              // expires injected keys
}
```
Owns: a 256-entry `haxe.ds.Vector<Int>` bitset/state. Tests (Ruffle via `injectKey`):
(1) `pressed` is true for exactly one frame; (2) `clear` drops a held key; (3) `fwd()`
with both up and down held is 0; (4) `injectKey` never calls `onGesture` (it is not a
user gesture, so nothing it triggers may try to enter fullscreen).

### `Save`

```haxe
typedef SaveData = { v:Int, tapeCount:Int, salt:Int, deaths:Int, bestSeconds:Int, rung:Int, maxRungWin:Int, maxRungFs:Int, benchDone:Bool, fsHw:Int, qLow:Int };
class Save {
    public static var ok:Bool;                          // false if SharedObject threw; the game runs in-memory
    public static function load():SaveData;             // defaults: v 1, tapeCount 0, salt = Rng.mix(getTimer() ^ 0x1234567), deaths 0, bestSeconds 0, rung 2, maxRungWin 2, maxRungFs 2, benchDone false, fsHw -1, qLow 0
    public static function flush(d:SaveData):Bool;      // try/catch; false on failure (and ok = false)
}
```
Tests (Ruffle): tape count survives a reload; a thrown `SharedObject.getLocal` (stubbed)
yields defaults with `ok == false`.

### `Telemetry` (exists — unchanged interface)

```haxe
class Telemetry {
    public static var host:String;                      // from loaderInfo.url up to the third slash
    public static var enabled:Bool;                     // only when loaded over http
    public static function init(loaderUrl:String):Void;
    public static function ping(q:String):Void;         // GET host + "/telemetry?" + q + "&t=" + getTimer(); the URLLoader is held until COMPLETE
    public static function snap(bmd:flash.display.BitmapData, tag:String):Void;   // POST host + "/snap?tag=" + tag, body = Png.encode(bmd), Content-Type application/octet-stream
    public static function pollRC(handler:String->Void, everyMs:Int = 300):Void;  // polls host + "/rc"; one handler call per non-empty line
    public static function registerEI(fn:String->Dynamic->String):Bool;
}
```
Rules for callers: `Main` is the only caller of `ping` in the game path, at most 2
per second (`tick` every 10 s; events as they happen but coalesced into the next tick if
one fired within 0.5 s). `snap` at most once per 5 s automatically (P key and `rc snap`
are exempt).

### `Png` (exists — unchanged)

```haxe
class Png { public static function encode(bmd:flash.display.BitmapData):flash.utils.ByteArray; }  // 8-bit RGB, no filter, zlib via ByteArray.compress(), CRC table
```
`haxe.zip.Compress.run` on the flash target also wraps `ByteArray.compress` in this
std (verified in `std/flash/_std/haxe/zip/Compress.hx`) but `Png` uses `ByteArray`
directly; nobody else compresses anything.

### `Bench`

```haxe
typedef BenchResult = { maxRungWin:Int, maxRungFs:Int, fsHw:Int, qLow:Int, presentW:Float, presentFs:Float, presentFsRect:Float };
class Bench {
    public static inline var FRAMES = 60;               // every arm, ray arms included (there is no 90-frame arm)
    public static inline var GESTURE_NONE = 0; public static inline var GESTURE_FS_RECT = 1; public static inline var GESTURE_FS_NORECT = 2;
    public function new(stage:flash.display.Stage, display:Display, renderer:Renderer, cam:Camcorder, sprites:SpritePass, rc:Raycaster, world:World, textures:Textures):Void;
    public function runWindowed(onDone:BenchResult->Void):Void;    // sets stage.frameRate = 100; runs the windowed arms; restores frameRate; calls onDone with fsHw = -1, maxRungFs = maxRungWin
    // Fullscreen is measured in TWO arms, each armed by its own user gesture and each called from Input.onGesture (never from the loop, and never
    // enter/exit/enter in one call — a second entry needs a fresh gesture): which = GESTURE_FS_RECT enters with hwRect (armed by the first card
    // click; the card says CLICK TO START), runs FRAMES frames, exits; which = GESTURE_FS_NORECT enters without the rect (armed by Space; the card
    // says PRESS SPACE), runs FRAMES frames, exits. After the second arm onDone gets presentFs*/fsHw/maxRungFs filled in.
    public function runFullscreenArm(which:Int, onDone:BenchResult->Void):Void;
    public var needGesture:Int;                         // GESTURE_* the bench is waiting for (Cards shows the matching prompt); GESTURE_NONE when done or under ?nofs=1
    public var arm:String;                              // current arm name (for the OSD)
}
```
Windowed arms, each `FRAMES` (= 60) frames, each reported as
`bk=bench&arm=<name>&frames=60&ms_work=<getTimer-bracketed work, total>&ms_frame=<ENTER_FRAME-to-ENTER_FRAME, total>&mspf_work=&mspf_frame=<per frame, one decimal>`
(both numbers always; `ms_work` brackets only the arm's own code, `ms_frame` includes
the present and the player's own overhead):
`present_t1` (blank fb, setVector, composite, `stage.quality = LOW`, smoothing flag on —
**at LOW Flash ignores `Bitmap.smoothing`, so this is nearest-neighbour**),
`present_t1_nosmooth` (LOW, smoothing off; expected identical to `present_t1` — the pair
proves the point, and the BRIEF's "smoothing is free" row, measured the same way by
`run/hello/Bench.hx`, is void), `present_t1_smooth_medium` (`stage.quality = MEDIUM`,
smoothing on: the design's chosen bilinear look, unmeasured until this runs),
`present_t1_nosmooth_medium`, `present_t0` (LOW), `present_t0_smooth_medium`, `post_t1`
(present + `Camcorder.apply`; `ms_work` = the `apply` bracket), `ray_t1_f0_160`,
`ray_t1_f1_160`, `ray_t1_f1_320`, `ray_t1_f2_320`, `ray_t0_f0_128` (`ms_work` = cast +
render bracket), `sprites_t1` (the `ray_t1_f1_320` scene plus 2 near full-height
sprites; `ms_work` = the `SpritePass.draw` bracket alone), `mapink` (a 2,000-face re-ink
through `MapPaper.pump`), `glitch_t1` (post with `G_GLITCH` every frame). The ray arms
walk a fixed `FRAMES`-frame path in a fixed 5×5 chunk region of seed 1234
(`World.generateNow`), so numbers are comparable across runs. `qLow = 1` (Display falls
back to `stage.quality = LOW`) only if `present_t1_smooth_medium.ms_frame −
present_t1.ms_frame > 4 × FRAMES` ms; otherwise MEDIUM + smoothing is the shipped present
and `presentW` is its `mspf_frame`. Fullscreen arms (eMac only — Ruffle stubs the
`fullScreenSourceRect` setter, so `tools/ruffle_run.py` passes `?nofs=1` and the arms are
skipped with `fsHw = -1`): `present_fs_rect`, `present_fs_norect`, at the chosen
quality. `fsHw = 1` when `presentFsRect < 0.6 × presentW`. Rung estimate =
`present.mspf_frame + ray arm.mspf_work + sprites_t1.mspf_work + post_t1.mspf_work + 3`
(present is counted once, from the present arm only; sprites are in because a chase is
exactly when a rung must still fit). `maxRungWin` = the highest rung whose estimate with
`presentW` fits its budget (45 ms for rungs 0–3, 30 ms for rungs 4–5); `maxRungFs` = the
same with `presentFsRect` if `fsHw == 1` else `presentFs` (software fullscreen scales to
1024×768 = 786k px against 822×617 = 507k px windowed, ~1.55× the present cost, so
`maxRungFs` is usually below `maxRungWin` when `fsHw == 0`). Reported as
`bk=benchdone&maxRungWin=&maxRungFs=&fsHw=&qLow=&presentW=&presentFs=&presentFsRect=`.
Owns: a blank `fb`. Budget: n/a (runs before the game).

### `Main`

```haxe
class Main extends flash.display.Sprite {
    public static inline var ST_BOOT = 0; public static inline var ST_BENCH = 1; public static inline var ST_CARD = 2; public static inline var ST_PLAY = 3;
    public static inline var ST_MAP = 4; public static inline var ST_DYING = 5; public static inline var ST_ENDS = 6; public static inline var ST_PAUSED = 7;
    public var state:Int;
    public var prevState:Int;                           // for PAUSED resume
    public static function main():Void;                 // Lib.current.addChild(new Main())
    public var dyingFrame:Int;                          // frames since ST_DYING began (the "killer plain for exactly 2 frames" rule counts frames, never seconds)
    public function new():Void;                         // Params.init, Telemetry.init, Save.load, constructs every subsystem, uncaughtErrorEvents listener, ENTER_FRAME listener, DEACTIVATE/ACTIVATE, input.onGesture = onGesture (once)
    public function onGesture(code:Int):Void;           // called synchronously inside Input's KEY_DOWN/CLICK listeners (code = keyCode, -1 = click): the ONLY place display.enterFullscreen() / bench.runFullscreenArm() are called — see §3
    public function setState(s:Int):Void;               // logs bk=state
    public function startTape(index:Int):Void;          // Tape.make, world/textures/camcorder/paper/map/director rebuilt (reusing buffers), player placed, bed started
    public function onRC(line:String):Void;             // "key <code> <holdms>", "snap [tag]", "state", "seed <n>", "die [kind]", "map", "fs" (exit only — an rc poll is not a user gesture, so entering from here would throw; it pings bk=fs&on=0&why=nogesture), "rung <n>", "tele", "blackout", "hound", "relocate"
}
```

## 3. The frame loop (Main.onFrame)

```
now = getTimer(); dtMs = Params.has("fixeddt") ? Params.int("fixeddt", 50) : min(100, now - last); last = now; dt = dtMs / 1000
frameToFrameMs = now - lastEnterFrame; lastEnterFrame = now     // wall time: the drop test only (pinned at >= 1000/frameRate by the player)
input.update(dt)
frameSeed = rng.nextInt()               // Main's own Rng (TAG_DIRECTOR, 1); never used by world gen
try {                                   // ONE try/catch around every step below; a throw never skips endFrame() (see "Errors")
switch state:
  ST_BOOT    -> (first frame only) startTape(save.tapeCount + 1); state = benchWanted ? ST_BENCH : ST_CARD
  ST_BENCH   -> bench drives everything itself (its fullscreen arms are started from onGesture, never from here); on done: quality.setMaxRung(display.fullscreen ? result.maxRungFs : result.maxRungWin) (or Params rung for both), display.setLowQuality(result.qLow == 1), quality.presentEstimate = the present for the current tier and mode, save.flush, state = ST_CARD
  ST_CARD    -> cards.drawCard(fb); hud none; renderer.present(); camcorder.apply (dread 0, G_TEAR in the last second); if (t > 0.8 && (input.anyKey || input.clicked)) || (auto && t > 4.5) or t > 4.5: enter play
                fullscreen is NEVER entered here or anywhere else in the frame loop (SecurityError #2152 outside a gesture dispatch): the first click on the first card enters it from onGesture; F/Enter windowed likewise
  ST_PLAY    -> 1 world.ensureAround(player.cellX() >> 5, player.cellY() >> 5); world.pump(1); if (frame % 30 == 0) world.evictOutside(...)
                2 pe = player.update(dt, bot? bot.fwd : input.fwd(), ..., world)
                3 director.update(dt, false, pe)
                4 apply director.events -> audio (oneShots/humLow/dark/presence/drip), camcorder (tearNow/glitchNow/flags), hud.recVisible = !(events & EV_WATCHER_RELOCATED), quality.lock(2) on glitch (a raise-lock only)
                5 if (events & EV_KILL) -> setState(ST_DYING); dyingFrame = 0; deathKind = director.killer; break
                6 raycaster.setColumns(Quality.rays(rung), tape.fov) (only when changed); raycaster.castRays(world, player.x, player.y, player.ang, hits)
                7 if (frame % 3 == 0) { mapMemory.recordHits(hits); mapMemory.visit(cellX, cellY, world.cell(...)); if (mapMemory.chunkCount() > MAX) mapMemory.evictFarthest(...) }
                8 mapPaper.pump(mapMemory, cellX, cellY)        // no-op when the queue is empty; residency centre = the player while the map is closed
                9 renderer.render(hits, raycaster, player.x, player.y, director.lightOffset, Quality.floorMode(rung), world)
               10 spritePass.draw(renderer, hits, raycaster, px, py, ang, watcher, hound, lightOffset, frameSeed, false)
               11 hud.tick(dt, tapeTime, tsSkip); hud.draw(fb, w, h, director.battery, strobeFrame)
               12 renderer.present()
               13 camcorder.dread = director.presence; camcorder.flags = ...; camcorder.apply(renderer.bd, frameSeed)
               14 audio.update(dt); spatial: audio.setPresence, setHumLight(light of player's cell), setDrip(director.pitDist, director.pitPan), houndStep on EV_HOUND_STEP
               15 if input.mapToggle(): presence > 0.6 ? noSignalFrames = 30 : setState(ST_MAP), mapPaper.openAt(px, py), audio.oneShot(PAPER)
               16 snap key / digits (debug) / rc. NOT the fullscreen key: input.fullscreenKey() here is an OSD/telemetry edge only (see "Gestures" below)
  ST_MAP     -> director.update(dt, true, 0); mapPaper.pan(arrows * 4 * (shift ? 3 : 1)) (moves the residency centre with the view); mapPaper.pump(...); mapPaper.compose(renderer.bd, w, h, px, py, ang, wobble);
                hud.tick(dt, tapeTime, tsSkip); hud.drawStrip(renderer.strip, w, director.battery, strobeFrame); renderer.presentStrip(h - Renderer.STRIP_H); camcorder.apply; audio.update
                (hud.draw and renderer.present are NOT called: the paper fills bd, and a whole-frame present would overwrite it with the stale fb; the timestamp reaches bd only through the strip — no fb, no getVector, no allocation)
                on mapToggle: setState(ST_PLAY), mapPaper.close() (residency snaps back to the player)
  ST_DYING   -> t += dt; dyingFrame++; input locked. Timeline (DESIGN §7), t relative to the start of the state:
                K_PIT:     0..0.5 s tumbling roll (G_ROLL, rollPx growing 4..24 px per frame, tearNow(2) every 3rd frame), then the common tail with plainStart = 0.5 s, plainStartFrame = the first frame at t >= 0.5
                K_BATTERY: 0..0.6 s collapse-to-line (render, then black out every row outside a horizontal band shrinking from h to 2 rows; G_STROBE), then the common tail with plainStart = 0.6 s
                K_WATCHER / K_HOUND / K_DAMAGED: plainStart = 0, plainStartFrame = 0
                common tail, u = t - plainStart: u in [0, 1.2): renderer.render(...) + spritePass.draw(..., plain = (dyingFrame - plainStartFrame) < 2) — the killer plain for EXACTLY 2 frames, a frame count, never a seconds comparison —
                with escalating camcorder flags (tearNow(1 + int(u * 3)), G_GLITCH every 3rd frame, dread -> 1, rollPx rising); at u >= 1.2: audio.oneShot(STATIC) once; u in [1.2, 1.7): G_NOISE_FULL (pure noise sheet, no render);
                u in [1.7, 1.8): black (fill fb 0xFF000000, present, no post); at u >= 1.8 -> setState(ST_ENDS). K_DAMAGED uses the same tail with caption TAPE DAMAGED. Total DYING = 1.8 s (+0.5 pit, +0.6 battery); with ENDS = 3.8 s
  ST_ENDS    -> cards.drawEnds(fb, caption); renderer.present(); camcorder.apply; at t >= 2.0: audio.oneShot(TAPE); save.tapeCount++, deaths++, bestSeconds; save.flush; startTape(next); setState(ST_CARD)
  ST_PAUSED  -> cards.drawPause(fb, !display.fullscreen) once; no updates; on Event.ACTIVATE, any key or click: audio.resume(); state = prevState
} catch (e:Dynamic) { onFrameError(e) }   // the one Dynamic in Main; see "Errors" below
tOurs = getTimer() - now                                  // busy time, bracketed around everything above
tPresent (telemetry only): on RENDER (stage.invalidate() each frame) record tRenderStart; on the next ENTER_FRAME tPresent = now - tRenderStart.
                This is "present + idle": it includes the wait for the next frame tick, so it measures the present step ONLY when frameToFrameMs > budget; it is never fed to Quality
quality.noteFrame(tOurs + quality.presentEstimate, frameToFrameMs, entityActive, state == ST_DYING, state == ST_MAP) -> apply rung change: renderer.setTier, camcorder.setTier, display.attach, raycaster.setColumns, stage.frameRate = Quality.frameRate(rung), quality.presentEstimate = the bench present for the new tier and mode; Telemetry bk=rung
every 10 s: Telemetry bk=tick ...; every 60 s: save.flush
input.endFrame(); frame++                                 // ALWAYS reached, even after a throw
```

**Gestures (`Main.onGesture(code)`)** — runs synchronously inside `Input`'s KEY_DOWN /
CLICK listener, before the listener returns, and is the only place fullscreen is ever
entered: Flash Player permits `displayState = FULL_SCREEN` only during the dispatch of
the user's own mouse/key event, and from ENTER_FRAME, a Timer, a URLLoader callback or
ExternalInterface it throws SecurityError #2152 every time. Decision table, in order:
(1) `state == ST_BENCH && bench.needGesture == GESTURE_FS_RECT && code == -1` →
`bench.runFullscreenArm(GESTURE_FS_RECT, ...)`; (2) `state == ST_BENCH &&
bench.needGesture == GESTURE_FS_NORECT && code == K_SPACE` →
`bench.runFullscreenArm(GESTURE_FS_NORECT, ...)`; (3) `state == ST_CARD &&
firstCardOfSession && code == -1 && !display.fullscreen && !Params.has("nofs")` →
`display.enterFullscreen()` (the click both focuses the plugin and is the gesture);
(4) `!display.fullscreen && (code == K_F || code == K_ENTER) && state != ST_BENCH &&
!Params.has("nofs")` → `display.enterFullscreen()`. Everything else is ignored here and
handled by the loop through the normal edge flags. `onGesture` allocates nothing and
touches no pixel buffer. `rc fs` and `g3("fs")` arrive outside any gesture and can only
exit fullscreen.

**Pause.** `Event.DEACTIVATE` only: `input.clear()`; if state is PLAY or MAP →
`prevState = state; setState(ST_PAUSED); audio.pause()`. Resume on `Event.ACTIVATE`, any
key or a click. Stage `FOCUS_OUT` and `MOUSE_LEAVE` call `input.clear()` and **nothing
else** — `MOUSE_LEAVE` fires whenever the pointer crosses the plugin's edge and
`FOCUS_OUT` fires on focus changes inside the plugin, so neither means the player has
gone, and pausing a keyboard game on them would freeze it mid-chase. Windowed, the pause
card says `CLICK TO RESUME` (Safari 3 delivers no keys until a click refocuses the
plugin), so "any key resumes" is only the fullscreen wording.

**Errors.** Steps 1–16 run inside the single try/catch in `onFrame`; `onFrameError(e)`:
`Telemetry.ping("bk=err&msg=...&n=...&where=...")`, classify by the stage flag (set
around steps 9–13 → `quality.forceDrop()`; set around `world.pump` → `world.genErrors++`,
next `pump` uses `altSeed = 1`), push `getTimer()` into a 3-entry ring `errTimes`, and
fall through — `input.endFrame(); frame++` always run, so a pressed-edge never survives
into the next frame and re-fires (a second map toggle, for instance). `errors10s` = the
number of ring entries within the last 10 s of `getTimer()` (a sliding window, so it
resets by itself); `errors10s >= 3` → `setState(ST_DYING)` with caption `TAPE DAMAGED`.
`uncaughtErrorEvents.UNCAUGHT_ERROR` stays registered for errors outside the frame
handler (event listeners, URLLoader callbacks, Timer) and feeds the same ring and
classification. `?throw=1` throws a `String` at frame 100 inside step 9 for the test,
and the test also asserts that frame 101 opens no map (`input.endFrame()` ran).

## 4. Telemetry and snapshot protocol

Host is taken from `loaderInfo.url` (`Telemetry.init`), same origin, so the eMac
reports to whatever served the SWF (`http://192.168.11.10:9980`). All values are
URL-encoded by the sender; the daemon logs the decoded query to `run/telemetry.log` with
a timestamp and device name.

`GET /telemetry?<k=v&...>&t=<getTimer>` — one line per event. Keys (`bk` is the record kind):

| bk | keys |
|---|---|
| `boot` | `ver, cpu, os, sw, sh, so_ok, tape, rung, maxRungWin, maxRungFs, fsHw, qLow, params` |
| `bench` | `arm, frames, ms_work, ms_frame, mspf_work, mspf_frame` |
| `benchdone` | `maxRungWin, maxRungFs, fsHw, qLow, presentW, presentFs, presentFsRect` |
| `tick` (every 10 s) | `fps, ms, rung, tier, t_logic, t_gen, t_ray, t_wall, t_floor, t_spr, t_hud, t_map, t_set, t_post, t_audio, t_ours, t_present, t_busy, mem, chunks, mapChunks, sheets, ents, D, P, tape, chans, tt, x, y, fs` — `t_present` is RENDER → next ENTER_FRAME, i.e. present + idle, a measurement only when `ms` > budget; `t_busy` = `t_ours + presentEstimate` is what Quality sees |
| `audiolat` (once) | `ms` (MP3 `play()` start latency; `LoopPlayer.crossMs = max(120, 2 × ms)`) |
| `state` | `s` (BOOT/BENCH/CARD/PLAY/MAP/DYING/ENDS/PAUSED), `tape`, `why` |
| `rung` | `from, to, why` (drop/raise/err/override/bench) |
| `err` | `msg, n, rung, where` |
| `key` | `code, fs` (first-run fullscreen probe: each distinct code once) |
| `fs` | `on, sw, sh, rect, why` (`why` = nogesture / denied on a refused entry) |
| `death` | `kind, tt, tape, D, x, y` |
| `nosignal` | `P` |

`POST /snap?tag=<tag>` — body is the raw PNG bytes (`Content-Type:
application/octet-stream`); the daemon detects `\x89PNG` and writes
`run/snap_<device>_<unix>.png`. The base64 `data=` form the daemon also accepts is
**not** used. Tags: `card, play, watcher, hound, map, death_<kind>, stage, rung<N>,
soak<M>`.

`GET /rc?t=<getTimer>` (only with `?rc=1`, every 300 ms) — returns queued lines; the
vocabulary is in `Main.onRC`. Queue from the PC with `tools/rc.py "key 38 500" "snap"`.

## 5. Asset plan

Everything visual is procedural at runtime; there are no `@:bitmap` embeds. Audio is
the only embedded asset class.

- `tools/backrooms_sfx.py` (Windows Python 3.10, standard library `wave`/`array`/
  `math`/`random` only — no numpy) synthesises every sound in DESIGN §6 that does not
  already exist as 22050 Hz mono 16-bit WAV in `run/sfx_wav/`, then runs
  `ffmpeg -y -i in.wav -ac 1 -ar 22050 -b:a 64k -codec:a libmp3lame out.mp3` into
  `www/games/backrooms/sfx/`. Existing files (`hum, drone, presence, static, step1-4,
  tape, thud, screech, flicker`) are kept as they are. `hum_low.mp3` is `hum.mp3`
  resampled by ffmpeg (`asetrate=22050*0.9439,aresample=22050`) so it is a true
  pitch-shift of the same loop. Loop files are trimmed to a zero crossing at both ends
  and given 50 ms fades so the crossfade is clean.
- `www/games/backrooms/` receives `backrooms.swf` (the game), the existing
  `backrooms.html` wrapper at `www/games/backrooms.html` (already passes the query
  string as flashvars and sets `allowFullScreen`), `sfx/*.mp3`. Nothing else is served.
- Procedural at startup (per tape, seeded): 14 textures × 16 bands, 2 sprite mask
  sets, the scanline/vignette sheets (two per tier: normal and tight), 4 grain sheets,
  the paper master, the PixelFont glyph tables (once).

## 6. Build, test and check commands

Run from the repo root. From Windows: `C:\AI\G3Bridge`, `C:\AI\tools\haxe\haxe.exe`.
From WSL: `cd /mnt/c/AI/G3Bridge` and call `/mnt/c/AI/tools/haxe/haxe.exe` with
**relative paths only** (the Windows binary cannot read `/mnt/c/...` paths).

```
# the game (exactly the brief's command plus dead-code elimination; -D swf-header is the
# non-deprecated spelling of -swf-header on Haxe 4.3; verified to write the same SWF header)
haxe -cp src/backrooms -main Main -swf www/games/backrooms/backrooms.swf -swf-version 10.1 -D swf-header=1024:768:30:000000 -dce full

# unit tests (core only; fails if any core class imports flash.*)
haxe -cp src/backrooms -cp tests/backrooms -main TestAll --interp

# standalone compile check of one class against stubs (the LAST class path wins, so stubs go after src)
haxe -cp src/backrooms -cp stubs/pixels -swf-version 10.1 -swf run/check_pixels.swf Renderer

# core purity and rule checks (greps core files for "flash.", "Dynamic", "new " inside functions named update/render/apply/draw/pump;
# greps ALL of src/backrooms for ".keys()" / ".iterator()" outside constructors and buildForTape — rule 4)
C:\Python310\python.exe tools\backrooms_check.py

# Ruffle smoke on the PC (daemon running)
C:\Python310\python.exe tools\ruffle_run.py /games/backrooms/backrooms.swf?seed=1234 --seconds 20 --shot run\ruffle_play.png --keys "ArrowUp:3000,Space:100"

# eMac
C:\Python310\python.exe tools\emac.py open "/games/backrooms.html?bench=1&rc=1"
C:\Python310\python.exe tools\emac.py wait "bk=benchdone" 300
C:\Python310\python.exe tools\emac.py rc "snap play"
```

`tests/backrooms/TestAll.hx` is a plain `static function main()` that calls one static
`run():Int` per test class (`TestRng, TestChunkGen, TestWorld, TestRaycaster,
TestMapMemory, TestPath, TestPlayer, TestWatcher, TestHound, TestDirector, TestTape,
TestQuality, TestBot`), prints `name: pass/fail` lines and exits non-zero on any
failure via `Sys.exit(1)`. Each test class must reference its subject through the real
class, never a stub.

## 7. Who owns what (integration map)

| implementer unit | classes | depends on (signatures only) |
|---|---|---|
| world | `Cells, Rng, Chunk, ChunkGen, World` | — |
| geometry | `RayHits, Raycaster, Path` | `Cells, World` |
| sim | `Player, Entity, Watcher, Hound, Director, Tape, Bot, Quality` | `Cells, Rng, World, Path` |
| mapping | `MapMemory, MapPaper` | `Cells, Rng, RayHits, Tape, World.key` |
| pixels | `Textures, Renderer, SpritePass, PixelFont, Hud, Cards` | `Cells, Rng, Tape, RayHits, Raycaster, World, Watcher, Hound` |
| post | `Camcorder, Display` | `Tape` |
| audio | `Sfx, LoopPlayer, AudioBus` | — |
| platform | `Params, Input, Save, Bench, Main` (+ existing `Telemetry, Png`) | everything |
| assets | `tools/backrooms_sfx.py`, `tools/backrooms_check.py`, `tests/backrooms/TestAll.hx` skeleton | — |

Anything not in this file that two units both need is added **here first**, then
implemented.
