// On-device benchmark (CONTRACT §2, DESIGN §1/§11). fp class.
//
// Runs before the game, driven by its own ENTER_FRAME listener on the stage, with
// stage.frameRate = 100 so every present is measured uncapped. Every arm is FRAMES
// frames after a short uncounted settle; each is reported as
//   bk=bench&arm=<name>&frames=60&ms_work=&ms_frame=&mspf_work=&mspf_frame=
// where ms_work brackets only the arm's own code (getTimer) and ms_frame is
// ENTER_FRAME-to-ENTER_FRAME over the same frames (present + player overhead).
//
// Windowed arms (runWindowed): the present matrix (T1/T0 at LOW and MEDIUM, smoothing
// on/off), post_t1, the five ray arms on a fixed 60-frame walk through a fixed 5x5 chunk
// region of seed 1234 (its own World, World.generateNow), sprites_t1, mapink, glitch_t1.
// qLow is decided after the present matrix and the chosen quality is used for the rest.
// Fullscreen arms (runFullscreenArm): each entered from its OWN user gesture via
// Main.onGesture (Flash refuses displayState = FULL_SCREEN outside a gesture dispatch):
// present_fs_rect (hwRect, the first card click) and present_fs_norect (Space).
//
// Allocation: the bench runs before the game and may allocate; the mapink collaborators
// are released after the windowed run and the scene (blank fbs, the bench world, player,
// hits, entities) once the run is final, so nothing of the bench outlives it but numbers.
import flash.display.Stage;
import flash.events.Event;

typedef BenchResult = { maxRungWin:Int, maxRungFs:Int, fsHw:Int, qLow:Int, presentW:Float, presentFs:Float, presentFsRect:Float };

class Bench {
    public static inline var FRAMES = 60;               // every arm, ray arms included (there is no 90-frame arm)
    public static inline var GESTURE_NONE = 0; public static inline var GESTURE_FS_RECT = 1; public static inline var GESTURE_FS_NORECT = 2;
    public var needGesture:Int;                         // GESTURE_* the bench is waiting for (Cards shows the matching prompt); GESTURE_NONE when done or under ?nofs=1
    public var arm:String;                              // current arm name (for the OSD)
    // Extra (platform-internal): the T0 windowed present per frame, so Main can scale a T0 estimate for fullscreen where only T1 was measured.
    public var presentW0:Float;

    static inline var SETTLE = 6;                       // uncounted warm-up frames per arm (tier/quality changes settle)
    static inline var SETTLE_FS = 12;                   // fullscreen entry is slower to settle (counted from the first fullscreen frame)
    static inline var FS_WAIT_MAX = 200;                // frames to wait for the FULL_SCREEN transition before the arm is reported invalid
    static inline var BENCH_SEED = 1234;
    static inline var REGION = 2;                       // 5x5 chunks: -2..2
    static inline var STEP_DT = 0.05;                   // fixed dt of the ray-arm walk (20 fps equivalent)

    // arm indices (order = run order)
    static inline var A_PRESENT_T1 = 0;
    static inline var A_PRESENT_T1_NOSMOOTH = 1;
    static inline var A_PRESENT_T1_SMOOTH_MEDIUM = 2;
    static inline var A_PRESENT_T1_NOSMOOTH_MEDIUM = 3;
    static inline var A_PRESENT_T0 = 4;
    static inline var A_PRESENT_T0_SMOOTH_MEDIUM = 5;
    static inline var A_POST_T1 = 6;
    static inline var A_RAY_T1_F0_160 = 7;
    static inline var A_RAY_T1_F1_160 = 8;
    static inline var A_RAY_T1_F1_320 = 9;
    static inline var A_RAY_T1_F2_320 = 10;
    static inline var A_RAY_T0_F0_128 = 11;
    static inline var A_SPRITES_T1 = 12;
    static inline var A_MAPINK = 13;
    static inline var A_GLITCH_T1 = 14;
    static inline var A_FS_RECT = 15;
    static inline var A_FS_NORECT = 16;
    static inline var N_ARMS = 17;

