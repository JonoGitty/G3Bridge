// The one Bitmap on the stage and its layout (CONTRACT §2). fp class.
//
// Stage modes: NO_SCALE, TOP_LEFT, quality MEDIUM (LOW makes Flash ignore Bitmap.smoothing and draws the
// map's pencil Shapes unantialiased; the only vector content is one Bitmap and the map draws, so MEDIUM's AA
// costs nothing). Layout: windowed = 4:3 letterbox centred in the stage (1024x617 -> (101, 0, 822, 617));
// fullscreen with the source rect taken = scale 1 at (0,0) and the player's own scaler does the upscale;
// fullscreen software = scaled to the full screen (3.2x at T1, 4x at T0 on 1024x768).
//
// enterFullscreen() MUST be called synchronously inside the dispatch of the user's own mouse/key event
// (Input.onGesture -> Main.onGesture): from ENTER_FRAME, a Timer, a URLLoader callback or ExternalInterface
// Flash Player throws SecurityError #2152 every time. exitFullscreen() may be called from anywhere.
//
// Budget: 0 per frame (nothing here runs in the frame loop). Present timing is Main's: it calls
// stage.invalidate() each frame and brackets RENDER -> next ENTER_FRAME as t_present (CONTRACT §3);
// this class reads no clock (rule 10). Main adds `bitmap` to its own display list.
import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.display.Stage;
import flash.display.StageAlign;
import flash.display.StageDisplayState;
import flash.display.StageQuality;
import flash.display.StageScaleMode;
import flash.events.Event;
import flash.events.FullScreenEvent;
import flash.geom.Rectangle;

class Display {
    public var bitmap:Bitmap;
    public var tier:Int;
    public var fullscreen:Bool;
    public var hwRect:Bool;                             // use fullScreenSourceRect when entering fullscreen
    public var lowQuality:Bool;                         // false (default): stage.quality = MEDIUM; true: LOW — the fallback Bench picks only if MEDIUM+smoothing measured > 4 ms worse than LOW
    public var stageW:Int;
    public var stageH:Int;
    public var onFullscreenChange:Bool->Void;           // Main hooks this (allocated once at start): quality.setMaxRung(fs ? maxRungFs : maxRungWin) and quality.presentEstimate for the new mode

    var stage:Stage;
    var srcRect:Rectangle;                              // reused source rect for fullscreen
    var rectTook:Bool;                                  // the player accepted fullScreenSourceRect on the last entry (reads back non-null)
    var rectWanted:Bool;                                // hwRect at the moment of the last entry attempt (hwRect may be flipped between bench arms)
    var bufW:Int;                                       // native size of the attached BitmapData
    var bufH:Int;

    // NO_SCALE, TOP_LEFT, quality MEDIUM (at LOW Flash ignores Bitmap.smoothing entirely and BitmapData.draw() is unantialiased; the only vector content is one Bitmap and the map draws, so AA costs nothing), listens to RESIZE and FULL_SCREEN
    public function new(stage:Stage):Void {
        this.stage = stage;
        bitmap = new Bitmap();
        bitmap.smoothing = true;
        srcRect = new Rectangle(0, 0, Renderer.W1, Renderer.H1);
        tier = 1;
        fullscreen = false;
        hwRect = true;
        lowQuality = false;
        rectTook = false;
        rectWanted = false;
        bufW = Renderer.W1;
        bufH = Renderer.H1;
        stageW = stage.stageWidth;
        stageH = stage.stageHeight;
        onFullscreenChange = null;
        stage.scaleMode = StageScaleMode.NO_SCALE;
        stage.align = StageAlign.TOP_LEFT;
        stage.quality = StageQuality.MEDIUM;
        try {
            fullscreen = stage.displayState != StageDisplayState.NORMAL;
        } catch (e:flash.errors.Error) {
            fullscreen = false;
        }
        stage.addEventListener(Event.RESIZE, onResize);
        stage.addEventListener(FullScreenEvent.FULL_SCREEN, onFullScreen);
        layout();
    }

    // stage.quality = on ? LOW : MEDIUM (smoothing is then ignored at LOW); lowQuality = on
    public function setLowQuality(on:Bool):Void {
        lowQuality = on;
        stage.quality = on ? StageQuality.LOW : StageQuality.MEDIUM;
    }

    // sets bitmapData, smoothing = true, relayouts
    public function attach(bd:BitmapData, tier:Int):Void {
        this.tier = tier;
        bitmap.bitmapData = bd;
        bitmap.smoothing = true;
        bufW = bd.width;
        bufH = bd.height;
        layout();
    }

    // windowed: 4:3 letterbox centred; fullscreen+hwRect: scale 1 at (0,0); fullscreen software: scale to 1024x768
    public function layout():Void {
        stageW = stage.stageWidth;
        stageH = stage.stageHeight;
        layoutFor(stageW, stageH);
    }

