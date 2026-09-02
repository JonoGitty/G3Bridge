import flash.display.Sprite;
import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.display.StageQuality;
import flash.display.StageScaleMode;
import flash.display.StageAlign;
import flash.events.Event;
import flash.net.URLRequest;
import flash.net.URLLoader;
import flash.Lib;

// Second benchmark: the per-pixel costs a real raycaster adds on top of walls --
// textured floor+ceiling casting at full and half vertical resolution, and
// billboard sprites drawn as scaled column slices. 320x240, all into a Vector.
class Bench2 extends Sprite {
    static inline var FRAMES = 60;
    static inline var W = 320;
    static inline var H = 240;
    var modes:Array<String>;
    var mi:Int = -1;
    var bmd:BitmapData;
    var buf:flash.Vector<UInt>;
    var tex:flash.Vector<UInt>;
    var ftex:flash.Vector<UInt>;
    var frame:Int; var t0:Int;
    var host:String;
    var keep:Array<URLLoader> = [];
    var cosT:flash.Vector<Float>; var sinT:flash.Vector<Float>;
    var zbuf:flash.Vector<Float>;

    public function new() {
        super();
        var url = Lib.current.loaderInfo.url;
        host = url.substr(0, url.indexOf("/", 8));
        var st = Lib.current.stage;
        st.scaleMode = StageScaleMode.NO_SCALE; st.align = StageAlign.TOP_LEFT; st.quality = StageQuality.LOW;
        modes = ["walls", "walls+floorfull", "walls+floorhalf", "walls+floorfull+2sprites", "walls+floorhalf+4sprites"];
        tex = new flash.Vector<UInt>(4096, true); ftex = new flash.Vector<UInt>(4096, true);
        for (i in 0...4096) { tex[i] = 0xC0A040 + ((i * 7) & 0x1F) + (((i >> 6) & 0x1F) << 8); ftex[i] = 0x3A3018 + ((i * 13) & 0x0F) + (((i >> 6) & 0x0F) << 8); }
        cosT = new flash.Vector<Float>(W, true); sinT = new flash.Vector<Float>(W, true);
        for (i in 0...W) { var a = (i / W - 0.5) * 1.1; cosT[i] = Math.cos(a); sinT[i] = Math.sin(a); }
        zbuf = new flash.Vector<Float>(W, true);
        bmd = new BitmapData(W, H, false, 0);
        buf = new flash.Vector<UInt>(W * H, true);
        var bm = new Bitmap(bmd); bm.scaleX = 1024 / W; bm.scaleY = 768 / H; addChild(bm);
        ping("bench2=start");
        next();
        addEventListener(Event.ENTER_FRAME, onFrame);
    }

    function next() {
        mi++;
        if (mi >= modes.length) { ping("bench2=done"); removeEventListener(Event.ENTER_FRAME, onFrame); return; }
        frame = 0; t0 = Lib.getTimer();
    }

    function onFrame(_) {
        var m = modes[mi];
        var f = frame;
        var half = H >> 1;
        var px = 3.5 + f * 0.01, py = 2.5;
        // walls
        for (x in 0...W) {
            var dx = cosT[x], dy = sinT[x];
            var rx = px, ry = py, dist = 0.0, steps = 0;
            while (steps < 12) { rx += dx * 0.5; ry += dy * 0.5; dist += 0.5; steps++; if (((Std.int(rx) * 7 + Std.int(ry) * 13) & 15) == 0) break; }
            zbuf[x] = dist;
            var hh = Std.int(H / (dist + 0.3)); if (hh > H) hh = H;
            var top = half - (hh >> 1);
            var tx = (Std.int(rx * 64) & 63);
            var idx = x + top * W;
            var ty = 0.0, tstep = 64.0 / hh;
            for (y in top...(top + hh)) { buf[idx] = tex[(Std.int(ty) << 6) | tx]; ty += tstep; idx += W; }
            if (m == "walls") { var i2 = x; for (y in 0...top) { buf[i2] = 0x3A3320; i2 += W; } i2 = x + (top + hh) * W; for (y in (top + hh)...H) { buf[i2] = 0x2A2418; i2 += W; } }
        }
        // floor + ceiling casting (perspective-correct per row)
        if (m != "walls") {
            var stepRows = (m.indexOf("floorhalf") >= 0) ? 2 : 1;
            var y = half + 1;
            while (y < H) {
                var rowDist = (0.5 * H) / (y - half);
                var fx0 = px + rowDist * cosT[0], fy0 = py + rowDist * sinT[0];
                var fxs = rowDist * (cosT[W - 1] - cosT[0]) / W, fys = rowDist * (sinT[W - 1] - sinT[0]) / W;
                var idx = y * W; var cidx = (H - 1 - y) * W;
                var fx = fx0, fy = fy0;
                for (x in 0...W) {
                    var t = ftex[((Std.int(fy * 64) & 63) << 6) | (Std.int(fx * 64) & 63)];
                    buf[idx + x] = t; buf[cidx + x] = t ^ 0x101010;
                    fx += fxs; fy += fys;
                }
                if (stepRows == 2 && y + 1 < H) { var src = y * W, dst = (y + 1) * W, csrc = (H - 1 - y) * W, cdst = (H - 2 - y) * W; for (x in 0...W) { buf[dst + x] = buf[src + x]; if (cdst >= 0) buf[cdst + x] = buf[csrc + x]; } }
                y += stepRows;
            }
        }
        // sprites: billboards of a 64x64 texture, scaled by distance, z-tested per column
        var ns = (m.indexOf("2sprites") >= 0) ? 2 : (m.indexOf("4sprites") >= 0 ? 4 : 0);
        for (s in 0...ns) {
            var sd = 1.5 + s * 1.2 + ((f >> 3) & 1) * 0.3;
            var sh = Std.int(H / sd); if (sh > H) sh = H;
            var sw = sh;
            var sx0 = Std.int(W * 0.5 + (s - ns * 0.5) * 60 - sw * 0.5);
            var top = half - (sh >> 1);
            var tstepX = 64.0 / sw, tstepY = 64.0 / sh;
            var tx = 0.0;
            for (x in sx0...(sx0 + sw)) {
                if (x < 0 || x >= W || zbuf[x] < sd) { tx += tstepX; continue; }
                var col = Std.int(tx) & 63;
                var ty = 0.0; var idx = x + top * W;
                for (y in top...(top + sh)) { if (y >= 0 && y < H) { var c = tex[(Std.int(ty) << 6) | col]; if ((c & 0xFF) > 0x48) buf[idx] = c ^ 0x402020; } ty += tstepY; idx += W; }
                tx += tstepX;
            }
        }
        bmd.setVector(bmd.rect, buf);
        frame++;
        if (frame == FRAMES) {
            var ms = Lib.getTimer() - t0;
            ping("bench2=" + StringTools.urlEncode(m) + "&fps=" + Math.round(FRAMES * 1000 / ms) + "&msperframe=" + Math.round(ms / FRAMES));
            next();
        }
    }

    function ping(q:String) {
        var l = new URLLoader(); keep.push(l);
        l.addEventListener(Event.COMPLETE, function (_) { keep.remove(l); });
        l.load(new URLRequest(host + "/telemetry?" + q + "&r=" + Lib.getTimer()));
    }
    static function main() { Lib.current.addChild(new Bench2()); }
}
