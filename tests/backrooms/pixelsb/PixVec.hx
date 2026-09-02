// Test shim for the pixels-b harness ONLY (haxe --interp cannot see the flash package, so
// run.sh copies PixelFont/Hud/Cards with `flash.Vector` textually replaced by `PixVec`).
// A fixed-length pixel buffer that THROWS on any out-of-range index, so a blit that writes
// outside the buffer fails the test instead of silently passing.
class PixVecData<T> {
    public var a:haxe.ds.Vector<T>;
    public var length:Int;
    public function new(n:Int) { a = new haxe.ds.Vector<T>(n); length = n; }
}

@:forward(length)
abstract PixVec<T>(PixVecData<T>) {
    public inline function new(n:Int, fixed:Bool = false) this = new PixVecData<T>(n);
    @:arrayAccess public function get(i:Int):T {
        if (i < 0 || i >= this.length) throw "read out of range: " + i + " / " + this.length;
        return this.a[i];
    }
    @:arrayAccess public function set(i:Int, v:T):T {
        if (i < 0 || i >= this.length) throw "write out of range: " + i + " / " + this.length;
        this.a[i] = v;
        return v;
    }
}