    // The layout arithmetic for a given stage size (split out so a probe can check the 1024x617 letterbox on any stage).
    function layoutFor(sw:Int, sh:Int):Void {
        var bw = bufW;
        var bh = bufH;
        if (bw <= 0 || bh <= 0) return;
        if (fullscreen && rectTook) {
            // the player scales srcRect (0,0,bw,bh) to the screen itself; the Bitmap sits at native size
            bitmap.scaleX = 1.0;
            bitmap.scaleY = 1.0;
            bitmap.x = 0;
            bitmap.y = 0;
            return;
        }
        if (sw <= 0 || sh <= 0) return;
        // aspect-preserving fit: limited by height on the 1024x617 window (822x617 at x = 101), exact on 1024x768
        var outW:Int;
        var outH:Int;
        if (sw * bh >= sh * bw) {
            outH = sh;
            outW = Std.int((bw * sh) / bh);
        } else {
            outW = sw;
            outH = Std.int((bh * sw) / bw);
        }
        bitmap.scaleX = outW / bw;
        bitmap.scaleY = outH / bh;
        bitmap.x = (sw - outW) >> 1;
        bitmap.y = (sh - outH) >> 1;
    }

    // MUST be called synchronously inside the dispatch of the user's own MouseEvent/KeyboardEvent, i.e. from Input.onGesture. Flash Player throws
    // SecurityError #2152 for displayState = FULL_SCREEN from ENTER_FRAME, a Timer, a URLLoader callback or ExternalInterface — every time.
    // sets fullScreenSourceRect first if hwRect; try/catch; returns false on SecurityError (pings bk=fs&on=0&why=nogesture|denied)
    public function enterFullscreen():Bool {
        if (fullscreen) return true;
        rectWanted = hwRect;
        rectTook = false;
        try {
            if (hwRect) {
                srcRect.x = 0;
                srcRect.y = 0;
                srcRect.width = bufW;
                srcRect.height = bufH;
                stage.fullScreenSourceRect = srcRect;
            } else {
                stage.fullScreenSourceRect = null;
            }
        } catch (e:flash.errors.Error) {
            // Ruffle stubs the setter; a real player never throws here. Software scaling still works.
            rectWanted = false;
        }
        try {
            stage.displayState = StageDisplayState.FULL_SCREEN;
            return true;
        } catch (e:flash.errors.SecurityError) {
            // #2152: outside a user gesture, or the wrapper lacks allowFullScreen
            Telemetry.ping("bk=fs&on=0&sw=" + stageW + "&sh=" + stageH + "&rect=0&why=" + (e.errorID == 2152 ? "nogesture" : "denied") + "&n=" + e.errorID);
            return false;
        } catch (e:flash.errors.Error) {
            Telemetry.ping("bk=fs&on=0&sw=" + stageW + "&sh=" + stageH + "&rect=0&why=denied&n=" + e.errorID);
            return false;
        }
    }

    // may be called from anywhere (no gesture needed)
    public function exitFullscreen():Void {
        try {
            if (stage.displayState != StageDisplayState.NORMAL) stage.displayState = StageDisplayState.NORMAL;
        } catch (e:flash.errors.Error) {
            // leaving fullscreen never needs a gesture; a throw here means the player is already normal
        }
    }

    // draws the stage into a 1024x768 BitmapData and Telemetry.snap()s it (one-off, ~100 ms)
    public function snapStage(tag:String):Void {
        var bd:BitmapData = null;
        try {
            bd = new BitmapData(1024, 768, false, 0xFF000000);
            bd.draw(stage);
            Telemetry.snap(bd, tag);
        } catch (e:flash.errors.Error) {
            Telemetry.ping("bk=err&msg=snapStage&n=" + e.errorID + "&where=display");
        }
        if (bd != null) bd.dispose();
    }

    function onResize(e:Event):Void {
        layout();
    }

    // the player reports the mode change here (entry or Esc); the rect is "taken" when it reads back non-null after an entry that asked for it
    function onFullScreen(e:FullScreenEvent):Void {
        fullscreen = e.fullScreen;
        rectTook = false;
        if (fullscreen && rectWanted) {
            try {
                var r = stage.fullScreenSourceRect;
                rectTook = r != null && r.width == bufW && r.height == bufH;
            } catch (err:flash.errors.Error) {
                rectTook = false;
            }
        }
        layout();
        Telemetry.ping("bk=fs&on=" + (fullscreen ? 1 : 0) + "&sw=" + stageW + "&sh=" + stageH + "&rect=" + (rectTook ? 1 : 0) + "&tier=" + tier);
        if (onFullscreenChange != null) onFullscreenChange(fullscreen);
    }
}
