// Gapless loop via two alternating channels (CONTRACT §2). fp class.
// SKELETON: constructor reads snd.length and allocates two SoundTransforms; nothing plays.
import flash.media.Sound;
import flash.media.SoundChannel;
import flash.media.SoundTransform;

class LoopPlayer {
    public static inline var CROSS_MS = 120;
    public var volume:Float;                            // 0..1 target, applied each update
    public var pan:Float;
    public var playing:Bool;

    var snd:Sound;
    var lengthMs:Float;
    var stA:SoundTransform;
    var stB:SoundTransform;
    var chA:SoundChannel;
    var chB:SoundChannel;

    // reads snd.length; allocates two SoundTransforms
    public function new(snd:Sound):Void {
        this.snd = snd;
        lengthMs = snd.length;
        stA = new SoundTransform(0, 0);
        stB = new SoundTransform(0, 0);
        chA = null;
        chB = null;
        volume = 0.0;
        pan = 0.0;
        playing = false;
    }

    public function start():Void {
        playing = true; // SKELETON
    }

    public function stop():Void {
        playing = false; // SKELETON
    }

    // starts the second channel CROSS_MS before the first ends (by getTimer), equal-power crossfade, alternates; applies volume/pan
    public function update(dt:Float):Void {
        // SKELETON
    }

    // 1 or 2 currently active
    public function channels():Int {
        return 0; // SKELETON
    }
}
