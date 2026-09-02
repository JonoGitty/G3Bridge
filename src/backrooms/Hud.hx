// Camcorder on-screen display (CONTRACT §2). fp class.
//
// Burned into the frame buffer before setVector (so it takes the tape's grain like a real
// camcorder overlay): REC dot (1 Hz blink, red), "REC", "SP" mode, a battery meter, the
// camcorder model and a DD.MM.YYYY HH:MM:SS timestamp that starts at the tape's period-correct
// date + time and ticks with play time plus the Director's dread skips (tsSkip).
// Three skins (layout + colour) per Tape.hudSkin.
//
// Allocation: the timestamp string is rebuilt at most once per second inside tick() (the
// contract's one allowed HUD allocation); draw(), drawPlayFade() and drawStrip() allocate
// nothing. Everything is scale 1 (a 5x7 glyph at 320x240 lands at ~22 px on the 1024x768 CRT).
class Hud {
    public var recVisible:Bool;                         // Main clears it for one frame on EV_WATCHER_RELOCATED
    public var skin:Int;

    static inline var M = 8;                            // margin from the buffer edge, px
    static inline var GH = 7;                           // glyph height
    static inline var DAY = 86400;
    static inline var COL_REC:UInt = 0xFFE83030;        // the REC dot is red on every skin
    static inline var COL_SHADOW:UInt = 0xFF000000;
    static inline var COL_STRIP_TEXT_DIM:UInt = 0xFF606060;

    // strings (constant or rebuilt once per second)
    var strRec:String;
    var strDot:String;
    var strSp:String;
    var strPlay:String;
    var strCam:String;
    var strTs:String;

    // clock
    var startSec:Int;                                   // tape clock at play start, seconds since midnight (shifted by -86400 per rolled day)
    var elapsedMs:Int;                                  // play time seen through tick(), integer ms (a Float sum of dt would drift below whole seconds and read low)
    var skipTotal:Int;                                  // sum of tsSkip
    var shownSec:Int;                                   // seconds-since-midnight value the current strTs shows (-1 = never built)
    var day:Int;
    var month:Int;
    var year:Int;
    var blinkOn:Bool;                                   // REC dot phase, 1 Hz

    public function new():Void {
        recVisible = true;
        skin = 0;
        strRec = "REC";
        strDot = String.fromCharCode(PixelFont.CODE_REC);
        strSp = "SP";
        strPlay = "PLAY " + String.fromCharCode(PixelFont.CODE_PLAY);
        strCam = "VX-200";
        strTs = "";
        startSec = 0;
        elapsedMs = 0;
        skipTotal = 0;
        shownSec = -1;
        day = 1;
        month = 1;
        year = 1990;
        blinkOn = true;
        rebuild();
    }

    // skin, date, camName
    public function setTape(t:Tape):Void {
        skin = t.hudSkin;
        if (skin < 0 || skin > 2) skin = 0;
        strCam = t.camName;
        // "DD.MM.YYYY"; anything malformed falls back to a plausible date rather than throwing
        var ok = t.dateStr != null && t.dateStr.length == 10;
        if (ok) {
            var d = digits(t.dateStr, 0, 2);
            var mo = digits(t.dateStr, 3, 2);
            var y = digits(t.dateStr, 6, 4);
            ok = d >= 1 && d <= 31 && mo >= 1 && mo <= 12 && y >= 1900 && y <= 2099;
            if (ok) { day = d; month = mo; year = y; }
        }
        if (!ok) { day = 1; month = 1; year = 1990; }
        var s = Std.int(t.dateSeconds);
        if (s < 0) s = 0;
        if (s >= DAY) s = DAY - 1;
        startSec = s;
        elapsedMs = 0;
        skipTotal = 0;
        shownSec = -1;
        blinkOn = true;
        recVisible = true;
        rebuild();
    }

    // advances the displayed clock; rebuilds strings once per second (the only allocation).
    // The clock integrates dt (playSeconds is the contract's tape time, carried for callers that pass it; both advance by the same clamped dt).
    public function tick(dt:Float, playSeconds:Float, tsSkip:Int):Void {
        if (dt > 0) elapsedMs += Std.int(dt * 1000.0 + 0.5);
        if (tsSkip > 0) skipTotal += tsSkip;
        blinkOn = (Std.int(elapsedMs / 500) & 1) == 0;    // 1 Hz: on for the first half of every second
        var total = startSec + skipTotal + Std.int(elapsedMs / 1000);
        while (total >= DAY) {                            // midnight: roll the date forward
            total -= DAY;
            startSec -= DAY;
            nextDay();
            shownSec = -1;
        }
        if (total != shownSec) rebuild();
    }

