// Keyboard/mouse state (CONTRACT §2, DESIGN §8). fp class.
//
// A 256-entry key table: bit 0 = held, bit 1 = went down since the last endFrame()
// (the pressed edge). Edges are recorded in a small list so endFrame() clears only
// what was set (no 256-wide sweep per frame). Injected keys (rc / tests) carry a
// hold time in holdMs and are released by update(dt).
//
// onGesture is invoked SYNCHRONOUSLY inside the KEY_DOWN and CLICK listeners, before
// they return: Flash Player only allows Stage.displayState = FULL_SCREEN during the
// dispatch of the user's own event. injectKey never calls it (not a user gesture).
// Key-repeat KEY_DOWN events (the key already held) neither set a new edge nor fire
// the gesture hook.
import flash.display.Stage;
import flash.events.Event;
import flash.events.FocusEvent;
import flash.events.KeyboardEvent;
import flash.events.MouseEvent;

class Input {
    public static inline var K_UP = 38; public static inline var K_DOWN = 40; public static inline var K_LEFT = 37; public static inline var K_RIGHT = 39;
    public static inline var K_SHIFT = 16; public static inline var K_SPACE = 32; public static inline var K_TAB = 9; public static inline var K_ENTER = 13; public static inline var K_ESC = 27;
    public static inline var K_M = 77; public static inline var K_W = 87; public static inline var K_S = 83; public static inline var K_A = 65; public static inline var K_D = 68; public static inline var K_F = 70; public static inline var K_P = 80;
    public static inline var K_1 = 49;   // ..K_6 = 54
    static inline var B_DOWN = 1;
    static inline var B_PRESSED = 2;
    static inline var EDGE_MAX = 32;                    // distinct pressed edges remembered per frame
    public var fullscreen:Bool;                         // set by Main from Display
    public var clicked:Bool;                            // a mouse click happened since endFrame()
    public var anyKey:Bool;                             // any key went down since endFrame()
    public var lastKeyCode:Int;
    // Synchronous gesture hook: invoked INSIDE the KEY_DOWN and CLICK listeners, before they return, with the keyCode (or -1 for a click).
    // Flash only permits Stage.displayState = FULL_SCREEN during the dispatch of the user's own event, so this callback is the ONLY place
    // Display.enterFullscreen() / Bench.runFullscreenArm() may be called. Main assigns it once at start (no per-frame allocation).
    public var onGesture:Int->Void;

    var stage:Stage;
    var keys:haxe.ds.Vector<Int>;                       // 256 entries: bit 0 = down, bit 1 = pressed this frame
    var holdMs:haxe.ds.Vector<Int>;                     // 256 entries: injected hold remaining, ms
    var edges:haxe.ds.Vector<Int>;                      // codes whose pressed bit is set this frame
    var edgeCount:Int;
    var injected:Int;                                   // number of codes with holdMs > 0 (skips the sweep when 0)

    // listens KEY_DOWN/KEY_UP/CLICK on the stage; DEACTIVATE/FOCUS_OUT/MOUSE_LEAVE call clear() — clear only, none of these pause (Main pauses on Event.DEACTIVATE alone)
    public function new(stage:Stage):Void {
        this.stage = stage;
        keys = new haxe.ds.Vector<Int>(256);
        holdMs = new haxe.ds.Vector<Int>(256);
        for (i in 0...256) { keys[i] = 0; holdMs[i] = 0; }
        edges = new haxe.ds.Vector<Int>(EDGE_MAX);
        for (i in 0...EDGE_MAX) edges[i] = 0;
        edgeCount = 0;
        injected = 0;
        fullscreen = false;
        clicked = false;
        anyKey = false;
        lastKeyCode = 0;
        onGesture = null;
        if (stage != null) {
            stage.addEventListener(KeyboardEvent.KEY_DOWN, onKeyDown);
            stage.addEventListener(KeyboardEvent.KEY_UP, onKeyUp);
            stage.addEventListener(MouseEvent.CLICK, onClick);
            stage.addEventListener(Event.DEACTIVATE, onLost);
            stage.addEventListener(FocusEvent.FOCUS_OUT, onLost);
            stage.addEventListener(Event.MOUSE_LEAVE, onLost);
        }
    }

    // --- listeners ---------------------------------------------------------------

    function onKeyDown(e:KeyboardEvent):Void {
        var code:Int = e.keyCode;
        if (code < 0 || code > 255) return;
        var k = keys[code];
        if ((k & B_DOWN) != 0) return;                  // key repeat: no new edge, no gesture
        press(code);
        holdMs[code] = 0;
        if (onGesture != null) onGesture(code);         // synchronous: still inside the user's event dispatch
    }

