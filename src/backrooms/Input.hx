// Keyboard/mouse state (CONTRACT §2, DESIGN §8). fp class.
// SKELETON: constructor allocates the 256-entry state vector; no listeners are attached and every query reads "nothing held".
import flash.display.Stage;

class Input {
    public static inline var K_UP = 38; public static inline var K_DOWN = 40; public static inline var K_LEFT = 37; public static inline var K_RIGHT = 39;
    public static inline var K_SHIFT = 16; public static inline var K_SPACE = 32; public static inline var K_TAB = 9; public static inline var K_ENTER = 13; public static inline var K_ESC = 27;
    public static inline var K_M = 77; public static inline var K_W = 87; public static inline var K_S = 83; public static inline var K_A = 65; public static inline var K_D = 68; public static inline var K_F = 70; public static inline var K_P = 80;
    public static inline var K_1 = 49;   // ..K_6 = 54
    public var fullscreen:Bool;                         // set by Main from Display
    public var clicked:Bool;                            // a mouse click happened since endFrame()
    public var anyKey:Bool;                             // any key went down since endFrame()
    public var lastKeyCode:Int;

    var stage:Stage;
    var keys:haxe.ds.Vector<Int>;                       // 256 entries: bit 0 = down, bit 1 = pressed this frame
    var holdMs:haxe.ds.Vector<Int>;                     // 256 entries: injected hold remaining, ms

    // listens KEY_DOWN/KEY_UP/CLICK on the stage; DEACTIVATE/FOCUS_OUT/MOUSE_LEAVE call clear()
    public function new(stage:Stage):Void {
        this.stage = stage;
        keys = new haxe.ds.Vector<Int>(256);
        holdMs = new haxe.ds.Vector<Int>(256);
        for (i in 0...256) { keys[i] = 0; holdMs[i] = 0; }
        fullscreen = false;
        clicked = false;
        anyKey = false;
        lastKeyCode = 0;
        // SKELETON: listeners not attached
    }

    public function down(code:Int):Bool {
        return false; // SKELETON
    }

    // went down since the last endFrame()
    public function pressed(code:Int):Bool {
        return false; // SKELETON
    }

    // clears edge flags
    public function endFrame():Void {
        clicked = false;
        anyKey = false;
    }

    // clears everything (stuck-key guard)
    public function clear():Void {
        for (i in 0...256) { keys[i] = 0; holdMs[i] = 0; }
        clicked = false;
        anyKey = false;
    }

    // up/W = 1, down/S = -1
    public function fwd():Int {
        return 0; // SKELETON
    }

    // right = 1, left = -1
    public function turn():Int {
        return 0; // SKELETON
    }

    // D = 1, A = -1 (windowed only; letters never arrive in fullscreen)
    public function strafe():Int {
        return 0; // SKELETON
    }

    // shift
    public function run():Bool {
        return false; // SKELETON
    }

    // pressed(TAB) || pressed(SPACE) || pressed(M)
    public function mapToggle():Bool {
        return false; // SKELETON
    }

    // pressed(F) || pressed(ENTER)
    public function fullscreenKey():Bool {
        return false; // SKELETON
    }

    // pressed(P)
    public function snapKey():Bool {
        return false; // SKELETON
    }

    // 1..6 if pressed, else 0
    public function digit():Int {
        return 0; // SKELETON
    }

    // rc/test: sets down for holdMs (Main ticks it via update(dt))
    public function injectKey(code:Int, holdMs:Int):Void {
        // SKELETON
    }

    // expires injected keys
    public function update(dt:Float):Void {
        // SKELETON
    }
}
