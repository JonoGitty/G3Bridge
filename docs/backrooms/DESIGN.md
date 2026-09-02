# BACKROOMS TAPE — final design

Synthesised 2 Sep 2026 from three candidate designs ("perf", "horror", "systems") and
three judgements. Two judges chose perf, one chose horror. This document is perf's
engine with horror's content and systems' robustness and test discipline folded in,
and every flaw the judges listed avoided. It states decisions. Options that were
considered and rejected are marked *rejected* so nobody re-opens them.

Companion: `CONTRACT.md` (the module contract implementers code against). Brief and
measurements: `BRIEF.md`. Target: Haxe 4.3.7 → SWF 10.1 → Flash Player 10.1.102.64 in
Safari 3.2.1 on an eMac G4 1.25 GHz (PowerMac6,4), 1024×768 CRT.

## 0. The ten decisions that shape everything

1. **One composite per frame, nothing else on the stage.** A single `Bitmap` showing
   the native-resolution frame. Scanlines, vignette, grain, tint, flicker, chroma,
   tracking, HUD and the map are all applied to the 320×240 (or 256×192) buffer before
   the one upscale. No overlay Bitmaps, no TextFields, no blend modes, no `.filters` on
   any display object, ever. (Measured: one 320×240 frame costs the whole cap; a filter
   on the scaled Bitmap costs 154 ms.)
2. **Budget is 50 ms (20 fps) by default; 30 fps is a bench-proven privilege.** The
   brief's own conclusion. The SWF header says 30; `stage.frameRate` is 20 at rungs
   0–3 and 30 at rungs 4–5, which the first-run bench must earn.
3. **Present cost is measured uncapped before the game starts.** `?bench=1` runs with
   `stage.frameRate = 100` and reports the present step on a blank frame, with and
   without smoothing at `stage.quality` MEDIUM and LOW (smoothing is ignored at LOW),
   windowed and fullscreen, with and without `fullScreenSourceRect`.
   Every budget number below is an estimate until `run/telemetry.log` replaces it.
4. **No `SampleDataEvent`.** Every sound is an embedded MP3. Loops are gapless via two
   alternating `SoundChannel`s with an equal-power crossfade. Presence, death static,
   hum detune: all pre-rendered on the PC. *Rejected*: any software mixer.
5. **World = 32×32-cell chunks, pure function of `(tapeSeed, cx, cy)`,** connected by
   hashed edge profiles shared by both neighbours and random-walk spines from every
   edge door to a hub, then a bounded connectivity-repair pass. *Rejected*: fixed
   lattice spines, wall border rings, portals at fixed edge cells.
6. **Map: the world freezes while the paper is up, the danger clock does not, and the
   map refuses to open ("NO SIGNAL") when presence > 0.6.** Ink is incremental, batched
   one `draw()` per frame, on capped paper sheets over capped map memory.
7. **Two entities, one hazard set, one fairness law in code**: `Entity.canKill()` is
   false until 3 s of telegraph (audio and picture) have accumulated. Watcher stalks
   (relocates out of view; freezes when seen; REC dot goes out for one frame when it
   moves). Hound hunts (hears you; howls before it runs; bounded BFS; loses you after 6 s
   without sight or sound). Hazards: dark zones, wet carpet, blackouts, pits.
8. **Zero allocation in the frame loop.** All buffers preallocated for both tiers, all
   `Point`/`Rectangle`/`ColorTransform` objects reused, HUD strings rebuilt once per
   second, 16.16 `Int` fixed point in every pixel loop, locals hoisted from fields.
   `Map.keys()`/`iterator()` are never called after start — every resident set (world
   chunks, map-memory chunks, paper sheets) keeps a parallel vector of keys that
   eviction scans instead. The bounded exceptions are listed in CONTRACT §0 rule 4;
   map-memory chunk vectors (allocated on first touch, ≤ 256) are one of them.
9. **Core/fp split, enforced by the build.** Classes that hold logic (world, map memory,
   raycast geometry, entities, director, RNG, tape, quality, bot, path) import nothing
   from `flash.*` and compile under `haxe --interp` for unit tests. Pixel and platform
   classes are the only ones allowed to touch `flash.*`.
10. **Robust by construction**: the whole frame handler runs inside one try/catch, so
    a throw never skips `input.endFrame()` (a pressed-edge that survived would re-fire
    next frame — a second map toggle, say); `uncaughtErrorEvents` catches everything
    outside the handler; both → telemetry; render error drops a rung; gen error
    regenerates with `seed ^ 1`; 3 errors within a sliding 10 s window (a ring of the
    last 3 error timestamps) → "TAPE DAMAGED" → next tape; `dt` clamped to 100 ms; keys
    cleared on deactivate; `SharedObject` and fullscreen wrapped in try/catch with the
    windowed game complete without either.

## 1. Rendering

### Units and camera

- Cell = 1.0 unit ≈ 2 m. Walls are 1 unit high (eye at 0.5). Corridors 1–2 cells wide.
- Player radius 0.22. Walk 0.8 cells/s (≈1.6 m/s), run ×1.6. Turn 100°/s with 0.15 s
  ease-in; `turn = +1` is **right**, i.e. `ang += turn × TURN × dt` — clockwise on
  screen (y down), increasing angle, the same sign as "positive bearing = right" and
  the raycaster's camera plane. *Rejected*: 2.2 cells/s (a jog; kills dread).
- FOV 66° default, 60–72° per tape. Rays are cast to `MAX_DIST = 16` cells; the fog
  (shade band 15 = black) is reached at 12 cells, so nothing past 16 is ever needed.

### Tiers and rungs

Two internal tiers only. *Rejected*: 400×300 (measured 56 ms) and any tier that is not
an integer or near-integer scale of the output.

| tier | buffer | fullscreen scale | windowed (1024×617 stage) |
|---|---|---|---|
| T1 | 320×240 | 3.2× → 1024×768 | 822×617 centred at x = 101 |
| T0 | 256×192 | 4× exact → 1024×768 | 822×617 centred at x = 101 |

Quality is a rung ladder `(tier, floorMode, rays, frameRate)`:

| rung | tier | floor | rays | fps cap | note |
|---|---|---|---|---|---|
| 0 | T0 | F0 flat | 128 (2-px columns) | 20 | guaranteed floor; never disabled |
| 1 | T1 | F0 flat | 160 (2-px) | 20 | |
| 2 | T1 | F1 2×2 blocks | 160 (2-px) | 20 | expected eMac windowed steady state |
| 3 | T1 | F1 2×2 blocks | 320 | 20 | |
| 4 | T1 | F1 2×2 blocks | 320 | 30 | needs measured present ≤ 12 ms (HW fullscreen scaling) |
| 5 | T1 | F2 full floorcast | 320 | 30 | only if the bench proves it |

