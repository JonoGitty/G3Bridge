// Ruffle probe for the 'post' unit (Camcorder + Display) — CONTRACT §2 tests (1) and (2), the Display
// letterbox arithmetic, a flag sweep with timings and the T0 path. Not part of TestAll (that build is
// core-only under --interp). Build against the post stubs and serve it:
//   haxe -cp src/backrooms -cp stubs/post -cp tests/backrooms -main PostProbe -swf-version 10.1 -swf www/games/backrooms/post_probe.swf
//   C:\Python310\python.exe tools\ruffle_run.py /games/backrooms/post_probe.swf --seconds 6
// Results arrive as bk=probe&test=<name>&ok=0|1 telemetry lines, one per frame (the runner prints them).
import flash.display.BitmapData;
import flash.display.Sprite;
import flash.events.Event;
import flash.geom.Rectangle;

class PostProbe extends Sprite {
    static inline var W = 320;
    static inline var H = 240;
    var frame:Int;
    var display:Display;
    var cam:Camcorder;
    var bd:BitmapData;
    var src:flash.Vector<UInt>;
    var rect:Rectangle;

    public static function main():Void {
        flash.Lib.current.addChild(new PostProbe());
    }

    public function new():Void {
        super();
        frame = 0;
        Telemetry.init(flash.Lib.current.loaderInfo.url);
        display = new Display(flash.Lib.current.stage);
        cam = new Camcorder();
        cam.buildForTape(Tape.make(1, 1234));
        bd = new BitmapData(W, H, false, 0xFF000000);
        rect = new Rectangle(0, 0, W, H);
        src = new flash.Vector<UInt>(W * H, true);
        // scene, shaped like a lit corridor frame from the renderer: wallpaper 0xC8B450 in shade bands 0..8 across
        // the width (band 0 = full brightness at the centre, darker toward the edges), dark floor and ceiling
        // tiles, one near-white light panel (~5% of the frame)
        for (y in 0...H) for (x in 0...W) {
            var dx = x - 160; if (dx < 0) dx = -dx;
            var band = Std.int((dx * 9) / 160);   // 0 at the centre, 8 at the edges
            var f = 16 - band;                    // 16..8 of 16
            var r:Int, g:Int, b:Int;
            if (y >= 70 && y < 170) { r = (0xC8 * f) >> 4; g = (0xB4 * f) >> 4; b = (0x50 * f) >> 4; }
            else if (y < 70) { r = (0x90 * f) >> 4; g = (0x8C * f) >> 4; b = (0x80 * f) >> 4; }
            else { r = (0x70 * f) >> 4; g = (0x60 * f) >> 4; b = (0x30 * f) >> 4; }
            if (y >= 20 && y < 50 && x >= 100 && x < 220) { r = 0xE8; g = 0xE8; b = 0xE0; }
            src[y * W + x] = 0xFF000000 | (clamp(r) << 16) | (clamp(g) << 8) | clamp(b);
        }
        display.attach(bd, 1);
        addChild(display.bitmap);
        addEventListener(Event.ENTER_FRAME, onFrame);
    }

    function onFrame(e:Event):Void {
        frame++;
        var line = "";
        try {
            switch (frame) {
                case 2: line = testLayout();
                case 3: line = testPlain();
                case 4: line = testRoll();
                case 5: line = testSweep();
                case 6: line = testTier0();
                case 7: line = testFullscreenOutsideGesture();
                case 8: line = testMergeSemantics();
                case 9: line = "bk=probe&test=done&ok=1";
            }
        } catch (e:flash.errors.Error) {
            line = "bk=probe&test=frame" + frame + "&ok=0&err=" + e.errorID + "&msg=" + StringTools.urlEncode(e.message);
        }
        if (line != "") Telemetry.ping(line);
    }

