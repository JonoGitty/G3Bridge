import flash.display.Sprite;
import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.display.StageQuality;
import flash.display.StageScaleMode;
import flash.display.StageAlign;
import flash.events.Event;
import flash.net.URLRequest;
import flash.net.URLLoader;
import flash.geom.Rectangle;
import flash.geom.Point;
import flash.geom.ColorTransform;
import flash.filters.BlurFilter;
import flash.Lib;

// Measures the pixel pipeline on the real machine. Each mode runs for FRAMES
// frames and reports fps to /telemetry, then the next mode starts.
class Bench extends Sprite {
    static inline var FRAMES = 60;
    var modes:Array<{name:String, w:Int, h:Int, smooth:Bool, noise:Bool, blur:Bool, ray:Bool}>;
    var mi:Int = -1;
    var bmd:BitmapData;
    var bm:Bitmap;
    var buf:flash.Vector<UInt>;
    var noise:BitmapData;
    var tex:flash.Vector<UInt>;
    var frame:Int;
    var t0:Int;
    var host:String;
    var W:Int; var H:Int;
    var ct:ColorTransform;
    var cosT:flash.Vector<Float>; var sinT:flash.Vector<Float>;

    public function new() {
        super();
        var url = Lib.current.loaderInfo.url;
        host = url.substr(0, url.indexOf("/", 8));
        var st = Lib.current.stage;
        st.scaleMode = StageScaleMode.NO_SCALE;
        st.align = StageAlign.TOP_LEFT;
        st.quality = StageQuality.LOW;
        modes = [
            {name: "fill320", w: 320, h: 240, smooth: false, noise: false, blur: false, ray: false},
            {name: "fill320smooth", w: 320, h: 240, smooth: true, noise: false, blur: false, ray: false},
            {name: "fill256", w: 256, h: 192, smooth: false, noise: false, blur: false, ray: false},
            {name: "fill400", w: 400, h: 300, smooth: false, noise: false, blur: false, ray: false},
            {name: "ray320", w: 320, h: 240, smooth: false, noise: false, blur: false, ray: true},
            {name: "ray320noise", w: 320, h: 240, smooth: false, noise: true, blur: false, ray: true},
            {name: "ray256noise", w: 256, h: 192, smooth: false, noise: true, blur: false, ray: true},
            {name: "ray400noise", w: 400, h: 300, smooth: false, noise: true, blur: false, ray: true},
            {name: "ray320blur", w: 320, h: 240, smooth: false, noise: true, blur: true, ray: true},
        ];
        tex = new flash.Vector<UInt>(64 * 64, true);
        for (i in 0...4096) tex[i] = 0xC0A040 + ((i * 7) & 0x1F) + (((i >> 6) & 0x1F) << 8);
        cosT = new flash.Vector<Float>(400, true); sinT = new flash.Vector<Float>(400, true);
        for (i in 0...400) { var a = (i / 400.0 - 0.5) * 1.1; cosT[i] = Math.cos(a); sinT[i] = Math.sin(a); }
        ct = new ColorTransform(1.05, 1.0, 0.85, 1, 0, 0, 0, 0);
        ping("bench=start&player=" + StringTools.urlEncode(flash.system.Capabilities.version) + "&cpu=" + StringTools.urlEncode(flash.system.Capabilities.cpuArchitecture) + "&os=" + StringTools.urlEncode(flash.system.Capabilities.os) + "&screen=" + flash.system.Capabilities.screenResolutionX + "x" + flash.system.Capabilities.screenResolutionY);
        next();
        addEventListener(Event.ENTER_FRAME, onFrame);
    }

    function next() {
        mi++;
        if (mi >= modes.length) { ping("bench=done"); removeEventListener(Event.ENTER_FRAME, onFrame); return; }
        var m = modes[mi];
        W = m.w; H = m.h;
        while (numChildren > 0) removeChildAt(0);
        bmd = new BitmapData(W, H, false, 0);
        buf = new flash.Vector<UInt>(W * H, true);
        bm = new Bitmap(bmd, flash.display.PixelSnapping.NEVER, m.smooth);
        bm.scaleX = 1024 / W; bm.scaleY = 768 / H;
        addChild(bm);
        noise = new BitmapData(W, H, true, 0);
        noise.noise(7, 0, 255, 7, true);
        noise.colorTransform(noise.rect, new ColorTransform(1, 1, 1, 0.18));
        if (m.blur) bm.filters = [new BlurFilter(2, 2, 1)] else bm.filters = [];
        frame = 0; t0 = Lib.getTimer();
    }

    function onFrame(_) {
        var m = modes[mi];
        var f = frame;
        if (m.ray) {
            // a raycast-shaped workload: per column a DDA of ~12 steps, then a textured vertical slice
            var i = 0;
            var half = H >> 1;
            for (x in 0...W) {
                var dx = cosT[x]; var dy = sinT[x];
                var px = 3.5 + f * 0.01; var py = 2.5;
                var dist = 0.0;
                var steps = 0;
                while (steps < 12) { px += dx * 0.5; py += dy * 0.5; dist += 0.5; steps++; if (((Std.int(px) * 7 + Std.int(py) * 13) & 15) == 0) break; }
                var hh = Std.int(H / (dist + 0.3));
                if (hh > H) hh = H;
                var top = half - (hh >> 1);
                var shade = dist > 5 ? 1 : 0;
                var tx = (Std.int(px * 64) & 63);
                // ceiling
                var idx = x;
                for (y in 0...top) { buf[idx] = 0x3A3320; idx += W; }
                // wall
                var ty = 0.0; var tstep = 64.0 / hh;
                for (y in top...(top + hh)) { var c = tex[(Std.int(ty) << 6) | tx]; buf[idx] = shade == 1 ? ((c >> 1) & 0x7F7F7F) : c; ty += tstep; idx += W; }
                // floor
                for (y in (top + hh)...H) { buf[idx] = 0x2A2418; idx += W; }
            }
        } else {
            var i = 0;
            for (y in 0...H) for (x in 0...W) buf[i++] = ((x + f) & 0xff) << 16 | ((y + f) & 0xff) << 8 | ((x ^ y) & 0xff);
        }
        bmd.setVector(bmd.rect, buf);
        if (m.noise) {
            bmd.copyPixels(noise, noise.rect, new Point(0, (f * 7) % 16 - 8), null, null, true);
            bmd.colorTransform(bmd.rect, ct);
        }
        frame++;
        if (frame == FRAMES) {
            var ms = Lib.getTimer() - t0;
            ping("bench=" + m.name + "&frames=" + FRAMES + "&ms=" + ms + "&fps=" + Math.round(FRAMES * 1000 / ms) + "&msperframe=" + Math.round(ms / FRAMES));
            next();
        }
    }

    function ping(q:String) {
        var l = new URLLoader();
        l.load(new URLRequest(host + "/telemetry?" + q + "&r=" + Lib.getTimer()));
    }

    static function main() { Lib.current.addChild(new Bench()); }
}
