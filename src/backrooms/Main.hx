// Entry point and frame loop (CONTRACT §2, §3). fp class.
//
// Main is the integration point: it owns every subsystem, runs EXACTLY the frame loop
// of CONTRACT §3 inside one try/catch (so input.endFrame() always runs), applies the
// Director's events to audio and the camcorder, drives the tape loop
// BOOT -> BENCH? -> CARD -> PLAY <-> MAP -> DYING -> ENDS -> CARD ..., feeds Quality and
// applies rung changes, and reports to the PC (telemetry ticks every 10 s, events
// coalesced to at most two pings per second).
//
// Fullscreen is entered ONLY from onGesture, which Input calls synchronously inside its
// KEY_DOWN / CLICK listeners: Flash Player throws SecurityError #2152 for
// displayState = FULL_SCREEN from ENTER_FRAME, a Timer, a URLLoader callback or
// ExternalInterface, every time. The frame loop never enters it.
//
// Allocation: nothing in the per-frame path allocates. The bounded exceptions are the
// contract's (Hud strings once a second, MapPaper sheets, Telemetry strings at most twice
// a second, World/MapMemory pooled chunks) plus the per-tape rebuild in startTape
// (a Tape, a MapMemory, a Director with its two entities, a Bot) which runs once per tape
// between ENDS and the next CARD, never during play.
import flash.display.Sprite;
import flash.events.Event;
import flash.events.UncaughtErrorEvent;

class Main extends Sprite {
    public static inline var ST_BOOT = 0; public static inline var ST_BENCH = 1; public static inline var ST_CARD = 2; public static inline var ST_PLAY = 3;
    public static inline var ST_MAP = 4; public static inline var ST_DYING = 5; public static inline var ST_ENDS = 6; public static inline var ST_PAUSED = 7;
    public var state:Int;
    public var prevState:Int;                           // for PAUSED resume
    public var dyingFrame:Int;                          // frames since ST_DYING began (the "killer plain for exactly 2 frames" rule counts frames, never seconds)

    // where-flag values for error classification
    static inline var W_LOGIC = 0;
    static inline var W_GEN = 1;
    static inline var W_RENDER = 2;
    static inline var W_OTHER = 3;
    // tick accumulator slots
    static inline var T_LOGIC = 0; static inline var T_GEN = 1; static inline var T_RAY = 2; static inline var T_WALL = 3;
    static inline var T_FLOOR = 4; static inline var T_SPR = 5; static inline var T_HUD = 6; static inline var T_MAP = 7;
    static inline var T_SET = 8; static inline var T_POST = 9; static inline var T_AUDIO = 10; static inline var T_OURS = 11;
    static inline var T_PRESENT = 12; static inline var T_BUSY = 13; static inline var T_SPAN = 14; static inline var N_T = 15;
    static inline var ERR_RING = 3;
    static inline var TICK_MS = 10000;
    static inline var FLUSH_MS = 60000;
    static inline var SNAP_MIN_MS = 5000;
    static inline var PING_MIN_MS = 500;
    static inline var CARD_SECS = 4.5;
    static inline var CARD_MIN_SECS = 0.8;
    static inline var ENDS_SECS = 2.0;
    // per-tape automatic snapshot bits
    static inline var SN_CARD = 1; static inline var SN_PLAY = 2; static inline var SN_WATCHER = 4; static inline var SN_HOUND = 8; static inline var SN_MAP = 16;

    // subsystems
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
    var stg:flash.display.Stage;

    // params
    var benchWanted:Bool;
    var soak:Bool;
    var auto:Bool;
    var debug:Bool;
    var nosnap:Bool;
    var nofs:Bool;
    var rungOverride:Int;                               // -1 = none
    var throwAt:Int;                                    // frame of the deliberate throw (?throw=1), 0 = none
    var dieKind:Int;                                    // ?die= scripted death kind, 0 = none
    var firstRun:Bool;                                  // no benchDone in the save at boot: fullscreen key probe on
    var saveEnabled:Bool;                               // false under ?tape=N / ?seed=N (a test override must not overwrite the real tape count or salt)
    var salt:Int;                                       // the tape salt in use: save.salt, or a ?seed= / rc seed override that is NEVER copied back into the save
    var benchCb:Bench.BenchResult->Void;                // onBenchDone bound once (a method reference evaluated per call allocates a closure on AVM2)

    // timing
    var frame:Int;
    var last:Int;
    var lastEnterFrame:Int;
    var tRenderStart:Int;
    var tPresent:Int;
    var stateT:Float;                                   // seconds since the state began (dt-driven, so ?fixeddt pins it)
    var frameSeed:Int;
    var whereFlag:Int;

    // bench / quality
    var benchResult:Bench.BenchResult;
    var benchFinished:Bool;
    var benchWait:Float;                                // seconds spent waiting for a bench gesture (unattended timeout)
    var maxRungWin:Int;
    var maxRungFs:Int;
    var fsHw:Int;
    var qLow:Int;
    var presentW:Float;
    var presentW0:Float;
    var presentFs:Float;
    var presentFsRect:Float;
    var curCols:Int;
    var curFov:Float;

    // tape / play
    var firstCardOfSession:Bool;
    var bedStarted:Bool;
    var deathKind:Int;
    var plainStartFrame:Int;
    var staticDone:Bool;
    var pendingKill:Int;
    var dieDone:Bool;
    var noSignalFrames:Int;
    var strobeOn:Bool;
    var stormFrames:Int;
    var tearTimer:Float;
    var dropTimer:Float;
    var playFade:Float;
    var prevDark:Bool;
    var prevWantMap:Bool;
    var pausedDrawn:Bool;
    var tapeSnaps:Int;
    var stageSnapDone:Bool;
    var soakSnaps:Int;
    var lastSoakSnap:Int;

    // errors
    var errTimes:haxe.ds.Vector<Int>;
    var errHead:Int;
    var errTotal:Int;

    // telemetry
    var tick:haxe.ds.Vector<Int>;
    var tickFrames:Int;
    var lastTick:Int;
    var lastFlush:Int;
    var lastPing:Int;
    var pending:String;
    var lastSnap:Int;
    var keySeen:haxe.ds.Vector<Int>;
    var bootUrl:String;

    // Lib.current.addChild(new Main())
    public static function main():Void {
        flash.Lib.current.addChild(new Main());
    }

