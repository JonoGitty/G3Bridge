// Billboard sprites for the two entities (CONTRACT §2). fp class.
// SKELETON: signatures exact; draw() draws nothing.
class SpritePass {
    public var drawn:Int;                               // sprites drawn this frame (telemetry)
    public var tSpr:Int;

    var textures:Textures;

    public function new(textures:Textures):Void {
        this.textures = textures;
        drawn = 0;
        tSpr = 0;
    }

    // Draws alive entities as billboards into r.fb, sorted far to near, clipped per column against hits.dist. frameSeed re-noises the Watcher.
    public function draw(r:Renderer, hits:RayHits, rc:Raycaster, px:Float, py:Float, ang:Float, watcher:Watcher, hound:Hound, lightOffset:Int, frameSeed:Int, plain:Bool):Void {
        drawn = 0; // SKELETON
    }
}