`Bitmap.smoothing` is **on** and `stage.quality` is **MEDIUM**. At `StageQuality.LOW`
Flash ignores `Bitmap.smoothing` entirely (bitmaps are never smoothed; smoothing is
honoured only at MEDIUM and above) and `BitmapData.draw()` of the map's pencil Shapes is
unantialiased — so the BRIEF's "smoothing on = 34 ms, smoothing is free" row, measured
at LOW by `run/hello/Bench.hx`, compared two identical nearest-neighbour presents and is
**void**. The chosen look (bilinear, consistent with the hardware fullscreen scaler) is
unmeasured until the `present_t1_smooth_medium` / `present_t1_nosmooth_medium` bench
arms run; MEDIUM costs nothing in AA because the only vector content is one Bitmap and
the map draws. LOW (nearest-neighbour) stays as the fallback rung, chosen by the bench
only if MEDIUM + smoothing measures more than 4 ms worse. The scanline pattern is baked
at native resolution and survives either scaler.

### Pipeline (per frame, in this order)

1. **Raycast** (`Raycaster.cast`): one DDA per column over `World.cell`, Float DDA in the
   core class, writing `RayHits` (perpendicular distance as 16.16 `Int`, `texX` 0..63,
   `side`, hit cell coordinates, cell value, face). Per-column direction and fisheye
   tables are rebuilt only when the column count or FOV changes.
2. **Walls** (`Renderer`): per column, one contiguous read from a column-major,
   pre-shaded texture bank. `fb[i] = tex[base + (ty >> 16)]; i += W; ty += step;` — no
   per-pixel arithmetic beyond the fixed-point add. At 2-px rungs each column is written
   to `x` and `x+1` from the same fetch. Shade band = `clamp(int(dist × 1.25) + lightOffset
   + sideBias(0|1) + vignetteBias[x](0..2), 0, 15)`; band 15 is black. The one exact
   integer form, on the 16.16 distance, is `(dist * 5) >> 18` (CONTRACT `Renderer`):
   1 cell → band 1, 4 → 5, 8 → 10, 12 → 15 (the fog).
3. **Floor and ceiling**: per row, constant depth `rowDist[y]` (no pitch), so each row is
   a straight fixed-point walk across a pre-shaded carpet/tile band chosen by
   `rowBand[y] + lightOffset`. F2 = every pixel; F1 = every second pixel of every second
   row, written as 2×2 blocks (reads as chroma smear); F0 = per-row solid colours from two
   240-entry tables (fog-darkened) with a moving sine light band on ceiling rows and
   per-cell floor overrides for WET/PIT so hazards stay visible at F0. **Which texture
   within a row** (carpet / wet / rim / pit / dark carpet; tile / light panel / dark
   tile) is a span rule shared by every mode: the row walk re-evaluates the cell under
   it every **8 px** (one `World.cell` through the last-chunk cache) and switches
   texture base there — never per pixel; the 8-px granularity is a feature (more chroma
   smear). F0's WET/PIT override uses the same stride but only on rows nearer than
   6 cells (≤ ~4,000 cached lookups, ~0.8 ms), so the cheapest rung stays the cheapest.
4. **Sprites** (`SpritePass`): billboards, painter-sorted far to near, column-clipped
   against `zbuf`. ≤ 2 visible by design (one Watcher, one Hound). The Watcher is drawn
   at band `max(6, wallBandAtItsDistance + 3)` — always darker than the wall behind it,
   a hole in the wallpaper — with its silhouette pixels re-noised every frame. The Hound
   is a low, wide black shape with two 2-px pale eyes that flicker: the only pixels
   allowed to be brighter than the wall.
5. **HUD** (`Hud` via `PixelFont`): 5×7 glyph blits straight into `fb`, so the OSD is
   burned into the picture and takes the tape's grain like a real camcorder overlay.
6. `bd.setVector(rect, fb)`.
7. **Camcorder post** (`Camcorder.apply`): native `BitmapData` ops on `bd` (§3).
8. The display list composites the single `Bitmap`. Fullscreen uses
   `stage.fullScreenSourceRect = Rectangle(0, 0, W, H)` set **before**
   `displayState = FULL_SCREEN`, with the Bitmap at scale 1, so the player's fullscreen
   scaler (OpenGL on Mac since 9.0.115) does the upscale. Whether that path is active on
   this eMac is unknown — the GPU is expected to be a Radeon 9200 with 32 MB (verify with
   `system_profiler SPDisplaysDataType` over SSH); the bench decides, and windowed
   822×617 software scaling is the guaranteed path.

### Textures

All procedural at tape start (`Textures.build`, ~30–60 ms on the G4, hidden under the
tape card), seeded from the tape, 64×64, stored column-major with **16 pre-darkened
bands** per texture in one `flash.Vector<UInt>` of 65,536 entries: index =
`(band << 12) | (tx << 6) | ty`. Fourteen textures ≈ 3.7 MB. IDs and content:

| id | texture | content |
|---|---|---|
| 0–3 | wallpaper variants | base `#C9B160` ± tape tint, two-octave value-noise stains, a darker seam every 16 texels, **red channel shifted 1 px** (free permanent chroma fringe) |
| 4 | damaged wall | torn-paper reveal, 1-in-40 walls |
| 5 | dark-zone wall | variant 0 at 15% |
| 6 | carpet | mustard-brown low-contrast speckle |
| 7 | wet carpet | 30% darker with specular speckles |
| 8 | pit rim | carpet, 25% brighter (the ring of cells around a pit) |
| 9 | ceiling tile | grid every 32 texels, grime |
| 10 | ceiling light panel | bright panel; ceiling of cells with the light bit |
| 11 | dark-zone ceiling | tile at 15% |
| 12 | pit | pure black |
| 13 | dark-zone carpet | carpet at 15%: the floor of DARK cells, chosen by `Textures.floorId` (mirrors 5 and 11) |

Sprites: Watcher 32×64 (2 frames), Hound 48×32 (3 frames), stored as masks plus a
per-frame colour fill; 0 = transparent.

### Light flicker

`Director.lightOffset` (0..15) is added to every shade band for the whole frame and
costs nothing. Random 1–3-frame stutters every 4–9 s; deeper (up to +5) near the
Watcher; blackouts set it to 15 for 2–4 s; **+9 while the player's own cell is DARK**
(the dark-zone fog: band 15 lands at (15 − 9) / 1.25 ≈ 4.8 cells, the hazard table's
5). The renderer only ever sees the one summed value — it may not read `Director` —
so "dark locally" has exactly this mechanism plus the 15% textures. It is the most-used
horror lever.

### Adaptive quality policy (`Quality`)

- Input: two numbers per frame. **Busy time** = `t_ours` (a `getTimer()` bracket around
  the whole frame handler) + `presentEstimate` (the bench's `presentW` / `presentFs` /
  `presentFsRect` for the current tier and display mode, `fs_hw`-aware). **Wall time** =
  ENTER_FRAME to ENTER_FRAME. With `stage.frameRate = 20` the player pins wall time at
  ≥ 50 ms whatever the work costs, so wall time can never justify a raise — it is kept
  only for the drop test, where an overrun is real. (`t_present`, RENDER → next
  ENTER_FRAME, is "present + idle": a measurement of the present step only in frames
  that overran; it is telemetry, never a Quality input.) Both EMAs α = 0.1.