    // REC dot (1 Hz), "SP", battery bars, timestamp, camName per skin
    public function draw(fb:flash.Vector<UInt>, w:Int, h:Int, battery:Float, strobeFrame:Bool):Void {
        var col = textColour(skin);
        var top = M;
        var bot = h - M - GH;
        var right = w - M;
        var dot = recVisible && blinkOn;
        var battOn = battery >= 0.1 || !strobeFrame;    // low battery: the meter blinks with the strobe
        switch (skin) {
            case 1:
                // amber: timestamp top-left, "REC ●" top-right, battery + SP bottom-left, cam bottom-right
                text(fb, w, h, M, top, strTs, col);
                var rx = right - 18 - 8 - 5;
                text(fb, w, h, rx, top, strRec, col);
                if (dot) text(fb, w, h, rx + 26, top, strDot, COL_REC);
                if (battOn) meter(fb, w, h, M, bot, battery, col);
                text(fb, w, h, M + 24, bot, strSp, col);
                text(fb, w, h, right - PixelFont.width(strCam, 1), bot, strCam, col);
            case 2:
                // pale green: "● REC CAM" top-left, battery top-right, SP bottom-left, timestamp bottom-right
                if (dot) text(fb, w, h, M, top, strDot, COL_REC);
                text(fb, w, h, M + 8, top, strRec, col);
                text(fb, w, h, M + 8 + 18 + 6, top, strCam, col);
                if (battOn) meter(fb, w, h, right - 18, top, battery, col);
                text(fb, w, h, M, bot, strSp, col);
                text(fb, w, h, right - PixelFont.width(strTs, 1), bot, strTs, col);
            default:
                // white (classic): "● REC" top-left, SP over battery top-right, timestamp bottom-left, cam bottom-right
                if (dot) text(fb, w, h, M, top, strDot, COL_REC);
                text(fb, w, h, M + 8, top, strRec, col);
                text(fb, w, h, right - 12, top, strSp, col);
                if (battOn) meter(fb, w, h, right - 18, top + GH + 4, battery, col);
                text(fb, w, h, M, bot, strTs, col);
                text(fb, w, h, right - PixelFont.width(strCam, 1), bot, strCam, col);
        }
    }

    // "PLAY >" at tape start (alpha simulated by skipping pixels)
    public function drawPlayFade(fb:flash.Vector<UInt>, w:Int, h:Int, alpha01:Float):Void {
        if (alpha01 <= 0) return;
        var level = Std.int(alpha01 * 16.0 + 0.5);
        if (level > 16) level = 16;
        var col = textColour(skin);
        // under the top OSD line, left, scale 2 — where a VCR puts its transport status
        PixelFont.blitDither(fb, w, h, M, M + GH + 6, strPlay, col, 2, level);
    }

    // ST_MAP only: fills the preallocated w x Renderer.STRIP_H strip (opaque OSD bar in the skin colour) and blits REC dot + timestamp + battery into it. Never touches fb.
    public function drawStrip(strip:flash.Vector<UInt>, w:Int, battery:Float, strobeFrame:Bool):Void {
        var sh = Renderer.STRIP_H;
        var n = w * sh;
        var bar = barColour(skin);
        for (i in 0...n) strip[i] = bar;                 // every entry written: the bar is opaque
        var col = textColour(skin);
        var dot = recVisible && blinkOn;
        // glyph rows 0..6 of the 8-row strip; row 7 stays bar colour
        if (dot) PixelFont.blit(strip, w, sh, 4, 0, strDot, COL_REC, 1);
        PixelFont.blit(strip, w, sh, 12, 0, strRec, col, 1);
        PixelFont.blit(strip, w, sh, 36, 0, strTs, col, 1);
        var battOn = battery >= 0.1 || !strobeFrame;
        if (battOn) meter(strip, w, sh, w - 4 - 18, 0, battery, col);
        else meter(strip, w, sh, w - 4 - 18, 0, 0.0, COL_STRIP_TEXT_DIM);
    }

