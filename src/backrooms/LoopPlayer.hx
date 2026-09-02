// Gapless loop via two alternating channels (CONTRACT §2, DESIGN §6). fp class.
//
// MP3 encoder padding makes play(0, int max) click at every loop point, so one Sound is
// run on two SoundChannels: the primary plays, and crossMs before its scheduled end
// (by getTimer) the secondary is started on the same Sound; the two are equal-power
// crossfaded over crossMs, the old channel is stopped, and the roles swap. Nothing is
// allocated after the constructor: two SoundTransforms are reused for the life of the
// player, and play() is the only runtime object creation (a SoundChannel the Flash
// player itself hands back; unavoidable and bounded at two per loop).
//
// Timing model (L = MP3 play() start latency, the same for both channels of one Sound):
//   primary play() at tP; its audio runs from tP + L to tP + L + lengthMs.
//   secondary play() at tS = tP + lengthMs - crossMs; its audio starts at tS + L.
//   the fade runs over crossMs from the moment the secondary's audio is observed to be
//   running (position > 0; fallback: tS + crossMs), ending at tS + L + crossMs, which is
//   exactly where the primary's audio ends. L cancels out of the schedule, so crossMs
//   only needs to be long enough that the two are both audible during the fade, hence
//   crossMs = max(CROSS_MIN_MS, 2 * latencyMs).
//
// The first start() of the run measures L once (static): getTimer at play(), then at
// the first update() that sees a non-zero position, latency = elapsed - position.
// It is pinged once as bk=audiolat&ms= so the listening test has a number to check.
import flash.media.Sound;
import flash.media.SoundChannel;
import flash.media.SoundTransform;

class LoopPlayer {
    public static inline var CROSS_MIN_MS = 120;        // floor for the lead / crossfade
    public static var latencyMs:Int = 0;                // measured once per run: getTimer at play() -> first non-zero SoundChannel.position; 0 until measured; pinged once as bk=audiolat&ms=
    public static var crossMs:Int = CROSS_MIN_MS;       // runtime lead = max(CROSS_MIN_MS, 2 * latencyMs); MP3 play() latency in the browser plugin on this machine is typically 100-250 ms, so a fixed 120 ms could gap or overlap every loop point
    public var volume:Float;                            // 0..1 target, applied each update
    public var pan:Float;
    public var playing:Bool;

    static inline var HALF_PI = 1.5707963267948966;
    static inline var MAX_LATENCY_MS = 2000;            // a measurement above this is a stall, not a latency: clamp it

    // the one instance that is measuring the start latency (null = none / done)
    static var measuring:LoopPlayer = null;
    static var measureT0:Int = 0;

    var snd:Sound;
    var lengthMs:Float;
    var lengthInt:Int;                                  // lengthMs rounded down, for the getTimer arithmetic
    var stP:SoundTransform;                             // transform of the primary channel
    var stS:SoundTransform;                             // transform of the secondary channel
    var chP:SoundChannel;                               // primary: the channel that is (or will be) the one left after a fade
    var chS:SoundChannel;                               // secondary: the incoming channel during a fade, else null
    var tP:Int;                                         // getTimer at the primary's play()
    var tS:Int;                                         // getTimer at the secondary's play()
    var fading:Bool;                                    // a secondary is running
    var fadeStart:Int;                                  // getTimer when the fade began (-1 = secondary started, audio not yet observed)
    var gainP:Float;                                    // crossfade gain applied to the primary (1 when not fading)
    var gainS:Float;                                    // crossfade gain applied to the secondary
    var appliedVolP:Float;                              // last values written to stP / stS (skip the setter when unchanged)
    var appliedPanP:Float;
    var appliedVolS:Float;
    var appliedPanS:Float;

    // reads snd.length; allocates two SoundTransforms
    public function new(snd:Sound):Void {
        this.snd = snd;
        lengthMs = snd.length;
        if (!(lengthMs > 0)) lengthMs = 0;              // also catches NaN
        lengthInt = Std.int(lengthMs);
        stP = new SoundTransform(0, 0);
        stS = new SoundTransform(0, 0);
        chP = null;
        chS = null;
        tP = 0;
        tS = 0;
        fading = false;
        fadeStart = -1;
        gainP = 1.0;
        gainS = 0.0;
        appliedVolP = -1.0;
        appliedPanP = -2.0;
        appliedVolS = -1.0;
        appliedPanS = -2.0;
        volume = 0.0;
        pan = 0.0;
        playing = false;
    }

    // the first start() of the run records getTimer at play(); update() completes the measurement at the first non-zero position and sets crossMs
    public function start():Void {
        if (playing) return;
        if (lengthInt <= 0) return;                      // nothing to loop (a broken embed); stay silent rather than spin
        playing = true;
        var now = flash.Lib.getTimer();
        var ch = restartPrimary(now);
        if (latencyMs == 0 && measuring == null && ch != null) {
            measuring = this;
            measureT0 = now;
        }
    }

    public function stop():Void {
        if (chP != null) { chP.stop(); chP = null; }
        if (chS != null) { chS.stop(); chS = null; }
        if (measuring == this) measuring = null;         // the measurement re-arms on the next start() of any loop
        playing = false;
        fading = false;
        fadeStart = -1;
        gainP = 1.0;
        gainS = 0.0;
    }