    var stage:Stage;
    var display:Display;
    var renderer:Renderer;
    var cam:Camcorder;
    var sprites:SpritePass;
    var rc:Raycaster;
    var world:World;                                    // the game's world (kept for the contract; the ray arms use benchWorld)
    var textures:Textures;
    var blank1:flash.Vector<UInt>;                      // blank fb, W1*H1
    var blank0:flash.Vector<UInt>;                      // blank fb, W0*H0

    var names:Array<String>;
    var msWork:haxe.ds.Vector<Float>;
    var msFrame:haxe.ds.Vector<Float>;
    var valid:haxe.ds.Vector<Bool>;

    var running:Bool;
    var cur:Int;                                        // current arm index
    var lastArm:Int;                                    // the run ends after this arm
    var settle:Int;
    var n:Int;                                          // counted frames done in the current arm
    var t0:Int;                                         // getTimer at the first counted frame
    var workAcc:Int;
    var frameIdx:Int;                                   // frames since the arm began (drives the walk and the frame seed)
    var floorMode:Int;
    var fsAtStart:Bool;
    var fsSeen:Bool;                                    // fullscreen arms: the transition has landed (settle starts here)
    var fsWait:Int;                                     // frames spent waiting for it
    var savedFrameRate:Float;
    var onDoneCb:BenchResult->Void;
    var result:BenchResult;
    var qLow:Int;
    var presentW:Float;
    var windowedDone:Bool;

    // ray-arm scene
    var benchWorld:World;
    var benchTape:Tape;
    var player:Player;
    var hits:RayHits;
    var watcher:Watcher;
    var hound:Hound;
    var startX:Float;
    var startY:Float;
    var startAng:Float;

    // mapink collaborators (allocated for the run, released after)
    var mem:MapMemory;
    var paper:MapPaper;

    public function new(stage:Stage, display:Display, renderer:Renderer, cam:Camcorder, sprites:SpritePass, rc:Raycaster, world:World, textures:Textures):Void {
        this.stage = stage;
        this.display = display;
        this.renderer = renderer;
        this.cam = cam;
        this.sprites = sprites;
        this.rc = rc;
        this.world = world;
        this.textures = textures;
        blank1 = new flash.Vector<UInt>(Renderer.W1 * Renderer.H1, true);
        blank0 = new flash.Vector<UInt>(Renderer.W0 * Renderer.H0, true);
        fillBlank(blank1, Renderer.W1, Renderer.H1);
        fillBlank(blank0, Renderer.W0, Renderer.H0);
        names = [
            "present_t1", "present_t1_nosmooth", "present_t1_smooth_medium", "present_t1_nosmooth_medium",
            "present_t0", "present_t0_smooth_medium", "post_t1",
            "ray_t1_f0_160", "ray_t1_f1_160", "ray_t1_f1_320", "ray_t1_f2_320", "ray_t0_f0_128",
            "sprites_t1", "mapink", "glitch_t1", "present_fs_rect", "present_fs_norect"
        ];
        msWork = new haxe.ds.Vector<Float>(N_ARMS);
        msFrame = new haxe.ds.Vector<Float>(N_ARMS);
        valid = new haxe.ds.Vector<Bool>(N_ARMS);
        for (i in 0...N_ARMS) { msWork[i] = 0.0; msFrame[i] = 0.0; valid[i] = false; }
        arm = "";
        needGesture = GESTURE_NONE;
        running = false;
        cur = -1;
        lastArm = -1;
        settle = 0;
        n = 0;
        t0 = 0;
        workAcc = 0;
        frameIdx = 0;
        floorMode = 1;
        fsAtStart = false;
        fsSeen = false;
        fsWait = 0;
        savedFrameRate = 30;
        onDoneCb = null;
        qLow = 0;
        presentW = 0.0;
        presentW0 = 0.0;
        windowedDone = false;
        result = { maxRungWin: 2, maxRungFs: 2, fsHw: -1, qLow: 0, presentW: 0.0, presentFs: 0.0, presentFsRect: 0.0 };
        benchWorld = null;
        benchTape = null;
        player = null;
        hits = null;
        watcher = null;
        hound = null;
        startX = 16.5;
        startY = 16.5;
        startAng = 0.3;
        mem = null;
        paper = null;
    }

