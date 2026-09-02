// All audio routing (CONTRACT §2, DESIGN §6). fp class.
//
// Owns the seven LoopPlayers (ids 0..6) and a pool of MAX_ONESHOTS one-shot slots, each
// with its own SoundTransform made once in the constructor. Nothing is allocated after
// that: every per-frame change is a field write and a SoundTransform reassignment; the
// only runtime object creation is the SoundChannel that Sound.play() hands back.
//
// Mixing (all SoundTransform.volume, every level multiplied by master, 0 while muted or paused):
//   bed:      HUM / HUM_LOW / HUM_DARK share one 0.35 bed. humLevel (the light level of the
//             player's cell, setHumLight) scales the lit hums; lowMix (setHumLow) crossfades
//             HUM <-> HUM_LOW and darkMix (setDark) crossfades the lit pair <-> HUM_DARK, both
//             equal-power over 1 s. HUM_DARK is NOT scaled by the light level: in a DARK cell
//             the light level is near zero and the dark bed is the sound of that darkness.
//             DRONE is a constant 0.25.
//   presence: PRESENCE_LO = P^2, PRESENCE_HI = max(0, P - 0.5) * 1.2 (clamped to 1).
//   drip:     the pit telegraph, falloff(dist) with a one-cell taper to 0 at DRIP_RANGE, panned.
//   one-shots: footsteps 0.5 (wet 0.8) alternating samples; everything else through oneShot().
// Channel count: 7 loops x <= 2 + MAX_ONESHOTS one-shots = 20 at most (Flash caps at 32).
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
    static inline var STEPS = 4;                 // STEP1..4
    static inline var SPLASHES = 2;              // SPLASH1..2
    static inline var BED_HUM = 0.35;
    static inline var BED_DRONE = 0.25;
    static inline var STEP_VOL = 0.5;
    static inline var SPLASH_VOL = 0.8;
    static inline var STEP_PAN = 0.08;           // left / right alternation of the player's own steps
    static inline var DRIP_GAIN = 0.8;
    static inline var DRIP_RANGE = 6.0;          // cells; dist >= DRIP_RANGE => silent
    static inline var HOUND_STEP_GAIN = 0.9;
    static inline var RAMP_PER_S = 1.0;          // the 1 s bed crossfades
    static inline var HALF_PI = 1.5707963267948966;
    static inline var SLOT_SLACK_S = 0.05;       // extra time a one-shot slot stays busy past its sound's length
    public var master:Float;
    public var muted:Bool;

    var sounds:Array<Sound>;                            // Sfx.all()
    var loops:flash.Vector<LoopPlayer>;                 // LOOPS entries
    var oneShotSt:flash.Vector<SoundTransform>;         // MAX_ONESHOTS entries
    var oneShotCh:flash.Vector<SoundChannel>;           // MAX_ONESHOTS slots
    var oneShotLeft:flash.Vector<Float>;                // seconds until the slot frees itself (dt countdown; no getTimer here, rule 10)
    var oneShotLen:flash.Vector<Float>;                 // ms length of the sound in the slot (position >= len frees it early)
    var oneShotVol:flash.Vector<Float>;                 // requested volume, before master (restored on resume / master change)
    var oneShotPan:flash.Vector<Float>;

    // mix state
    var paused:Bool;
    var bedOn:Bool;
    var humLevel:Float;                                 // 0..1 light level of the player's cell
    var lowMix:Float;                                   // 0 = HUM, 1 = HUM_LOW
    var lowTarget:Float;
    var darkMix:Float;                                  // 0 = lit hums, 1 = HUM_DARK
    var darkTarget:Float;
    var presLo:Float;
    var presHi:Float;
    var dripVol:Float;
    var dripPan:Float;
    var appliedEff:Float;                               // master * (muted || paused ? 0 : 1) last pushed to the one-shot slots
    var stepIdx:Int;
    var splashIdx:Int;
    var stepSide:Int;                                   // +1 / -1

    // creates LoopPlayers for ids 0..6, SoundTransforms for one-shots
    public function new():Void {
        master = 1.0;
        muted = false;
        sounds = Sfx.all();
        loops = new flash.Vector<LoopPlayer>(LOOPS, true);
        for (i in 0...LOOPS) loops[i] = new LoopPlayer(sounds[i]);
        oneShotSt = new flash.Vector<SoundTransform>(MAX_ONESHOTS, true);
        oneShotCh = new flash.Vector<SoundChannel>(MAX_ONESHOTS, true);
        oneShotLeft = new flash.Vector<Float>(MAX_ONESHOTS, true);
        oneShotLen = new flash.Vector<Float>(MAX_ONESHOTS, true);
        oneShotVol = new flash.Vector<Float>(MAX_ONESHOTS, true);
        oneShotPan = new flash.Vector<Float>(MAX_ONESHOTS, true);
        for (i in 0...MAX_ONESHOTS) {
            oneShotSt[i] = new SoundTransform(0, 0);
            oneShotCh[i] = null;
            oneShotLeft[i] = 0.0;
            oneShotLen[i] = 0.0;
            oneShotVol[i] = 0.0;
            oneShotPan[i] = 0.0;
        }
        paused = false;
        bedOn = false;
        humLevel = 1.0;
        lowMix = 0.0;
        lowTarget = 0.0;
        darkMix = 0.0;
        darkTarget = 0.0;
        presLo = 0.0;
        presHi = 0.0;
        dripVol = 0.0;
        dripPan = 0.0;
        appliedEff = 1.0;
        stepIdx = 0;
        splashIdx = 0;
        stepSide = 1;
        computeLoops();
    }

    // hum 0.35, drone 0.25, others at 0
    public function startBed():Void {
        humLevel = 1.0;
        lowMix = 0.0; lowTarget = 0.0;
        darkMix = 0.0; darkTarget = 0.0;
        presLo = 0.0; presHi = 0.0;
        dripVol = 0.0; dripPan = 0.0;
        computeLoops();                                 // volumes must be in place before start() reads them
        for (i in 0...LOOPS) loops[i].start();          // every loop runs (at 0 where silent) so a later rise is instantaneous
        bedOn = true;
    }

    public function stopAll():Void {
        for (i in 0...LOOPS) loops[i].stop();
        for (i in 0...MAX_ONESHOTS) {
            var ch = oneShotCh[i];
            if (ch != null) { ch.stop(); oneShotCh[i] = null; }
            oneShotLeft[i] = 0.0;
        }
        bedOn = false;
    }

    // lo = p*p, hi = max(0, p - 0.5) * 1.2
    public function setPresence(p:Float):Void {
        if (!(p > 0.0)) p = 0.0;                        // also catches NaN
        if (p > 1.0) p = 1.0;
        presLo = p * p;
        var h = (p - 0.5) * 1.2;
        presHi = h < 0.0 ? 0.0 : (h > 1.0 ? 1.0 : h);
    }

    // hum volume = 0.35 * level
    public function setHumLight(level:Float):Void {
        if (!(level > 0.0)) level = 0.0;
        if (level > 1.0) level = 1.0;
        humLevel = level;
    }

    // crossfades HUM <-> HUM_LOW over 1 s
    public function setHumLow(on:Bool):Void {
        lowTarget = on ? 1.0 : 0.0;
    }

    // crossfades HUM(_LOW) <-> HUM_DARK over 1 s
    public function setDark(on:Bool):Void {
        darkTarget = on ? 1.0 : 0.0;
    }

    // falloff; dist >= 6 => 0
    public function setDrip(dist:Float, pan:Float):Void {
        if (!(dist < DRIP_RANGE)) {                     // also catches NaN
            dripVol = 0.0;
        } else {
            if (dist < 0.0) dist = 0.0;
            var v = falloff(dist) * DRIP_GAIN;
            var edge = DRIP_RANGE - dist;               // one-cell taper so the cut at DRIP_RANGE is not a step
            if (edge < 1.0) v *= edge;
            dripVol = v;
        }
        dripPan = clampPan(pan);
    }

    // alternates STEP1..4 / SPLASH1..2 at 0.5 / 0.8
    public function footstep(wet:Bool):Void {
        var id:Int;
        var vol:Float;
        if (wet) {
            id = SPLASH1 + splashIdx;
            splashIdx = (splashIdx + 1) % SPLASHES;
            vol = SPLASH_VOL;
        } else {
            id = STEP1 + stepIdx;
            stepIdx = (stepIdx + 1) % STEPS;
            vol = STEP_VOL;
        }
        stepSide = -stepSide;
        oneShot(id, vol, STEP_PAN * stepSide);
    }

    // dropped silently if MAX_ONESHOTS active
    public function oneShot(id:Int, vol:Float, pan:Float):Void {
        if (id < LOOPS || id >= sounds.length) return;  // loops are not one-shots; unknown ids are ignored
        var slot = -1;
        for (i in 0...MAX_ONESHOTS) {
            if (oneShotCh[i] == null) { slot = i; break; }
        }
        if (slot < 0) return;                           // pool full: dropped silently
        var snd = sounds[id];
        var v = clampVol(vol);
        var p = clampPan(pan);
        var st = oneShotSt[slot];
        st.volume = v * effective();
        st.pan = p;
        var ch = snd.play(0, 0, st);
        if (ch == null) return;                         // the player refused (channel cap / no device)
        oneShotCh[slot] = ch;
        var len = snd.length;
        if (!(len > 0)) len = 0;
        oneShotLen[slot] = len;
        oneShotLeft[slot] = len / 1000.0 + SLOT_SLACK_S;
        oneShotVol[slot] = v;
        oneShotPan[slot] = p;
    }

    public function houndStep(dist:Float, pan:Float):Void {
        if (dist < 0.0) dist = 0.0;
        oneShot(HOUND_STEP, falloff(dist) * HOUND_STEP_GAIN, pan);
    }

    // every volume to 0, loops keep running
    public function pause():Void {
        paused = true;
        computeLoops();
        pushLoops();
        refreshOneShots();
    }

    public function resume():Void {
        paused = false;
        computeLoops();
        pushLoops();
        refreshOneShots();
    }

    // LoopPlayer updates + crossfade ramps
    public function update(dt:Float):Void {
        if (!(dt > 0.0)) dt = 0.0;
        var step = dt * RAMP_PER_S;
        // bed crossfade ramps (1 s each way)
        if (lowMix < lowTarget) { lowMix += step; if (lowMix > lowTarget) lowMix = lowTarget; }
        else if (lowMix > lowTarget) { lowMix -= step; if (lowMix < lowTarget) lowMix = lowTarget; }
        if (darkMix < darkTarget) { darkMix += step; if (darkMix > darkTarget) darkMix = darkTarget; }
        else if (darkMix > darkTarget) { darkMix -= step; if (darkMix < darkTarget) darkMix = darkTarget; }

        computeLoops();
        var loops = this.loops;
        for (i in 0...LOOPS) loops[i].update(dt);

        // one-shot slots: free when the sound has run its length (position) or the countdown expires
        var chs = oneShotCh;
        var left = oneShotLeft;
        var lens = oneShotLen;
        for (i in 0...MAX_ONESHOTS) {
            var ch = chs[i];
            if (ch == null) continue;
            var t = left[i] - dt;
            var len = lens[i];
            if (t <= 0.0 || (len > 0 && ch.position >= len)) {
                ch.stop();
                chs[i] = null;
                left[i] = 0.0;
            } else {
                left[i] = t;
            }
        }

        // master / mute changes reach the one-shots already playing
        if (effective() != appliedEff) refreshOneShots();
    }

    // active SoundChannels (telemetry)
    public function channels():Int {
        var n = 0;
        for (i in 0...LOOPS) n += loops[i].channels();
        for (i in 0...MAX_ONESHOTS) if (oneShotCh[i] != null) n++;
        return n;
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

    // ---- private ---------------------------------------------------------------------------

    // the multiplier every level goes through
    inline function effective():Float {
        return (muted || paused) ? 0.0 : clampVol(master);
    }

    // writes the seven loop targets from the mix state (LoopPlayer.update pushes them to the channels)
    function computeLoops():Void {
        var eff = effective();
        var loops = this.loops;
        var bed = BED_HUM * humLevel;
        var aLow = lowMix * HALF_PI;
        var aDark = darkMix * HALF_PI;
        var sLow = Math.sin(aLow), cLow = Math.cos(aLow);
        var sDark = Math.sin(aDark), cDark = Math.cos(aDark);
        var lit = bed * cDark;
        loops[HUM].volume = lit * cLow * eff;
        loops[HUM_LOW].volume = lit * sLow * eff;
        loops[HUM_DARK].volume = BED_HUM * sDark * eff;
        loops[DRONE].volume = BED_DRONE * eff;
        loops[PRESENCE_LO].volume = presLo * eff;
        loops[PRESENCE_HI].volume = presHi * eff;
        var drip = loops[DRIP];
        drip.volume = dripVol * eff;
        drip.pan = dripPan;
    }

    // apply the loop targets now (outside the frame loop: pause / resume)
    function pushLoops():Void {
        for (i in 0...LOOPS) loops[i].update(0.0);
    }

    // re-apply master / mute / pause to every live one-shot
    function refreshOneShots():Void {
        var eff = effective();
        appliedEff = eff;
        for (i in 0...MAX_ONESHOTS) {
            var ch = oneShotCh[i];
            if (ch == null) continue;
            var st = oneShotSt[i];
            st.volume = oneShotVol[i] * eff;
            st.pan = oneShotPan[i];
            ch.soundTransform = st;
        }
    }

    static inline function clampVol(v:Float):Float {
        return !(v > 0.0) ? 0.0 : (v > 1.0 ? 1.0 : v);
    }

    static inline function clampPan(p:Float):Float {
        return !(p > -1.0) ? -1.0 : (p > 1.0 ? 1.0 : p);
    }
}
