// On-device benchmark (CONTRACT §2, DESIGN §11). fp class.
// SKELETON: constructor stores its collaborators and allocates a blank fb; both runs call onDone at once with default results.
import flash.display.Stage;

typedef BenchResult = { maxRung:Int, fsHw:Int, presentW:Float, presentFs:Float, presentFsRect:Float };

class Bench {
    public static inline var FRAMES = 60;
    public var arm:String;                              // current arm name (for the OSD)

    var stage:Stage;
    var display:Display;
    var renderer:Renderer;
    var cam:Camcorder;
    var sprites:SpritePass;
    var rc:Raycaster;
    var world:World;
    var textures:Textures;
    var blank:flash.Vector<UInt>;                       // blank fb, W1*H1

    public function new(stage:Stage, display:Display, renderer:Renderer, cam:Camcorder, sprites:SpritePass, rc:Raycaster, world:World, textures:Textures):Void {
        this.stage = stage;
        this.display = display;
        this.renderer = renderer;
        this.cam = cam;
        this.sprites = sprites;
        this.rc = rc;
        this.world = world;
        this.textures = textures;
        blank = new flash.Vector<UInt>(Renderer.W1 * Renderer.H1, true);
        arm = "";
    }

    // sets stage.frameRate = 100; runs the windowed arms; restores frameRate; calls onDone with fsHw = -1
    public function runWindowed(onDone:BenchResult->Void):Void {
        // SKELETON: no arms run
        onDone({ maxRung: 2, fsHw: -1, presentW: 0.0, presentFs: 0.0, presentFsRect: 0.0 });
    }

    // after a user gesture: enters fullscreen with hwRect, 60 frames, exits, enters without, 60 frames, exits; fills presentFs*/fsHw
    public function runFullscreen(onDone:BenchResult->Void):Void {
        // SKELETON: no arms run
        onDone({ maxRung: 2, fsHw: -1, presentW: 0.0, presentFs: 0.0, presentFsRect: 0.0 });
    }
}