    // a grey field with a faint checker so smoothing has real edges to interpolate; content never changes the present cost, but a flat field looks like a hang
    static function fillBlank(v:flash.Vector<UInt>, w:Int, h:Int):Void {
        var i = 0;
        for (y in 0...h) {
            var dark:UInt = ((y >> 3) & 1) == 0 ? 0xFF1C1A16 : 0xFF221F1A;
            for (x in 0...w) {
                v[i] = (((x >> 3) & 1) == 0) ? dark : 0xFF2A2620;
                i++;
            }
        }
    }

    // --- public runs -----------------------------------------------------------------

    // sets stage.frameRate = 100; runs the windowed arms; restores frameRate; calls onDone with fsHw = -1, maxRungFs = maxRungWin
    public function runWindowed(onDone:BenchResult->Void):Void {
        if (running) return;
        onDoneCb = onDone;
        prepareScene();
        savedFrameRate = stage.frameRate;
        stage.frameRate = 100;
        windowedDone = false;
        needGesture = GESTURE_NONE;
        cur = A_PRESENT_T1;
        lastArm = A_GLITCH_T1;
        beginArm(cur, SETTLE);
        running = true;
        stage.addEventListener(Event.ENTER_FRAME, onFrame);
    }

    // Fullscreen is measured in TWO arms, each armed by its own user gesture and each called from Input.onGesture (never from the loop, and never
    // enter/exit/enter in one call — a second entry needs a fresh gesture): which = GESTURE_FS_RECT enters with hwRect (armed by the first card
    // click; the card says CLICK TO START), runs FRAMES frames, exits; which = GESTURE_FS_NORECT enters without the rect (armed by Space; the card
    // says PRESS SPACE), runs FRAMES frames, exits. After the second arm onDone gets presentFs*/fsHw/maxRungFs filled in.
    public function runFullscreenArm(which:Int, onDone:BenchResult->Void):Void {
        if (running) return;
        if (which != needGesture || which == GESTURE_NONE) return;
        onDoneCb = onDone;
        needGesture = GESTURE_NONE;
        display.hwRect = (which == GESTURE_FS_RECT);
        var ok = display.enterFullscreen();             // legal here: we are inside the user's own event dispatch
        if (!ok) {
            // refused: nothing fullscreen can be measured this run; finish on the windowed numbers
            finishFullscreen();
            return;
        }
        cur = (which == GESTURE_FS_RECT) ? A_FS_RECT : A_FS_NORECT;
        lastArm = cur;
        savedFrameRate = stage.frameRate;
        stage.frameRate = 100;
        beginArm(cur, SETTLE_FS);
        running = true;
        stage.addEventListener(Event.ENTER_FRAME, onFrame);
    }

    // Extra (platform-internal): an unattended run (?auto / ?soak) that never gets the gesture the fullscreen arms need gives up on them
    // after a timeout; the windowed numbers become final (fsHw = -1, maxRungFs = maxRungWin) and bk=benchdone is reported.
    public function abandonFullscreen(onDone:BenchResult->Void):Void {
        if (running || needGesture == GESTURE_NONE) return;
        onDoneCb = onDone;
        finishFullscreen();
    }

    // --- scene ------------------------------------------------------------------------

