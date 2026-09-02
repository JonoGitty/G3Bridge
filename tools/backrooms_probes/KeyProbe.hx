import flash.display.Sprite;
import flash.display.StageDisplayState;
import flash.display.StageScaleMode;
import flash.display.StageAlign;
import flash.events.Event;
import flash.events.TimerEvent;
import flash.events.KeyboardEvent;
import flash.events.MouseEvent;
import flash.events.FullScreenEvent;
import flash.net.URLRequest;
import flash.net.URLLoader;
import flash.text.TextField;
import flash.text.TextFormat;
import flash.utils.Timer;
import flash.external.ExternalInterface;
import flash.Lib;

class KeyProbe extends Sprite {
    var host:String;
    var tf:TextField;
    var keep:Array<URLLoader> = [];
    var rcLoader:URLLoader;
    var st:flash.display.Stage;
    public function new() {
        super();
        var url = Lib.current.loaderInfo.url;
        host = url.substr(0, url.indexOf("/", 8));
        st = Lib.current.stage;
        st.scaleMode = StageScaleMode.NO_SCALE; st.align = StageAlign.TOP_LEFT;
        graphics.beginFill(0x202020); graphics.drawRect(0, 0, 1024, 768); graphics.endFill();
        tf = new TextField(); tf.width = 900; tf.height = 600; tf.x = 40; tf.y = 40;
        tf.defaultTextFormat = new TextFormat("_typewriter", 20, 0x80FF80); tf.multiline = true;
        tf.text = "KEY PROBE v3\n"; addChild(tf);
        st.addEventListener(KeyboardEvent.KEY_DOWN, function (e:KeyboardEvent) { say("key=" + e.keyCode + "&char=" + e.charCode + "&fs=" + st.displayState); });
        st.addEventListener(MouseEvent.CLICK, function (e:MouseEvent) { try { st.displayState = StageDisplayState.FULL_SCREEN; say("click=fullscreen"); } catch (err:Dynamic) { say("click=fserror&e=" + StringTools.urlEncode(Std.string(err))); } });
        st.addEventListener(FullScreenEvent.FULL_SCREEN, function (e:FullScreenEvent) { say("fullscreenevent=" + e.fullScreen + "&sw=" + st.stageWidth + "&sh=" + st.stageHeight); });
        registerEI("now");
        var t = new Timer(1000, 1); t.addEventListener(TimerEvent.TIMER, function (_) { registerEI("late"); }); t.start();
        var rc = new Timer(400); rc.addEventListener(TimerEvent.TIMER, function (_) { pollRC(); }); rc.start();
        say("keyprobe=ready&v=3&sw=" + st.stageWidth + "&sh=" + st.stageHeight);
    }
    function registerEI(when:String) {
        try {
            var av = ExternalInterface.available;
            var oid = ExternalInterface.objectID;
            ExternalInterface.addCallback("g3", function (cmd:String, a:Dynamic):String { return handle(cmd, a); });
            say("ei=" + when + "&available=" + (av ? 1 : 0) + "&objectID=" + StringTools.urlEncode(Std.string(oid)));
        } catch (e:Dynamic) { say("ei=" + when + "&error=" + StringTools.urlEncode(Std.string(e))); }
    }
    function handle(cmd:String, a:Dynamic):String {
        if (cmd == "key") { st.dispatchEvent(new KeyboardEvent(KeyboardEvent.KEY_DOWN, true, false, 0, Std.int(a))); return "key ok"; }
        if (cmd == "fs") { try { st.displayState = StageDisplayState.FULL_SCREEN; return "fs " + st.displayState; } catch (e:Dynamic) { return "fs error " + Std.string(e); } }
        if (cmd == "ping") { say("eiping=" + StringTools.urlEncode(Std.string(a))); return "pong " + Std.string(a); }
        if (cmd == "snap") { var t0 = Lib.getTimer(); var shot = new flash.display.BitmapData(512, 384, false, 0); var m = new flash.geom.Matrix(); m.scale(512 / st.stageWidth, 384 / st.stageHeight); shot.draw(st, m); var t1 = Lib.getTimer(); Telemetry.init(Lib.current.loaderInfo.url); Telemetry.snap(shot, "probe"); say("snapms=" + (t1 - t0) + "&encms=" + (Lib.getTimer() - t1)); return "snap ok"; }
        return "unknown " + cmd;
    }
    function pollRC() {
        if (rcLoader != null) return;
        rcLoader = new URLLoader();
        rcLoader.addEventListener(Event.COMPLETE, function (_) {
            var txt:String = rcLoader.data; rcLoader = null;
            if (txt == null || txt == "") return;
            for (line in txt.split("\n")) { var p = line.split(" "); if (p[0] == "key") handle("key", p[1]); else if (p[0] == "fs") handle("fs", 0); else if (p[0] == "ping") handle("ping", p.slice(1).join(" ")); else if (p[0] == "snap") handle("snap", 0); say("rc=" + StringTools.urlEncode(line)); }
        });
        rcLoader.addEventListener(flash.events.IOErrorEvent.IO_ERROR, function (_) { rcLoader = null; });
        rcLoader.load(new URLRequest(host + "/rc?r=" + Lib.getTimer()));
    }
    function say(q:String) {
        tf.appendText(q + "\n");
        var l = new URLLoader(); keep.push(l);
        l.addEventListener(Event.COMPLETE, function (_) { keep.remove(l); });
        l.load(new URLRequest(host + "/telemetry?keyprobe=1&" + q + "&r=" + Lib.getTimer()));
    }
    static function main() { Lib.current.addChild(new KeyProbe()); }
}
