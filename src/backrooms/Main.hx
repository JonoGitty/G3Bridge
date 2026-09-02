// Entry point and frame loop (CONTRACT §2, §3). fp class.
// SKELETON: the constructor builds every subsystem (so the fixed build command types the whole project);
// the frame loop presents a black frame and nothing else.
import flash.display.Sprite;
import flash.events.Event;
import flash.events.UncaughtErrorEvent;

class Main extends Sprite {
    public static inline var ST_BOOT = 0; public static inline var ST_BENCH = 1; public static inline var ST_CARD = 2; public static inline var ST_PLAY = 3;
    public static inline var ST_MAP = 4; public static inline var ST_DYING = 5; public static inline var ST_ENDS = 6; public static inline var ST_PAUSED = 7;
    public var state:Int;
    public var prevState:Int;                           // for PAUSED resume

    // subsystems — private; implementer may rename
    var save:Save.SaveData;
    var tape:Tape;
    var world:World;
    var player:Player;
    var director:Director;
    var quality:Quality;
    var bot:Bot;
    var raycaster:Raycaster;
    var hits:RayHits;
    var mapMemory:MapMemory;
    var textures:Textures;
    var renderer:Renderer;
    var spritePass:SpritePass;
    var hud:Hud;
    var cards:Cards;
    var camcorder:Camcorder;
    var mapPaper:MapPaper;
    var audio:AudioBus;
    var input:Input;
    var display:Display;
    var bench:Bench;
    var rng:Rng;                                        // Main's own frame-seed stream (TAG_DIRECTOR, 1)
    var frame:Int;
    var last:Int;

    // Lib.current.addChild(new Main())
    public static function main():Void {
        flash.Lib.current.addChild(new Main());
    }

    // Params.init, Telemetry.init, Save.load, constructs every subsystem, uncaughtErrorEvents listener, ENTER_FRAME listener, DEACTIVATE/ACTIVATE
    public function new():Void {
        super();
        var cur = flash.Lib.current;
        var stg = cur.stage;
        Params.init(cur.loaderInfo);
        Telemetry.init(cur.loaderInfo.url);
        save = Save.load();
        state = ST_BOOT;
        prevState = ST_BOOT;
        frame = 0;
        last = flash.Lib.getTimer();

        tape = Tape.make(save.tapeCount + 1, save.salt);
        world = new World(tape.seed);
        player = new Player(tape.startX, tape.startY, tape.startAng);
        director = new Director(world, player, tape);
        quality = new Quality(save.rung, save.maxRung);
        bot = new Bot(tape.seed);
        raycaster = new Raycaster(Renderer.W1);
        hits = new RayHits(Renderer.W1);
        mapMemory = new MapMemory();
        textures = new Textures();
        renderer = new Renderer(textures);
        spritePass = new SpritePass(textures);
        hud = new Hud();
        cards = new Cards();
        camcorder = new Camcorder();
        mapPaper = new MapPaper();
        audio = new AudioBus();
        input = new Input(stg);
        display = new Display(stg);
        bench = new Bench(stg, display, renderer, camcorder, spritePass, raycaster, world, textures);
        rng = new Rng(Rng.hash3(tape.seed, Rng.TAG_DIRECTOR, 1));
        // SKELETON: touch the classes nothing above reaches yet, so the fixed build command types the whole project
        PixelFont.width("REC", 1);
        Path.bfs(world, 0, 0, 0, 0, director.hound.path);

        display.attach(renderer.bd, renderer.tier);
        addChild(display.bitmap);
        cur.loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onUncaught);
        addEventListener(Event.ENTER_FRAME, onFrame);
        // SKELETON: DEACTIVATE/ACTIVATE not yet handled
    }

    // logs bk=state
    public function setState(s:Int):Void {
        prevState = state;
        state = s; // SKELETON: not logged
    }

    // Tape.make, world/textures/camcorder/paper/map/director rebuilt (reusing buffers), player placed, bed started
    public function startTape(index:Int):Void {
        // SKELETON
    }

    // "key <code> <holdms>", "snap [tag]", "state", "seed <n>", "die [kind]", "map", "fs", "rung <n>", "tele", "blackout", "hound", "relocate"
    public function onRC(line:String):Void {
        // SKELETON
    }

    function onFrame(e:Event):Void {
        // SKELETON: present a black frame
        var now = flash.Lib.getTimer();
        last = now;
        renderer.present();
        frame++;
    }

    function onUncaught(e:UncaughtErrorEvent):Void {
        // SKELETON
    }
}