    function prepareScene():Void {
        if (blank1 == null) { blank1 = new flash.Vector<UInt>(Renderer.W1 * Renderer.H1, true); fillBlank(blank1, Renderer.W1, Renderer.H1); }
        if (blank0 == null) { blank0 = new flash.Vector<UInt>(Renderer.W0 * Renderer.H0, true); fillBlank(blank0, Renderer.W0, Renderer.H0); }
        if (benchTape == null) benchTape = Tape.make(1, BENCH_SEED);
        if (!textures.built) textures.build(benchTape);
        if (benchWorld == null) {
            benchWorld = new World(BENCH_SEED);
            for (cy in -REGION...(REGION + 1)) for (cx in -REGION...(REGION + 1)) benchWorld.generateNow(cx, cy);
            // start on the walkable (non-pit) cell of chunk (0,0) nearest its centre
            var bestD = 0x7FFFFFFF;
            var bx = 16; var by = 16;
            for (y in 0...32) for (x in 0...32) {
                var c = benchWorld.cell(x, y);
                if (!Cells.walkable(c) || Cells.type(c) == Cells.PIT) continue;
                var dx = x - 16; var dy = y - 16;
                var d = dx * dx + dy * dy;
                if (d < bestD) { bestD = d; bx = x; by = y; }
            }
            startX = bx + 0.5;
            startY = by + 0.5;
        }
        if (player == null) player = new Player(startX, startY, startAng);
        if (hits == null) hits = new RayHits(Renderer.W1);
        if (watcher == null) watcher = new Watcher();
        if (hound == null) hound = new Hound();
    }

    // the run is final: drop everything but the numbers (~600 KB: two blank fbs, the 25-chunk bench world, player, hits, entities)
    function releaseScene():Void {
        blank0 = null;
        blank1 = null;
        benchWorld = null;
        benchTape = null;
        player = null;
        hits = null;
        watcher = null;
        hound = null;
        mem = null;
        paper = null;
    }

    function resetPath():Void {
        player.placeAt(startX, startY, startAng);
        frameIdx = 0;
    }

    // one step of the fixed walk: straight, a right turn, a left turn, straight (deterministic given the world and STEP_DT)
    function stepPath():Void {
        var k = frameIdx;
        var turn = 0;
        if (k >= 20 && k < 35) turn = 1;
        else if (k >= 35 && k < 50) turn = -1;
        player.update(STEP_DT, 1, turn, 0, false, benchWorld);
    }

    // two near, full-height billboards straight ahead of the camera
    function placeSprites():Void {
        var cx = Math.cos(player.ang);
        var sy = Math.sin(player.ang);
        watcher.spawnAt(player.x + cx * 1.15 - sy * 0.25, player.y + sy * 1.15 + cx * 0.25);
        hound.spawnAt(player.x + cx * 1.05 + sy * 0.3, player.y + sy * 1.05 - cx * 0.3);
    }

    // --- arm machinery ----------------------------------------------------------------

    function beginArm(i:Int, settleFrames:Int):Void {
        cur = i;
        arm = names[i];
        n = 0;
        settle = settleFrames;
        workAcc = 0;
        frameIdx = 0;
        fsAtStart = false;
        fsSeen = false;
        fsWait = 0;
        setup(i);
    }

    function setTier(t:Int):Void {
        renderer.setTier(t);
        cam.setTier(t);
        display.attach(renderer.bd, t);
    }

    function setQuality(low:Bool, smooth:Bool):Void {
        display.setLowQuality(low);
        display.bitmap.smoothing = smooth;
    }

    function applyChosen():Void {
        setQuality(qLow == 1, true);
    }

