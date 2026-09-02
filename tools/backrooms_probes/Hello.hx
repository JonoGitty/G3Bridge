import flash.display.Sprite;
import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.events.Event;
import flash.net.URLRequest;
import flash.net.URLLoader;
import flash.Lib;

class Hello extends Sprite {
    static var W = 320;
    static var H = 240;
    var bmd:BitmapData;
    var buf:flash.Vector<UInt>;
    var frame:Int = 0;
    var t0:Int;
    var host:String;

    public function new() {
        super();
        var url = Lib.current.loaderInfo.url;
        host = url.substr(0, url.indexOf("/", 8));
        bmd = new BitmapData(W, H, false, 0x000000);
        buf = new flash.Vector<UInt>(W * H, true);
        var bm = new Bitmap(bmd);
        bm.scaleX = bm.scaleY = 3.2;
        addChild(bm);
        t0 = Lib.getTimer();
        addEventListener(Event.ENTER_FRAME, onFrame);
    }

    function onFrame(_) {
        var f = frame;
        var i = 0;
        for (y in 0...H) {
            for (x in 0...W) {
                buf[i++] = ((x + f) & 0xff) << 16 | ((y * 2 + f) & 0xff) << 8 | ((x ^ y) & 0xff);
            }
        }
        bmd.setVector(bmd.rect, buf);
        frame++;
        if (frame == 90) {
            var ms = Lib.getTimer() - t0;
            var fps = Math.round(90000 / ms);
            ping("hello=1&frames=90&ms=" + ms + "&fps=" + fps + "&w=" + W + "&h=" + H + "&player=" + StringTools.urlEncode(flash.system.Capabilities.version));
        }
    }

    function ping(q:String) {
        var l = new URLLoader();
        l.load(new URLRequest(host + "/telemetry?" + q + "&r=" + Lib.getTimer()));
    }

    static function main() {
        Lib.current.addChild(new Hello());
    }
}
