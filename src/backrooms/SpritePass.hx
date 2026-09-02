// Billboard sprites for the two entities (CONTRACT §2, DESIGN §1 step 4). fp class.
//
// Standard camera-plane billboard: transformY is the depth along the facing, screen x
// comes from the camera-plane inverse, height and width are h * size / depth, and the
// feet sit on the floor at that depth (the same row the wall base of a wall at that
// distance would have). Sprites are drawn far to near and every column is z-tested
// against the ray hit for that column, so an entity behind a wall leaves no pixel.
//
// The Watcher is a hole in the wallpaper: its band is the wall band of the same column
// + 3 (never below 6), its body pixels come from the per-tape noise table darkened by
// that band, re-noised every frame from frameSeed; at band 15 a column is not drawn.
// The Hound is a low black shape at its own distance band with two pale eye pixels
// that blink on (frameSeed >> 3) & 7 == 0, the only pixels allowed to be brighter than
// the wall. plain = true (the death frames) draws the entity at band 0 with a flat
// 0xFF303030 body, in front of the camera whatever side it struck from (depth clamped
// to PLAIN_MIN_DEPTH, centred) and without the per-column z-test, so a killer in
// contact behind the player or nearer than the wall the player is pressed against
// still fills the frame.
//
// Allocation: the hound body table is built in the constructor; draw() and drawOne()
// touch only locals and preallocated vectors. Float is used per sprite (two at most),
// never per pixel.
class SpritePass {
    static inline var EYE:UInt = 0xFFD8D0B0;
    static inline var PLAIN_BODY:UInt = 0xFF303030;
    static inline var HOUND_R = 0x0C;                   // body 0xFF0C0A08
    static inline var HOUND_G = 0x0A;
    static inline var HOUND_B = 0x08;
    static inline var FOG_R = 0x0A;                     // Textures' fog colour 0xFF0A0906
    static inline var FOG_G = 0x09;
    static inline var FOG_B = 0x06;
    static inline var MIN_DEPTH = 0.05;                 // nearer than this = behind or inside the camera
    static inline var PLAIN_MIN_DEPTH = 0.2;            // a killer in contact still fills the frame on the death frames
    static inline var MAX_DEPTH = 24.0;                 // past the fog (band 15 at 12 cells) nothing is drawn
    static inline var WATCHER_MIN_BAND = 6;
    static inline var WATCHER_BAND_ADD = 3;

    public var drawn:Int;                               // sprites drawn this frame (telemetry)
    public var tSpr:Int;

    var textures:Textures;
    var houndBody:flash.Vector<UInt>;                   // 16 entries: 0xFF0C0A08 darkened by band

    public function new(textures:Textures):Void {
        this.textures = textures;
        drawn = 0;
        tSpr = 0;
        houndBody = new flash.Vector<UInt>(16, true);
        for (b in 0...16) {
            houndBody[b] = 0xFF000000 | (shade(HOUND_R, b, FOG_R) << 16) | (shade(HOUND_G, b, FOG_G) << 8) | shade(HOUND_B, b, FOG_B);
        }
    }

    // The contract's band law for one channel: c * (15 - b) / 15, blended toward the fog channel for b >= 12, 0 at band 15.
    static function shade(c:Int, b:Int, fog:Int):Int {
        if (b >= 15) return 0;
        var v = Std.int((c * (15 - b)) / 15);
        if (b >= 12) v = Std.int(v + (fog - v) * ((b - 11) / 4.0) + 0.5);
        return v < 0 ? 0 : (v > 255 ? 255 : v);
    }

    // Draws alive entities as billboards into r.fb, sorted far to near, clipped per column against hits.dist. frameSeed re-noises the Watcher.
    public function draw(r:Renderer, hits:RayHits, rc:Raycaster, px:Float, py:Float, ang:Float, watcher:Watcher, hound:Hound, lightOffset:Int, frameSeed:Int, plain:Bool):Void {
        drawn = 0;
        var t0 = flash.Lib.getTimer();
        if (hits.count > 0) {
            if (lightOffset < 0) lightOffset = 0;
            if (lightOffset > 15) lightOffset = 15;
            var c = Math.cos(ang);
            var s = Math.sin(ang);
            var t = Math.tan(rc.fov * 0.5);
            if (t < 0.01) t = 0.01;
            var plx = -s * t;
            var ply = c * t;
            var invDet = 1.0 / (plx * s - c * ply);
            var minDepth = plain ? PLAIN_MIN_DEPTH : MIN_DEPTH;

            var wDepth = -1.0; var wTx = 0.0;
            if (watcher != null && watcher.alive) {
                var rx = watcher.x - px;
                var ry = watcher.y - py;
                wTx = invDet * (s * rx - c * ry);
                wDepth = invDet * (-ply * rx + plx * ry);
                if (plain && wDepth < minDepth) { wDepth = minDepth; wTx = 0.0; }   // death frames: the killer fills the centre even from behind or beside
            }
            var hDepth = -1.0; var hTx = 0.0;
            if (hound != null && hound.alive) {
                var rx = hound.x - px;
                var ry = hound.y - py;
                hTx = invDet * (s * rx - c * ry);
                hDepth = invDet * (-ply * rx + plx * ry);
                if (plain && hDepth < minDepth) { hDepth = minDepth; hTx = 0.0; }
            }
            var wOk = wDepth >= minDepth;
            var hOk = hDepth >= minDepth;
            // painter's order: the farther one first
            if (wOk && hOk && hDepth > wDepth) {
                drawOne(r, hits, Entity.K_HOUND, hound.frame, hTx, hDepth, hound.height, hound.width, lightOffset, frameSeed, plain);
                drawOne(r, hits, Entity.K_WATCHER, watcher.frame, wTx, wDepth, watcher.height, watcher.width, lightOffset, frameSeed, plain);
            } else {
                if (wOk) drawOne(r, hits, Entity.K_WATCHER, watcher.frame, wTx, wDepth, watcher.height, watcher.width, lightOffset, frameSeed, plain);
                if (hOk) drawOne(r, hits, Entity.K_HOUND, hound.frame, hTx, hDepth, hound.height, hound.width, lightOffset, frameSeed, plain);
            }
        }
        tSpr = flash.Lib.getTimer() - t0;
    }