    function setup(i:Int):Void {
        switch (i) {
            case A_PRESENT_T1: setTier(1); setQuality(true, true);
            case A_PRESENT_T1_NOSMOOTH: setTier(1); setQuality(true, false);
            case A_PRESENT_T1_SMOOTH_MEDIUM: setTier(1); setQuality(false, true);
            case A_PRESENT_T1_NOSMOOTH_MEDIUM: setTier(1); setQuality(false, false);
            case A_PRESENT_T0: setTier(0); setQuality(true, true);
            case A_PRESENT_T0_SMOOTH_MEDIUM: setTier(0); setQuality(false, true);
            case A_POST_T1:
                decideQLow();
                setTier(1); applyChosen();
                cam.dread = 0.0; cam.flags = Camcorder.G_NONE; cam.rollPx = 0;
            case A_RAY_T1_F0_160: setTier(1); applyChosen(); rc.setColumns(160, benchTape.fov); floorMode = 0; resetPath();
            case A_RAY_T1_F1_160: setTier(1); applyChosen(); rc.setColumns(160, benchTape.fov); floorMode = 1; resetPath();
            case A_RAY_T1_F1_320: setTier(1); applyChosen(); rc.setColumns(320, benchTape.fov); floorMode = 1; resetPath();
            case A_RAY_T1_F2_320: setTier(1); applyChosen(); rc.setColumns(320, benchTape.fov); floorMode = 2; resetPath();
            case A_RAY_T0_F0_128: setTier(0); applyChosen(); rc.setColumns(128, benchTape.fov); floorMode = 0; resetPath();
            case A_SPRITES_T1: setTier(1); applyChosen(); rc.setColumns(320, benchTape.fov); floorMode = 1; resetPath();
            case A_MAPINK:
                setTier(1); applyChosen();
                mem = new MapMemory();
                paper = new MapPaper();
                paper.buildForTape(benchTape);
                // 2,048 faces inside one 64x64 sheet: both long faces of 16 rows of 64 cells
                for (y in 0...16) for (x in 0...64) { mem.seeFace(x, y, Cells.N); mem.seeFace(x, y, Cells.S); }
                paper.openAt(32.5, 8.5);
            case A_GLITCH_T1:
                setTier(1); applyChosen();
                cam.dread = 0.5; cam.rollPx = 0;
            case A_FS_RECT, A_FS_NORECT:
                setTier(1); applyChosen();
            default:
        }
    }

    function decideQLow():Void {
        // LOW only if MEDIUM + smoothing measured more than 4 ms per frame worse than LOW
        var diff = msFrame[A_PRESENT_T1_SMOOTH_MEDIUM] - msFrame[A_PRESENT_T1];
        qLow = diff > 4.0 * FRAMES ? 1 : 0;
        var p1 = qLow == 1 ? msFrame[A_PRESENT_T1] : msFrame[A_PRESENT_T1_SMOOTH_MEDIUM];
        var p0 = qLow == 1 ? msFrame[A_PRESENT_T0] : msFrame[A_PRESENT_T0_SMOOTH_MEDIUM];
        presentW = p1 / FRAMES;
        presentW0 = p0 / FRAMES;
    }

    function presentBlank():Void {
        if (renderer.tier == 0) renderer.bd.setVector(renderer.rect, blank0);
        else renderer.bd.setVector(renderer.rect, blank1);
    }

    function frameSeed():Int {
        return Rng.hash2(BENCH_SEED, frameIdx);
    }

