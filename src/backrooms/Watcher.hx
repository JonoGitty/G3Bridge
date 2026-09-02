// The stalker (CONTRACT §1, DESIGN §5). Core class: no flash.* imports.
// SKELETON: signatures exact; update() calls super and does nothing else; relocate() stays.
class Watcher extends Entity {
    public static inline var S_IDLE = 0;                // standing at its post
    public static inline var S_APPROACH = 1;            // R <= 2, walking in at 0.6 cells/s
    public var targetRadius:Float;                      // R = lerp(14, 4, d.D), minus the unseen shrink, floor 3 at D > 0.9
    public var relocateTimer:Float;                     // counts down; relocation when <= 0 (4..9 s, halved in DARK)
    public var unseenSeconds:Float;
    public var lookedAtSeconds:Float;                   // within 10 deg of centre
    public var relocations:Int;
    public var relocated:Bool;                          // true for exactly the update() in which it relocated

    public function new():Void {
        super(Entity.K_WATCHER);
        height = 0.95;
        targetRadius = 14.0;
        relocateTimer = 0.0;
        unseenSeconds = 0.0;
        lookedAtSeconds = 0.0;
        relocations = 0;
        relocated = false;
    }

    override public function update(dt:Float, d:Director):Void {
        super.update(dt, d);
        relocated = false; // SKELETON
    }

    // choose and move to a new post: a walkable cell at distance targetRadius +/- 1 not in view, preferring dead ends / corridor ends
    // aligned with the facing +/- 30 deg; closer = true forces distance <= current dist - 1 (blackout). Returns false if none found (stays).
    public function relocate(d:Director, closer:Bool):Bool {
        return false; // SKELETON
    }
}
