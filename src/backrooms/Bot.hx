// Soak-test auto-walker (CONTRACT §1). Core class: no flash.* imports.
// SKELETON: signatures exact; update() leaves the inputs at rest.
class Bot {
    public var fwd:Int;
    public var turn:Int;
    public var run:Bool;
    public var wantMapToggle:Bool;                      // every 45 s, held open 3 s

    var rng:Rng;                                        // hash3(seed, TAG_BOT, 0)

    public function new(seed:Int):Void {
        rng = new Rng(Rng.hash3(seed, Rng.TAG_BOT, 0));
        fwd = 0;
        turn = 0;
        run = false;
        wantMapToggle = false;
    }

    // sets fwd/turn/run/wantMapToggle for this frame
    public function update(dt:Float, player:Player, world:World):Void {
        // SKELETON
    }
}