    // the arm's per-frame work; adds its own bracket to workAcc
    function work(i:Int):Void {
        var t:Int;
        switch (i) {
            case A_POST_T1:
                presentBlank();
                cam.flags = Camcorder.G_NONE;
                t = flash.Lib.getTimer();
                cam.apply(renderer.bd, frameSeed());
                workAcc += flash.Lib.getTimer() - t;
            case A_RAY_T1_F0_160, A_RAY_T1_F1_160, A_RAY_T1_F1_320, A_RAY_T1_F2_320, A_RAY_T0_F0_128:
                stepPath();
                t = flash.Lib.getTimer();
                rc.castRays(benchWorld, player.x, player.y, player.ang, hits);
                renderer.render(hits, rc, player.x, player.y, 0, floorMode, benchWorld);
                workAcc += flash.Lib.getTimer() - t;
                renderer.present();
            case A_SPRITES_T1:
                stepPath();
                rc.castRays(benchWorld, player.x, player.y, player.ang, hits);
                renderer.render(hits, rc, player.x, player.y, 0, floorMode, benchWorld);
                placeSprites();
                t = flash.Lib.getTimer();
                sprites.draw(renderer, hits, rc, player.x, player.y, player.ang, watcher, hound, 0, frameSeed(), false);
                workAcc += flash.Lib.getTimer() - t;
                renderer.present();
            case A_MAPINK:
                t = flash.Lib.getTimer();
                paper.pump(mem, 32, 8);
                workAcc += flash.Lib.getTimer() - t;
                paper.compose(renderer.bd, renderer.w, renderer.h, 32.5, 8.5, 0.0, 0, 0);
            case A_GLITCH_T1:
                presentBlank();
                cam.flags = Camcorder.G_GLITCH;
                cam.glitchNow();
                t = flash.Lib.getTimer();
                cam.apply(renderer.bd, frameSeed());
                workAcc += flash.Lib.getTimer() - t;
            default:
                // every present arm, windowed or fullscreen: the present step alone
                t = flash.Lib.getTimer();
                presentBlank();
                workAcc += flash.Lib.getTimer() - t;
        }
        frameIdx++;
    }

    function onFrame(e:Event):Void {
        var now = flash.Lib.getTimer();
        if ((cur == A_FS_RECT || cur == A_FS_NORECT) && !fsSeen) {
            // keep presenting until Display reports FULL_SCREEN; the settle counts from the first fullscreen frame
            if (display.fullscreen) {
                fsSeen = true;
                settle = SETTLE_FS;
            } else {
                fsWait++;
                if (fsWait >= FS_WAIT_MAX) {
                    // the transition never landed: nothing fullscreen can be measured by this arm
                    msFrame[cur] = 0.0;
                    msWork[cur] = 0.0;
                    valid[cur] = false;
                    report(cur);
                    endRun();
                    return;
                }
                work(cur);
                return;
            }
        }
        if (n == 0 && settle > 0) {
            settle--;
            work(cur);
            return;
        }
        if (n < FRAMES) {
            if (n == 0) { t0 = now; fsAtStart = display.fullscreen; }
            work(cur);
            n++;
            return;
        }
        // n == FRAMES: this tick closes the last counted interval
        msFrame[cur] = now - t0;
        msWork[cur] = workAcc;
        valid[cur] = true;
        if (cur == A_FS_RECT || cur == A_FS_NORECT) valid[cur] = fsAtStart && display.fullscreen;
        report(cur);
        if (cur == lastArm) endRun();
        else beginArm(cur + 1, SETTLE);
    }

    static function d1(v:Float):String {
        var r = Std.int(v * 10.0 + 0.5) / 10.0;
        return Std.string(r);
    }

    function report(i:Int):Void {
        Telemetry.ping("bk=bench&arm=" + names[i] + "&frames=" + FRAMES
            + "&ms_work=" + Std.int(msWork[i]) + "&ms_frame=" + Std.int(msFrame[i])
            + "&mspf_work=" + d1(msWork[i] / FRAMES) + "&mspf_frame=" + d1(msFrame[i] / FRAMES)
            + "&fs=" + (display.fullscreen ? 1 : 0) + "&valid=" + (valid[i] ? 1 : 0));
    }

    function endRun():Void {
        stage.removeEventListener(Event.ENTER_FRAME, onFrame);
        running = false;
        stage.frameRate = savedFrameRate;
        arm = "";
        if (cur == A_FS_RECT) {
            display.exitFullscreen();
            needGesture = GESTURE_FS_NORECT;             // the second arm needs a fresh gesture (Space)
            return;
        }
        if (cur == A_FS_NORECT) {
            display.exitFullscreen();
            finishFullscreen();
            return;
        }
        finishWindowed();
    }