    // (Display) the letterbox on a 1024x617 stage is (101, 0, 822, 617) at both tiers; 1024x768 is exact 3.2x / 4x
    function testLayout():String {
        var bm = display.bitmap;
        var out = "bk=probe&test=layout&stage=" + display.stageW + "x" + display.stageH
            + "&bmp=" + Std.int(bm.x) + "," + Std.int(bm.y) + "," + Std.int(bm.width) + "," + Std.int(bm.height);
        @:privateAccess display.layoutFor(1024, 617);
        var ok1 = bm.x == 101 && bm.y == 0 && Std.int(bm.width + 0.5) == 822 && Std.int(bm.height + 0.5) == 617;
        out += "&win617=" + Std.int(bm.x) + "," + Std.int(bm.y) + "," + Std.int(bm.width + 0.5) + "," + Std.int(bm.height + 0.5);
        @:privateAccess display.layoutFor(1024, 768);
        var ok2 = bm.x == 0 && bm.y == 0 && Math.abs(bm.scaleX - 3.2) < 0.001 && Math.abs(bm.scaleY - 3.2) < 0.001;
        var bd0 = new BitmapData(256, 192, false, 0xFF000000);
        display.attach(bd0, 0);
        @:privateAccess display.layoutFor(1024, 617);
        var ok3 = bm.x == 101 && bm.y == 0 && Std.int(bm.width + 0.5) == 822 && Std.int(bm.height + 0.5) == 617;
        @:privateAccess display.layoutFor(1024, 768);
        var ok4 = bm.x == 0 && bm.y == 0 && Math.abs(bm.scaleX - 4.0) < 0.001;
        display.attach(bd, 1);
        bd0.dispose();
        return out + "&t1fs=" + (ok2 ? 1 : 0) + "&t0win=" + (ok3 ? 1 : 0) + "&t0fs=" + (ok4 ? 1 : 0)
            + "&ok=" + ((ok1 && ok2 && ok3 && ok4) ? 1 : 0);
    }

    // (Camcorder 1) flags = 0, dread = 0: fewer than 40% of pixels change by more than 0x30 in any channel
    function testPlain():String {
        bd.setVector(rect, src);
        cam.flags = 0; cam.dread = 0; cam.chromaPx = 0; cam.flickerBrightness = 1.0;
        cam.apply(bd, 777);
        var t = cam.tPost;
        var after = bd.getVector(rect);
        var changed = 0;
        for (i in 0...(W * H)) {
            var a = src[i], b = after[i];
            var dr = chDiff(a, b, 16), dg = chDiff(a, b, 8), db = chDiff(a, b, 0);
            if (dr > 0x30 || dg > 0x30 || db > 0x30) changed++;
        }
        var permille = Std.int(changed * 1000 / (W * H));
        Telemetry.snap(bd, "postplain");   // the plain frame itself, for the look review
        // the corners of what a real tape can produce (tint 0.92..1.08, offsets -8..8, grain 40): the worst must stay under 40% too
        var base = Tape.make(1, 1234);
        var tints = [0.92, 0.92, 0.92,  1.08, 1.08, 1.08,  0.92, 0.92, 1.08,  1.08, 0.92, 0.92,  0.92, 1.08, 0.92];
        var offs = [-8, -8, -8,  8, 8, 8,  -8, -8, 8,  8, -8, -8,  -8, 8, -8];
        var worstPermille = 0;
        var detail = "";
        for (k in 0...5) {
            var tp = @:privateAccess new Tape();
            tp.index = base.index; tp.seed = base.seed; tp.salt = base.salt; tp.badTape = false;
            tp.tintR = tints[k * 3]; tp.tintG = tints[k * 3 + 1]; tp.tintB = tints[k * 3 + 2];
            tp.offR = offs[k * 3]; tp.offG = offs[k * 3 + 1]; tp.offB = offs[k * 3 + 2];
            tp.grainAlpha = 40;
            cam.buildForTape(tp);
            bd.setVector(rect, src);
            cam.flags = 0; cam.dread = 0; cam.chromaPx = 0; cam.flickerBrightness = 1.0;
            cam.apply(bd, 779 + k);
            after = bd.getVector(rect);
            var changedW = 0;
            for (i in 0...(W * H)) {
                var a = src[i], b = after[i];
                var dr = chDiff(a, b, 16), dg = chDiff(a, b, 8), db = chDiff(a, b, 0);
                if (dr > 0x30 || dg > 0x30 || db > 0x30) changedW++;
            }
            var pw = Std.int(changedW * 1000 / (W * H));
            if (pw > worstPermille) worstPermille = pw;
            detail += "&c" + k + "=" + pw;
        }
        cam.buildForTape(base);
        return "bk=probe&test=plain&changed_permille=" + permille + "&worst_tint_permille=" + worstPermille + "&tpost=" + t + detail
            + "&ok=" + ((permille < 400 && worstPermille < 400) ? 1 : 0);
    }