    // ---------------------------------------------------------------- unit-internal accessors (tests, telemetry)

    public function timestamp():String return strTs;                 // the "DD.MM.YYYY HH:MM:SS" currently shown
    public function clockSeconds():Int return shownSec;             // seconds since midnight the shown clock reads

    // ---------------------------------------------------------------- internals

    static inline function textColour(skin:Int):UInt {
        return skin == 1 ? 0xFFF2C84A : (skin == 2 ? 0xFFC0F0C8 : 0xFFF4F4F4);
    }

    static inline function barColour(skin:Int):UInt {
        return skin == 1 ? 0xFF1C1200 : (skin == 2 ? 0xFF061410 : 0xFF141414);
    }

    // text with a 1-px drop shadow (legible over the yellow wallpaper)
    static inline function text(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, col:UInt):Void {
        PixelFont.blit(fb, w, h, x + 1, y + 1, s, COL_SHADOW, 1);
        PixelFont.blit(fb, w, h, x, y, s, col, 1);
    }

    // Battery meter, 18 x 7: a 16 x 7 outline, a 2 x 3 terminal nub, four 2-px segments inside.
    static function meter(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, battery:Float, col:UInt):Void {
        fill(fb, w, h, x + 1, y + 1, x + 17, y + 8, COL_SHADOW);   // shadow under the whole meter
        fill(fb, w, h, x, y, x + 16, y + 1, col);                  // top edge
        fill(fb, w, h, x, y + 6, x + 16, y + 7, col);              // bottom edge
        fill(fb, w, h, x, y + 1, x + 1, y + 6, col);               // left edge
        fill(fb, w, h, x + 15, y + 1, x + 16, y + 6, col);         // right edge
        fill(fb, w, h, x + 16, y + 2, x + 18, y + 5, col);         // nub
        fill(fb, w, h, x + 1, y + 1, x + 15, y + 6, COL_SHADOW);   // hollow interior
        var segs = battery <= 0 ? 0 : Std.int(battery * 4.0 + 0.999);
        if (segs > 4) segs = 4;
        for (k in 0...segs) {
            var sx = x + 2 + k * 3;
            fill(fb, w, h, sx, y + 2, sx + 2, y + 5, col);
        }
    }

    // clipped rectangle fill, [x0, x1) x [y0, y1)
    static function fill(fb:flash.Vector<UInt>, w:Int, h:Int, x0:Int, y0:Int, x1:Int, y1:Int, col:UInt):Void {
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > w) x1 = w;
        if (y1 > h) y1 = h;
        if (x0 >= x1 || y0 >= y1) return;
        var span = x1 - x0;
        var idx = y0 * w + x0;
        for (yy in y0...y1) {
            var i = idx;
            for (k in 0...span) { fb[i] = col; i++; }
            idx += w;
        }
    }

    // parse n ASCII digits of s starting at pos; -1 if any is not a digit
    static function digits(s:String, pos:Int, n:Int):Int {
        var v = 0;
        for (i in 0...n) {
            var c = StringTools.fastCodeAt(s, pos + i) - 48;
            if (c < 0 || c > 9) return -1;
            v = v * 10 + c;
        }
        return v;
    }

    static function daysIn(m:Int, y:Int):Int {
        if (m == 2) return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28;
        return (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31;
    }

    function nextDay():Void {
        day++;
        if (day > daysIn(month, year)) {
            day = 1;
            month++;
            if (month > 12) { month = 1; year++; }
        }
    }

    // Rebuild the timestamp for the current clock (the once-per-second allocation).
    function rebuild():Void {
        var total = startSec + skipTotal + Std.int(elapsedMs / 1000);
        if (total < 0) total = 0;
        if (total >= DAY) total = DAY - 1;
        shownSec = total;
        var hh = Std.int(total / 3600);
        var mm = Std.int((total - hh * 3600) / 60);
        var ss = total - hh * 3600 - mm * 60;
        strTs = two(day) + "." + two(month) + "." + year + " " + two(hh) + ":" + two(mm) + ":" + two(ss);
    }

    static function two(n:Int):String {
        return n < 10 ? "0" + n : "" + n;
    }
}