- Budget per rung: 50 ms at rungs 0–3, 33.3 ms at rungs 4–5.
- **Drop** one rung when either EMA > 1.15 × budget for 60 consecutive frames. Drops are
  never blocked: `maxRung` is estimated from a bench with no chase in it, so a rung that
  fits without sprites can overrun exactly during a chase, and that is when it must be
  allowed to fall; the 60-frame hysteresis is what stops a single glitch frame dropping.
- **Raise** one rung when the busy EMA < 0.70 × budget for 300 consecutive frames, and
  only if not locked and `rung < maxRung`.
- **Locks** (block raises only): an entity is active (Watcher within 12 cells, or Hound
  not dormant); the death sequence; the map is open; 2 s after any glitch frame; 5 s
  after the previous change.
- `maxRung` = the richest rung the bench proved (its estimate `present + ray arm +
  sprites arm + post + 3` ≤ 45 ms for 20 fps rungs, ≤ 30 ms for 30 fps rungs). There
  are **two** ceilings: `maxRungWin` (windowed present, 822×617 = 507k px) and
  `maxRungFs` (fullscreen present: hardware-scaled if `fs_hw`, else software-scaled to
  1024×768 = 786k px, ~1.55× the windowed present cost — a rung that fits windowed by
  10 ms can overrun by 14 ms in software fullscreen). `Quality.maxRung` is swapped to
  the right one on every fullscreen change and the current rung clamped to it. Both
  are persisted in the `SharedObject` with the current rung so the second run starts
  right. Rung 0 can never be disabled.