    // --- results ----------------------------------------------------------------------

    // the ray arm that stands for a rung
    function rayArmOf(r:Int):Int {
        switch (r) {
            case 0: return A_RAY_T0_F0_128;
            case 1: return A_RAY_T1_F0_160;
            case 2: return A_RAY_T1_F1_160;
            case 3, 4: return A_RAY_T1_F1_320;
            default: return A_RAY_T1_F2_320;
        }
    }

    // estimate = present.mspf_frame + ray arm.mspf_work + sprites_t1.mspf_work + post_t1.mspf_work + 3 (present counted once)
    function estimate(r:Int, present1:Float, present0:Float):Float {
        var present = r == 0 ? present0 : present1;
        return present + msWork[rayArmOf(r)] / FRAMES + msWork[A_SPRITES_T1] / FRAMES + msWork[A_POST_T1] / FRAMES + 3.0;
    }

    // the highest rung whose estimate fits its budget (45 ms for rungs 0-3, 30 ms for 4-5); rung 0 is never disabled
    function maxRungFor(present1:Float, present0:Float):Int {
        var best = 0;
        for (r in 0...Quality.RUNGS) {
            var budget = r <= 3 ? 45.0 : 30.0;
            if (estimate(r, present1, present0) <= budget) best = r;
        }
        return best;
    }

    function finishWindowed():Void {
        windowedDone = true;
        // release the mapink collaborators: nothing of the bench outlives it but numbers
        mem = null;
        paper = null;
        // leave the display at the chosen quality, T1, smoothing on
        setTier(1);
        applyChosen();
        result.qLow = qLow;
        result.presentW = presentW;
        result.maxRungWin = maxRungFor(presentW, presentW0);
        result.fsHw = -1;
        result.maxRungFs = result.maxRungWin;
        result.presentFs = presentW;
        result.presentFsRect = presentW;
        if (Params.has("nofs")) {
            needGesture = GESTURE_NONE;
            releaseScene();
            reportDone();
            if (onDoneCb != null) onDoneCb(result);
            return;
        }
        needGesture = GESTURE_FS_RECT;                  // the first card click arms present_fs_rect
        if (onDoneCb != null) onDoneCb(result);          // provisional: fsHw = -1, maxRungFs = maxRungWin
    }

    function finishFullscreen():Void {
        needGesture = GESTURE_NONE;
        var rectOk = valid[A_FS_RECT];
        var norectOk = valid[A_FS_NORECT];
        var pRect = rectOk ? msFrame[A_FS_RECT] / FRAMES : presentW;
        var pNo = norectOk ? msFrame[A_FS_NORECT] / FRAMES : presentW * 1.55;   // software fullscreen scales 786k px vs 507k windowed
        var fsHw = -1;
        if (rectOk) fsHw = (pRect < 0.6 * presentW) ? 1 : 0;
        if (rectOk && !norectOk && fsHw == 0) pNo = pRect;                 // the rect took but was software: same path
        result.fsHw = fsHw;
        result.presentFsRect = pRect;
        result.presentFs = pNo;
        var use = fsHw == 1 ? pRect : pNo;
        var ratio0 = presentW > 0 ? presentW0 / presentW : 1.0;
        result.maxRungFs = (rectOk || norectOk) ? maxRungFor(use, use * ratio0) : result.maxRungWin;
        releaseScene();
        reportDone();
        if (onDoneCb != null) onDoneCb(result);
    }

    function reportDone():Void {
        Telemetry.ping("bk=benchdone&maxRungWin=" + result.maxRungWin + "&maxRungFs=" + result.maxRungFs
            + "&fsHw=" + result.fsHw + "&qLow=" + result.qLow
            + "&presentW=" + d1(result.presentW) + "&presentFs=" + d1(result.presentFs) + "&presentFsRect=" + d1(result.presentFsRect)
            + "&presentW0=" + d1(presentW0));
    }
}
