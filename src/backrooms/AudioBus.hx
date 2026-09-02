// All audio routing (CONTRACT §2, DESIGN §6). fp class.
// SKELETON: constructor loads Sfx.all(), creates the 7 LoopPlayers and the one-shot transforms; falloff/panOf are complete.
import flash.media.Sound;
import flash.media.SoundChannel;
import flash.media.SoundTransform;

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
    static inline var LOOPS = 7;                 // ids 0..6 are loops
    public var master:Float;
    public var muted:Bool;

    var sounds:Array<Sound>;                            // Sfx.all()
    var loops:flash.Vector<LoopPlayer>;                 // LOOPS entries
    var oneShotSt:flash.Vector<SoundTransform>;         // MAX_ONESHOTS entries
    var oneShotCh:flash.Vector<SoundChannel>;           // MAX_ONESHOTS slots

    // creates LoopPlayers for ids 0..6, SoundTransforms for one-shots
    public function new():Void {
        master = 1.0;
        muted = false;
        sounds = Sfx.all();
        loops = new flash.Vector<LoopPlayer>(LOOPS, true);
        for (i in 0...LOOPS) loops[i] = new LoopPlayer(sounds[i]);
        oneShotSt = new flash.Vector<SoundTransform>(MAX_ONESHOTS, true);
        oneShotCh = new flash.Vector<SoundChannel>(MAX_ONESHOTS, true);
        for (i in 0...MAX_ONESHOTS) { oneShotSt[i] = new SoundTransform(0, 0); oneShotCh[i] = null; }
    }

    // hum 0.35, drone 0.25, others at 0
    public function startBed():Void {
        // SKELETON
    }

    public function stopAll():Void {
        // SKELETON
    }

    // lo = p*p, hi = max(0, p - 0.5) * 1.2
    public function setPresence(p:Float):Void {
        // SKELETON
    }

    // hum volume = 0.35 * level
    public function setHumLight(level:Float):Void {
        // SKELETON
    }

    // crossfades HUM <-> HUM_LOW over 1 s
    public function setHumLow(on:Bool):Void {
        // SKELETON
    }

    // crossfades HUM(_LOW) <-> HUM_DARK over 1 s
    public function setDark(on:Bool):Void {
        // SKELETON
    }

    // falloff; dist >= 6 => 0
    public function setDrip(dist:Float, pan:Float):Void {
        // SKELETON
    }

    // alternates STEP1..4 / SPLASH1..2 at 0.5 / 0.8
    public function footstep(wet:Bool):Void {
        // SKELETON
    }

    // dropped silently if MAX_ONESHOTS active
    public function oneShot(id:Int, vol:Float, pan:Float):Void {
        // SKELETON
    }

    public function houndStep(dist:Float, pan:Float):Void {
        // SKELETON
    }

    // every volume to 0, loops keep running
    public function pause():Void {
        // SKELETON
    }

    public function resume():Void {
        // SKELETON
    }

    // LoopPlayer updates + crossfade ramps
    public function update(dt:Float):Void {
        // SKELETON
    }

    // active SoundChannels (telemetry)
    public function channels():Int {
        return 0; // SKELETON
    }

    // clamp(1 / (1 + d/3)^2, 0, 1)
    public static function falloff(d:Float):Float {
        var k = 1.0 + d / 3.0;
        var f = 1.0 / (k * k);
        return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
    }

    // 0.7 * sin(bearing)
    public static function panOf(bearing:Float):Float {
        return 0.7 * Math.sin(bearing);
    }
}