- A render error (from the frame handler's try/catch or `uncaughtErrorEvents`) drops a
  rung immediately.
- A rung change is an index swap of preallocated buffers, a `Raycaster.setColumns`, a
  `Camcorder` sheet select, a `Display.setTier` and a `stage.frameRate` write. No
  allocation.

## 2. World generation

### Storage

- `Chunk`: 32×32 cells in a `haxe.ds.Vector<Int>` (1024 entries); `cx, cy` are chunk
  coordinates; cell `(x, y)` in world coordinates lives in chunk `(x >> 5, y >> 5)` at
  `(x & 31, y & 31)` — arithmetic shift and mask are correct for negatives, and a unit
  test proves it in all four sign quadrants.
- Cell value bits: 0–2 type (`FLOOR 0, WALL 1, PILLAR 2, WET 3, DARK 4, PIT 5`),
  3–5 wall texture variant (0–7), 6 light panel above, 7 damaged.
- `World`: `Map<Int, Chunk>` keyed `((cx + 0x8000) << 16) | ((cy + 0x8000) & 0xFFFF)`.
  Resident window: the 3×3 around the player; eviction beyond Chebyshev 2 (so at most
  25 chunks ever resident, ~100 KB). Rays reach 16 cells; the nearest non-resident
  chunk is ≥ 32 cells away. An unloaded cell reads as WALL.
- Pending-chunk ring: crossing into a new chunk queues up to 3 chunks; `pump` generates
  at most one per frame (~1 ms). The player moves < 0.05 cells per frame, so the queue
  drains long before anything can see it.

### Determinism

Everything derives from `tapeSeed` through `Rng.hash3` (murmur3 fmix mixing, `Int`
only). A chunk is a pure function of `(tapeSeed, cx, cy)` plus the four edge profiles,
each a pure function of `(tapeSeed, min(a, b), max(a, b))` over the unordered pair of
chunk coordinates. Evicted chunks regenerate byte-identical (unit-tested).

### Edge profiles (how chunks join without seams)

For the shared edge between two 4-adjacent chunks, `ChunkGen.edgeProfile` produces 32
entries (1 = open, 0 = wall) that both chunks stamp on their own border cells. Because
both border rows carry the same profile, walls are 2 cells thick across a seam (reads
as a normal wall) and openings are 2 cells long (reads as a doorway or an open hall).
Profile content depends on the openness of the zone noise at the edge midpoint: HALL
edges are mostly open (60–90%) with wall runs; WARREN and ROOMS edges are mostly wall
with 1–3 door runs 1–3 cells wide; every profile has at least one opening.
*Rejected*: wall border rings, doors at fixed positions.

### Zones (moods that span chunks)

`ChunkGen.zoneAt(tapeSeed, cx, cy)` samples low-frequency value noise (period 3–4 chunks)
so a zone spans 2–5 chunks:

| zone | share | content |
|---|---|---|
| HALL | 55% | open floor; pillars every 4 cells with ±1 jitter (p 0.7); wall slabs 6–10 cells long |
| WARREN | 25% | 1–2-wide corridors from a randomised DFS maze on a 2-cell lattice; 35% of dead ends kept (Watcher cover) |
| ROOMS | 12% | BSP into 3–7-cell rooms, one doorway per shared wall (p 0.8, sometimes two), 12% of rooms walled on three sides |
| DARK | 8% | any of the above with the DARK floor type; no light panels; walls, ceiling and floor use the 15% textures (5, 11, 13); `Director` adds +9 to `lightOffset` while the player's own cell is DARK, so the fog (band 15) lands at (15 − 9) / 1.25 ≈ 4.8 cells = the hazard table's 5 |

Zone share shifts with distance from origin: DARK and WARREN rise by up to +10 points
each over the first 20 chunks.

### Generation order (`ChunkGen.generate`)

1. Fill WALL. Stamp the four edge profiles onto the border cells.
2. Carve the **spine**: from every open run on every edge, a random-walk corridor
   (1–2 wide, steps biased 70% toward the hub) to a hub cell in the middle third of the
   chunk. Every door is now connected to the hub.
3. Zone carving (HALL/WARREN/ROOMS/DARK as above), never overwriting spine cells with
   WALL.
4. Wet patches: 1–3 blobs of radius 2–4 in 30% of chunks (WET type on floor cells).
5. Long sightline in 1-in-6 chunks: a straight 20–32-cell corridor (may exit the
   chunk; it stops at the border profile).
6. Pits: in HALL or ROOMS zones only, p 0.04 per chunk, one 1×1 PIT on a floor cell
   with all 8 neighbours floor; those neighbours become carpet variant "rim". Never in
   DARK zones.
7. Texture variant bits from cell hash; light bit on every third floor cell in a
   lattice (none in DARK); damaged bit 1-in-40 walls.
8. **Feel rules**: fill any 1×1 floor pocket; guarantee an alcove (a 1-cell side
   notch) within every 12 corridor cells; remove pillars within 2 cells of a door.
9. **Connectivity repair**: flood-fill from the hub; for each unreached floor region
   (≤ 16 handled), carve a straight tunnel from its cell nearest the reached set toward
   it. Bounded (≤ 1024 cells touched). Anything still unreached is filled WALL.

Cost ≈ 40–60k simple ops ≈ 1 ms at 50 Mops/s.

## 3. Camcorder presentation

All effects act on the native-resolution `BitmapData` **after** `setVector` and
**before** the single composite, in native calls, with every `Point`, `Rectangle` and
`ColorTransform` preallocated. `dread` = `Director.presence` (0..1).

| effect | implementation | cost | trigger |
|---|---|---|---|
| scanlines + vignette | ONE W×H ARGB sheet per tier (odd rows black α 0x38; corners to 65% black), `copyPixels` with `mergeAlpha = true` | 1 native merge, ~1 ms | always; vignette variant sheet with a 15% tighter radius selected at dread > 0.5 |
| grain | 4 pre-rendered 512×512 ARGB noise sheets per tape (alpha 24–40 per tape), `copyPixels` of a W×H window at a random offset, `mergeAlpha = true` | 1 native merge, ~1 ms | always; sheet index `min(3, int(dread × 4))` selects heavier grain |
| tint + flicker | `bd.colorTransform(rect, ct)` with per-tape multipliers (±8%) and offsets, brightness jitter ±4 per frame | ~1 ms (measured with noise: 3 ms for both) | always |
| chroma bleed | permanent: baked into wallpaper (red shifted 1 px). Glitch frames: `copyChannel` of the red channel from a scratch copy offset `2 + int(dread × 3)` px | 0 / 2 native ops | always / glitch |
| head-switch bar | bottom 4 rows overwritten with a noise strip (`copyPixels` from a grain sheet) at a cycling x offset | trivial | always |
| tracking tear | 1–4 bands 6–40 rows tall shifted 2–12 px via `copyPixels` from the scratch copy, a 2-row grey `fillRect` at each band edge | trivial | random every 12–25 s; every 2–5 s at dread > 0.4; continuous while the Hound is within 4 cells |
| vertical roll | `bd.scroll(0, k)` and the wrap band filled from a grain sheet | 1 native op | Hound chase; permanent slow roll on a bad tape |
| dropout | 1–3 white `fillRect` streaks 1–2 rows | trivial | random every 6–15 s, more with dread |
| glitch frame | `bd.applyFilter(bd, strip320x32, p, BlurFilter(3, 0, 1))` on ONE strip plus random slice offsets and an inverted band | ~1 ms, ≤ 1 frame in 30 | Watcher relocation or lunge, Hound spawn, damage tick, death |
| light flicker | `lightOffset` shade shift (§1) | free | continuous |
| strobe | alternate frames colorTransform ×0.6 | free | battery < 10% |
| HUD | `PixelFont` blits into `fb` before `setVector`: `REC ●` (1 Hz blink), `SP`, battery bars, timestamp `DD.MM.YYYY HH:MM:SS` (tape date + play time), `PLAY ▶` fading at tape start; three HUD skins per tape (layout/colour) | ~600 px writes | always; the REC dot is **off for exactly one frame** when the Watcher relocates; the timestamp skips 1–7 s forward occasionally at dread > 0.7 |
| picture degrade | grain sheet, tracking rate, chroma offset, and tint desaturation all scale with dread | 0 | proximity |

Death breakup and NO SIGNAL are described in §7 and §4. Nothing is ever applied to the
scaled display object. *Rejected*: overlay Bitmaps, TextFields, `BlendMode`, filters on
the Bitmap.

## 4. Auto-mapping

### What is recorded

Wall faces the camera has seen at distance < 10 cells (inside the fog), and floor cells
stood on. Every column's hit is recorded (not every Nth column), every third frame; a
face is `(cellX, cellY, N|E|S|W)` derived from `side` and the ray's step sign. Nothing
seen through the fog, nothing behind the camera: the map is what the tape saw.

### Data (`MapMemory`, core)

`Map<Int, haxe.ds.Vector<Int>>` keyed like world chunks, 1024 entries per chunk, one
per cell: bits 0–3 faces seen (N=1, E=2, S=4, W=8), 4 visited, 5 wet seen, 6 dark seen,
7 pit seen. Never evicted by world residency. **Cap 256 chunks**; over the cap the
chunk farthest from the player is dropped ("the ink fades"). Newly set faces and cells
go to a ring queue (capacity 4096) that the paper drains.

### Paper (`MapPaper`, fp)

- Sheets: 384×384 `BitmapData` covering 64×64 cells at **6 px per cell**, keyed by
  sheet coordinate `(x >> 6, y >> 6)`. At most 9 resident: the 3×3 around the
  **residency centre**, which is the player while the map is closed and the **view
  centre while it is open** (`openAt` and every `pan` move it) — so panning back over
  ground explored 200 cells ago re-inks those sheets from `MapMemory` instead of showing
  bare paper, and the brief's "see what you've explored" holds everywhere the memory
  holds (256 chunks), not just near the player. Beyond the 3×3 the farthest is
  disposed; on close, residency snaps back to the player. A sheet that comes back is
  re-inked from `MapMemory` at ≤ 256 faces per frame while a "still wet" pencil hatch
  marks the area.
- Paper: each new sheet starts as a window (seeded offset) of a per-tape 512×512 paper
  master: warm grey-white with `noise()` fibre, faint grid, fold creases at thirds, one
  coffee ring somewhere per tape.
- Ink: a face is two overlapping 1-px blue-black strokes with ±1 px jitter seeded by
  the face id (so re-inking reproduces the same wobble). **All faces queued in a frame are
  drawn into ONE `Shape` and applied with ONE `sheet.draw()`, at most 64 faces per
  frame**; the remainder waits. Visited floor: a pencil dot; wet: a scribbled `~`; dark:
  a shaded pencil block; pit: a small filled circle with a cross.
- View: while the map is open the frame buffer shows a window of the sheets (2–4
  `copyPixels`), the player as a small arrowhead drawn live (one `Shape` draw per frame),
  then the camcorder post runs as normal: **the VHS effects stay on** — you are watching
  a tape of someone holding a map up to the lens — and the whole map wobbles at 0.5 Hz
  by ±2 px. The timestamp keeps running, drawn into an 8-row opaque OSD strip
  (`Hud.drawStrip` → `Renderer.presentStrip`) that is set straight into `bd` under the
  paper: `fb` is never presented while the map is up, because a whole-frame `setVector`
  would overwrite the composed map with the stale frame buffer, and reading `bd` back
  would allocate.
- Pan: arrows 4 px per frame at native resolution (Shift ×3). No zoom.

### Controls

M (windowed) / Tab or Space (fullscreen or windowed) toggles. The same key closes it.

### Pause policy — decided

**The world freezes while the map is open; the danger clock does not; the map refuses
to open when presence > 0.6.** Justification: in fullscreen the arrows are consumed by
panning, so an unpaused world would kill a reading player with no possible response —
unfair by the brief's own rule. But a free pause would be a free rest, so
`Director.tapeTime` keeps running (escalation continues), the Hound's alert state does
not decay, the ambience keeps playing with the presence tone frozen at its current
level, and the battery keeps draining. If something is already on you (`presence >
0.6`) the map does not open: "NO SIGNAL" in the OSD, a two-frame blue field, a static
blip — you cannot consult it while something is close, and you never die while reading.
Real pauses (`Event.DEACTIVATE` only: tab-away, another application in front) freeze
everything and silence the audio with a VCR-style `‖ PAUSE` OSD; `Event.ACTIVATE`, any
key or a click resumes. Windowed, the OSD says `CLICK TO RESUME`, because Safari 3
gives the plugin no keys until a click refocuses it. Mouse-leave and stage focus-out
never pause: `MOUSE_LEAVE` fires whenever the pointer crosses the plugin's edge and
`FOCUS_OUT` fires on focus changes inside the plugin, so a keyboard player who nudges
the mouse would otherwise freeze mid-chase; both only clear the key state.

## 5. Dangers

### Escalation and presence

- `D = clamp(0.5 × (tapeTime / 600) + 0.5 × (cellsWalked / 500), 0, 1)`: ten minutes or
  five hundred cells to maximum. Milestones: Watcher exists from `tapeTime = 90 s`;
  Hound may spawn at `D > 0.25`; timestamp skips and permanent hum detune at `D > 0.7`;
  Watcher radius floor 3 at `D > 0.9`. Per-tape initial `D` offset 0–0.1.
- `presence P = max(watcherP, houndP)`, `watcherP = clamp(1 − dist / 10, 0, 1)²` while
  the Watcher exists, `houndP = clamp(1 − dist / 14, 0, 1)` while it howls or chases,
  0.3 while it is lost and wandering. `P` drives the presence loops, grain sheet,
  tracking rate, chroma offset, and NO SIGNAL.
- Relief valve: whenever the Hound loses you, the Watcher does not relocate for 45 s.
  No double-teaming: the Hound never spawns while the Watcher is within 6 cells.

### Fairness law (in code)

`Entity.canKill()` returns false until `telegraph ≥ 3.0` s. `telegraph` accumulates only
while the entity's audio and picture cues are active (Watcher within 10 cells, Hound
from the start of its howl) and decays at 1/s otherwise. Unit-tested: no entity can kill
inside 3 s of first becoming a threat.

