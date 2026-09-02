# BACKROOMS TAPE — design brief

A first-person analog-horror game that runs on a 2004 eMac, served to it from the PC
by the G3Bridge daemon. Jono's words, lightly tidied:

> A full 3D analog horror game. You explore what seems to be endless backrooms. As you
> walk through it you get the ambient backrooms noise. It should look like you are
> looking through a vintage camcorder. As you go, your character automatically updates a
> map with what it sees, with a basic pen-and-paper drawing scheme: walk down a corridor
> and the system draws out the walls as you go. Press M to open the map and look around on
> it to see what you've explored. There should be dangers. If one kills you, it resets:
> you pick up some other footage, a different camcorder, a new map. It should look funky,
> analog, retro and cool on the eMac's CRT.

Endless, no win state. Death is the loop: the tape ends, the next tape begins.

## The machine (measured, not assumed)

- eMac G4 **1.25 GHz PowerPC**, 1 GB RAM, Mac OS X 10.5.6, **1024x768 CRT**.
- Safari 3.2.1 (WebKit 525). Its JavaScript is ~1000x slower than a modern engine
  (2M loop iterations = 2.5 s) — which is why the game is NOT JavaScript.
- **Adobe Flash Player 10.1.102.64**, the last PowerPC build, installed per-user in
  `~/Library/Internet Plug-Ins` (no admin password exists on this machine).
- Browser viewport windowed: 1024x617. Fullscreen (Stage.displayState = FULL_SCREEN,
  needs a click/keypress): 1024x768, and **Flash 10.1 fullscreen accepts only arrow keys,
  space, shift and tab**. Letters (M, WASD) only work windowed. Design controls so the
  full game is playable with arrows + space + shift + tab, with letters as extras.
- No internet on the Mac. Everything comes from `http://192.168.11.10:9980/games/...`.
  The SWF may load same-origin assets or embed them.

## Toolchain

- **Haxe 4.3.7** on the PC, Flash target: `haxe -cp src/backrooms -main Main -swf www/games/backrooms/backrooms.swf -swf-version 10.1 -D swf-header=1024:768:30:000000` (`-D swf-header=` is the non-deprecated spelling of `-swf-header` on Haxe 4.3; verified to write the same SWF header: 1024x768, 30 fps, version 10).
  The compiler enforces the API level: anything past Flash 10.1 fails to compile. Standard
  library only, no haxelib.
- Assets: `@:bitmap`/`@:sound` embeds (PNG/MP3 produced by Python/ffmpeg on the PC) or
  procedural generation at startup. Prefer procedural textures (they cost nothing to
  transfer and can vary per tape); MP3 embeds for ambience are fine.
- **Ruffle** (Flash emulator) on the PC for smoke tests and screenshots; the **eMac is the
  truth** for frame rate. Two same-origin endpoints on the daemon exist for the game to
  report: `GET /telemetry?key=value&...` (logged) and `POST /snap` (PNG body → saved on
  the PC, so real frames from the eMac can be looked at).
- A `?bench=1` query on the wrapper page should make the SWF run a fixed benchmark and
  report fps per render mode to `/telemetry`, then continue into the game.

## Performance envelope (Flash 10.1, G4 1.25 GHz)

AVM2 is JIT-compiled: expect ~50-150 M simple ops/s. A 320x240 frame is 76,800 pixels.
Writing every pixel from a `Vector.<uint>` with `BitmapData.setVector` each frame is the
right architecture; per-pixel `setPixel` is not. The final upscale to 1024x768 is done by
the display list (a `Bitmap` with `scaleX/Y`), and its cost (smoothing on vs off) must be
measured on the eMac, not guessed. Adaptive resolution (256x192 / 320x240 / 400x300) is
expected. Full-stage BitmapData filters every frame are probably too expensive; cheap
tricks (pre-rendered noise sheets blitted with `copyPixels`, scanline overlay bitmap,
`ColorTransform` on the whole thing, occasional slice offsets for tracking wobble) are the
budget-friendly way to the VHS look. `BlurFilter`/`DisplacementMapFilter` may be
affordable at low res on glitch frames only. Measure.

## What the game must have

1. **First-person 3D** exploration of an **endless** procedurally generated backrooms
   (yellow wallpaper, damp carpet, drop-ceiling tiles, buzzing fluorescents). Same seed
   → same world within a tape; chunks generated on demand; never runs out.
2. **Camcorder look**: low-res 4:3 image, scanlines, tape noise, colour bleed, vignette,
   occasional tracking glitches, REC dot, timestamp (a period-correct date per tape),
   battery, "SP" mode indicator. Light flicker. Degrades when something is near.
3. **Ambience**: fluorescent hum + low drone loop always; carpet footsteps; distant
   one-shots; a presence cue that rises with proximity to danger; static burst at death.
4. **Auto-mapping**: what the camera has *seen* (wall faces hit by rays) is inked onto a
   paper map as hand-drawn lines; visited floor is marked; player position and facing
   drawn; the map opens on **M (windowed) / Tab or Space (fullscreen)**; arrows pan the
   map while it is open; the world pauses (or not — decide and justify).