    // (Camcorder 2) G_ROLL with rollPx = 20 moves a marker pixel down 20 rows
    function testRoll():String {
        bd.fillRect(rect, 0xFF000000);
        bd.setPixel(100, 50, 0xFFFFFF);
        bd.setPixel(101, 50, 0xFFFFFF);
        cam.flags = Camcorder.G_ROLL; cam.rollPx = 20; cam.dread = 0;
        cam.apply(bd, 778);
        var p70 = bd.getPixel(100, 70);
        var p50 = bd.getPixel(100, 50);
        var ok = ((p70 >> 16) & 255) > 0x80 && ((p50 >> 16) & 255) < 0x60;
        cam.flags = 0; cam.rollPx = 0;
        return "bk=probe&test=roll&at70=" + StringTools.hex(p70, 6) + "&at50=" + StringTools.hex(p50, 6) + "&ok=" + (ok ? 1 : 0);
    }

    // flag sweep: every path runs without throwing; ms for 20 applies of each; NOISE_FULL frames are opaque static
    function testSweep():String {
        var names = ["plain", "tear", "glitch", "dropout", "strobe", "blackout", "noisefull", "roll", "dread1"];
        var flagv = [0, Camcorder.G_TEAR, Camcorder.G_GLITCH, Camcorder.G_DROPOUT, Camcorder.G_STROBE, Camcorder.G_BLACKOUT, Camcorder.G_NOISE_FULL, Camcorder.G_ROLL, 0];
        var out = "bk=probe&test=sweep";
        var noisy = false;
        for (k in 0...names.length) {
            cam.dread = k == 8 ? 1.0 : 0.0;
            cam.rollPx = 8; cam.chromaPx = k == 8 ? 3 : 0;
            var t0 = flash.Lib.getTimer();
            for (n in 0...20) {
                bd.setVector(rect, src);
                cam.flags = flagv[k];
                if (k == 1) cam.tearNow(1 + (n & 3));
                if (k == 2) cam.glitchNow();
                cam.apply(bd, 1000 + n * 31 + k);
            }
            out += "&" + names[k] + "_ms=" + (flash.Lib.getTimer() - t0);
            if (k == 6) {
                var dark = 0, bright = 0;
                for (i in 0...64) {
                    var g = (bd.getPixel((i * 37) % W, (i * 53) % (H - 4)) >> 8) & 255;
                    if (g < 0x60) dark++;
                    if (g > 0xA0) bright++;
                }
                noisy = dark > 4 && bright > 4;
                out += "&noise_dark=" + dark + "&noise_bright=" + bright;
            }
        }
        cam.flags = 0; cam.dread = 0; cam.chromaPx = 0; cam.rollPx = 0;
        return out + "&ok=" + (noisy ? 1 : 0);
    }

