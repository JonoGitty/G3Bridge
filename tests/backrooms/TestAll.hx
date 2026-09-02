// Unit test entry point (CONTRACT §6).
//   haxe -cp src/backrooms -cp tests/backrooms -main TestAll --interp
// Calls run():Int on every test class, prints "name: pass/fail", exits 1 on any failure.
// coreRefs() references every core class so a stray flash.* import in any of them fails this build.
class TestAll {
    static function main():Void {
        coreRefs();
        var failed = 0;
        failed += report("TestRng", TestRng.run());
        failed += report("TestChunkGen", TestChunkGen.run());
        failed += report("TestWorld", TestWorld.run());
        failed += report("TestRaycaster", TestRaycaster.run());
        failed += report("TestMapMemory", TestMapMemory.run());
        failed += report("TestPath", TestPath.run());
        failed += report("TestPlayer", TestPlayer.run());
        failed += report("TestWatcher", TestWatcher.run());
        failed += report("TestHound", TestHound.run());
        failed += report("TestDirector", TestDirector.run());
        failed += report("TestTape", TestTape.run());
        failed += report("TestQuality", TestQuality.run());
        failed += report("TestBot", TestBot.run());
        Sys.println(failed == 0 ? "ALL PASS" : failed + " FAILED");
        if (failed > 0) Sys.exit(1);
    }

    static function report(name:String, r:Int):Int {
        Sys.println(name + ": " + (r == 0 ? "pass" : "fail"));
        return r == 0 ? 0 : 1;
    }

    // touches every core class: Rng, Cells, Chunk, ChunkGen, World, RayHits, Raycaster, MapMemory,
    // Path, Player, Entity, Watcher, Hound, Director, Tape, Quality, Bot
    static function coreRefs():Void {
        var rng = new Rng(1);
        var s = Cells.solid(Cells.WALL);
        var chunk = new Chunk();
        ChunkGen.generate(1, 0, 0, chunk);
        var world = new World(1);
        var hits = new RayHits(320);
        var rc = new Raycaster(320);
        var mem = new MapMemory();
        var out = new haxe.ds.Vector<Int>(Path.MAX_LEN);
        Path.bfs(world, 0, 0, 0, 0, out);
        var player = new Player(16.5, 16.5, 0.0);
        var e = new Entity(Entity.K_WATCHER);
        var w = new Watcher();
        var h = new Hound();
        var tape = Tape.make(1, 1);
        var d = new Director(world, player, tape);
        var q = new Quality(2, 2);
        var b = new Bot(1);
        if (rng == null || !s || chunk == null || world == null || hits == null || rc == null || mem == null
            || player == null || e == null || w == null || h == null || tape == null || d == null || q == null || b == null)
            throw "coreRefs";
    }
}