### The Watcher (stalks)

Tall, thin, matte-black, no face, slightly too many joints; a hole in the wallpaper
(§1 sprites), silhouette re-noised every frame. Exists from 90 s.

- Lives at target radius `R = lerp(14, 4, D)` cells. Every 4–9 s it **relocates** to a
  floor cell at distance ≈ R (±1) that is not in the view cone (±(FOV/2 + 5°) of
  facing — ±35° at FOV 60°, ±41° at 72°, so it is never placed at the screen edge and
  never pops in — with line of sight), preferring dead ends and corridor ends aligned
  with the facing ±30°, so that when you turn, it is there. Relocation: REC dot out for one frame, a wet
  click-cluster one-shot panned to its bearing, a glitch frame at dread > 0.3.
- While in view and within 8 cells it does not move. Looked at within 10° of centre for
  > 1.5 s → it relocates on the next flicker. Unseen for > 20 s → R shrinks by 1 per
  relocation. At R ≤ 2 it approaches at 0.6 cells/s and kills on contact (subject to
  `canKill`). During any blackout it relocates, always closer.
- Despawns (a dropout, "it isn't on the tape") if the player gets > 30 cells away for
  20 s; respawns per the director.
- Telegraph: presence loops rise with `watcherP`; the hum drops a semitone
  (crossfade to the pre-pitched low hum) within 6 cells; grain, chroma and tracking
  scale with dread; deeper light flicker.
- Counterplay: keep moving, keep it in the corner of the eye, never stand still in a
  dead end.

### The Hound (hunts)

Low, wide, quadruped-ish, 0.45 cells tall, pale flickering eyes. States: DORMANT → HOWL
→ CHASE → LOST → DORMANT.

- Spawns beyond 20 cells, out of view, when `D > 0.25`, at most one; a distant scream
  one-shot plays 5 s before it spawns. Dormant, it wanders slowly and makes no sound.
- It **hears**: running within 24 cells, wet-carpet splashes within 32, walking within
  10, any blackout within 40. Hearing sets its target to your last-heard position and
  starts the **howl** (2–3 s, it does not move; the telegraph).
- Chase: 1.35 × walk speed for up to 12 s of stamina, then 0.9 × walk (it tires).
  Pathing: `Path.bfs` over a 24×24 window (≤ 576 nodes) to the last-heard or last-seen
  position, re-pathed every 0.5 s; clamped to loaded chunks. *Rejected*: greedy DDA.
- It **loses you** after 6 s without line of sight and without hearing you; then it
  wanders back toward dormancy at 0.5 × speed for 30 s, snarling every few seconds so
  you know where it is.
- Sprint gives 1.6 × walk for 4 s with 12 s recovery: a chase is won by breaking line of
  sight around two corners and standing still, never by outrunning.
- Telegraph: howl; then fast slapping footsteps with distance falloff and pan; vertical
  roll and continuous tear while it is within 4 cells.
- Lethal on contact (subject to `canKill`, which the howl satisfies).

### Hazards

| hazard | effect | telegraph |
|---|---|---|
| DARK zone | fog at 5 cells (`lightOffset` +9 while standing in a DARK cell, plus the 15% wall/ceiling/carpet textures), no light panels, Watcher relocations twice as often, Hound hearing radii +50%, battery drains 4× | the zone edge is a visible falloff; the hum changes to the dark-zone loop |
| WET carpet | speed × 0.6; footsteps +6 dB and heard by the Hound at 32 cells | visibly darker, specular floor (also at F0 via per-cell override); splashing steps |
| Blackout | lights out (`lightOffset` 15) for 2–4 s, every 60–120 s at `D > 0.5`; the Watcher relocates closer; the Hound hears it | flicker stutter 1 s before; the hum dips |
| PIT | stepping in = "the tape falls": 0.5 s tumbling roll, then death | a black floor cell inside a ring of brighter "rim" carpet, visible at 8 cells in lit zones (never in DARK zones); a drip loop audible and panned within 5 cells. During a blackout a pit is not lethal: a stumble, a thud, a 3 s tracking storm |
| Battery | starts 60–100%, drains to 0 over ~25 min (4× in DARK); < 10% strobes; 0% = "BATTERY" → tape ends | the bar on the HUD; the strobe |

Battery is the soft ceiling that makes every tape finite; the design wants a tape to end
around 12–20 minutes.

## 6. Audio

Embedded MP3 only (`@:sound`, produced by `tools/backrooms_sfx.py` + ffmpeg, mono,
22050 Hz, 64 kbps). No `SampleDataEvent` anywhere. Existing files in
`www/games/backrooms/sfx/` are kept and the set is extended:

