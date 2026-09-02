// flashvars + query string parameters (CONTRACT §2). fp class.
//
// init() merges two sources into one table: the query string of loaderInfo.url
// (Safari loading the .swf directly, Ruffle, the daemon's test runner) and
// loaderInfo.parameters (the wrapper page's flashvars). Flashvars win. Every value
// is stored as a String; `int` parses on demand. Bare keys ("?nofs") read as "1"
// so `has` and `int` agree with the "=1" spelling the contract documents.
//
// The one Dynamic here is the flashvars Object in init(), read once at boot;
// every accessor is typed.
class Params {
    static var table:Map<String, String> = new Map<String, String>();

    // merges li.parameters (flashvars) and the query string of li.url; flashvars win
    public static function init(li:flash.display.LoaderInfo):Void {
        if (li == null) return;
        var url:String = null;
        try { url = li.url; } catch (e:Dynamic) { url = null; }
        if (url != null) {
            var q = url.indexOf("?");
            if (q >= 0) {
                var qs = url.substr(q + 1);
                var hash = qs.indexOf("#");
                if (hash >= 0) qs = qs.substr(0, hash);
                parseQuery(qs);
            }
        }
        var fv:Dynamic = null;
        try { fv = li.parameters; } catch (e:Dynamic) { fv = null; }
        if (fv != null) {
            var names = Reflect.fields(fv);
            for (i in 0...names.length) {
                var k = names[i];
                if (k == null || k == "") continue;
                var v:Dynamic = Reflect.field(fv, k);
                table.set(k, v == null ? "1" : Std.string(v));
            }
        }
    }

    // "a=1&b=two&c" -> a:"1", b:"two", c:"1"
    static function parseQuery(qs:String):Void {
        if (qs == null || qs == "") return;
        var parts = qs.split("&");
        for (i in 0...parts.length) {
            var p = parts[i];
            if (p == "") continue;
            var eq = p.indexOf("=");
            var k:String;
            var v:String;
            if (eq < 0) { k = p; v = "1"; }
            else { k = p.substr(0, eq); v = p.substr(eq + 1); }
            k = decode(k);
            v = decode(v);
            if (k == "") continue;
            table.set(k, v);
        }
    }

    static function decode(s:String):String {
        var r:String;
        try { r = StringTools.urlDecode(s); } catch (e:Dynamic) { r = s; }
        return r;
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
