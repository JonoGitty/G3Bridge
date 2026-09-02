// Ruffle smoke test for the audio unit (CONTRACT §2: LoopPlayer tests 1-3, AudioBus tests 1-3).
// Not part of TestAll (fp classes cannot run under --interp). Build and run:
//   haxe -cp src/backrooms -cp tests/backrooms -main AudioSmoke -swf www/games/backrooms/audiosmoke.swf -swf-version 10.1 -D swf-header=1024:768:30:000000
//   C:\Python310\python.exe tools\ruffle_run.py /games/backrooms/audiosmoke.swf --seconds 30 --shot run\audiosmoke.png
// Results go to the daemon's telemetry log as bk=audiotest lines; the final line carries result=pass|fail.
import flash.display.Sprite;
import flash.events.Event;
import flash.text.TextField;
import flash.text.TextFormat;

class AudioSmoke extends Sprite {
    static inline var RUN_SECONDS = 25.0;

    var bus:AudioBus;
    var tf:TextField;
    var t:Float;
    var last:Int;
    var frame:Int;
    var failures:Int;
    var zeroChannelFrames:Int;       // frames where a playing loop reported 0 channels
    var maxChannels:Int;
    var maxLoopChannels:Int;
    var latOk:Bool;
    var latFrameTime:Float;
    var restarted:Bool;
    var done:Bool;
    var log:String;

    public static function main():Void {
        flash.Lib.current.addChild(new AudioSmoke());
    }

    public function new() {
        super();
        Telemetry.init(flash.Lib.current.loaderInfo.url);
        tf = new TextField();
        tf.defaultTextFormat = new TextFormat("_typewriter", 16, 0x00FF66);
        tf.width = 1000; tf.height = 740; tf.x = 12; tf.y = 12;
        tf.multiline = true; tf.wordWrap = true;
        addChild(tf);
        t = 0; frame = 0; failures = 0; zeroChannelFrames = 0; maxChannels = 0; maxLoopChannels = 0;
        latOk = false; latFrameTime = -1; restarted = false; done = false; log = "";
        last = flash.Lib.getTimer();

        bus = new AudioBus();

        // AudioBus test 1: falloff
        check("falloff(0) == 1", Math.abs(AudioBus.falloff(0) - 1.0) < 1e-9);
        check("falloff(3) == 0.25", Math.abs(AudioBus.falloff(3) - 0.25) < 1e-9);
        check("panOf(pi/2) == 0.7", Math.abs(AudioBus.panOf(Math.PI / 2) - 0.7) < 1e-9);

        bus.startBed();
        say("bed started: channels=" + bus.channels());
        check("bed running: channels >= 7", bus.channels() >= 7);

        // AudioBus test 2: one-shot spam in one frame
        for (i in 0...100) bus.oneShot(AudioBus.DISTANT1 + (i % 6), 0.5, 0.0);
        var c = bus.channels();
        say("after 100 oneShots: channels=" + c);
        check("channels <= 20 after 100 oneShots", c <= 20);
        check("one-shot pool used: channels >= 7 + 6", c >= 13);

        // AudioBus test 3: pause / resume restores the volumes set before
        bus.setPresence(0.8);
        bus.setHumLight(0.6);
        bus.setDrip(2.0, 0.3);
        bus.update(0.05);
        var v0 = loopVols();
        bus.pause();
        var vp = loopVols();
        check("pause: every loop volume 0", allZero());
        check("pause: loops keep running", bus.channels() >= 7);
        bus.resume();
        var v1 = loopVols();
        say("volumes before pause: " + v0 + "\n after pause: " + vp + "\n after resume: " + v1);
        check("resume restores the volumes", v0 == v1);

        // LoopPlayer test 2: stop then start does not leak channels
        var lp = new LoopPlayer(Sfx.all()[AudioBus.DRIP]);
        lp.volume = 0.0;
        lp.start(); lp.update(0.05); lp.stop(); lp.start(); lp.update(0.05); lp.stop(); lp.start(); lp.update(0.05);
        check("stop/start: channels() <= 2 (" + lp.channels() + ")", lp.channels() <= 2 && lp.channels() >= 1);
        lp.stop();
        check("stop: channels() == 0", lp.channels() == 0);

        Telemetry.ping("bk=audiotest&phase=start&fail=" + failures);
        addEventListener(Event.ENTER_FRAME, onFrame);
    }

    function loopVols():String {
        // the seven loop targets, via the private field through reflection-free access: read back what LoopPlayer will apply
        var s = "";
        for (i in 0...7) s += (i > 0 ? "," : "") + Std.string(Math.round(loopAt(i).volume * 10000) / 10000);
        return s;
    }