    // Params.init, Telemetry.init, Save.load, constructs every subsystem, uncaughtErrorEvents listener, ENTER_FRAME listener, DEACTIVATE/ACTIVATE, input.onGesture = onGesture (once)
    public function new():Void {
        super();
        var cur = flash.Lib.current;
        stg = cur.stage;
        Params.init(cur.loaderInfo);
        bootUrl = cur.loaderInfo.url;
        Telemetry.init(bootUrl);
        save = Save.load();

        soak = Params.has("soak");
        auto = Params.has("auto") || soak;
        debug = Params.has("debug");
        nosnap = Params.has("nosnap");
        nofs = Params.has("nofs");
        rungOverride = Params.has("rung") ? clampRung(Params.int("rung", 2)) : -1;
        throwAt = Params.has("throw") ? 100 : 0;
        dieKind = killOf(Params.get("die", ""));
        firstRun = !save.benchDone;
        // bench=1 is the contract's trigger. The eMac's implicit first-run bench (DESIGN §1) is gated so that a test run
        // (Ruffle: file:// or a fresh SharedObject; ?throw/?fixeddt/?seed) never benches implicitly and sits waiting for a gesture.
        benchWanted = Params.has("bench")
            || (!save.benchDone && rungOverride < 0 && Telemetry.enabled
                && !Params.has("throw") && !Params.has("fixeddt") && !Params.has("seed") && !Params.has("nofs"));
        saveEnabled = !Params.has("tape") && !Params.has("seed");
        if (Params.has("tape")) { var ti = Params.int("tape", 1); if (ti >= 1) save.tapeCount = ti - 1; }
        salt = Params.has("seed") ? Params.int("seed", save.salt) : save.salt;

        state = ST_BOOT;
        prevState = ST_BOOT;
        dyingFrame = 0;
        frame = 0;
        last = flash.Lib.getTimer();
        lastEnterFrame = last;
        tRenderStart = 0;
        tPresent = 0;
        stateT = 0.0;
        frameSeed = 0;
        whereFlag = W_OTHER;

        maxRungWin = save.maxRungWin;
        maxRungFs = save.maxRungFs;
        fsHw = save.fsHw;
        qLow = save.qLow;
        // present estimates until the bench of this session replaces them (the save keeps no present numbers)
        presentW = 20.0;
        presentW0 = 20.0;
        presentFs = 31.0;
        presentFsRect = fsHw == 1 ? 4.0 : 31.0;
        benchResult = null;
        benchFinished = false;
        benchWait = 0.0;
        curCols = 0;
        curFov = 0.0;

        firstCardOfSession = true;
        bedStarted = false;
        deathKind = 0;
        plainStartFrame = 0;
        staticDone = false;
        pendingKill = 0;
        dieDone = false;
        noSignalFrames = 0;
        strobeOn = false;
        stormFrames = 0;
        tearTimer = 15.0;
        dropTimer = 9.0;
        playFade = 0.0;
        prevDark = false;
        prevWantMap = false;
        pausedDrawn = false;
        tapeSnaps = 0;
        stageSnapDone = false;
        soakSnaps = 0;
        lastSoakSnap = last;

        errTimes = new haxe.ds.Vector<Int>(ERR_RING);
        for (i in 0...ERR_RING) errTimes[i] = -1000000;
        errHead = 0;
        errTotal = 0;

        tick = new haxe.ds.Vector<Int>(N_T);
        for (i in 0...N_T) tick[i] = 0;
        tickFrames = 0;
        lastTick = last;
        lastFlush = last;
        lastPing = last - PING_MIN_MS;
        pending = "";
        lastSnap = last - SNAP_MIN_MS;
        keySeen = new haxe.ds.Vector<Int>(256);
        for (i in 0...256) keySeen[i] = 0;

        // reusable subsystems (per-tape objects are built by startTape at ST_BOOT)
        tape = null;
        director = null;
        mapMemory = null;
        bot = null;
        world = new World(0);
        player = new Player(16.5, 16.5, 0.0);
        var startRung = rungOverride >= 0 ? rungOverride : clampRung(save.rung);
        var startMax = rungOverride >= 0 ? rungOverride : clampRung(save.maxRungWin);
        if (startRung > startMax) startRung = startMax;
        quality = new Quality(startRung, startMax);
        raycaster = new Raycaster(Renderer.W1);
        hits = new RayHits(Renderer.W1);
        textures = new Textures();
        renderer = new Renderer(textures);
        spritePass = new SpritePass(textures);
        hud = new Hud();
        cards = new Cards();
        camcorder = new Camcorder();
        mapPaper = new MapPaper();
        audio = new AudioBus();
        input = new Input(stg);
        input.onGesture = onGesture;
        benchCb = onBenchDone;
        display = new Display(stg);
        display.onFullscreenChange = onFullscreenChange;
        display.setLowQuality(qLow == 1);
        display.hwRect = fsHw == 1;
        bench = new Bench(stg, display, renderer, camcorder, spritePass, raycaster, world, textures);
        rng = new Rng(1);

        display.attach(renderer.bd, renderer.tier);
        addChild(display.bitmap);
        cur.loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onUncaught);
        addEventListener(Event.ENTER_FRAME, onFrame);
        stg.addEventListener(Event.RENDER, onRender);
        stg.addEventListener(Event.DEACTIVATE, onDeactivate);
        stg.addEventListener(Event.ACTIVATE, onActivate);
        if (Params.has("rc")) Telemetry.pollRC(onRC, 300);
        Telemetry.registerEI(onEI);
    }

    // --- small helpers -------------------------------------------------------------------

    static inline function clampRung(r:Int):Int {
        return r < 0 ? 0 : (r >= Quality.RUNGS ? Quality.RUNGS - 1 : r);
    }

    static function killOf(s:String):Int {
        switch (s) {
            case "watcher": return Director.K_WATCHER;
            case "hound": return Director.K_HOUND;
            case "pit": return Director.K_PIT;
            case "battery": return Director.K_BATTERY;
            case "damaged": return Director.K_DAMAGED;
            default: return 0;
        }
    }

    static function killName(k:Int):String {
        switch (k) {
            case Director.K_WATCHER: return "watcher";
            case Director.K_HOUND: return "hound";
            case Director.K_PIT: return "pit";
            case Director.K_BATTERY: return "battery";
            case Director.K_DAMAGED: return "damaged";
            default: return "none";
        }
    }

    static function stateName(s:Int):String {
        switch (s) {
            case ST_BOOT: return "BOOT";
            case ST_BENCH: return "BENCH";
            case ST_CARD: return "CARD";
            case ST_PLAY: return "PLAY";
            case ST_MAP: return "MAP";
            case ST_DYING: return "DYING";
            case ST_ENDS: return "ENDS";
            case ST_PAUSED: return "PAUSED";
            default: return "?";
        }
    }

    static function whereName(w:Int):String {
        switch (w) {
            case W_LOGIC: return "logic";
            case W_GEN: return "gen";
            case W_RENDER: return "render";
            default: return "other";
        }
    }

    static function d1(v:Float):String {
        return Std.string(Std.int(v * 10.0 + 0.5) / 10.0);
    }

    static function d2(v:Float):String {
        return Std.string(Std.int(v * 100.0 + 0.5) / 100.0);
    }

    // event pings: at most one per 0.5 s; anything sooner is coalesced ('|'-joined) into the next ping or tick
    function emit(q:String):Void {
        var now = flash.Lib.getTimer();
        if (now - lastPing >= PING_MIN_MS) {
            if (pending != "") { Telemetry.ping(pending + "|" + q); pending = ""; }
            else Telemetry.ping(q);
            lastPing = now;
        } else {
            pending = pending == "" ? q : pending + "|" + q;
        }
    }

    function flushPending(now:Int):Void {
        if (pending == "" || now - lastPing < PING_MIN_MS) return;
        Telemetry.ping(pending);
        pending = "";
        lastPing = now;
    }

    // automatic snapshots: never more than one per 5 s; P and rc snap bypass this
    function autoSnap(tag:String):Void {
        if (nosnap || !Telemetry.enabled) return;
        var now = flash.Lib.getTimer();
        if (now - lastSnap < SNAP_MIN_MS) return;
        lastSnap = now;
        Telemetry.snap(renderer.bd, tag);
    }

    function tapeSnap(bit:Int, tag:String):Void {
        if ((tapeSnaps & bit) != 0) return;
        tapeSnaps |= bit;
        autoSnap(tag);
    }

    // the bench present for a tier and display mode (fsHw-aware); T0 fullscreen is scaled from the windowed T0/T1 ratio
    function presentFor(tier:Int, fs:Bool):Float {
        if (!fs) return tier == 0 ? presentW0 : presentW;
        var p = fsHw == 1 ? presentFsRect : presentFs;
        if (tier == 0 && presentW > 0) p = p * (presentW0 / presentW);
        return p;
    }

    function ceilingFor(fs:Bool):Int {
        if (rungOverride >= 0) return rungOverride;
        return fs ? maxRungFs : maxRungWin;
    }

    // --- state machine -------------------------------------------------------------------

    // logs bk=state
    public function setState(s:Int):Void {
        prevState = state;
        state = s;
        stateT = 0.0;
        pausedDrawn = false;
        emit("bk=state&s=" + stateName(s) + "&tape=" + (tape != null ? tape.index : 0) + "&why=" + stateName(prevState));
    }

    // Tape.make, world/textures/camcorder/paper/map/director rebuilt (reusing buffers), player placed, bed started
    public function startTape(index:Int):Void {
        tape = Tape.make(index, salt);
        // world: same pool, new seed, every chunk back to the pool (a centre no chunk is near, radius 0 = everything is outside)
        world.evictOutside(0x4000, 0x4000, 0);
        world.tapeSeed = tape.seed;
        world.genErrors = 0;
        world.ensureAround(0, 0);
        var guard = 0;
        while (world.pendingCount() > 0 && guard < 32) { world.pump(4); guard++; }
        // player: the walkable, non-pit cell of chunk (0,0) nearest the tape's start
        var sx = Std.int(tape.startX); var sy = Std.int(tape.startY);
        if (sx < 0) sx = 0; if (sx > 31) sx = 31; if (sy < 0) sy = 0; if (sy > 31) sy = 31;
        var bx = sx; var by = sy; var bestD = 0x7FFFFFFF;
        for (y in 0...32) for (x in 0...32) {
            var c = world.cell(x, y);
            if (!Cells.walkable(c) || Cells.type(c) == Cells.PIT) continue;
            var dx = x - sx; var dy = y - sy;
            var d = dx * dx + dy * dy;
            if (d < bestD) { bestD = d; bx = x; by = y; }
        }
        player.placeAt(bx + 0.5, by + 0.5, tape.startAng);
        textures.build(tape);
        camcorder.buildForTape(tape);
        mapPaper.buildForTape(tape);
        hud.setTape(tape);
        hud.recVisible = true;
        mapMemory = new MapMemory();
        director = new Director(world, player, tape);
        bot = new Bot(tape.seed);
        var s = Rng.mix(Rng.hash3(tape.seed, Rng.TAG_DIRECTOR, 1));
        rng.state = s == 0 ? 0x9E3779B9 : s;
        curFov = tape.fov;
        curCols = Quality.rays(quality.rung);
        raycaster.setColumns(curCols, curFov);
        if (!bedStarted) { audio.startBed(); bedStarted = true; }
        audio.setPresence(0.0);
        audio.setHumLow(tape.badTape);
        audio.setDark(false);
        audio.setDrip(99.0, 0.0);
        audio.setHumLight(1.0);
        camcorder.dread = 0.0;
        camcorder.flags = Camcorder.G_NONE;
        camcorder.rollPx = 0;
        camcorder.tearBands = 1;
        camcorder.chromaPx = 0;
        camcorder.flickerBrightness = 1.0;
        deathKind = 0;
        plainStartFrame = 0;
        staticDone = false;
        pendingKill = 0;
        dieDone = false;
        noSignalFrames = 0;
        strobeOn = false;
        stormFrames = 0;
        tearTimer = 15.0;
        dropTimer = 9.0;
        playFade = 0.0;
        prevDark = false;
        prevWantMap = false;
        tapeSnaps = 0;
        audio.oneShot(AudioBus.VCR, 0.5, 0.0);
    }

    function enterPlay():Void {
        firstCardOfSession = false;
        setState(ST_PLAY);
        playFade = 1.5;
        camcorder.tearNow(3);
        stormFrames = 20;                               // tracking settles over ~1 s
        input.fullscreen = display.fullscreen;
    }

    function beginDying(kind:Int):Void {
        deathKind = kind;
        dyingFrame = 0;
        plainStartFrame = (kind == Director.K_PIT || kind == Director.K_BATTERY) ? -1 : 0;
        staticDone = false;
        setState(ST_DYING);
        audio.setPresence(1.0);
        emit("bk=death&kind=" + killName(kind) + "&tt=" + d1(director.tapeTime) + "&tape=" + tape.index
            + "&D=" + d2(director.D) + "&x=" + player.cellX() + "&y=" + player.cellY());
    }

    function resumeFromPause():Void {
        audio.resume();
        var back = prevState;
        if (back != ST_PLAY && back != ST_MAP) back = ST_PLAY;
        setState(back);
    }

    // Bench callback: provisional after the windowed arms (needGesture set), final after the fullscreen arms or under ?nofs=1
    function onBenchDone(r:Bench.BenchResult):Void {
        benchResult = r;
        if (bench.needGesture != Bench.GESTURE_NONE) return;
        benchFinished = true;
    }

    function finishBench():Void {
        var r = benchResult;
        maxRungWin = clampRung(r.maxRungWin);
        maxRungFs = clampRung(r.maxRungFs);
        fsHw = r.fsHw;
        qLow = r.qLow;
        presentW = r.presentW;
        presentW0 = bench.presentW0 > 0 ? bench.presentW0 : presentW;
        presentFs = r.presentFs;
        presentFsRect = r.presentFsRect;
        display.hwRect = fsHw == 1;
        display.setLowQuality(qLow == 1);
        var from = quality.rung;
        quality.setMaxRung(ceilingFor(display.fullscreen));
        if (rungOverride < 0) quality.set(quality.maxRung);   // a fresh bench starts at the richest proven rung; the ladder settles it
        applyRung(from, "bench");
        save.benchDone = true;
        save.maxRungWin = maxRungWin;
        save.maxRungFs = maxRungFs;
        save.fsHw = fsHw;
        save.qLow = qLow;
        save.rung = quality.rung;
        if (saveEnabled) Save.flush(save);
        setState(ST_CARD);
    }

    // applies the current quality.rung to every subsystem (index swaps only) and reports it
    function applyRung(from:Int, why:String):Void {
        var r = quality.rung;
        var t = Quality.tier(r);
        if (renderer.tier != t) {
            renderer.setTier(t);
            camcorder.setTier(t);
        }
        display.attach(renderer.bd, t);
        curCols = Quality.rays(r);
        raycaster.setColumns(curCols, curFov);
        stg.frameRate = Quality.frameRate(r);
        quality.presentEstimate = presentFor(t, display.fullscreen);
        save.rung = r;
        if (from != r) emit("bk=rung&from=" + from + "&to=" + r + "&why=" + why);
    }

    // --- gestures, focus, fullscreen ---------------------------------------------------------

    // called synchronously inside Input's KEY_DOWN/CLICK listeners (code = keyCode, -1 = click): the ONLY place display.enterFullscreen() / bench.runFullscreenArm() are called — see CONTRACT §3
    public function onGesture(code:Int):Void {
        if (state == ST_BENCH) {
            if (bench.needGesture == Bench.GESTURE_FS_RECT && code == -1) { benchWait = 0.0; bench.runFullscreenArm(Bench.GESTURE_FS_RECT, benchCb); return; }
            if (bench.needGesture == Bench.GESTURE_FS_NORECT && code == Input.K_SPACE) { benchWait = 0.0; bench.runFullscreenArm(Bench.GESTURE_FS_NORECT, benchCb); return; }
            return;
        }
        if (nofs || display.fullscreen) return;
        if (state == ST_CARD && firstCardOfSession && code == -1) { display.enterFullscreen(); return; }
        if (code == Input.K_F || code == Input.K_ENTER) display.enterFullscreen();
    }

    function onFullscreenChange(fs:Bool):Void {
        input.fullscreen = fs;
        var from = quality.rung;
        quality.setMaxRung(ceilingFor(fs));
        if (state != ST_BENCH) applyRung(from, fs ? "fs" : "win");
        else quality.presentEstimate = presentFor(renderer.tier, fs);
    }

    function onDeactivate(e:Event):Void {
        input.clear();
        if (state == ST_PLAY || state == ST_MAP) {
            prevState = state;
            setState(ST_PAUSED);
            audio.pause();
        }
    }

    function onActivate(e:Event):Void {
        if (state == ST_PAUSED) resumeFromPause();
    }

    function onRender(e:Event):Void {
        tRenderStart = flash.Lib.getTimer();
    }

    // --- remote control ----------------------------------------------------------------------

    // ExternalInterface "g3(cmd, arg)" from Safari's JavaScript: same vocabulary as /rc
    function onEI(cmd:String, arg:Dynamic):String {
        if (cmd == null) return "err";
        var line = cmd;
        if (arg != null) line = cmd + " " + Std.string(arg);
        onRC(line);
        return "ok";
    }

    // "key <code> <holdms>", "snap [tag]", "state", "seed <n>", "die [kind]", "map", "fs" (exit only — an rc poll is not a user gesture, so entering from here would throw; it pings bk=fs&on=0&why=nogesture), "rung <n>", "tele", "blackout", "hound", "relocate"
    public function onRC(line:String):Void {
        if (line == null) return;
        var parts = StringTools.trim(line).split(" ");
        if (parts.length == 0) return;
        var cmd = parts[0];
        var a1 = parts.length > 1 ? parts[1] : "";
        var a2 = parts.length > 2 ? parts[2] : "";
        switch (cmd) {
            case "key":
                var code = Std.parseInt(a1);
                var hold = Std.parseInt(a2);
                if (code != null) input.injectKey(code, hold == null ? 100 : hold);
            case "snap":
                var tag = a1 == "" ? "rc" : a1;
                if (tag == "stage") display.snapStage("stage");
                else Telemetry.snap(renderer.bd, tag);
            case "state":
                emit("bk=state&s=" + stateName(state) + "&tape=" + (tape != null ? tape.index : 0) + "&why=rc&rung=" + quality.rung
                    + "&x=" + player.cellX() + "&y=" + player.cellY() + "&fs=" + (display.fullscreen ? 1 : 0));
            case "seed":
                var n = Std.parseInt(a1);
                if (n != null && state != ST_BOOT && state != ST_BENCH) {
                    salt = n;                           // a test salt: never written into save.salt
                    startTape(tape != null ? tape.index : save.tapeCount + 1);
                    if (state == ST_MAP) mapPaper.close();
                    setState(ST_CARD);
                }
            case "die":
                var k = killOf(a1);
                pendingKill = k == 0 ? Director.K_WATCHER : k;
            case "map":
                input.injectKey(Input.K_TAB, 60);
            case "fs":
                if (display.fullscreen) display.exitFullscreen();
                else emit("bk=fs&on=0&sw=" + display.stageW + "&sh=" + display.stageH + "&rect=0&why=nogesture");
            case "rung":
                var n = Std.parseInt(a1);
                if (n != null) {
                    var from = quality.rung;
                    quality.set(clampRung(n));
                    applyRung(from, "override");
                }
            case "tele":
                sendTick(flash.Lib.getTimer());
            case "blackout":
                if (director != null) director.forceBlackout();
            case "hound":
                if (director != null) director.forceSpawnHound();
            case "relocate":
                if (director != null) director.forceRelocate();
            default:
        }
    }

    // --- errors --------------------------------------------------------------------------------

    function pushError(msg:String, where:Int):Void {
        var now = flash.Lib.getTimer();
        errTotal++;
        errTimes[errHead] = now;
        errHead = (errHead + 1) % ERR_RING;
        emit("bk=err&msg=" + StringTools.urlEncode(msg) + "&n=" + errTotal + "&rung=" + quality.rung + "&where=" + whereName(where) + "&frame=" + frame);
        if (where == W_RENDER) {
            var from = quality.rung;
            quality.forceDrop();
            if (quality.rung != from) applyRung(from, "err");
        } else if (where == W_GEN) {
            world.genErrors++;
        }
        var recent = 0;
        for (i in 0...ERR_RING) if (now - errTimes[i] <= 10000) recent++;
        if (recent >= ERR_RING && state != ST_DYING && state != ST_ENDS && state != ST_BOOT && state != ST_BENCH) {
            if (state == ST_MAP) mapPaper.close();
            beginDying(Director.K_DAMAGED);
        }
    }

    function onFrameError(e:Dynamic):Void {
        var msg:String;
        try { msg = Std.string(e); } catch (e2:Dynamic) { msg = "unprintable"; }
        if (msg == null) msg = "null";
        if (msg.length > 120) msg = msg.substr(0, 120);
        pushError(msg, whereFlag);
    }

    function onUncaught(e:UncaughtErrorEvent):Void {
        e.preventDefault();
        var msg:String = "uncaught";
        try {
            var err:Dynamic = e.error;
            if (Std.isOfType(err, flash.errors.Error)) {
                var fe:flash.errors.Error = cast err;
                msg = "uncaught:" + fe.errorID + ":" + fe.message;
            } else if (Std.isOfType(err, flash.events.ErrorEvent)) {
                var ee:flash.events.ErrorEvent = cast err;
                msg = "uncaught:" + ee.text;
            } else {
                msg = "uncaught:" + Std.string(err);
            }
        } catch (e2:Dynamic) { msg = "uncaught"; }
        if (msg.length > 120) msg = msg.substr(0, 120);
        pushError(msg, W_OTHER);
    }

    // --- the frame loop (CONTRACT §3) -------------------------------------------------------

    function onFrame(e:Event):Void {
        var now = flash.Lib.getTimer();
        var dtMs = Params.has("fixeddt") ? Params.int("fixeddt", 50) : (now - last);
        if (dtMs > 100) dtMs = 100;
        if (dtMs < 0) dtMs = 0;
        last = now;
        var dt = dtMs / 1000.0;
        var frameToFrameMs = now - lastEnterFrame;
        lastEnterFrame = now;
        if (tRenderStart > 0) { tPresent = now - tRenderStart; tRenderStart = 0; }
        input.update(dt);
        frameSeed = rng.nextInt();
        stateT += dt;
        input.fullscreen = display.fullscreen;

        var tLogic = 0; var tGen = 0; var tRay = 0; var tHud = 0; var tMap = 0; var tSet = 0; var tAudio = 0;
        var entityActive = false;
        whereFlag = W_LOGIC;
        try {
            switch (state) {
                case ST_BOOT:
                    startTape(save.tapeCount + 1);
                    var from = quality.rung;
                    quality.setMaxRung(ceilingFor(display.fullscreen));
                    applyRung(from, "boot");
                    pingBoot();
                    if (benchWanted) {
                        setState(ST_BENCH);
                        bench.runWindowed(benchCb);
                    } else {
                        setState(ST_CARD);
                    }
                case ST_BENCH:
                    audio.update(dt);                       // the bed keeps crossfading under the bench
                    if (benchFinished) {
                        benchFinished = false;
                        finishBench();
                    } else if (bench.needGesture != Bench.GESTURE_NONE) {
                        // waiting for a gesture: the card carries the prompt (CLICK TO START / PRESS SPACE); bench arms own the display otherwise
                        cards.drawCard(renderer.fb, renderer.w, renderer.h, tape, stateT, bench.needGesture == Bench.GESTURE_FS_RECT);
                        renderer.present();
                        camcorder.dread = 0.0;
                        camcorder.flags = Camcorder.G_NONE;
                        camcorder.apply(renderer.bd, frameSeed);
                        // unattended (?auto / ?soak): nobody will click; after 20 s of waiting the windowed numbers become final
                        benchWait += dt;
                        if (auto && benchWait > 20.0) bench.abandonFullscreen(benchCb);
                    }
                case ST_CARD:
                    cards.drawCard(renderer.fb, renderer.w, renderer.h, tape, stateT, firstCardOfSession);
                    whereFlag = W_RENDER;
                    renderer.present();
                    camcorder.dread = 0.0;
                    camcorder.flags = stateT > CARD_SECS - 1.0 ? Camcorder.G_TEAR : Camcorder.G_NONE;
                    camcorder.apply(renderer.bd, frameSeed);
                    whereFlag = W_LOGIC;
                    audio.update(dt);
                    if (stateT > 1.0) tapeSnap(SN_CARD, "card");
                    if ((stateT > CARD_MIN_SECS && (input.anyKey || input.clicked)) || stateT > CARD_SECS) enterPlay();
                case ST_PLAY:
                    var t0 = flash.Lib.getTimer();
                    // 1 world residency
                    whereFlag = W_GEN;
                    var pcx = player.cellX(); var pcy = player.cellY();
                    var ccx = pcx >> 5; var ccy = pcy >> 5;
                    world.ensureAround(ccx, ccy);
                    world.pump(1);
                    if (frame % 30 == 0) world.evictOutside(ccx, ccy, World.EVICT_RADIUS);
                    var t1 = flash.Lib.getTimer();
                    tGen = t1 - t0;
                    whereFlag = W_LOGIC;
                    // 2 player
                    var pe:Int;
                    if (soak) {
                        bot.update(dt, player, world);
                        pe = player.update(dt, bot.fwd, bot.turn, 0, bot.run, world);
                    } else {
                        pe = player.update(dt, input.fwd(), input.turn(), input.strafe(), input.run(), world);
                    }
                    // 3 director
                    director.update(dt, false, pe);
                    var ev = director.events;
                    // scripted deaths: ?die= at 8 s of tape time, rc "die"
                    if (dieKind != 0 && !dieDone && director.tapeTime >= 8.0) { pendingKill = dieKind; dieDone = true; }
                    // 4 events -> audio / camcorder / hud / quality
                    applyEvents(ev, pe);
                    // 5 kill
                    if ((ev & Director.EV_KILL) != 0 || pendingKill != 0) {
                        var k = (ev & Director.EV_KILL) != 0 ? director.killer : pendingKill;
                        pendingKill = 0;
                        tLogic = flash.Lib.getTimer() - t1;
                        beginDying(k);
                    } else {
                        pcx = player.cellX(); pcy = player.cellY();
                        // 6 raycast
                        var cols = Quality.rays(quality.rung);
                        if (cols != curCols || tape.fov != curFov) { curCols = cols; curFov = tape.fov; raycaster.setColumns(curCols, curFov); }
                        var t2 = flash.Lib.getTimer();
                        tLogic = t2 - t1;
                        raycaster.castRays(world, player.x, player.y, player.ang, hits);
                        var t3 = flash.Lib.getTimer();
                        tRay = t3 - t2;
                        // 7 map memory (every 3rd frame)
                        if (frame % 3 == 0) {
                            mapMemory.recordHits(hits);
                            mapMemory.visit(pcx, pcy, world.cell(pcx, pcy));
                            if (mapMemory.chunkCount() > MapMemory.MAX_CHUNKS) mapMemory.evictFarthest(pcx, pcy);
                        }
                        // 8 paper (no-op with an empty queue)
                        mapPaper.pump(mapMemory, pcx, pcy);
                        var t4 = flash.Lib.getTimer();
                        tMap = t4 - t3;
                        // 9 render
                        whereFlag = W_RENDER;
                        if (throwAt > 0 && frame >= throwAt) { throwAt = 0; throw "throw=1: deliberate throw at frame 100"; }   // the first PLAY frame at or after 100
                        renderer.render(hits, raycaster, player.x, player.y, director.lightOffset, Quality.floorMode(quality.rung), world);
                        // 10 sprites
                        spritePass.draw(renderer, hits, raycaster, player.x, player.y, player.ang, director.watcher, director.hound, director.lightOffset, frameSeed, false);
                        // 11 hud
                        var t5 = flash.Lib.getTimer();
                        var strobeFrame = strobeOn && (frame & 1) == 0;
                        hud.tick(dt, director.tapeTime, tsSkipThisFrame(ev));
                        hud.draw(renderer.fb, renderer.w, renderer.h, director.battery, strobeFrame);
                        if (playFade > 0.0) {
                            hud.drawPlayFade(renderer.fb, renderer.w, renderer.h, playFade > 1.0 ? 1.0 : playFade);
                            playFade -= dt;
                        }
                        if (noSignalFrames > 0) {
                            cards.drawNoSignal(renderer.fb, renderer.w, renderer.h, 30 - noSignalFrames);
                            noSignalFrames--;
                        }
                        var t6 = flash.Lib.getTimer();
                        tHud = t6 - t5;
                        // 12 present
                        renderer.present();
                        var t7 = flash.Lib.getTimer();
                        tSet = t7 - t6;
                        // 13 post
                        camcorder.dread = director.presence;
                        camcorder.flags = playFlags(dt, strobeFrame);
                        camcorder.apply(renderer.bd, frameSeed);
                        whereFlag = W_LOGIC;
                        // 14 audio
                        var t8 = flash.Lib.getTimer();
                        spatialAudio(ev);
                        audio.update(dt);
                        tAudio = flash.Lib.getTimer() - t8;
                        // 15 map toggle
                        var wantToggle = input.mapToggle();
                        if (soak) { if (bot.wantMapToggle && !prevWantMap) wantToggle = true; prevWantMap = bot.wantMapToggle; }
                        if (wantToggle) {
                            if (director.presence > 0.6) {
                                noSignalFrames = 30;
                                audio.oneShot(AudioBus.STATIC, 0.15, 0.0);
                                emit("bk=nosignal&P=" + d2(director.presence));
                            } else {
                                setState(ST_MAP);
                                mapPaper.openAt(player.x, player.y);
                                audio.oneShot(AudioBus.PAPER, 0.6, 0.0);
                            }
                        }
                        // 16 snap / digits / probes
                        if (input.snapKey()) Telemetry.snap(renderer.bd, "play");
                        if (debug) {
                            var dg = input.digit();
                            if (dg > 0) { var from = quality.rung; quality.set(dg - 1); applyRung(from, "override"); }
                        }
                        if (input.fullscreenKey()) input.fullscreen = display.fullscreen;   // OSD/telemetry edge only: the entry happened in onGesture
                        if (firstRun && display.fullscreen && input.anyKey) {
                            var kc = input.lastKeyCode;
                            if (kc >= 0 && kc < 256 && keySeen[kc] == 0) { keySeen[kc] = 1; emit("bk=key&code=" + kc + "&fs=1"); }
                        }
                        // automatic snapshots (rate-limited)
                        if (stateT > 5.0) tapeSnap(SN_PLAY, "play");
                        if (director.watcher.alive && director.watcher.inView && director.watcher.dist < 8.0) tapeSnap(SN_WATCHER, "watcher");
                        if (director.hound.alive && director.hound.state == Hound.S_CHASE) tapeSnap(SN_HOUND, "hound");
                        if (!stageSnapDone && stateT > 6.0 && !nosnap && Telemetry.enabled) { stageSnapDone = true; display.snapStage("stage"); }
                        if (soak && flash.Lib.getTimer() - lastSoakSnap >= 300000) { lastSoakSnap = flash.Lib.getTimer(); soakSnaps++; autoSnap("soak" + soakSnaps); }
                    }
                    entityActive = (director.watcher.alive && director.watcher.dist < 12.0) || (director.hound.alive && director.hound.state != Hound.S_DORMANT);
                case ST_MAP:
                    var t0 = flash.Lib.getTimer();
                    director.update(dt, true, 0);
                    var ev = director.events;
                    applyEvents(ev, 0);
                    var mul = 4 * (input.run() ? 3 : 1);
                    var pdx = input.turn() * mul;
                    var pdy = -input.fwd() * mul;
                    if (pdx != 0 || pdy != 0) mapPaper.pan(pdx, pdy);
                    var t1 = flash.Lib.getTimer();
                    tLogic = t1 - t0;
                    var pcx = player.cellX(); var pcy = player.cellY();
                    mapPaper.pump(mapMemory, pcx, pcy);
                    whereFlag = W_RENDER;
                    var wob = stateT * Math.PI;                       // 0.5 Hz hand wobble, +/-2 px
                    var wx = Std.int(Math.sin(wob) * 2.0);
                    var wy = Std.int(Math.cos(wob * 0.7) * 2.0);
                    mapPaper.compose(renderer.bd, renderer.w, renderer.h, player.x, player.y, player.ang, wx, wy);
                    var t2 = flash.Lib.getTimer();
                    tMap = t2 - t1;
                    var strobeFrame = strobeOn && (frame & 1) == 0;
                    hud.tick(dt, director.tapeTime, tsSkipThisFrame(ev));
                    hud.drawStrip(renderer.strip, renderer.w, director.battery, strobeFrame);
                    var t3 = flash.Lib.getTimer();
                    tHud = t3 - t2;
                    renderer.presentStrip(renderer.h - Renderer.STRIP_H - Camcorder.HEAD_ROWS);   // above the head-switch bar, which would otherwise eat the timestamp's lower rows
                    var t4 = flash.Lib.getTimer();
                    tSet = t4 - t3;
                    camcorder.dread = director.presence;
                    camcorder.flags = playFlags(dt, strobeFrame);
                    camcorder.apply(renderer.bd, frameSeed);
                    whereFlag = W_LOGIC;
                    var t5 = flash.Lib.getTimer();
                    spatialAudio(ev);
                    audio.update(dt);
                    tAudio = flash.Lib.getTimer() - t5;
                    tapeSnap(SN_MAP, "map");
                    if (input.snapKey()) Telemetry.snap(renderer.bd, "map");
                    var wantToggle = input.mapToggle();
                    if (soak) { if (!bot.wantMapToggle && prevWantMap) wantToggle = true; prevWantMap = bot.wantMapToggle; }
                    if (wantToggle || pendingKill != 0) {
                        setState(ST_PLAY);
                        mapPaper.close();
                        audio.oneShot(AudioBus.PAPER, 0.6, 0.0);
                    }
                    entityActive = true;
                case ST_DYING:
                    stepDying(dt);
                    entityActive = true;
                case ST_ENDS:
                    var caption = deathKind == Director.K_BATTERY ? "BATTERY" : (deathKind == Director.K_DAMAGED ? "TAPE DAMAGED" : "TAPE ENDS");
                    cards.drawEnds(renderer.fb, renderer.w, renderer.h, stateT, caption);
                    whereFlag = W_RENDER;
                    renderer.present();
                    camcorder.dread = 0.0;
                    camcorder.flags = Camcorder.G_NONE;
                    camcorder.apply(renderer.bd, frameSeed);
                    whereFlag = W_LOGIC;
                    audio.update(dt);
                    if (stateT >= ENDS_SECS) {
                        audio.oneShot(AudioBus.TAPE, 0.7, 0.0);
                        audio.setPresence(0.0);
                        save.tapeCount++;
                        save.deaths++;
                        var secs = Std.int(director.tapeTime);
                        if (secs > save.bestSeconds) save.bestSeconds = secs;
                        save.rung = quality.rung;
                        if (saveEnabled) Save.flush(save);
                        lastFlush = flash.Lib.getTimer();
                        startTape(save.tapeCount + 1);
                        setState(ST_CARD);
                    }
                case ST_PAUSED:
                    if (!pausedDrawn) {
                        pausedDrawn = true;
                        cards.drawPause(renderer.fb, renderer.w, renderer.h, !display.fullscreen);
                        renderer.present();
                        camcorder.dread = 0.0;
                        camcorder.flags = Camcorder.G_NONE;
                        camcorder.apply(renderer.bd, frameSeed);
                    }
                    audio.update(dt);                       // silent (paused volumes), but the loops keep their crossfade state
                    if (input.anyKey || input.clicked) resumeFromPause();
                default:
            }
        } catch (err:Dynamic) {
            onFrameError(err);
        }
        whereFlag = W_OTHER;
        var tOurs = flash.Lib.getTimer() - now;

        // quality ladder: fed by play, map and death frames only (cards and the bench would pre-load its raise counter with cheap frames)
        if (state == ST_PLAY || state == ST_MAP || state == ST_DYING) {
            var change = quality.noteFrame(tOurs + quality.presentEstimate, frameToFrameMs, entityActive, state == ST_DYING, state == ST_MAP);
            if (change != 0) {
                var from = quality.rung;
                var to = from + change;
                if (to < 0) to = 0;
                if (to > quality.maxRung) to = quality.maxRung;
                if (to != from) {
                    quality.set(to);
                    applyRung(from, change < 0 ? "drop" : "raise");
                    if (state == ST_PLAY) autoSnap("rung" + quality.rung);   // §4 tag rung<N>; the concatenation happens only on a rung change (an event)
                }
            }
        }

        // telemetry accumulation and ticks
        if (state == ST_PLAY || state == ST_MAP || state == ST_DYING) {
            tick[T_LOGIC] += tLogic; tick[T_GEN] += tGen; tick[T_RAY] += tRay;
            tick[T_WALL] += renderer.tWall; tick[T_FLOOR] += renderer.tFloor; tick[T_SPR] += spritePass.tSpr;
            tick[T_HUD] += tHud; tick[T_MAP] += tMap; tick[T_SET] += tSet; tick[T_POST] += camcorder.tPost;
            tick[T_AUDIO] += tAudio; tick[T_OURS] += tOurs; tick[T_PRESENT] += tPresent;
            tick[T_BUSY] += tOurs + Std.int(quality.presentEstimate);
            tick[T_SPAN] += frameToFrameMs;               // the counted frames' own wall time (fps/ms exclude card/ends/pause frames)
            tickFrames++;
        }
        var tnow = flash.Lib.getTimer();
        if (tnow - lastTick >= TICK_MS) sendTick(tnow);
        else flushPending(tnow);
        if (tnow - lastFlush >= FLUSH_MS && state != ST_BENCH && state != ST_BOOT) {
            lastFlush = tnow;
            save.rung = quality.rung;
            if (saveEnabled) Save.flush(save);
        }
        stg.invalidate();                               // RENDER fires before the present: tPresent = RENDER -> next ENTER_FRAME
        input.endFrame();                               // ALWAYS reached, even after a throw
        frame++;
    }

    // --- per-frame pieces ------------------------------------------------------------------

    function tsSkipThisFrame(ev:Int):Int {
        return (ev & Director.EV_TS_SKIP) != 0 ? director.tsSkipSeconds : 0;
    }

    // step 4: Director events -> audio, camcorder, hud, quality
    function applyEvents(ev:Int, pe:Int):Void {
        var w = director.watcher;
        var h = director.hound;
        hud.recVisible = (ev & Director.EV_WATCHER_RELOCATED) == 0;
        if ((ev & Director.EV_WATCHER_RELOCATED) != 0) {
            audio.oneShot(AudioBus.CLICKS1 + (frameSeed & 1), AudioBus.falloff(w.dist) * 0.8, AudioBus.panOf(w.bearing));
            if (director.presence > 0.3) { camcorder.glitchNow(); quality.lock(2.0); }
        }
        if ((ev & Director.EV_WATCHER_DESPAWN) != 0) camcorder.flags |= Camcorder.G_DROPOUT;
        if ((ev & Director.EV_WATCHER_LUNGE) != 0) { camcorder.glitchNow(); camcorder.tearNow(3); quality.lock(2.0); }
        if ((ev & Director.EV_HOUND_SPAWN) != 0) { camcorder.glitchNow(); quality.lock(2.0); }
        if ((ev & Director.EV_SCREAM) != 0) audio.oneShot(AudioBus.SCREAM, 0.45, director.distantPan * 0.5);
        if ((ev & Director.EV_HOWL) != 0) audio.oneShot(AudioBus.HOWL1 + (frameSeed & 1), AudioBus.falloff(h.dist * 0.5), AudioBus.panOf(h.bearing));
        if ((ev & Director.EV_SNARL) != 0) audio.oneShot(AudioBus.SNARL, AudioBus.falloff(h.dist * 0.6), AudioBus.panOf(h.bearing));
        if ((ev & Director.EV_HOUND_STEP) != 0) audio.houndStep(h.dist, AudioBus.panOf(h.bearing));
        if ((ev & Director.EV_BLACKOUT_START) != 0) { audio.oneShot(AudioBus.FLICKER, 0.6, 0.0); camcorder.tearNow(2); }
        if ((ev & Director.EV_FLICKER) != 0) audio.oneShot(AudioBus.FLICKER, 0.25, 0.0);
        if ((ev & Director.EV_DISTANT) != 0) {
            var id = director.distantId;
            var behind = id >= 16;
            var snd = AudioBus.DISTANT1 + (id & 15);
            if (snd > AudioBus.DISTANT1 + 5) snd = AudioBus.DISTANT1 + 5;
            audio.oneShot(snd, director.distantVol, behind ? director.distantPan * 0.2 : director.distantPan);
        }
        if ((ev & Director.EV_HUM_LOW_ON) != 0) audio.setHumLow(true);
        if ((ev & Director.EV_HUM_LOW_OFF) != 0) audio.setHumLow(false);
        if ((ev & Director.EV_PIT_STUMBLE) != 0) {
            audio.oneShot(AudioBus.DISTANT1 + 4, 0.8, 0.0);     // the thud
            camcorder.tearNow(4);
            stormFrames = 60;                                   // 3 s tracking storm
        }
        if ((ev & Director.EV_STROBE_ON) != 0) strobeOn = true;
        if ((pe & Player.PE_STEP_WET) != 0) audio.footstep(true);
        else if ((pe & Player.PE_STEP) != 0) audio.footstep(false);
        if (player.onDark != prevDark) { prevDark = player.onDark; audio.setDark(prevDark); }
        // light-derived brightness jitter for the post: 0.85..1.05
        var lo = director.lightOffset;
        camcorder.flickerBrightness = 1.02 - lo * 0.008 - ((frameSeed >> 4) & 3) * 0.01;
        camcorder.chromaPx = Std.int(director.presence * 5.0);
    }

    // step 14 spatial audio
    function spatialAudio(ev:Int):Void {
        audio.setPresence(director.presence);
        var c = world.cell(player.cellX(), player.cellY());
        var base = Cells.hasLight(c) ? 1.0 : 0.65;
        if (Cells.type(c) == Cells.DARK) base = 0.35;
        var lo = director.lightOffset;
        var level = base * (1.0 - lo / 15.0);
        if (level < 0.0) level = 0.0;
        audio.setHumLight(level);
        audio.setDrip(director.pitDist, director.pitPan);
    }

    // the camcorder flags of a play/map frame (tears, roll, blackout, strobe, dropouts)
    function playFlags(dt:Float, strobeFrame:Bool):Int {
        var f = camcorder.flags & Camcorder.G_DROPOUT;      // a despawn dropout requested this frame survives; the rest is rebuilt
        var h = director.hound;
        var dread = director.presence;
        if (director.blackoutT > 0.0) f |= Camcorder.G_BLACKOUT;
        if (strobeFrame) f |= Camcorder.G_STROBE;
        var houndNear = h.alive && h.state == Hound.S_CHASE && h.dist < 4.0;
        if (houndNear || stormFrames > 0) {
            f |= Camcorder.G_TEAR;
            camcorder.tearBands = 1 + ((frameSeed >>> 8) & 3);
            if (stormFrames > 0) stormFrames--;
        }
        tearTimer -= dt;
        if (tearTimer <= 0.0) {
            camcorder.tearNow(1 + ((frameSeed >>> 12) & 3));
            var u = ((frameSeed >>> 16) & 255) / 255.0;
            tearTimer = dread > 0.4 ? 2.0 + 3.0 * u : 12.0 + 13.0 * u;
        }
        dropTimer -= dt;
        if (dropTimer <= 0.0) {
            f |= Camcorder.G_DROPOUT;
            var u2 = ((frameSeed >>> 20) & 255) / 255.0;
            dropTimer = (6.0 + 9.0 * u2) * (1.0 - 0.5 * dread);
        }
        if (h.alive && h.state == Hound.S_CHASE) {
            f |= Camcorder.G_ROLL;
            camcorder.rollPx = 2 + ((frameSeed >>> 24) & 3);
        } else if (tape.badTape) {
            f |= Camcorder.G_ROLL;
            camcorder.rollPx = 1;
        } else {
            camcorder.rollPx = 0;
        }
        return f;
    }

    // the whole scene: cast, walls/floor, sprites (plain = the killer drawn at band 0)
    function renderScene(plain:Bool):Void {
        raycaster.castRays(world, player.x, player.y, player.ang, hits);
        renderer.render(hits, raycaster, player.x, player.y, director.lightOffset, Quality.floorMode(quality.rung), world);
        spritePass.draw(renderer, hits, raycaster, player.x, player.y, player.ang, director.watcher, director.hound, director.lightOffset, frameSeed, plain);
    }

    function fillBlack():Void {
        var fb = renderer.fb;
        var n = renderer.w * renderer.h;
        for (i in 0...n) fb[i] = 0xFF000000;
    }

    // ST_DYING timeline (CONTRACT §3, DESIGN §7); dyingFrame counts the frames of this state from 0
    function stepDying(dt:Float):Void {
        var kind = deathKind;
        var plainStart = kind == Director.K_PIT ? 0.5 : (kind == Director.K_BATTERY ? 0.6 : 0.0);
        var t = stateT;
        var w = renderer.w; var h = renderer.h;
        audio.update(dt);
        if (t < plainStart) {
            whereFlag = W_RENDER;
            renderScene(false);
            hud.tick(dt, director.tapeTime, 0);
            hud.draw(renderer.fb, w, h, director.battery, false);
            if (kind == Director.K_PIT) {
                renderer.present();
                camcorder.dread = 0.6;
                camcorder.flags = Camcorder.G_ROLL;
                camcorder.rollPx = 4 + Std.int(t / 0.5 * 20.0);
                if (camcorder.rollPx > 24) camcorder.rollPx = 24;
                if (dyingFrame % 3 == 0) camcorder.tearNow(2);
                camcorder.apply(renderer.bd, frameSeed);
            } else {
                // collapse to a line: a horizontal band shrinking from h rows to 2
                var band = Std.int(h * (1.0 - t / 0.6));
                if (band < 2) band = 2;
                var y0 = (h - band) >> 1;
                var y1 = y0 + band;
                var fb = renderer.fb;
                for (i in 0...(y0 * w)) fb[i] = 0xFF000000;
                for (i in (y1 * w)...(h * w)) fb[i] = 0xFF000000;
                renderer.present();
                camcorder.dread = 0.3;
                camcorder.flags = Camcorder.G_STROBE;
                camcorder.rollPx = 0;
                camcorder.apply(renderer.bd, frameSeed);
            }
            whereFlag = W_LOGIC;
            dyingFrame++;
            return;
        }
        if (plainStartFrame < 0) plainStartFrame = dyingFrame;   // the first frame at t >= plainStart
        var u = t - plainStart;
        if (u < 1.2) {
            whereFlag = W_RENDER;
            renderScene((dyingFrame - plainStartFrame) < 2);        // the killer plain for EXACTLY 2 frames (a frame count)
            hud.tick(dt, director.tapeTime, 0);
            hud.draw(renderer.fb, w, h, director.battery, (dyingFrame & 1) == 0 && strobeOn);
            renderer.present();
            camcorder.tearNow(1 + Std.int(u * 3.0));
            var f = Camcorder.G_TEAR | Camcorder.G_ROLL;
            if (dyingFrame % 3 == 0) { f |= Camcorder.G_GLITCH; camcorder.glitchNow(); }
            camcorder.dread = u / 1.2;
            camcorder.rollPx = 2 + Std.int(u * 12.0);
            camcorder.chromaPx = 2 + Std.int(u * 2.5);
            camcorder.flags = f;
            camcorder.apply(renderer.bd, frameSeed);
            whereFlag = W_LOGIC;
        } else if (u < 1.7) {
            if (!staticDone) { staticDone = true; audio.oneShot(AudioBus.STATIC, 0.9, 0.0); }
            whereFlag = W_RENDER;
            camcorder.dread = 1.0;
            camcorder.flags = Camcorder.G_NOISE_FULL;            // pure noise sheet, no render
            camcorder.apply(renderer.bd, frameSeed);
            whereFlag = W_LOGIC;
            if (u < 1.25) autoSnap(kind == Director.K_WATCHER ? "death_watcher" : (kind == Director.K_HOUND ? "death_hound" : (kind == Director.K_PIT ? "death_pit" : (kind == Director.K_BATTERY ? "death_battery" : "death_damaged"))));
        } else if (u < 1.8) {
            whereFlag = W_RENDER;
            fillBlack();
            renderer.present();                                  // black, no post
            whereFlag = W_LOGIC;
        } else {
            setState(ST_ENDS);
        }
        dyingFrame++;
    }

    // --- telemetry -------------------------------------------------------------------------

    function pingBoot():Void {
        var q = bootUrl.indexOf("?");
        var params = q >= 0 ? bootUrl.substr(q + 1) : "";
        var ver = "";
        var cpu = "";
        var os = "";
        try {
            ver = flash.system.Capabilities.version;
            os = flash.system.Capabilities.os;
            cpu = flash.system.Capabilities.cpuArchitecture;
        } catch (e:Dynamic) {}
        Telemetry.ping("bk=boot&ver=" + StringTools.urlEncode(ver) + "&cpu=" + StringTools.urlEncode(cpu) + "&os=" + StringTools.urlEncode(os)
            + "&sw=" + display.stageW + "&sh=" + display.stageH + "&so_ok=" + (Save.ok ? 1 : 0)
            + "&tape=" + tape.index + "&rung=" + quality.rung + "&maxRungWin=" + maxRungWin + "&maxRungFs=" + maxRungFs
            + "&fsHw=" + fsHw + "&qLow=" + qLow + "&bench=" + (benchWanted ? 1 : 0) + "&params=" + StringTools.urlEncode(params));
        lastPing = flash.Lib.getTimer();
    }

    function sendTick(now:Int):Void {
        var wall = now - lastTick;
        lastTick = now;
        var n = tickFrames;
        if (n < 1) n = 1;
        // fps and ms over the counted (PLAY/MAP/DYING) frames' own wall time, so a tape change inside the window does not read as a drop
        var span = tick[T_SPAN];
        var fps = span > 0 ? tickFrames * 1000.0 / span : 0.0;
        var ms = tickFrames > 0 ? span / tickFrames : 0.0;
        var ents = 0;
        if (director != null) {
            if (director.watcher.alive) ents++;
            if (director.hound.alive) ents++;
        }
        var mem:Float = 0;
        try { mem = flash.system.System.totalMemory; } catch (e:Dynamic) { mem = 0; }
        var s = "bk=tick&fps=" + d1(fps) + "&ms=" + d1(ms) + "&rung=" + quality.rung + "&tier=" + renderer.tier
            + "&t_logic=" + d1(tick[T_LOGIC] / n) + "&t_gen=" + d1(tick[T_GEN] / n) + "&t_ray=" + d1(tick[T_RAY] / n)
            + "&t_wall=" + d1(tick[T_WALL] / n) + "&t_floor=" + d1(tick[T_FLOOR] / n) + "&t_spr=" + d1(tick[T_SPR] / n)
            + "&t_hud=" + d1(tick[T_HUD] / n) + "&t_map=" + d1(tick[T_MAP] / n) + "&t_set=" + d1(tick[T_SET] / n)
            + "&t_post=" + d1(tick[T_POST] / n) + "&t_audio=" + d1(tick[T_AUDIO] / n) + "&t_ours=" + d1(tick[T_OURS] / n)
            + "&t_present=" + d1(tick[T_PRESENT] / n) + "&t_busy=" + d1(tick[T_BUSY] / n)
            + "&mem=" + Std.int(mem) + "&chunks=" + world.loadedCount()
            + "&mapChunks=" + (mapMemory != null ? mapMemory.chunkCount() : 0) + "&sheets=" + mapPaper.sheets + "&ents=" + ents
            + "&D=" + (director != null ? d2(director.D) : "0") + "&P=" + (director != null ? d2(director.presence) : "0")
            + "&tape=" + (tape != null ? tape.index : 0) + "&chans=" + audio.channels()
            + "&tt=" + (director != null ? d1(director.tapeTime) : "0")
            + "&x=" + player.cellX() + "&y=" + player.cellY() + "&fs=" + (display.fullscreen ? 1 : 0)
            + "&s=" + stateName(state) + "&frames=" + tickFrames + "&wall=" + wall + "&err=" + errTotal;
        if (pending != "") { s = s + "|" + pending; pending = ""; }
        Telemetry.ping(s);
        lastPing = now;
        for (i in 0...N_T) tick[i] = 0;
        tickFrames = 0;
    }
}