5. **Dangers**: at least two kinds of entity with different behaviour (one that stalks,
   one that hunts), plus an environmental hazard. Danger scales with time and distance.
   Fair: telegraphed by sound and picture degradation before it is lethal.
6. **Death → new tape**: the recording breaks up, "TAPE ENDS", then a new tape card
   (tape number, a name, a date), a new seed, a fresh map. Tape count persists in a
   `SharedObject`. Each tape's picture can differ slightly (tint, grain) so it feels like
   different footage.
7. **Input**: arrows move/turn (up/down forward/back, left/right turn), shift = run
   (limited), space/tab = map, click or any key = start, F/Enter = fullscreen (windowed).
   Optional strafe on A/D windowed.
8. **Robust**: no crash over an hour of play; memory does not grow without bound
   (chunk eviction); handles being tabbed away; pauses cleanly.

## Verification (Jono's L1–L5 discipline, applied here)

L1 plan (this brief + DESIGN.md), L2 build against a written module contract, L3 test
(unit tests for world gen/mapping/entity logic run in Haxe's own interpreter target or
via Ruffle; smoke tests in Ruffle with screenshots), L4 re-plan from what the eMac's
telemetry says (fps, errors), L4.5 ground every claim in a measurement from the real
machine, L5 adversarial review before it ships.

## MEASURED ON THE EMAC — Flash Player 10.1.102.64, Safari 3.2.1, 2 Sep 2026

`www/games/backrooms/bench.swf` (source `run/hello/Bench.hx`), 60 frames per mode,
SWF frame rate 30 (so 33 ms is the cap). "ray" = a raycast-shaped workload: per
column a 12-step DDA in floats, then a textured vertical wall slice from a 64x64
`Vector.<uint>` texture, flat ceiling and floor, all into a `Vector.<uint>` and
`BitmapData.setVector`, displayed through a `Bitmap` scaled to 1024x768.

| mode | ms/frame | fps | note |
|---|---|---|---|
| fill 320x240 | 35 | 29 | at the frame cap |
| fill 320x240, smoothing on | 34 | 29 | **smoothing is free** |
| fill 256x192 | 32 | 31 | cap |
| fill 400x300 | 44 | 23 | |
| ray 320x240 | 41 | 24 | |
| ray 320x240 + noise `copyPixels` + `colorTransform` | 44 | 23 | **VHS overlay costs ~3 ms** |
| ray 256x192 + noise | 40 | 25 | |
| ray 400x300 + noise | 56 | 18 | |
| ray 320x240 + `BlurFilter` on the scaled bitmap every frame | 154 | 6 | **full-screen filters are out** |
| hello plasma 320x240 | 35 | 29 | |

Conclusions: design for **320x240 internal, 20 fps (50 ms) budget**, with 256x192 as
the fallback. Per-frame floor/ceiling texture casting must fit in the ~10 ms the "ray"
proxy leaves; if it does not, cast floors at half vertical resolution or use a flat
gradient. `Capabilities.cpuArchitecture` reports `PowerPC`, `Capabilities.version`
`MAC 10,1,102,64`. Safari will load a `.swf` URL directly (full window), and an
`<embed>` in a page also works. Same-origin `URLLoader` GETs to `/telemetry` work.

### Second benchmark (`run/hello/Bench2.hx`), 320x240, real eMac

| workload | ms/frame | fps |
|---|---|---|
| textured walls only (12-step DDA, flat floor/ceiling) | 43 | 23 |
| walls + perspective-correct textured floor AND ceiling, every row | 51 | 20 |
| walls + floor/ceiling cast every 2nd row (rows duplicated) | 48 | 21 |
| walls + full floor + 2 billboard sprites (~120px tall, z-tested per column) | 59 | 17 |
| walls + half-row floor + 4 sprites | 52 | 19 |

So the complete pixel pipeline for a frame — walls, textured floor and ceiling, a few
sprites — costs **~50-60 ms at 320x240** on this machine before game logic and the VHS
overlay (~3 ms). Plan for a **20 fps SWF frame rate at 320x240**, and expect ~25 fps at
256x192 (30% fewer pixels). Snapshot cost: `BitmapData.draw(stage)` at 512x384 = 23 ms,
PNG encode = 258 ms, so snapshots are for tests, never for gameplay.

### Test rig, all proven on the eMac (2 Sep)

- `tools/emac.py open <path>` navigates Safari on the eMac; `rc "key 38 500" "snap"`
  queues remote-control lines the SWF polls from `/rc`; `js "<code>"` runs JavaScript in
  Safari, which reaches the SWF's `ExternalInterface` callback `g3(cmd, arg)` — the SWF
  must sit in an `<object id="bk">` tag (an `<embed>` exposes nothing in Safari 3);
  `wait "<marker>" <s>` blocks on `run/telemetry.log`; `snap` prints the newest PNG the
  SWF posted to `/snap`.
- `src/backrooms/Telemetry.hx` and `Png.hx` exist and work on the real player: keep them.
- Scripted keystrokes from AppleScript do NOT reach the plugin (no assistive access), so
  every input the tests need must be injectable through `/rc` or `g3`.
- `.swf` and `.html` under `/games/` are served uncached; other assets cache for 120 s.
