// Camcorder on-screen display (CONTRACT §2). fp class.
// SKELETON: signatures exact; nothing is drawn.
class Hud {
    public var recVisible:Bool;                         // Main clears it for one frame on EV_WATCHER_RELOCATED
    public var skin:Int;

    public function new():Void {
        recVisible = true;
        skin = 0;
    }

    // skin, date, camName
    public function setTape(t:Tape):Void {
        skin = t.hudSkin; // SKELETON
    }

    // advances the displayed clock; rebuilds strings once per second (the only allocation)
    public function tick(dt:Float, playSeconds:Float, tsSkip:Int):Void {
        // SKELETON
    }

    // REC dot (1 Hz), "SP", battery bars, timestamp, camName per skin
    public function draw(fb:flash.Vector<UInt>, w:Int, h:Int, battery:Float, strobeFrame:Bool):Void {
        // SKELETON
    }

    // "PLAY >" at tape start (alpha simulated by skipping pixels)
    public function drawPlayFade(fb:flash.Vector<UInt>, w:Int, h:Int, alpha01:Float):Void {
        // SKELETON
    }
}