| id | file | kind | use |
|---|---|---|---|
| HUM | hum.mp3 (exists) | loop | fluorescent hum; volume = light level of the player's cell |
| HUM_LOW | hum_low.mp3 | loop | pre-pitched −1 semitone; crossfaded in near the Watcher and permanently at D > 0.7 |
| HUM_DARK | hum_dark.mp3 | loop | dark-zone bed (lower, more rattle) |
| DRONE | drone.mp3 (exists) | loop | low drone, always at 0.25 |
| PRESENCE_LO | presence.mp3 (exists) | loop | ~40 Hz rumble; volume = P² |
| PRESENCE_HI | presence_hi.mp3 | loop | thin 6 kHz whine; volume = max(0, P − 0.5) × 1.2 |
| DRIP | drip_loop.mp3 | loop | pit telegraph, spatialised |
| STEP1–4 | step1–4.mp3 (exist) | one-shot | carpet footsteps, alternating; every 0.7 cells |
| SPLASH1–2 | splash1–2.mp3 | one-shot | wet footsteps |
| DISTANT1–6 | distant1–6.mp3 | one-shot | door slam, fluorescent ping, something dragged, a cough, a thud (thud.mp3 exists), a chime; every 20–50 s, 8–20 cells away, low volume; 1-in-5 from directly behind |
| CLICKS1–2 | clicks1–2.mp3 | one-shot | Watcher relocation, panned to its bearing |
| HOWL1–2 | howl1–2.mp3 | one-shot | Hound telegraph |
| SNARL | snarl.mp3 | one-shot | Hound lost and wandering |
| HOUND_STEP | hound_step.mp3 | one-shot | fast slapping steps during chase, rate ∝ speed |
| SCREAM | screech.mp3 (exists) | one-shot | 5 s before the Hound spawns |
| STATIC | static.mp3 (exists) | one-shot | death burst; NO SIGNAL blip at low volume |
| TAPE | tape.mp3 (exists) | one-shot | tape clunk at TAPE ENDS |
| VCR | vcr_whirr.mp3 | one-shot | tape card |
| FLICKER | flicker.mp3 (exists) | one-shot | light stutter |
| PAPER | paper.mp3 | one-shot | map open/close |

- **Gapless loops**: MP3 encoder padding makes `play(0, int max)` click, so `LoopPlayer`
  runs two `SoundChannel`s of the same `Sound`, starts the second `crossMs` before the
  first ends, equal-power crossfades over `crossMs` via `SoundTransform.volume`, and
  alternates. `crossMs = max(120, 2 × measured start latency)`: MP3 `play()` latency in
  a browser plugin on this class of machine is typically 100–250 ms, so a fixed 120 ms
  lead could leave a gap (or a late overlap) at every loop point of the hum and drone —
  the two loops that are always on. The first `start()` measures it once (`getTimer()`
  at `play()` → first non-zero `SoundChannel.position`) and pings `bk=audiolat`, so the
  §11 listening test has a number to check. Loop lengths are chosen so the crossfade
  lands on a stationary part.
- **Mixing** (`AudioBus`, all `SoundTransform`): master; bed (hum 0.35 + drone 0.25);
  presence; footsteps 0.5 (wet 0.8); spot effects. Falloff `vol = clamp(1 / (1 + d / 3)²,
  0, 1)`, `pan = 0.7 × sin(bearing)`. Pitch is not variable in 10.1, so samples alternate.
- Channel count asserted ≤ 20 (Flash caps at 32): 7 loops × 2 channels + ≤ 6 one-shots.
- Tab-away / pause: every channel's volume to 0 and loops keep running (so the
  crossfade state is preserved); resume restores volumes.

## 7. Tape loop

State machine in `Main`: `BOOT → BENCH? → CARD → PLAY ⇄ MAP → DYING → ENDS → CARD …`
with `PAUSED` overlaid on PLAY/MAP by deactivate.

- **CARD** (4.5 s, or any key after 0.8 s): black; `VCR`; a blue field for 0.4 s; the
  label card in the PixelFont at scale 3 with per-glyph ±1 px jitter and a 0.5 Hz
  wobble, as if filmed off a desk: `TAPE #017`, `"BASEMENT LEVEL — DANNY"`, `REC
  03.11.1996`; then tracking settles over 1 s into gameplay, `REC ●` appears, `PLAY ▶`
  fades. On the very first card of a session the card also says `CLICK TO START`, and the
  click both focuses the plugin (Safari 3 does not deliver keys until the object has
  focus) and is the gesture that enters fullscreen. That entry happens **inside the
  CLICK listener** (`Input.onGesture` → `Main.onGesture`), never from the frame loop:
  Flash Player only permits `displayState = FULL_SCREEN` synchronously during the
  dispatch of the user's own mouse/key event and throws SecurityError #2152 from
  ENTER_FRAME or a Timer, every time. F/Enter windowed go the same way.
- **DYING** (1.8 s, + **ENDS** 2 s = 3.8 s; a pit adds 0.5 s, a dead battery 0.6 s;
  input locked). A pit death starts with 0.5 s of tumbling roll; a battery death with
  0.6 s of the picture collapsing to a line. Then, from `plainStart`: 1.2 s of
  escalating tear, roll and grain with the killer drawn plainly (band 0) for exactly
  2 frames — `dyingFrame − plainStartFrame < 2`, a frame counter, never a time
  comparison — the only time you see it; `STATIC` burst at +1.2 s; 0.5 s of pure noise
  sheet; 0.1 s of black; **ENDS**: `TAPE ENDS` for 2 s; `TAPE`. Then the next CARD.
  `TAPE DAMAGED` (the error path) uses the same sequence with a different caption. The
  exact per-state timeline is in CONTRACT §3.
- **New tape**: `Tape.make(index, salt)` → seed, name (from a 40-name list × a 16-place
  list), camcorder model, date 1987–1999, tint (warm/cool/green-sick/faded), grain alpha
  24–40, FOV 60–72°, initial D offset, battery start 60–100%, HUD skin, and — one tape in
  ten — a **bad tape** with a permanent slow roll and the hum already detuned. New world,
  new `MapMemory`, new textures, new paper.
- **Persistence**: `SharedObject.getLocal("backrooms")` → `{ v:1, tapeCount, salt,
  deaths, bestSeconds, rung, maxRungWin, maxRungFs, fsHw, qLow, benchDone }`; flushed on
  tape change and every
  60 s; wrapped in try/catch, `so_ok=0` to telemetry and an in-memory counter if denied.
  Nothing about the world is saved: every tape is someone else's footage.

## 8. Input

Fullscreen (Flash 10.1) delivers only arrows, Space, Shift and Tab, so that set is the
complete game; letters are windowed extras.

| action | fullscreen | windowed extras |
|---|---|---|
| forward / back | ↑ / ↓ | W / S |
| turn left / right | ← / → | — |
| strafe | — | A / D |
| run (4 s stamina, 12 s recovery) | Shift (hold) | — |
| map toggle | Tab or Space | M |
| map pan (map open) | arrows, Shift ×3 | — |
| start / dismiss card / unpause | any of the above, or click | any key (windowed unpause needs a click first — Safari 3 delivers no keys until the plugin is refocused) |
| fullscreen | — | F or Enter (also the first click on the card) |
| exit fullscreen | Esc (player-native) | — |
| snapshot to `/snap` | — | P |
| quality override (only with `?debug=1`) | — | 1–6 |

