// Unit tests for Quality (CONTRACT §1, DESIGN §1). Runs under haxe --interp via TestAll.
// Returns the number of failed checks; prints one line per check.
class TestQuality {
    static var fails:Int = 0;

    // result of the last feed(): first non-zero return, its 0-based frame index, and how many non-zero returns
    static var first:Int = 0;
    static var firstAt:Int = -1;
    static var nonZero:Int = 0;

    static function check(name:String, ok:Bool):Void {
        Sys.println((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) fails++;
    }

    static function near(a:Float, b:Float, eps:Float):Bool {
        var d = a - b;
        return (d < 0 ? -d : d) <= eps;
    }

    // feed n identical frames; returns the sum of the results (so a single change shows as +1 / -1).
    // noteFrame only REPORTS a change: feed() leaves rung alone (so the tests can see that), drive() applies
    // each verdict the way Main does (quality.set(rung + change) in the same frame).
    static function feed(q:Quality, n:Int, busy:Float, frame:Float, ent:Bool, dying:Bool, map:Bool):Int {
        return step(q, n, busy, frame, ent, dying, map, false);
    }

    static function drive(q:Quality, n:Int, busy:Float, frame:Float, ent:Bool, dying:Bool, map:Bool):Int {
        return step(q, n, busy, frame, ent, dying, map, true);
    }

    static function step(q:Quality, n:Int, busy:Float, frame:Float, ent:Bool, dying:Bool, map:Bool, apply:Bool):Int {
        first = 0;
        firstAt = -1;
        nonZero = 0;
        var sum = 0;
        for (i in 0...n) {
            var r = q.noteFrame(busy, frame, ent, dying, map);
            if (r != 0) {
                if (nonZero == 0) { first = r; firstAt = i; }
                nonZero++;
                sum += r;
                if (apply) q.set(q.rung + r);        // Main: to = quality.rung + change; quality.set(to)
            }
        }
        return sum;
    }

    public static function run():Int {
        fails = 0;

        // ---- the ladder tables (DESIGN §1) ----
        check("tier: rung 0 => T0, rungs 1..5 => T1",
            Quality.tier(0) == 0 && Quality.tier(1) == 1 && Quality.tier(2) == 1 && Quality.tier(5) == 1);
        check("floorMode: 0,1 => F0; 2,3,4 => F1; 5 => F2",
            Quality.floorMode(0) == 0 && Quality.floorMode(1) == 0 && Quality.floorMode(2) == 1
            && Quality.floorMode(3) == 1 && Quality.floorMode(4) == 1 && Quality.floorMode(5) == 2);
        check("rays: 0 => 128; 1,2 => 160; 3,4,5 => 320",
            Quality.rays(0) == 128 && Quality.rays(1) == 160 && Quality.rays(2) == 160
            && Quality.rays(3) == 320 && Quality.rays(4) == 320 && Quality.rays(5) == 320);
        check("frameRate: 0..3 => 20; 4,5 => 30",
            Quality.frameRate(0) == 20 && Quality.frameRate(3) == 20 && Quality.frameRate(4) == 30 && Quality.frameRate(5) == 30);
        check("budgetMs: 50 at 20 fps rungs, 33.3 at 30 fps rungs",
            near(Quality.budgetMs(0), 50.0, 1e-9) && near(Quality.budgetMs(3), 50.0, 1e-9)
            && near(Quality.budgetMs(4), 33.3, 1e-9) && near(Quality.budgetMs(5), 33.3, 1e-9));
        check("RUNGS == 6", Quality.RUNGS == 6);

        // ---- constructor clamps ----
        var q0 = new Quality(7, 9);
        check("constructor clamps rung and maxRung into 0..RUNGS-1 with rung <= maxRung", q0.rung == 5 && q0.maxRung == 5);
        var q1 = new Quality(4, 2);
        check("constructor: rung above maxRung is clamped to maxRung", q1.rung == 2 && q1.maxRung == 2);
        var q2 = new Quality(-3, 3);
        check("constructor: negative rung becomes 0", q2.rung == 0);

        // ---- (1) 60 slow frames -> -1 once, then 0 until 5 s pass ----
        var q = new Quality(3, 5);
        var s = feed(q, 60, 60.0, 50.0, false, false, false);
        check("(1) 60 frames of busy 60 ms at rung 3 -> exactly one -1, on the 60th frame", s == -1 && nonZero == 1 && firstAt == 59);
        check("(1) noteFrame only reports: rung is still 3 until the caller applies the change", q.rung == 3);
        check("(1) lastChange reset by the verdict (so it is not repeated next frame)", q.lastChange < 0.1);
        q.set(q.rung + s);                              // Main applies it
        check("(1) set(rung + change) lands ONE rung down: 2, not 1", q.rung == 2);
        s = feed(q, 99, 60.0, 50.0, false, false, false);
        check("(1) the next 99 slow frames (4.95 s) return 0: 5 s spacing", s == 0 && nonZero == 0 && q.rung == 2);
        s = feed(q, 1, 60.0, 50.0, false, false, false);
        check("(1) the frame that completes 5 s drops again, rung still 2 until applied", s == -1 && q.rung == 2);
        q.set(q.rung + s);
        check("(1) ... applied: rung 1", q.rung == 1);
        q = new Quality(3, 5);
        s = drive(q, 160, 60.0, 50.0, false, false, false);
        check("(1) driven like Main for 160 slow frames: two single-rung drops, 3 -> 1 (never two rungs per verdict)", s == -2 && nonZero == 2 && q.rung == 1);

        // ---- (2) 300 fast frames: blocked by entityActive, allowed without ----
        q = new Quality(2, 5);
        s = feed(q, 300, 20.0, 50.0, true, false, false);
        check("(2) 300 fast frames with entityActive -> 0", s == 0 && nonZero == 0 && q.rung == 2);
        s = feed(q, 300, 20.0, 50.0, false, false, false);
        check("(2) 300 fast frames without -> +1 exactly once, on the 300th clean frame; rung still 2 until applied", s == 1 && nonZero == 1 && firstAt == 299 && q.rung == 2);
        q.set(q.rung + s);
        check("(2) ... applied: rung 3 (one rung up, not two)", q.rung == 3);
        q = new Quality(2, 5);
        s = feed(q, 300, 20.0, 50.0, false, true, false);
        check("(2) dying blocks the raise", s == 0 && q.rung == 2);
        q = new Quality(2, 5);
        s = feed(q, 300, 20.0, 50.0, false, false, true);
        check("(2) mapOpen blocks the raise", s == 0 && q.rung == 2);
        q = new Quality(2, 5);
        feed(q, 200, 20.0, 50.0, false, false, false);
        feed(q, 1, 20.0, 50.0, true, false, false);
        s = feed(q, 299, 20.0, 50.0, false, false, false);
        check("(2) a single blocked frame restarts the 300-frame count", s == 0 && q.rung == 2);
        s = feed(q, 1, 20.0, 50.0, false, false, false);
        check("(2) ... and the 300th clean frame after it raises (rung unchanged until set)", s == 1 && q.rung == 2);
        q.set(q.rung + s);
        check("(2) ... applied: rung 3", q.rung == 3);

        // ---- (3) rung == maxRung never raises ----
        q = new Quality(5, 5);
        s = feed(q, 1000, 5.0, 33.0, false, false, false);
        check("(3) rung 5 == maxRung 5: 1000 fast frames never raise", s == 0 && nonZero == 0 && q.rung == 5);
        q = new Quality(2, 2);
        s = feed(q, 1000, 5.0, 50.0, false, false, false);
        check("(3) rung 2 == maxRung 2: never raises", s == 0 && q.rung == 2);

        // ---- (4) forceDrop at 0 stays 0 ----
        q = new Quality(0, 5);
        q.forceDrop();
        check("(4) forceDrop at rung 0 stays 0", q.rung == 0);
        q = new Quality(3, 5);
        q.forceDrop();
        check("(4) forceDrop at rung 3 -> 2 and resets the spacing clock", q.rung == 2 && q.lastChange < 0.1);
        s = feed(q, 60, 60.0, 50.0, false, false, false);
        check("(4) no automatic drop inside 5 s of a forceDrop", s == 0 && q.rung == 2);

        // ---- (5) pinned wall time never blocks a raise ----
        q = new Quality(2, 5);
        s = feed(q, 300, 20.0, 50.0, false, false, false);
        check("(5) rung 2, frameMs 50 (pinned by frameRate 20) and busy 20 for 300 frames -> +1, rung 2 until set", s == 1 && q.rung == 2);
        q.set(q.rung + s);
        check("(5) ... applied: rung 3", q.rung == 3);
        check("(5) emaFrame sits at the pinned 50 ms and emaBusy at 20", near(q.emaFrame, 50.0, 0.01) && near(q.emaBusy, 20.0, 0.01));

        // ---- (6) locks and activity never block a drop ----
        q = new Quality(3, 5);
        s = feed(q, 60, 60.0, 50.0, true, false, false);
        check("(6) 60 frames of busy 60 with entityActive -> -1 (rung 3 until set)", s == -1 && q.rung == 3);
        q.set(q.rung + s);
        check("(6) ... applied: rung 2", q.rung == 2);
        q = new Quality(3, 5);
        q.lock(10.0);
        s = feed(q, 60, 60.0, 50.0, false, false, false);
        check("(6) an explicit 10 s lock does not block the drop", s == -1 && q.rung == 3);
        q = new Quality(3, 5);
        s = feed(q, 60, 60.0, 50.0, false, true, true);
        check("(6) dying + mapOpen do not block the drop", s == -1 && q.rung == 3);

        // ---- (7) setMaxRung clamps the current rung ----
        q = new Quality(3, 5);
        q.setMaxRung(1);
        check("(7) setMaxRung(1) at rung 3 -> rung 1, maxRung 1", q.rung == 1 && q.maxRung == 1);
        q.setMaxRung(4);
        check("(7) setMaxRung(4) afterwards leaves rung 1 (a raise must be earned)", q.rung == 1 && q.maxRung == 4);
        q.setMaxRung(9);
        check("(7) setMaxRung clamps to RUNGS - 1", q.maxRung == 5);
        q.setMaxRung(-2);
        check("(7) setMaxRung(-2) -> maxRung 0 and rung 0 (rung 0 can never be disabled)", q.maxRung == 0 && q.rung == 0);

        // ---- the wall-time drop: a real overrun drops even with cheap busy time ----
        q = new Quality(2, 5);
        s = drive(q, 60, 20.0, 70.0, false, false, false);
        check("emaFrame 70 > 57.5 for 60 frames drops rung 2 -> 1 even with busy 20", s == -1 && q.rung == 1);
        q = new Quality(4, 5);
        s = drive(q, 60, 20.0, 40.0, false, false, false);
        check("30 fps rung: frame 40 > 38.3 for 60 frames drops rung 4 -> 3", s == -1 && q.rung == 3);
        s = drive(q, 200, 20.0, 40.0, false, false, false);
        check("... and at rung 3 (budget 50) the same 40 ms frame is fine", s == 0 && q.rung == 3);

        // ---- the threshold edges: 1.15 x budget and 0.70 x budget ----
        q = new Quality(2, 5);
        s = feed(q, 200, 57.0, 50.0, false, false, false);
        check("busy 57 (< 57.5) never drops", s == 0 && q.rung == 2);
        q = new Quality(2, 5);
        s = drive(q, 100, 58.0, 50.0, false, false, false);
        check("busy 58 (> 57.5) drops", s == -1 && q.rung == 1);
        s = drive(q, 100, 58.0, 50.0, false, false, false);
        check("... and again 5 s later while it stays slow", s == -1 && q.rung == 0);
        s = drive(q, 200, 58.0, 50.0, false, false, false);
        check("... but never below rung 0 (no verdict at rung 0)", s == 0 && nonZero == 0 && q.rung == 0);
        q = new Quality(2, 5);
        s = feed(q, 400, 35.5, 50.0, false, false, false);
        check("busy 35.5 (>= 35) never raises", s == 0 && q.rung == 2);
        q = new Quality(2, 5);
        s = drive(q, 400, 34.5, 50.0, false, false, false);
        check("busy 34.5 (< 35) raises", s == 1 && q.rung == 3);
        q = new Quality(5, 5);
        s = feed(q, 400, 5.0, 33.0, false, false, false);
        check("at maxRung there is no +1 verdict to apply", s == 0 && nonZero == 0 && q.rung == 5);

        // ---- the raise-lock ----
        q = new Quality(2, 5);
        q.lock(2.0);
        check("lock(2) -> lockUntil 2 s", near(q.lockUntil, 2.0, 1e-9));
        s = drive(q, 340, 20.0, 50.0, false, false, false);
        check("lock(2): the raise needs 300 clean frames after the 40-frame lock, so it lands on frame 339 (" + (firstAt + 1) + ")", s == 1 && firstAt >= 338 && firstAt <= 340 && q.rung == 3);
        q = new Quality(2, 5);
        q.lock(2.0);
        s = feed(q, 300, 20.0, 50.0, false, false, false);
        check("lock(2): 300 fast frames that start inside the lock do not raise", s == 0 && q.rung == 2);
        q = new Quality(2, 5);
        q.lock(2.0);
        q.lock(1.0);
        check("a shorter lock never shortens a longer one", near(q.lockUntil, 2.0, 1e-9));
        feed(q, 10, 20.0, 50.0, false, false, false);
        check("the lock counts down in wall time (0.5 s after 10 frames of 50 ms)", near(q.lockUntil, 1.5, 1e-6));

        // ---- the EMAs ----
        q = new Quality(2, 5);
        q.noteFrame(40.0, 50.0, false, false, false);
        check("first sample primes both EMAs (no warm-up from zero)", near(q.emaBusy, 40.0, 1e-9) && near(q.emaFrame, 50.0, 1e-9));
        q.noteFrame(20.0, 60.0, false, false, false);
        check("alpha 0.1: 40 -> 38 and 50 -> 51 after one sample", near(q.emaBusy, 38.0, 1e-9) && near(q.emaFrame, 51.0, 1e-9));
        q = new Quality(2, 5);
        feed(q, 200, 20.0, 50.0, false, false, false);
        feed(q, 1, 500.0, 50.0, false, false, false);
        s = feed(q, 59, 20.0, 50.0, false, false, false);
        check("one 500 ms glitch frame never drops on its own (60-frame hysteresis)", s == 0 && q.rung == 2);

        // ---- presentEstimate is the caller's field; set() overrides ----
        q = new Quality(2, 4);
        q.presentEstimate = 12.5;
        check("presentEstimate is a plain field for Main", near(q.presentEstimate, 12.5, 1e-9));
        q.set(9);
        check("set(9) clamps to maxRung", q.rung == 4);
        q.set(-1);
        check("set(-1) clamps to 0", q.rung == 0);
        q.set(3);
        check("set(3) -> 3 and resets the spacing clock", q.rung == 3 && q.lastChange < 0.1);

        return fails;
    }
}