    // starts the second channel crossMs before the first ends (by getTimer), equal-power crossfade over crossMs, alternates; applies volume/pan
    public function update(dt:Float):Void {
        if (!playing) return;
        var now = flash.Lib.getTimer();
        var chP = this.chP;

        // (a) the run's one-time latency measurement
        if (measuring == this) {
            if (chP == null) {
                measuring = null;
            } else {
                var pos = chP.position;
                if (pos > 0) {
                    var lat = (now - measureT0) - Std.int(pos);
                    if (lat < 1) lat = 1;
                    if (lat > MAX_LATENCY_MS) lat = MAX_LATENCY_MS;
                    latencyMs = lat;
                    var c = 2 * lat;
                    crossMs = c > CROSS_MIN_MS ? c : CROSS_MIN_MS;
                    measuring = null;
                    Telemetry.ping("bk=audiolat&ms=" + lat + "&cross=" + crossMs);
                }
            }
        }

        var cross = crossMs;
        var len = lengthInt;

        // (b) the primary vanished (play() refused, or the player dropped it): recover
        if (chP == null) {
            if (chS != null) {
                // the incoming channel becomes the primary outright
                promoteSecondary();
                chP = this.chP;
            } else {
                chP = restartPrimary(now);
                if (chP == null) return;                 // still refused: try again next frame
            }
        }

        if (!fading) {
            if (len <= 2 * cross) {
                // degenerate loop (shorter than two crossfades): plain restart at its end, no overlap
                if (now - tP >= len) {
                    chP.stop();
                    chP = restartPrimary(now);
                    if (chP == null) return;
                }
            } else if (now - tP >= len) {
                // too late for a crossfade (a stall or a pause longer than the lead): the primary has
                // ended on its own, so restart it cleanly rather than fading from silence
                chP.stop();
                chP = restartPrimary(now);
                if (chP == null) return;
            } else if (now - tP >= len - cross) {
                // lead point: start the incoming channel on the same sound at gain 0
                stS.volume = 0.0;
                stS.pan = clampPan(pan);
                appliedVolS = 0.0;
                appliedPanS = stS.pan;
                var ch = snd.play(0, 0, stS);
                if (ch != null) {
                    chS = ch;
                    tS = now;
                    fading = true;
                    fadeStart = -1;
                    gainS = 0.0;
                    gainP = 1.0;
                }
                // ch == null: the player refused (channel cap); retried next frame, still before the end
            }
        }

        if (fading) {
            var chS = this.chS;
            if (now - tS >= len) {
                // a stall longer than the loop itself (a real pause runs no updates): the incoming
                // channel has ended too, so fading toward it would fade into silence; start afresh
                chP.stop();
                chS.stop();
                this.chS = null;
                chP = restartPrimary(now);
                if (chP == null) return;
            } else {
                if (fadeStart < 0) {
                    // wait for the incoming audio to actually run (its play() latency), with a deadline
                    if (chS.position > 0 || now - tS >= cross) fadeStart = now;
                }
                if (fadeStart >= 0) {
                    var u = (now - fadeStart) / cross;
                    if (u >= 1.0) {
                        // fade complete: the incoming channel takes over
                        chP.stop();
                        promoteSecondary();
                        chP = this.chP;
                    } else {
                        var a = u * HALF_PI;
                        gainP = Math.cos(a);
                        gainS = Math.sin(a);
                        applyS(chS);
                    }
                }
            }
        }

        applyP(chP);
    }

    // 1 or 2 currently active
    public function channels():Int {
        var n = 0;
        if (chP != null) n++;
        if (chS != null) n++;
        return n;
    }

    // ---- private ---------------------------------------------------------------------------

    // the secondary becomes the primary (its transform, start time and gain come with it)
    function promoteSecondary():Void {
        var st = stP; stP = stS; stS = st;
        var av = appliedVolP; appliedVolP = appliedVolS; appliedVolS = av;
        var ap = appliedPanP; appliedPanP = appliedPanS; appliedPanS = ap;
        chP = chS;
        chS = null;
        tP = tS;
        fading = false;
        fadeStart = -1;
        gainP = 1.0;
        gainS = 0.0;
    }

    // play the primary afresh at full crossfade gain; returns the channel (null if refused)
    function restartPrimary(now:Int):SoundChannel {
        fading = false;
        fadeStart = -1;
        gainP = 1.0;
        gainS = 0.0;
        stP.volume = clampVol(volume);
        stP.pan = clampPan(pan);
        appliedVolP = stP.volume;
        appliedPanP = stP.pan;
        chP = snd.play(0, 0, stP);
        tP = now;
        return chP;
    }

    inline function applyP(ch:SoundChannel):Void {
        var v = clampVol(volume) * gainP;
        var p = clampPan(pan);
        if (v != appliedVolP || p != appliedPanP) {
            appliedVolP = v;
            appliedPanP = p;
            stP.volume = v;
            stP.pan = p;
            ch.soundTransform = stP;
        }
    }

    inline function applyS(ch:SoundChannel):Void {
        var v = clampVol(volume) * gainS;
        var p = clampPan(pan);
        if (v != appliedVolS || p != appliedPanS) {
            appliedVolS = v;
            appliedPanS = p;
            stS.volume = v;
            stS.pan = p;
            ch.soundTransform = stS;
        }
    }

    static inline function clampVol(v:Float):Float {
        return !(v > 0.0) ? 0.0 : (v > 1.0 ? 1.0 : v);   // !(v > 0) also catches NaN
    }

    static inline function clampPan(p:Float):Float {
        return !(p > -1.0) ? -1.0 : (p > 1.0 ? 1.0 : p);
    }
}
