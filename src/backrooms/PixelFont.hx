// 5x7 bitmap font blitter (CONTRACT §2). fp class.
// SKELETON: width() is complete (advance = 6*scale); blit()/blitJitter() draw nothing.
class PixelFont {
    // 5x7 glyphs for ASCII 32..126 plus 0x7F = REC dot, 0x80 = play triangle, 0x81 = pause bars, 0x82 = battery cell. Unknown chars draw as a box.
    // clips to the buffer; advance = 6*scale
    public static function blit(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, colour:UInt, scale:Int):Void {
        // SKELETON
    }

    public static function width(s:String, scale:Int):Int {
        return s.length * 6 * scale;
    }

    // per-glyph +/-1 px offsets from seed (card look)
    public static function blitJitter(fb:flash.Vector<UInt>, w:Int, h:Int, x:Int, y:Int, s:String, colour:UInt, scale:Int, seed:Int):Void {
        // SKELETON
    }
}
