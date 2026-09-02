// Everything the game says to the PC, and the two ways the PC talks back.
//
//   ping(q)          GET /telemetry?q  (fire and forget; the loader is KEPT
//                    until it completes -- Flash garbage-collects an
//                    unreferenced URLLoader mid-flight and the ping is lost)
//   snap(bmd, tag)   POST /snap with PNG bytes -- a real frame from the eMac
//   pollRC(handler)  poll /rc every 300 ms in test mode; each line -> handler
//   registerEI(fn)   ExternalInterface callback "g3" so Safari's AppleScript
//                    `do JavaScript` can drive the game (needs an <object> tag)
//
// The host is taken from loaderInfo.url, so it is whatever served the SWF.
import flash.display.BitmapData;
import flash.events.Event;
import flash.events.IOErrorEvent;
import flash.events.TimerEvent;
import flash.net.URLLoader;
import flash.net.URLRequest;
import flash.net.URLRequestMethod;
import flash.utils.ByteArray;
import flash.utils.Timer;

class Telemetry {
    public static var host:String = "";
    public static var enabled:Bool = true;
    static var keep:Array<URLLoader> = [];
    static var rcLoader:URLLoader;
    static var rcTimer:Timer;
    static var rcHandler:String->Void;

    public static function init(loaderUrl:String):Void {
        var i = loaderUrl.indexOf("/", 8);
        host = i > 0 ? loaderUrl.substr(0, i) : "";
        enabled = StringTools.startsWith(loaderUrl, "http");
    }

    static function hold(l:URLLoader):Void {
        keep.push(l);
        l.addEventListener(Event.COMPLETE, function (_) { keep.remove(l); });
        l.addEventListener(IOErrorEvent.IO_ERROR, function (_) { keep.remove(l); });
    }

    public static function ping(q:String):Void {
        if (!enabled) return;
        var l = new URLLoader();
        hold(l);
        l.load(new URLRequest(host + "/telemetry?" + q + "&t=" + flash.Lib.getTimer()));
    }

    public static function snap(bmd:BitmapData, tag:String):Void {
        if (!enabled) return;
        var png = Png.encode(bmd);
        var req = new URLRequest(host + "/snap?tag=" + tag);
        req.method = URLRequestMethod.POST;
        req.contentType = "application/octet-stream";
        req.data = png;
        var l = new URLLoader();
        hold(l);
        l.load(req);
        ping("snap=" + tag + "&bytes=" + png.length + "&w=" + bmd.width + "&h=" + bmd.height);
    }

    public static function pollRC(handler:String->Void, everyMs:Int = 300):Void {
        if (!enabled) return;
        rcHandler = handler;
        if (rcTimer != null) return;
        rcTimer = new Timer(everyMs);
        rcTimer.addEventListener(TimerEvent.TIMER, function (_) { pollOnce(); });
        rcTimer.start();
    }

    static function pollOnce():Void {
        if (rcLoader != null) return;
        var l = new URLLoader();
        rcLoader = l;
        l.addEventListener(Event.COMPLETE, function (_) {
            rcLoader = null;
            var txt:String = l.data;
            if (txt == null || txt == "") return;
            for (line in txt.split("\n")) if (line != "" && rcHandler != null) rcHandler(line);
        });
        l.addEventListener(IOErrorEvent.IO_ERROR, function (_) { rcLoader = null; });
        l.load(new URLRequest(host + "/rc?t=" + flash.Lib.getTimer()));
    }

    public static function registerEI(fn:String->Dynamic->String):Bool {
        try {
            if (!flash.external.ExternalInterface.available) return false;
            flash.external.ExternalInterface.addCallback("g3", fn);
            return true;
        } catch (e:Dynamic) { return false; }
    }
}