    function allZero():Bool {
        for (i in 0...7) if (loopAt(i).volume != 0.0) return false;
        return true;
    }

    @:access(AudioBus)
    inline function loopAt(i:Int):LoopPlayer return bus.loops[i];

    function check(name:String, ok:Bool):Void {
        if (!ok) failures++;
        say((ok ? "PASS " : "FAIL ") + name);
    }

    function say(s:String):Void {
        log += s + "\n";
        tf.text = log;
    }

    function onFrame(_):Void {
        if (done) return;
        var now = flash.Lib.getTimer();
        var dtMs = now - last; if (dtMs > 100) dtMs = 100;
        last = now;
        var dt = dtMs / 1000.0;
        t += dt;
        frame++;

        // drive the mix around so every path runs
        var p = 0.5 + 0.5 * Math.sin(t * 0.7);
        bus.setPresence(p);
        bus.setHumLight(0.7 + 0.3 * Math.sin(t * 3.1));
        bus.setHumLow(Std.int(t / 4) % 2 == 1);
        bus.setDark(Std.int(t / 6) % 2 == 1);
        bus.setDrip(1.0 + 6.0 * (0.5 + 0.5 * Math.sin(t * 0.4)), Math.sin(t));
        if (frame % 12 == 0) bus.footstep(Std.int(t / 5) % 2 == 1);
        if (frame % 45 == 0) bus.houndStep(3.0, 0.2);
        if (frame % 90 == 0) bus.oneShot(AudioBus.CLICKS1, 0.4, -0.5);
        bus.update(dt);

        // LoopPlayer test 1: a playing loop never reports 0 channels
        for (i in 0...7) {
            var lp = loopAt(i);
            if (lp.playing && lp.channels() == 0) zeroChannelFrames++;
            if (lp.channels() > maxLoopChannels) maxLoopChannels = lp.channels();
        }
        var c = bus.channels();
        if (c > maxChannels) maxChannels = c;

        // LoopPlayer test 3: latency measured within 2 s of the first start()
        if (!latOk && LoopPlayer.latencyMs > 0) { latOk = true; latFrameTime = t; }

        // stop and restart the whole bed once mid-run (channel accounting after stopAll)
        if (!restarted && t > 12.0) {
            restarted = true;
            bus.stopAll();
            check("stopAll: channels() == 0 (" + bus.channels() + ")", bus.channels() == 0);
            bus.startBed();
            check("restart: channels() >= 7", bus.channels() >= 7);
        }

        if (frame % 30 == 0) {
            tf.text = log + "\nt=" + Math.round(t * 10) / 10 + " chans=" + c + " max=" + maxChannels + " loopMax=" + maxLoopChannels
                + " zeroFrames=" + zeroChannelFrames + " lat=" + LoopPlayer.latencyMs + " cross=" + LoopPlayer.crossMs + " fails=" + failures;
        }
        if (frame % 150 == 0) {
            Telemetry.ping("bk=audiotest&phase=tick&t=" + Math.round(t) + "&chans=" + c + "&max=" + maxChannels + "&loopMax=" + maxLoopChannels
                + "&zero=" + zeroChannelFrames + "&lat=" + LoopPlayer.latencyMs + "&cross=" + LoopPlayer.crossMs + "&fail=" + failures);
        }

        if (t >= RUN_SECONDS) {
            done = true;
            check("loops never at 0 channels while playing (zeroFrames=" + zeroChannelFrames + ")", zeroChannelFrames == 0);
            check("channels() <= 20 over the run (max=" + maxChannels + ")", maxChannels <= 20);
            check("each loop <= 2 channels (max=" + maxLoopChannels + ")", maxLoopChannels <= 2);
            check("crossfade happened at least once (loopMax == 2)", maxLoopChannels == 2);
            check("latencyMs > 0 within 2 s (at t=" + latFrameTime + ", ms=" + LoopPlayer.latencyMs + ")", latOk && latFrameTime <= 2.0);
            check("crossMs == max(120, 2*lat)", LoopPlayer.crossMs == (2 * LoopPlayer.latencyMs > 120 ? 2 * LoopPlayer.latencyMs : 120));
            Telemetry.ping("bk=audiotest&phase=end&result=" + (failures == 0 ? "pass" : "fail") + "&fail=" + failures + "&max=" + maxChannels
                + "&loopMax=" + maxLoopChannels + "&zero=" + zeroChannelFrames + "&lat=" + LoopPlayer.latencyMs + "&cross=" + LoopPlayer.crossMs);
            tf.text = log + "\nRESULT: " + (failures == 0 ? "PASS" : "FAIL (" + failures + ")");
        }
    }
}
