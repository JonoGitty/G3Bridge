// Unit tests for Rng (CONTRACT §0 test vectors). Runs under haxe --interp via TestAll.
// Returns the number of failed checks.
class TestRng {
    static var fails:Int;

    static function check(name:String, got:Int, want:Int):Void {
        if (got != want) {
            fails++;
            Sys.println("  TestRng " + name + ": got " + got + " want " + want);
        }
    }

    public static function run():Int {
        fails = 0;
        // mix
        check("mix(0)", Rng.mix(0), 0);
        check("mix(1)", Rng.mix(1), 1364076727);
        check("mix(2)", Rng.mix(2), 821347078);
        check("mix(-1)", Rng.mix(-1), -2114883783);
        check("mix(0xDEADBEEF)", Rng.mix(0xDEADBEEF), 233162409);
        // nextInt sequence after new Rng(1)
        var r = new Rng(1);
        check("Rng(1).state", r.state, 1364076727);
        check("nextInt#1", r.nextInt(), 524866043);
        check("nextInt#2", r.nextInt(), -1417553088);
        check("nextInt#3", r.nextInt(), -1914964556);
        // seed whose mix is 0 falls back to the golden constant
        var z = new Rng(0);
        check("Rng(0).state", z.state, 0x9E3779B9);
        // hash2 / hash3
        check("hash2(1,2)", Rng.hash2(1, 2), 230461417);
        check("hash3(1,2,3)", Rng.hash3(1, 2, 3), 973068298);
        check("hash3(7,-3,5)", Rng.hash3(7, -3, 5), 236163387);
        // nextFloat in [0, 1); range within bounds; unit matches nextFloat's formula
        var f = new Rng(42);
        for (i in 0...1000) {
            var v = f.nextFloat();
            if (v < 0.0 || v >= 1.0) { fails++; Sys.println("  TestRng nextFloat out of range: " + v); break; }
        }
        var g = new Rng(7);
        for (i in 0...1000) {
            var v = g.range(-5, 5);
            if (v < -5 || v >= 5) { fails++; Sys.println("  TestRng range out of bounds: " + v); break; }
        }
        var h = 0x12345678;
        if (Rng.unit(h) != (h >>> 8) / 16777216.0) { fails++; Sys.println("  TestRng unit formula"); }
        return fails;
    }
}