    // One billboard. tX = camera-plane coordinate (screen x = w/2 * (1 + tX / depth)), depth in cells along the facing.
    function drawOne(r:Renderer, hits:RayHits, kind:Int, frame:Int, tX:Float, depth:Float, height:Float, width:Float, lo:Int, frameSeed:Int, plain:Bool):Void {
        var w = r.w;
        var h = r.h;
        var fb = r.fb;
        var cs = r.colShift;
        var half = h >> 1;
        if (depth > MAX_DEPTH) return;                          // beyond the fog: nothing to draw, and the band arithmetic stays in range
        var invDepth = 1.0 / depth;
        var sprH = Std.int(h * height * invDepth);
        var sprW = Std.int(h * width * invDepth);
        if (sprH < 1 || sprW < 1) return;
        var screenX = (w >> 1) * (1.0 + tX * invDepth);
        var bottom = half + Std.int(half * invDepth);          // feet on the floor at this depth
        var top = bottom - sprH;
        var xs = Std.int(screenX - sprW * 0.5);
        var xe = xs + sprW;
        var x0 = xs < 0 ? 0 : xs;
        var x1 = xe > w ? w : xe;
        if (x0 >= x1) return;
        var y0 = top < 0 ? 0 : top;
        var y1 = bottom > h ? h : bottom;
        if (y0 >= y1) return;
        var sw = Textures.spriteW(kind);
        var sh = Textures.spriteH(kind);
        var txStep = Std.int((sw << 16) / sprW);
        var tyStep = Std.int((sh << 16) / sprH);
        var ty0 = (y0 - top) * tyStep;
        var mask = textures.sprite(kind, frame);
        var depthFix = Std.int(depth * 65536.0);
        var hDist = hits.dist;
        var any = false;

        if (kind == Entity.K_WATCHER) {
            var wb = r.wallBand;
            var nb = textures.noiseBands;
            for (x in x0...x1) {
                if (!plain && depthFix >= hDist[x >> cs]) continue;
                var band = 0;
                if (!plain) {
                    band = wb[x] + WATCHER_BAND_ADD;
                    if (band < WATCHER_MIN_BAND) band = WATCHER_MIN_BAND;
                    if (band >= 15) continue;
                }
                var tx = ((x - xs) * txStep) >> 16;
                var mBase = tx * sh;
                var ty = ty0;
                var idx = y0 * w + x;
                any = true;
                if (plain) {
                    for (y in y0...y1) {
                        if (mask[mBase + (ty >> 16)] != 0) fb[idx] = PLAIN_BODY;
                        idx += w;
                        ty += tyStep;
                    }
                } else {
                    var bb = band << 8;
                    var kx = tx * 7 + frameSeed;
                    for (y in y0...y1) {
                        var tt = ty >> 16;
                        if (mask[mBase + tt] != 0) fb[idx] = nb[bb | ((kx + tt * 13) & 255)];
                        idx += w;
                        ty += tyStep;
                    }
                }
            }
        } else {
            var vig = r.vignetteBias;
            var bodies = houndBody;
            var baseBand = plain ? 0 : ((depthFix * 5) >> 18) + lo;
            var eyeOn = ((frameSeed >> 3) & 7) != 0;
            for (x in x0...x1) {
                if (!plain && depthFix >= hDist[x >> cs]) continue;
                var band = baseBand;
                if (!plain) {
                    band += vig[x];
                    if (band >= 15) continue;
                }
                var body = plain ? PLAIN_BODY : bodies[band];
                var eye = eyeOn ? EYE : body;
                var tx = ((x - xs) * txStep) >> 16;
                var mBase = tx * sh;
                var ty = ty0;
                var idx = y0 * w + x;
                any = true;
                for (y in y0...y1) {
                    var m = mask[mBase + (ty >> 16)];
                    if (m != 0) fb[idx] = m == 2 ? eye : body;
                    idx += w;
                    ty += tyStep;
                }
            }
        }
        if (any) drawn++;
    }
}
