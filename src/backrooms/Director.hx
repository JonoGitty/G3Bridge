// Escalation, entities, blackouts, battery (CONTRACT §1, DESIGN §5). Core class: no flash.* imports.
//
// Order inside update(): clocks (tapeTime, battery, D) -> DARK offsets -> flicker and blackout (so the Watcher
// sees EV_FLICKER / a blackout in the same frame) -> Watcher lifecycle + update -> Hound lifecycle + update ->
// hearing from the player's events -> distant one-shots, timestamp skips, hum detune -> pit scan -> presence ->
// lightOffset. While frozen (map open) only the clocks and D advance: no entity moves, no timer ticks, presence
// and lightOffset are held, no event is raised (Main does not read events in ST_MAP).
// No allocation anywhere after the constructor; the only Rng that advances here is `rng`.
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

    // tuning (DESIGN §5)
    public static inline var WATCHER_AT = 90.0;         // tapeTime at which the Watcher first exists
    public static inline var WATCHER_FAR = 30.0;        // cells; beyond this for WATCHER_FAR_SECS it drops off the tape
    public static inline var WATCHER_FAR_SECS = 20.0;
    public static inline var HOUND_D = 0.25;
    public static inline var HOUND_NEAR_WATCHER = 6.0;  // no double-teaming inside this
    public static inline var HOUND_SPAWN_DIST = 22.0;   // forceSpawnHound distance (contract); natural spawns use HOUND_SPAWN_MIN + spread
    public static inline var HOUND_SPAWN_MIN = 20.0;    // natural spawns land at 20..26, never nearer
    public static inline var SCREAM_LEAD = 5.0;
    public static inline var RELIEF_SECS = 45.0;
    public static inline var BATTERY_DRAIN = 1.0 / 1500.0;   // 25 minutes at normal drain
    public static inline var DARK_DRAIN_MUL = 4.0;
    public static inline var PIT_RANGE = 6.0;
    public static inline var DARK_OFFSET = 9;
    public static inline var LOS_MAX = 24.0;
    public static inline var POST_SAMPLES = 24;         // candidate cells tried per placement
    public static inline var PIT_SCAN_EVERY = 3;        // frames between pit scans (pitDist/pitPan are held between them)

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

    // private clocks and bookkeeping
    var queued:Int;                                     // events raised between frames (force*), delivered by the next update
    var flickerTimer:Float;                             // seconds until the next stutter
    var flickerFrames:Int;                              // frames of stutter left
    var flickerDepth:Int;                               // +2..+5 while stuttering
    var blackoutTimer:Float;                            // seconds until the next blackout (only counts at D > 0.5)
    var blackoutWarned:Bool;                            // the 1 s pre-blackout stutter has fired
    var distantTimer:Float;
    var tsSkipTimer:Float;
    var screamTimer:Float;                              // > 0: a scream has played and the Hound spawns when it hits 0
    var screamPending:Bool;
    var houndCooldown:Float;                            // seconds before another scream may start
    var watcherFarSeconds:Float;
    var watcherRespawnTimer:Float;                      // seconds before the Watcher may come back after a dropout
    var houndFarSeconds:Float;
    var houndPrevState:Int;
    var watcherPrevState:Int;
    var snarlTimer:Float;
    var strobeSent:Bool;
    var batteryDead:Bool;
    var lightPart:Int;                                  // flicker/blackout contribution to lightOffset (held while frozen)
    var wDist:Float;                                    // Watcher distance this frame (99 when not alive)
    var hDist:Float;
    var placeX:Float;                                   // result of findPost
    var placeY:Float;
    var pitPhase:Int;                                   // frames since the last pit scan

    public function new(world:World, player:Player, tape:Tape):Void {
        this.world = world;
        this.player = player;
        this.tape = tape;
        rng = new Rng(Rng.hash3(tape.seed, Rng.TAG_DIRECTOR, 0));
        watcher = new Watcher();
        hound = new Hound();
        tapeTime = 0.0;
        D = tape.dOffset;
        presence = 0.0;
        lightOffset = 0;
        darkOffset = 0;
        blackoutT = 0.0;
        battery = tape.batteryStart;
        hearingMul = 1.0;
        fogCells = 12;
        events = 0;
        killer = 0;
        distantId = 0;
        distantPan = 0.0;
        distantVol = 0.0;
        pitDist = 99.0;
        pitPan = 0.0;
        humLow = false;
        tsSkipSeconds = 0;
        noRelocateUntil = 0.0;
        queued = 0;
        flickerTimer = 4.0 + rng.nextFloat() * 5.0;
        flickerFrames = 0;
        flickerDepth = 0;
        blackoutTimer = 60.0 + rng.nextFloat() * 60.0;
        blackoutWarned = false;
        distantTimer = 20.0 + rng.nextFloat() * 30.0;
        tsSkipTimer = 30.0 + rng.nextFloat() * 60.0;
        screamTimer = 0.0;
        screamPending = false;
        houndCooldown = 0.0;
        watcherFarSeconds = 0.0;
        watcherRespawnTimer = 0.0;
        houndFarSeconds = 0.0;
        houndPrevState = Hound.S_DORMANT;
        watcherPrevState = Watcher.S_IDLE;
        snarlTimer = 0.0;
        strobeSent = false;
        batteryDead = false;
        lightPart = 0;
        wDist = 99.0;
        hDist = 99.0;
        placeX = 0.0;
        placeY = 0.0;
        pitPhase = PIT_SCAN_EVERY - 1;                  // the first unfrozen frame scans
    }

    // frozen = map open: clocks (tapeTime, battery) advance, entities and timers do not, presence is held.
    public function update(dt:Float, frozen:Bool, playerEvents:Int):Void {
        events = 0;
        var p = player;
        var px = p.x;
        var py = p.y;

        // ---- clocks: always ----
        tapeTime += dt;
        var here = Cells.type(world.cell(p.cellX(), p.cellY()));
        var inDark = here == Cells.DARK;
        darkOffset = inDark ? DARK_OFFSET : 0;
        hearingMul = inDark ? 1.5 : 1.0;
        fogCells = inDark ? 5 : 12;
        if (!batteryDead) {
            battery -= dt * BATTERY_DRAIN * (inDark ? DARK_DRAIN_MUL : 1.0);
            if (battery < 0.0) battery = 0.0;
        }
        var d = tape.dOffset + 0.5 * (tapeTime / 600.0) + 0.5 * (p.cellsWalked / 500.0);
        if (d > 1.0) d = 1.0;
        if (d > D) D = d;                               // monotone by construction; the guard also survives a rewound cellsWalked

        if (frozen) {
            // the paper is up: hold presence and the light state, deliver nothing
            lightOffset = clampOffset(lightPart + darkOffset);
            return;
        }
        events = queued;
        queued = 0;

        // ---- entity distances (computed here so the Director never depends on Entity.update having run) ----
        wDist = watcher.alive ? distTo(watcher.x, watcher.y) : 99.0;
        hDist = hound.alive ? distTo(hound.x, hound.y) : 99.0;

        // ---- flicker and blackout ----
        if (blackoutT > 0.0) {
            blackoutT -= dt;
            if (blackoutT <= 0.0) {
                blackoutT = 0.0;
                events |= EV_BLACKOUT_END;
                lightPart = 0;
            } else {
                lightPart = 15;
            }
        } else {
            if (D > 0.5) {
                blackoutTimer -= dt;
                if (blackoutTimer <= 1.0 && !blackoutWarned) {
                    // the telegraph: a stutter one second before the lights go
                    blackoutWarned = true;
                    startFlicker();
                }
                if (blackoutTimer <= 0.0) startBlackout();
            }
            if (blackoutT <= 0.0) {
                if (flickerFrames > 0) {
                    flickerFrames--;
                    lightPart = flickerFrames > 0 ? flickerDepth : 0;
                } else {
                    lightPart = 0;
                    flickerTimer -= dt;
                    if (flickerTimer <= 0.0) startFlicker();
                }
            }
        }

        // ---- Watcher lifecycle ----
        var w = watcher;
        if (!w.alive) {
            if (watcherRespawnTimer > 0.0) watcherRespawnTimer -= dt;
            if (tapeTime >= WATCHER_AT && watcherRespawnTimer <= 0.0) {
                var r = watcherRadius();
                if (findPost(r, 1.0)) {
                    w.spawnAt(placeX, placeY);
                    w.targetRadius = r;
                    w.relocateTimer = 4.0 + rng.nextFloat() * 5.0;
                    w.unseenSeconds = 0.0;
                    w.lookedAtSeconds = 0.0;
                    watcherFarSeconds = 0.0;
                    watcherPrevState = Watcher.S_IDLE;
                    wDist = distTo(w.x, w.y);
                    events |= EV_WATCHER_SPAWN;
                } else {
                    watcherRespawnTimer = 0.5;          // no post this time (hemmed in): retry twice a second, not every frame
                }
            }
        } else {
            if (wDist > WATCHER_FAR) {
                watcherFarSeconds += dt;
                if (watcherFarSeconds >= WATCHER_FAR_SECS) {
                    w.despawn();
                    watcherFarSeconds = 0.0;
                    watcherRespawnTimer = 15.0 + rng.nextFloat() * 20.0;
                    wDist = 99.0;
                    events |= EV_WATCHER_DESPAWN;
                }
            } else {
                watcherFarSeconds = 0.0;
            }
        }
        w.update(dt, this);
        if (w.alive) {
            wDist = distTo(w.x, w.y);
            if (w.relocated) events |= EV_WATCHER_RELOCATED;
            if (w.state == Watcher.S_APPROACH && watcherPrevState != Watcher.S_APPROACH) events |= EV_WATCHER_LUNGE;
            watcherPrevState = w.state;
        }

        // ---- Hound lifecycle ----
        var h = hound;
        if (houndCooldown > 0.0) houndCooldown -= dt;
        if (!h.alive) {
            var watcherNear = w.alive && wDist <= HOUND_NEAR_WATCHER;
            if (screamPending) {
                screamTimer -= dt;
                if (watcherNear) {
                    // the Watcher moved in during the lead: call it off, try again later
                    screamPending = false;
                    houndCooldown = 20.0 + rng.nextFloat() * 20.0;
                } else if (screamTimer <= 0.0) {
                    screamPending = false;
                    if (findPost(HOUND_SPAWN_MIN + 3.0, 3.0)) {
                        h.spawnAt(placeX, placeY);
                        h.state = Hound.S_DORMANT;
                        houndPrevState = Hound.S_DORMANT;
                        houndFarSeconds = 0.0;
                        hDist = distTo(h.x, h.y);
                        events |= EV_HOUND_SPAWN;
                    } else {
                        houndCooldown = 10.0;
                    }
                }
            } else if (D > HOUND_D && !watcherNear && houndCooldown <= 0.0) {
                screamPending = true;
                screamTimer = SCREAM_LEAD;
                events |= EV_SCREAM;
            }
        } else {
            // a dormant Hound left far behind drops off the tape so a fresh one can be placed nearer later
            if (h.state == Hound.S_DORMANT && hDist > 48.0) {
                houndFarSeconds += dt;
                if (houndFarSeconds >= 30.0) {
                    h.despawn();
                    hDist = 99.0;
                    houndFarSeconds = 0.0;
                    houndCooldown = 60.0;
                }
            } else {
                houndFarSeconds = 0.0;
            }
        }
        h.update(dt, this);
        if (h.alive) {
            hDist = distTo(h.x, h.y);
            var hs = h.state;
            if (hs != houndPrevState) {
                if (hs == Hound.S_HOWL) events |= EV_HOWL;
                if (hs == Hound.S_LOST) {
                    events |= EV_HOUND_LOST;
                    noRelocateUntil = tapeTime + RELIEF_SECS;
                    snarlTimer = 2.0 + rng.nextFloat() * 3.0;
                }
                houndPrevState = hs;
            }
            if (hs == Hound.S_LOST) {
                // the Hound snarls on its own clock while lost; this timer only fills a silence, never doubles one
                if ((events & EV_SNARL) != 0) {
                    snarlTimer = 3.0 + rng.nextFloat() * 4.0;
                } else {
                    snarlTimer -= dt;
                    if (snarlTimer <= 0.0) {
                        snarlTimer = 3.0 + rng.nextFloat() * 4.0;
                        events |= EV_SNARL;
                    }
                }
            }
            if (h.stepEvent) events |= EV_HOUND_STEP;

            // hearing: footsteps this frame
            if ((playerEvents & Player.PE_STEP_WET) != 0) {
                h.hear(p.cellX(), p.cellY(), Hound.HEAR_SPLASH);
            } else if ((playerEvents & Player.PE_STEP) != 0) {
                h.hear(p.cellX(), p.cellY(), p.running ? Hound.HEAR_RUN : Hound.HEAR_WALK);
            } else if ((playerEvents & Player.PE_RUN_START) != 0) {
                h.hear(p.cellX(), p.cellY(), Hound.HEAR_RUN);
            }
            // a hear() that started the howl has already raised EV_HOWL through this frame's events;
            // resync so the transition is not reported a second time next frame
            houndPrevState = h.state;
        }

        // ---- distant one-shots ----
        distantTimer -= dt;
        if (distantTimer <= 0.0) {
            distantTimer = 20.0 + rng.nextFloat() * 30.0;
            distantId = rng.range(0, 6);
            distantPan = rng.nextFloat() * 2.0 - 1.0;
            distantVol = 0.1 + rng.nextFloat() * 0.2;
            if (rng.chance(0.2)) distantId += 16;       // from directly behind
            events |= EV_DISTANT;
        }

        // ---- timestamp skips at D > 0.7 ----
        if (D > 0.7) {
            tsSkipTimer -= dt;
            if (tsSkipTimer <= 0.0) {
                tsSkipTimer = 30.0 + rng.nextFloat() * 60.0;
                tsSkipSeconds = rng.range(1, 8);
                events |= EV_TS_SKIP;
            }
        }

        // ---- hum detune ----
        var wantLow = (w.alive && wDist <= HOUND_NEAR_WATCHER) || D > 0.7;
        if (wantLow != humLow) {
            humLow = wantLow;
            events |= wantLow ? EV_HUM_LOW_ON : EV_HUM_LOW_OFF;
        }

        // ---- presence ----
        var wp = 0.0;
        if (w.alive) {
            wp = 1.0 - wDist / 10.0;
            if (wp < 0.0) wp = 0.0;
            wp *= wp;
        }
        var hp = 0.0;
        if (h.alive) {
            var hs = h.state;
            if (hs == Hound.S_HOWL || hs == Hound.S_CHASE) {
                hp = 1.0 - hDist / 14.0;
                if (hp < 0.0) hp = 0.0;
            } else if (hs == Hound.S_LOST) {
                hp = 0.3;
            }
        }
        presence = wp > hp ? wp : hp;
        if (presence > 1.0) presence = 1.0;

        // ---- light: the one summed value the renderer sees ----
        lightOffset = clampOffset(lightPart + darkOffset);

        // ---- pits: the drip telegraph, and the fall ----
        // the scan is the class's dominant per-frame cost (a 13x13 window of World.cell), so it runs every
        // PIT_SCAN_EVERY frames and pitDist/pitPan are held between scans (the fall itself never waits on it)
        pitPhase++;
        if (pitPhase >= PIT_SCAN_EVERY) {
            pitPhase = 0;
            scanPits(px, py, p.ang);
        }
        if ((playerEvents & Player.PE_ENTERED_PIT) != 0) {
            if (lightOffset >= 8) events |= EV_PIT_STUMBLE;
            else requestKill(K_PIT);
        }

        // ---- battery ----
        if (battery < 0.10 && !strobeSent) {
            strobeSent = true;
            events |= EV_STROBE_ON;
        }
        if (battery <= 0.0 && !batteryDead) {
            batteryDead = true;
            events |= EV_BATTERY_DEAD;
            requestKill(K_BATTERY);
        }
    }

    // sets EV_KILL + killer once (first wins). The fairness law lives in the entities (Entity.canKill gates their
    // contact calls); this takes any kind so Main's scripted deaths (?die=watcher) and the hazards go through unchanged.
    public function requestKill(kind:Int):Void {
        if ((events & EV_KILL) != 0) return;
        events |= EV_KILL;
        killer = kind;
    }

    // |bearing| <= tape.fov / 2 + 5 deg (in radians; 35 deg at FOV 60 is the documented minimum, 41 deg at 72) AND lineOfSight — wider than the screen, so a relocated Watcher never pops in at the edge
    public function inViewCone(x:Float, y:Float):Bool {
        var b = bearingTo(x, y);
        if (b < 0.0) b = -b;
        if (b > tape.fov * 0.5 + 0.0872664626) return false;   // 5 degrees
        return lineOfSight(player.x, player.y, x, y);
    }

    // DDA over World.solid, max 24 cells: true when no solid cell lies strictly between the two points
    public function lineOfSight(x0:Float, y0:Float, x1:Float, y1:Float):Bool {
        var dx = x1 - x0;
        var dy = y1 - y0;
        var len = Math.sqrt(dx * dx + dy * dy);
        if (len > LOS_MAX) return false;
        var cx = Math.floor(x0);
        var cy = Math.floor(y0);
        var tx = Math.floor(x1);
        var ty = Math.floor(y1);
        if (cx == tx && cy == ty) return true;
        var stepX = dx > 0.0 ? 1 : (dx < 0.0 ? -1 : 0);
        var stepY = dy > 0.0 ? 1 : (dy < 0.0 ? -1 : 0);
        // parametric distance (0..1 along the segment) to the next x and y cell boundaries
        var tMaxX = 1e30;
        var tDeltaX = 1e30;
        if (stepX != 0) {
            var nextX = stepX > 0 ? cx + 1.0 : cx;
            tMaxX = (nextX - x0) / dx;
            tDeltaX = stepX / dx;
        }
        var tMaxY = 1e30;
        var tDeltaY = 1e30;
        if (stepY != 0) {
            var nextY = stepY > 0 ? cy + 1.0 : cy;
            tMaxY = (nextY - y0) / dy;
            tDeltaY = stepY / dy;
        }
        var w = world;
        var guard = 0;
        while (guard < 64) {
            guard++;
            if (tMaxX < tMaxY) {
                cx += stepX;
                tMaxX += tDeltaX;
            } else {
                cy += stepY;
                tMaxY += tDeltaY;
            }
            if (cx == tx && cy == ty) return true;
            if (Cells.solid(w.cell(cx, cy))) return false;
            if (tMaxX > 1.0 && tMaxY > 1.0) return true;   // passed the end point (rounding)
        }
        return false;
    }

    public function bearingTo(x:Float, y:Float):Float {
        var b = Math.atan2(y - player.y, x - player.x) - player.ang;
        while (b > Math.PI) b -= Math.PI * 2.0;
        while (b <= -Math.PI) b += Math.PI * 2.0;
        return b;
    }

    // walkable with exactly one walkable 4-neighbour
    public function isDeadEnd(cx:Int, cy:Int):Bool {
        var w = world;
        if (!Cells.walkable(w.cell(cx, cy))) return false;
        var n = 0;
        if (Cells.walkable(w.cell(cx + 1, cy))) n++;
        if (Cells.walkable(w.cell(cx - 1, cy))) n++;
        if (Cells.walkable(w.cell(cx, cy + 1))) n++;
        if (Cells.walkable(w.cell(cx, cy - 1))) n++;
        return n == 1;
    }

    // test/rc
    // Called between frames (rc, tests): the bits it raises are also queued so the next update delivers them,
    // and only the bits this call produced are queued (the stale frame's events are not replayed).
    public function forceBlackout():Void {
        if (blackoutT > 0.0) return;
        var before = events;
        startBlackout();
        queued |= events & ~before & (EV_BLACKOUT_START | EV_WATCHER_RELOCATED);
    }

    // test/rc: spawns at 22 cells out of view and immediately hears
    public function forceSpawnHound():Void {
        var h = hound;
        if (!findPost(HOUND_SPAWN_DIST, 1.0)) {
            // no walkable candidate (test grids, unloaded world): put it directly behind the player
            placeX = player.x - Math.cos(player.ang) * HOUND_SPAWN_DIST;
            placeY = player.y - Math.sin(player.ang) * HOUND_SPAWN_DIST;
        }
        h.spawnAt(placeX, placeY);
        h.state = Hound.S_DORMANT;
        screamPending = false;
        houndFarSeconds = 0.0;
        hDist = distTo(h.x, h.y);
        h.hear(player.cellX(), player.cellY(), 99.0);
        var raised = EV_HOUND_SPAWN;
        if (h.state == Hound.S_HOWL) raised |= EV_HOWL;   // the Hound flags it only once it has seen a Director
        houndPrevState = h.state;
        events |= raised;
        queued |= raised;
    }

    public function forceRelocate():Void {
        if (!watcher.alive) return;
        if (watcher.relocate(this, false)) {
            wDist = distTo(watcher.x, watcher.y);
            events |= EV_WATCHER_RELOCATED;
            queued |= EV_WATCHER_RELOCATED;
        }
    }

    // ---- private ----

    // R = lerp(14, 4, D), floor 3 at D > 0.9 (the unseen shrink is the Watcher's own)
    function watcherRadius():Float {
        var r = 14.0 - 10.0 * D;
        var floor = D > 0.9 ? 3.0 : 4.0;
        return r < floor ? floor : r;
    }

    function startFlicker():Void {
        flickerFrames = rng.range(1, 4);
        var depth = 2 + rng.range(0, 2);                // 2..3
        if (watcher.alive && wDist < 10.0) depth += rng.range(1, 3);   // 3..5 near the Watcher
        if (depth > 5) depth = 5;
        flickerDepth = depth;
        lightPart = depth;
        flickerTimer = 4.0 + rng.nextFloat() * 5.0;
        events |= EV_FLICKER;
    }

    function startBlackout():Void {
        blackoutT = 2.0 + rng.nextFloat() * 2.0;
        blackoutTimer = 60.0 + rng.nextFloat() * 60.0;
        blackoutWarned = false;
        flickerFrames = 0;
        lightPart = 15;
        events |= EV_BLACKOUT_START;
        if (hound.alive) hound.hear(player.cellX(), player.cellY(), Hound.HEAR_BLACKOUT);
        if (watcher.alive && tapeTime >= noRelocateUntil) {
            if (watcher.relocate(this, true)) {
                wDist = distTo(watcher.x, watcher.y);
                events |= EV_WATCHER_RELOCATED;
            }
        }
    }

    inline function distTo(x:Float, y:Float):Float {
        var dx = x - player.x;
        var dy = y - player.y;
        return Math.sqrt(dx * dx + dy * dy);
    }

    static inline function clampOffset(v:Int):Int {
        return v < 0 ? 0 : (v > 15 ? 15 : v);
    }

    // Sample up to POST_SAMPLES walkable cells whose CENTRE lies at distance radius +/- spread from the player
    // (the polar sample is floored to a cell, so the centre is checked, not the sample) and that are outside the
    // view cone. Dead ends win immediately; otherwise the first valid candidate is kept. Result in placeX/placeY
    // (cell centre). No allocation.
    function findPost(radius:Float, spread:Float):Bool {
        var px = player.x;
        var py = player.y;
        var w = world;
        var found = false;
        var i = 0;
        while (i < POST_SAMPLES) {
            i++;
            var a = rng.nextFloat() * Math.PI * 2.0;
            var r = radius + (rng.nextFloat() * 2.0 - 1.0) * spread;
            if (r < 1.0) r = 1.0;
            var cx = Math.floor(px + Math.cos(a) * r);
            var cy = Math.floor(py + Math.sin(a) * r);
            var c = w.cell(cx, cy);
            if (!Cells.walkable(c) || Cells.type(c) == Cells.PIT) continue;
            var fx = cx + 0.5;
            var fy = cy + 0.5;
            var ddx = fx - px;
            var ddy = fy - py;
            var dd = Math.sqrt(ddx * ddx + ddy * ddy);
            if (dd < radius - spread || dd > radius + spread) continue;
            if (inViewCone(fx, fy)) continue;
            if (!found) {
                placeX = fx;
                placeY = fy;
                found = true;
            }
            if (isDeadEnd(cx, cy)) {
                placeX = fx;
                placeY = fy;
                return true;
            }
        }
        return found;
    }

    // nearest PIT cell within PIT_RANGE of the player: pitDist and a pan from its bearing; 99 / 0 when none
    function scanPits(px:Float, py:Float, ang:Float):Void {
        var w = world;
        var cx0 = Math.floor(px);
        var cy0 = Math.floor(py);
        var best = 99.0;
        var bx = 0.0;
        var by = 0.0;
        var r = Math.ceil(PIT_RANGE);
        var yy = cy0 - r;
        while (yy <= cy0 + r) {
            var ky = yy - cy0;
            if (ky < 0) ky = -ky;
            var ey = 2 * ky - 1;                        // 2 x (|ky| - 0.5): the least |centre offset| for |ky| >= 1
            var xx = cx0 - r;
            while (xx <= cx0 + r) {
                var kx = xx - cx0;
                if (kx < 0) kx = -kx;
                var ex = 2 * kx - 1;
                // a cell centre sits at least (|k| - 0.5) away on each axis, so cells whose nearest possible
                // centre is beyond PIT_RANGE are skipped before the World.cell call (the window's corners, 32 of 169);
                // a zero offset uses 1 instead of 0, which can only skip cells outside the window anyway
                if (ex * ex + ey * ey > 144) { xx++; continue; }   // (2 x 6)^2
                if (Cells.type(w.cell(xx, yy)) == Cells.PIT) {
                    var dx = xx + 0.5 - px;
                    var dy = yy + 0.5 - py;
                    var dd = Math.sqrt(dx * dx + dy * dy);
                    if (dd < best) {
                        best = dd;
                        bx = dx;
                        by = dy;
                    }
                }
                xx++;
            }
            yy++;
        }
        if (best <= PIT_RANGE) {
            pitDist = best;
            var b = Math.atan2(by, bx) - ang;
            pitPan = Math.sin(b);
        } else {
            pitDist = 99.0;
            pitPan = 0.0;
        }
    }
}
