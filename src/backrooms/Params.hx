// flashvars + query string parameters (CONTRACT §2). fp class.
// SKELETON: signatures exact; init() stores nothing, so every key reads as absent/default.
class Params {
    static var table:Map<String, String> = new Map<String, String>();

    // merges li.parameters (flashvars) and the query string of li.url; flashvars win
    public static function init(li:flash.display.LoaderInfo):Void {
        // SKELETON
    }

    public static function has(k:String):Bool {
        return table.exists(k);
    }

    public static function get(k:String, def:String = ""):String {
        var v = table.get(k);
        return v == null ? def : v;
    }

    public static function int(k:String, def:Int):Int {
        var v = table.get(k);
        if (v == null) return def;
        var n = Std.parseInt(v);
        return n == null ? def : n;
    }
}
