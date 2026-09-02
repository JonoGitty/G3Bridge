// The one Bitmap on the stage and its layout (CONTRACT §2). fp class.
// SKELETON: constructor creates the Bitmap and its Rectangle and sets the stage modes; layout/fullscreen do nothing.
import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.display.Stage;
import flash.geom.Rectangle;

class Display {
    public var bitmap:Bitmap;
    public var tier:Int;
    public var fullscreen:Bool;
    public var hwRect:Bool;                             // use fullScreenSourceRect when entering fullscreen
    public var stageW:Int;
    public var stageH:Int;
    public var onFullscreenChange:Bool->Void;           // Main hooks this (allocated once at start)

    var stage:Stage;
    var srcRect:Rectangle;                              // reused source rect for fullscreen

    // NO_SCALE, TOP_LEFT, quality LOW, listens to RESIZE and FULL_SCREEN
    public function new(stage:Stage):Void {
        this.stage = stage;
        bitmap = new Bitmap();
        srcRect = new Rectangle(0, 0, 320, 240);
        tier = 1;
        fullscreen = false;
        hwRect = false;
        stageW = stage.stageWidth;
        stageH = stage.stageHeight;
        onFullscreenChange = null;
        stage.scaleMode = flash.display.StageScaleMode.NO_SCALE;
        stage.align = flash.display.StageAlign.TOP_LEFT;
        stage.quality = flash.display.StageQuality.LOW;
        // SKELETON: RESIZE / FULL_SCREEN listeners not yet attached
    }

    // sets bitmapData, smoothing = true, relayouts
    public function attach(bd:BitmapData, tier:Int):Void {
        this.tier = tier;
        bitmap.bitmapData = bd;
        bitmap.smoothing = true;
        layout();
    }

    // windowed: 4:3 letterbox centred; fullscreen+hwRect: scale 1 at (0,0); fullscreen software: scale to 1024x768
    public function layout():Void {
        // SKELETON
    }

    // sets fullScreenSourceRect first if hwRect; try/catch; returns false on SecurityError
    public function enterFullscreen():Bool {
        return false; // SKELETON
    }

    public function exitFullscreen():Void {
        // SKELETON
    }

    // draws the stage into a 1024x768 BitmapData and Telemetry.snap()s it (one-off, ~100 ms)
    public function snapStage(tag:String):Void {
        // SKELETON
    }
}
