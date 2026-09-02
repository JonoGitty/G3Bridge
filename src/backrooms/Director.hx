// Escalation, entities, blackouts, battery (CONTRACT §1, DESIGN §5). Core class: no flash.* imports.
// SKELETON: signatures exact; constructor creates rng/watcher/hound; update() only clears events.
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
    public var lightOffset:Int;                         // 0..15 added to every shade band
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
    }

    // frozen = map open: clocks (tapeTime, battery) advance, entities and timers do not, presence is held.
    public function update(dt:Float, frozen:Bool, playerEvents:Int):Void {
        events = 0; // SKELETON
    }

    // sets EV_KILL + killer once (first wins)
    public function requestKill(kind:Int):Void {
        if ((events & EV_KILL) != 0) return;
        events |= EV_KILL;
        killer = kind;
    }

    // |bearing| <= 35 deg AND lineOfSight
    public function inViewCone(x:Float, y:Float):Bool {
        return false; // SKELETON
    }

    // DDA over World.solid, max 24 cells
    public function lineOfSight(x0:Float, y0:Float, x1:Float, y1:Float):Bool {
        return false; // SKELETON
    }

    public function bearingTo(x:Float, y:Float):Float {
        return 0.0; // SKELETON
    }

    // walkable with exactly one walkable 4-neighbour
    public function isDeadEnd(cx:Int, cy:Int):Bool {
        return false; // SKELETON
    }

    // test/rc
    public function forceBlackout():Void {
        // SKELETON
    }

    // test/rc: spawns at 22 cells out of view and immediately hears
    public function forceSpawnHound():Void {
        // SKELETON
    }

    public function forceRelocate():Void {
        // SKELETON
    }
}