`Input` keeps a key bitset from stage `KEY_DOWN`/`KEY_UP`, computes pressed-edges once
per frame, and clears everything on `DEACTIVATE`, `FOCUS_OUT` and `MOUSE_LEAVE` (clear
only; of the three, only `DEACTIVATE` pauses — §4). It also exposes a synchronous
`onGesture` hook, called inside the `KEY_DOWN`/`CLICK` listener itself, because that is
the only context in which Flash lets the SWF enter fullscreen: the fullscreen row above
(F/Enter, or the first click on the card) is handled there, never from the frame loop,
which would throw SecurityError #2152 on every attempt.
`getTimer()` deltas are clamped to 100 ms. In windowed mode Tab may move Safari's focus
out of the plugin; the wrapper page re-focuses the object on click and the card says
"click to start".

## 9. Modules

Flat layout, no package, every file in `src/backrooms/` (matching the existing
`Png.hx` and `Telemetry.hx`). The full contract — signatures, ownership, budgets,
tests — is in `CONTRACT.md`. Summary:

**Core (no `flash.*` imports, `haxe.ds.Vector` only, compiled under `--interp`)**
`Rng`, `Cells`, `Chunk`, `ChunkGen`, `World`, `RayHits`, `Raycaster`, `MapMemory`,
`Path`, `Player`, `Entity`, `Watcher`, `Hound`, `Director`, `Tape`, `Quality`, `Bot`.

**Flash platform (`fp`)**
`Main`, `Params`, `Display`, `Textures`, `Renderer`, `SpritePass`, `PixelFont`, `Hud`,
`Cards`, `Camcorder`, `MapPaper`, `Sfx`, `LoopPlayer`, `AudioBus`, `Input`, `Save`,
`Telemetry` (exists), `Png` (exists), `Bench`.

The split is enforced twice: `tests/backrooms/TestAll.hx` references every core class
and is built with `--interp` (a `flash.*` import anywhere in core fails that build), and
`tools/backrooms_check.py` greps core files for `flash.` and fails on a hit.

## 10. Per-frame budget

Assumes the **low end** of the brief's envelope, ~50 M simple ops/s, i.e. 1 ms per 50k
ops, because the measured Float DDA + textured fill implies that. Rung 2 (T1, F1, 160
rays, 20 fps) is the expected eMac windowed steady state. Every figure is replaced by
`t_*` telemetry after the first eMac run.

| stage | rung 2 (T1 F1 160) | rung 3 (T1 F1 320) | rung 5 (T1 F2 320) | measured by |
|---|---|---|---|---|
| input, player, director, entities, path (amortised) | 0.8 | 0.8 | 0.8 | `t_logic` |
| chunk gen (≤ 1 per frame, amortised) | 0.5 | 0.5 | 0.5 | `t_gen` |
| raycast DDA | 1.0 | 2.0 | 2.0 | `t_ray` |
| wall columns (~35k px) | 2.5 | 3.5 | 3.5 | `t_wall` |
| floor + ceiling (~42k px) | 2.7 | 2.7 | 10.8 | `t_floor` |
| sprites (≤ 2; **measured ~4 per near sprite** — BRIEF Bench2: +8 ms for 2 billboards; the earlier 2.4 is withdrawn until the `sprites_t1` arm says otherwise) | 8 (2 near) | 8 | 8 | `t_spr` |
| HUD blits | 0.2 | 0.2 | 0.2 | `t_hud` |
| map record (every 3rd frame) + ink batch | 0.3 | 0.3 | 0.3 | `t_map` |
| `setVector` | 1.5 | 1.5 | 1.5 | `t_set` |
| camcorder post (2 merges, 1 colorTransform, bands) | 4.0 | 4.0 | 4.0 | `t_post` |
| audio (crossfades, spatial updates) | 0.5 | 0.5 | 0.5 | `t_audio` |
| AVM2 events, GC slack | 1.5 | 1.5 | 1.5 | — |
| **ours** (worst case, 2 near sprites; ~8 less with none in the frustum) | **~24** | **~26** | **~34** | `t_ours` |
| present (single composite, software windowed 822×617) | 15–30 (unmeasured) | 15–30 | 15–30 | `t_present` |
| present (software fullscreen 1024×768, ~1.55× windowed) | 23–47 | 23–47 | 23–47 | `t_present` |
| present (hardware fullscreen, if active) | ~2 | ~2 | ~2 | `t_present` |
| **frame, windowed** | **39–54 of 50** | **41–56 of 50** | **49–64** (needs bench) | `t_frame` |
| **frame, HW fullscreen** | **~26 of 50** | **~28 of 33** | **~36 of 33** (over; rung 5 needs the bench) | `t_frame` |

`t_present` in the tick is RENDER → next ENTER_FRAME, i.e. present + idle: it measures
the present step only in frames that overran; the quality ladder runs on `t_ours` plus
the bench's present estimate (§1).

If measurements disagree: present > 30 ms windowed → rung 1 or 0 windowed and rungs ≥ 3
only in hardware fullscreen; wall/floor 2× worse → rung 0 (128 rays, F0, T0) is the
proven floor, then `stage.frameRate = 20` is already the cap so nothing else changes;
`setVector` > 4 ms → grain merge every other frame; post > 6 ms → drop the vignette
sheet (scanlines stay); map ink batch > 2 ms → 32 faces per frame.

## 11. Test plan

### Unit (`haxe -cp src/backrooms -cp tests/backrooms -main TestAll --interp`)

- `Rng`: determinism, `hash3` symmetry properties, distribution of `range`.
- `ChunkGen`: byte-identical on repeat; different across seeds; edge profiles agree for
  both orderings of the pair and have ≥ 1 opening; spine cells never WALL after
  generation; no 1×1 floor pockets; pillars ≥ 2 cells from doors; flood-fill over a 5×5
  chunk region reaches 100% of floor cells (2,000 seeds); repair carves ≤ 1024 cells;
  generation bounded (< 200k ops via a counter); zone shares within tolerance over 4,000
  chunks; pits never in DARK zones and always ringed.
- `World`: `cell(x, y)` in all four sign quadrants against direct chunk reads; window
  never exceeds 25 chunks over a 100k-step random walk; an evicted chunk regenerates
  byte-identical; unloaded cells read WALL; pump generates ≤ 1 per call.
- `Raycaster`: against a brute-force marcher on hand-built grids (100 random views):
  distance error < 1e-4 units, exact cell, side and face; face convention matches the map
  ink convention.
- `MapMemory`: face bits round-trip; queue delivers each new face once; cap evicts the
  farthest; `recordHits` ignores hits at ≥ 10 cells.
- `Path.bfs`: against brute force on random grids; never leaves the window; −1 when
  unreachable; clamps to loaded chunks.
- `Player`: wall sliding never ends inside a solid cell over 100k random inputs; wet
  slows; stamina curve.
- `Watcher`: never relocates into the view cone; relocation distance within R ± 1;
  never moves while in view and within 8; `canKill` false before 3 s.
- `Hound`: HOWL lasts 2–3 s with zero movement; loses target after 6 s silent and
  unseen; never spawns with the Watcher within 6; `canKill` false before 3 s.
- `Director`: `D` monotone in time and distance and capped at 1; relief valve after a
  lost Hound; blackout cadence; battery drain rates.
