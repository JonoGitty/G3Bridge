// Tape card, TAPE ENDS, pause and NO SIGNAL screens (CONTRACT §2). fp class.
// SKELETON: signatures exact; nothing is drawn.
class Cards {
    public function new():Void {}

    // black -> blue field 0.4 s -> label with jitter/wobble; "CLICK TO START" when firstRun
    public function drawCard(fb:flash.Vector<UInt>, w:Int, h:Int, t:Tape, seconds:Float, firstRun:Bool):Void {
        // SKELETON
    }

    // "TAPE ENDS" / "TAPE DAMAGED" / "BATTERY", centred, scale 3
    public function drawEnds(fb:flash.Vector<UInt>, w:Int, h:Int, seconds:Float, caption:String):Void {
        // SKELETON
    }

    // dims the frame (every other pixel) and blits "|| PAUSE"
    public function drawPause(fb:flash.Vector<UInt>, w:Int, h:Int):Void {
        // SKELETON
    }

    // blue field for frames 0-1, then "NO SIGNAL" top-left
    public function drawNoSignal(fb:flash.Vector<UInt>, w:Int, h:Int, frame:Int):Void {
        // SKELETON
    }
}
