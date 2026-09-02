// Unit tests for Tape (CONTRACT §1, DESIGN §7). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
class TestTape {
    static var fails:Int = 0;

    static function check(name:String, ok:Bool):Void {
        Sys.println((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) fails++;
    }

    static function same(a:Tape, b:Tape):Bool {
        return a.index == b.index && a.seed == b.seed && a.salt == b.salt && a.name == b.name && a.camName == b.camName
            && a.dateStr == b.dateStr && a.dateSeconds == b.dateSeconds
            && a.tintR == b.tintR && a.tintG == b.tintG && a.tintB == b.tintB
            && a.offR == b.offR && a.offG == b.offG && a.offB == b.offB
            && a.grainAlpha == b.grainAlpha && a.fov == b.fov && a.dOffset == b.dOffset
            && a.batteryStart == b.batteryStart && a.hudSkin == b.hudSkin && a.badTape == b.badTape
            && a.startX == b.startX && a.startY == b.startY && a.startAng == b.startAng;
    }

    static function ascii(s:String, max:Int):Bool {
        if (s == null || s.length == 0 || s.length > max) return false;
        for (i in 0...s.length) {
            var c = s.charCodeAt(i);
            if (c < 32 || c > 126) return false;
        }
        return true;
    }

    // "DD.MM.YYYY" with a real calendar day, year 1987..1999
    static function dateOk(s:String):Bool {
        if (s == null || s.length != 10) return false;
        if (s.charAt(2) != "." || s.charAt(5) != ".") return false;
        var d = Std.parseInt(s.substr(0, 2));
        var m = Std.parseInt(s.substr(3, 2));
        var y = Std.parseInt(s.substr(6, 4));
        if (d == null || m == null || y == null) return false;
        if (y < 1987 || y > 1999) return false;
        if (m < 1 || m > 12) return false;
        var dim = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
        if (m == 2 && (y % 4) == 0) dim = 29;
        return d >= 1 && d <= dim;
    }

    public static function run():Int {
        fails = 0;
        var DEG = Math.PI / 180.0;

        // ---- (1) determinism ----
        var a = Tape.make(7, 12345);
        var b = Tape.make(7, 12345);
        check("(1) make(7, 12345) twice -> identical fields", same(a, b));
        check("(1) index and salt are stored", a.index == 7 && a.salt == 12345);
        check("(1) seed == Rng.hash3(salt, TAG_TAPE, index)", a.seed == Rng.hash3(12345, Rng.TAG_TAPE, 7));
        var c = Tape.make(8, 12345);
        check("(1) a different index gives a different seed", c.seed != a.seed);
        var d = Tape.make(7, 12346);
        check("(1) a different salt gives a different seed", d.seed != a.seed);
        check("(1) the sample tape reads as a label: " + a.name + " / " + a.camName + " / " + a.dateStr,
            ascii(a.name, 28) && ascii(a.camName, 16) && dateOk(a.dateStr) && a.name.indexOf(" - ") > 0);

        // ---- nextSalt ----
        var s1 = Tape.nextSalt(12345);
        check("nextSalt is Rng.mix(salt ^ 0x5DEECE66)", s1 == Rng.mix(12345 ^ 0x5DEECE66));
        check("nextSalt changes the salt and is deterministic", s1 != 12345 && Tape.nextSalt(12345) == s1);
        var t1 = Tape.make(1, 12345);
        var t2 = Tape.make(1, s1);
        check("tape 1 on the next salt is a different tape", t1.seed != t2.seed);

        // ---- (2) + (3): 1,000 tapes ----
        var N = 1000;
        var bad = 0;
        var datesOk = true;
        var fovOk = true;
        var nameOk = true;
        var camOk = true;
        var tintOk = true;
        var offOk = true;
        var grainOk = true;
        var dOffOk = true;
        var battOk = true;
        var skinOk = true;
        var clockOk = true;
        var startOk = true;
        var badGrainOk = true;
        var seeds = new Map<Int, Bool>();
        var labels = new Map<String, Bool>();
        var seedDup = 0;
        var labelCount = 0;
        var skins = [0, 0, 0];
        var minFov = 999.0;
        var maxFov = -999.0;
        var leapDays = 0;
        for (i in 1...N + 1) {
            var t = Tape.make(i, 0x1234);
            if (t.badTape) bad++;
            if (!dateOk(t.dateStr)) datesOk = false;
            if (t.dateStr.substr(0, 5) == "29.02") leapDays++;
            if (t.fov < 60.0 * DEG - 1e-9 || t.fov > 72.0 * DEG + 1e-9) fovOk = false;
            if (t.fov < minFov) minFov = t.fov;
            if (t.fov > maxFov) maxFov = t.fov;
            if (!ascii(t.name, 28)) nameOk = false;
            if (!ascii(t.camName, 16)) camOk = false;
            if (t.tintR < 0.92 || t.tintR > 1.08 || t.tintG < 0.92 || t.tintG > 1.08 || t.tintB < 0.92 || t.tintB > 1.08) tintOk = false;
            if (t.offR < -8 || t.offR > 8 || t.offG < -8 || t.offG > 8 || t.offB < -8 || t.offB > 8) offOk = false;
            if (t.grainAlpha < 24 || t.grainAlpha > 40) grainOk = false;
            if (t.badTape && t.grainAlpha < 34) badGrainOk = false;
            if (t.dOffset < 0.0 || t.dOffset > 0.1) dOffOk = false;
            if (t.batteryStart < 0.6 || t.batteryStart > 1.0) battOk = false;
            if (t.hudSkin < 0 || t.hudSkin > 2) skinOk = false; else skins[t.hudSkin]++;
            if (t.dateSeconds < 0.0 || t.dateSeconds > 86399.0 || t.dateSeconds != Math.ffloor(t.dateSeconds)) clockOk = false;
            if (t.startX != 16.5 || t.startY != 16.5 || t.startAng < 0.0 || t.startAng >= Math.PI * 2.0) startOk = false;
            if (seeds.exists(t.seed)) seedDup++; else seeds.set(t.seed, true);
            var label = t.name + "|" + t.dateStr + "|" + t.camName;
            if (!labels.exists(label)) { labels.set(label, true); labelCount++; }
        }
        check("(2) badTape rate within 7..13% over 1,000 tapes (" + bad + ")", bad >= 70 && bad <= 130);
        check("(2) every date parses as DD.MM.YYYY, a real day, year 1987..1999 (" + leapDays + " on 29 Feb)", datesOk);
        check("(2) fov within 60..72 deg (min " + Math.round(minFov / DEG * 10) / 10 + ", max " + Math.round(maxFov / DEG * 10) / 10 + ")",
            fovOk && minFov < 62.0 * DEG && maxFov > 70.0 * DEG);
        check("(3) name is ASCII 32..126 and <= 28 chars", nameOk);
        check("(3) camName is ASCII", camOk);
        check("tint multipliers within 0.92..1.08", tintOk);
        check("offsets within -8..8", offOk);
        check("grainAlpha within 24..40", grainOk);
        check("a bad tape is grainy (grainAlpha >= 34)", badGrainOk);
        check("dOffset within 0..0.1", dOffOk);
        check("batteryStart within 0.6..1.0", battOk);
        check("hudSkin 0..2 and every skin used", skinOk && skins[0] > 0 && skins[1] > 0 && skins[2] > 0);
        check("dateSeconds is a whole number of seconds in 0..86399", clockOk);
        check("start at 16.5, 16.5 with a right-angle facing", startOk);
        check("seeds distinct across 1,000 indices (" + seedDup + " duplicates)", seedDup == 0);
        check("labels (name + date + camera) distinct across >= 95% of 1,000 tapes (" + labelCount + ")", labelCount >= 950);
        check("consecutive tapes differ in name or date", Tape.make(1, 0x1234).name + Tape.make(1, 0x1234).dateStr
            != Tape.make(2, 0x1234).name + Tape.make(2, 0x1234).dateStr);

        // ---- a negative salt and index 0 still make a valid tape ----
        var neg = Tape.make(0, -987654321);
        check("index 0 and a negative salt still produce a valid tape", ascii(neg.name, 28) && dateOk(neg.dateStr)
            && neg.fov >= 60.0 * DEG - 1e-9 && neg.fov <= 72.0 * DEG + 1e-9);

        return fails;
    }
}