    // T0 buffers: 20 frames of mixed effects at 256x192, then the size-sync guard (a T0 buffer handed in at T1)
    function testTier0():String {
        var bd0 = new BitmapData(Renderer.W0, Renderer.H0, false, 0xFF404040);
        cam.setTier(0);
        for (k in 0...20) {
            bd0.fillRect(bd0.rect, 0xFF404040);
            cam.flags = k & 7;
            cam.rollPx = 4 + k;
            cam.dread = k / 20.0;
            cam.apply(bd0, 0x5555 + k * 977);
        }
        cam.setTier(1);
        cam.apply(bd0, 0x999);
        cam.setTier(1);
        cam.flags = 0; cam.rollPx = 0; cam.dread = 0;
        bd0.dispose();
        return "bk=probe&test=tier0&ok=1";
    }

    // enterFullscreen from ENTER_FRAME is not a gesture: on a real player it returns false (SecurityError #2152).
    // Ruffle may allow it; either way it must not throw out of the call.
    function testFullscreenOutsideGesture():String {
        var r = display.enterFullscreen();
        display.exitFullscreen();
        return "bk=probe&test=fs&entered=" + (r ? 1 : 0) + "&fs=" + (display.fullscreen ? 1 : 0) + "&ok=1";
    }

    // what the player does with a setVector'd ARGB sheet merged onto an opaque frame, and what the real sheets hold
    function testMergeSemantics():String {
        var sheet = new BitmapData(4, 4, true, 0x00000000);
        var v = new flash.Vector<UInt>(16, true);
        for (i in 0...16) v[i] = 0x28808080;   // alpha 40, mid grey
        sheet.setVector(sheet.rect, v);
        var stored = sheet.getPixel32(1, 1);
        var target = new BitmapData(4, 4, false, 0xFFC8B450);
        target.copyPixels(sheet, sheet.rect, new flash.geom.Point(0, 0), null, null, true);
        var merged = target.getPixel(1, 1);     // expect ~BDAB58 (C8 + (80-C8)*40/255)
        var g0 = @:privateAccess cam.grain[0];
        var sc = @:privateAccess cam.scan1;
        var out = "bk=probe&test=merge&stored=" + StringTools.hex(stored, 8) + "&merged=" + StringTools.hex(merged, 6)
            + "&grain0=" + StringTools.hex(g0.getPixel32(10, 10), 8) + "," + StringTools.hex(g0.getPixel32(11, 10), 8) + "," + StringTools.hex(g0.getPixel32(12, 10), 8)
            + "&scan_c=" + StringTools.hex(sc.getPixel32(160, 120), 8) + "," + StringTools.hex(sc.getPixel32(160, 121), 8)
            + "&scan_corner=" + StringTools.hex(sc.getPixel32(0, 0), 8) + "," + StringTools.hex(sc.getPixel32(40, 40), 8);
        // a single grain merge on a flat frame: how far does one grain window move a C8B450 pixel?
        target.dispose();
        var flat = new BitmapData(W, H, false, 0xFFC8B450);
        var rc = new Rectangle(0, 0, W, H);
        flat.copyPixels(g0, rc, new flash.geom.Point(0, 0), null, null, true);
        var mn = 255, mx = 0;
        for (i in 0...200) {
            var p:Int = (flat.getPixel((i * 37) % W, (i * 53) % H) >> 8) & 255;
            if (p < mn) mn = p;
            if (p > mx) mx = p;
        }
        out += "&grain_on_b4_min=" + mn + "&max=" + mx;
        flat.dispose();
        sheet.dispose();
        return out + "&ok=1";
    }

    // channel difference as a signed Int (UInt arithmetic would wrap on a darkened channel)
    static inline function chDiff(a:UInt, b:UInt, sh:Int):Int {
        var x:Int = (a >> sh) & 255;
        var y:Int = (b >> sh) & 255;
        return x > y ? x - y : y - x;
    }

    static inline function clamp(v:Int):Int return v < 0 ? 0 : (v > 255 ? 255 : v);
}