- `Tape.make` reproducible; bad tape 1-in-10 over 1,000 tapes; dates in range.
- `Quality`: drop/raise thresholds on busy time; a pinned 50 ms wall time never blocks a
  raise; locks block raises only (a slow chase still drops); both `maxRung` ceilings via
  `setMaxRung`; 5 s spacing.
- `Bot`: never stands still > 5 s in an open grid.

### Ruffle on the PC (`tools/ruffle_run.py`; proves logic and rendering, never speed)

- SWF loads with no AVM2 verify errors; no `pageerror` over a 10-minute `?soak=1` run.
- Screenshots at the card, 5 s of play, the map open and panned, a scripted death
  (`?die=watcher|hound|pit|battery`), TAPE ENDS, and the second card with tape 2.
- Golden screenshot diff at `?seed=1234&fixeddt=50` frame 30 with tolerance for grain
  (`fixeddt` pins `dt`, so the card wobble/jitter and everything else time-driven is
  deterministic; without it the golden run is timing-dependent in Ruffle).
- What Ruffle cannot prove (confirmed by a probe SWF through `tools/ruffle_run.py`):
  it stubs `System.totalMemory`/`totalMemoryNumber`, `Capabilities.cpuArchitecture` and
  the `fullScreenSourceRect` setter, so memory-flatness, hardware-scaling and `fs_hw`
  claims are eMac-only; allocation-freedom is checked statically
  (`tools/backrooms_check.py`) and under `--interp` for core, and `ruffle_run.py` passes
  `?nofs=1` so the bench's fullscreen arms are skipped.
- `?bench=1` posts the full matrix to the daemon's `/telemetry`; `/snap` PNGs arrive and
  open in PIL.
- `SharedObject` tape count survives a reload.

### eMac (the truth; `tools/emac.py`, `/telemetry`, `/snap`, `/rc`)

- `?bench=1` first run: the present matrix at `frameRate = 100` (T1/T0, `stage.quality`
  LOW and MEDIUM, smoothing on/off, blank frame, post on/off), each rung's render stages
  and the sprite pass bracketed with `getTimer()` (`ms_work`) alongside the
  ENTER_FRAME-to-ENTER_FRAME total (`ms_frame`), `t_present` bracketed from `RENDER`
  (via `stage.invalidate()`) to the next `ENTER_FRAME`, then two fullscreen arms, each
  armed by its own gesture (the first click: with `fullScreenSourceRect`; then `PRESS
  SPACE`: without — a second fullscreen entry needs a fresh gesture, so never
  enter/exit/enter in one call). Result: `maxRungWin`, `maxRungFs`, `fs_hw=0|1` and
  `qLow`, persisted. The `Camcorder.apply` allocation test lives in the soak's `mem`
  series (Ruffle cannot run it).
- Fullscreen key probe: every `keyCode` seen in fullscreen is echoed once to
  `/telemetry` on the first run.
- 60-minute `?soak=1` unattended auto-walker reporting every 10 s: `fps, ms, rung, t_*,
  mem=System.totalMemory, chunks, mapChunks, sheets, ents, D, P, tape, chans`. Pass: no
  `err=`, `mem` drift < 15 MB after minute 5, fps within 10% of minute 1 at a fixed rung,
  no rung oscillation.
- `/snap` at the card, first Watcher sighting, a Hound chase, the map, and each death
  kind; one snapshot of the composed stage per session (`Display.snapStage`) to see the
  real scaler output. Design review on those PNGs: if the Watcher is legible at band 6,
  it is too bright.
- `?throw=1` (a deliberate throw on frame 100) → `err=` line, a rung drop, and no
  phantom map toggle on frame 101 (`input.endFrame()` still ran); storage-denied run
  (Flash settings → refuse) still plays; tab-away/return: audio silent, keys cleared,
  no `dt` jump; the mouse crossing the plugin's edge mid-play: no pause; fullscreen in
  and out twice (each entry from a fresh click or F).
- Audio: `bk=audiolat` reported once at start; hum and drone gapless by ear at the
  `crossMs` it implies (the listening test of §12).
- A one-hour human playtest covering the map, each death kind, and a photograph of the
  CRT to tune grain and scanline strength (the CRT, not Ruffle, decides the look).

## 12. Risks and unknowns

| risk | resolves with |
|---|---|
| The present step (setVector + software upscale) costs > 30 ms windowed, or MEDIUM + smoothing costs more than LOW | `?bench=1` present arms uncapped, per tier, at MEDIUM and LOW, smoothing on/off (the BRIEF's LOW-only smoothing row is void); fallback rung 0/1 windowed; `qLow` fallback to nearest-neighbour |
| `fullScreenSourceRect` hardware scaling inactive on 10.1.102 / Radeon 9200 / 10.5.6 | `system_profiler` over SSH; bench fullscreen arms with and without the rect; `fs_hw` telemetry; windowed is complete without it |
| AVM2 on this G4 sits below 50 Mops/s | per-stage `t_*`; rung 0 is the proven floor; column doubling and F0 are already the cheapest rungs |
| MP3 loop crossfade audible or CPU-heavy; `play()` latency of 100–250 ms gaps or overlaps the loop point | `bk=audiolat` measured at start sets `crossMs = max(120, 2 × latency)`; eMac listening test; fallback: longer loops (3 min drone) with the cut hidden under a distant one-shot |
| `SoundChannel` limit (32) | `chans` telemetry; asserted ≤ 20 in `AudioBus` |
| Fullscreen key set narrower or wider than the brief | first-run keyCode echo |
| `SharedObject` refused (per-user plugin, no admin) | try/catch, `so_ok`, in-memory counter |
| Memory growth from sheets, disposed frames or hidden allocation (closures, `new Point`, strings) | soak `mem` series; all hot objects preallocated; `dispose()` audited; sheets ≤ 9 |
| Map ink `draw()` of a 64-face batch > 2 ms on the G4 | `t_map` telemetry; batch size 32 |
| Sheet re-ink after eviction visible as a hitch | ≤ 256 faces per frame time-sliced; "still wet" hatch covers it |
| Safari 3 focus: keys not reaching the SWF until clicked; Tab tabbing out windowed | wrapper `focus()`s the object; card says click to start; Space and M also open the map windowed |
| `uncaughtErrorEvents` behaves differently in 10.1.102 | `?throw=1` on the eMac, expect `err=` |
| Ruffle disagrees with real FP on `copyChannel`, `scroll`, `mergeAlpha` | every visual claim needs an eMac `/snap`; Ruffle proves logic only |
| The Watcher reads as a bug, not a presence | `/snap` at first sighting reviewed on the CRT; tune band floor and click cluster |
| Chunk seam artefacts at negative coordinates | sign-quadrant unit test; a 5×5 flood-fill test; eMac walk to (−40, −40) with a snap |
| Hound BFS across chunk boundaries with evicted chunks | unit test: path over a 5×5 region; BFS clamps to loaded chunks and returns −1 cleanly |
| CRT makes scanlines vanish or moiré | photograph the CRT; sheet alpha is a per-build constant to retune |