    function onKeyUp(e:KeyboardEvent):Void {
        var code:Int = e.keyCode;
        if (code < 0 || code > 255) return;
        keys[code] &= ~B_DOWN;
        if (holdMs[code] > 0) { holdMs[code] = 0; if (injected > 0) injected--; }
    }

    function onClick(e:MouseEvent):Void {
        clicked = true;
        if (onGesture != null) onGesture(-1);           // synchronous: still inside the user's event dispatch
    }

    function onLost(e:Event):Void {
        clear();
    }

    // marks code held + pressed-edge, records anyKey/lastKeyCode. The pressed bit is set ONLY when the edge is recorded,
    // so a full edge list (a burst of rc key injections) leaves the key merely held and never a stuck edge that endFrame() cannot clear.
    function press(code:Int):Void {
        var k = keys[code] | B_DOWN;
        if ((k & B_PRESSED) == 0 && edgeCount < EDGE_MAX) { edges[edgeCount] = code; edgeCount++; k |= B_PRESSED; }
        keys[code] = k;
        anyKey = true;
        lastKeyCode = code;
    }

    // --- queries -----------------------------------------------------------------

    public function down(code:Int):Bool {
        if (code < 0 || code > 255) return false;
        return (keys[code] & B_DOWN) != 0;
    }

    // went down since the last endFrame()
    public function pressed(code:Int):Bool {
        if (code < 0 || code > 255) return false;
        return (keys[code] & B_PRESSED) != 0;
    }

    // clears edge flags
    public function endFrame():Void {
        var n = edgeCount;
        var ed = edges;
        var ks = keys;
        for (i in 0...n) ks[ed[i]] &= ~B_PRESSED;
        edgeCount = 0;
        clicked = false;
        anyKey = false;
    }

    // clears everything (stuck-key guard)
    public function clear():Void {
        for (i in 0...256) { keys[i] = 0; holdMs[i] = 0; }
        edgeCount = 0;
        injected = 0;
        clicked = false;
        anyKey = false;
    }

    // up/W = 1, down/S = -1
    public function fwd():Int {
        var f = 0;
        if (down(K_UP) || down(K_W)) f += 1;
        if (down(K_DOWN) || down(K_S)) f -= 1;
        return f;
    }

    // right = 1, left = -1
    public function turn():Int {
        var t = 0;
        if (down(K_RIGHT)) t += 1;
        if (down(K_LEFT)) t -= 1;
        return t;
    }

    // D = 1, A = -1 (windowed only; letters never arrive in fullscreen)
    public function strafe():Int {
        var s = 0;
        if (down(K_D)) s += 1;
        if (down(K_A)) s -= 1;
        return s;
    }

    // shift
    public function run():Bool {
        return down(K_SHIFT);
    }

    // pressed(TAB) || pressed(SPACE) || pressed(M)
    public function mapToggle():Bool {
        return pressed(K_TAB) || pressed(K_SPACE) || pressed(K_M);
    }

    // pressed(F) || pressed(ENTER) — an OSD/telemetry edge only; the fullscreen entry itself happens inside onGesture, never from the frame loop (SecurityError #2152)
    public function fullscreenKey():Bool {
        return pressed(K_F) || pressed(K_ENTER);
    }

    // pressed(P)
    public function snapKey():Bool {
        return pressed(K_P);
    }

    // 1..6 if pressed, else 0
    public function digit():Int {
        for (c in K_1...(K_1 + 6)) if (pressed(c)) return c - K_1 + 1;
        return 0;
    }

    // rc/test: sets down for holdMs (Main ticks it via update(dt)). Never calls onGesture (not a user gesture).
    public function injectKey(code:Int, holdMs:Int):Void {
        if (code < 0 || code > 255) return;
        if (holdMs < 1) holdMs = 1;
        if (this.holdMs[code] == 0) injected++;         // a fresh injection; a re-injection just extends the hold
        press(code);
        this.holdMs[code] = holdMs;
    }

    // expires injected keys
    public function update(dt:Float):Void {
        if (injected <= 0) return;
        var ms = Std.int(dt * 1000.0);
        if (ms < 1) ms = 1;
        var hm = holdMs;
        var ks = keys;
        var left = 0;
        for (i in 0...256) {
            var h = hm[i];
            if (h <= 0) continue;
            h -= ms;
            if (h <= 0) { hm[i] = 0; ks[i] &= ~B_DOWN; }
            else { hm[i] = h; left++; }
        }
        injected = left;
    }
}
