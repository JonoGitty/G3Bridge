"""Run a SWF served by the daemon inside Ruffle (the Flash emulator) in a
headless Chromium, so the game can be smoke-tested on the PC before it goes
anywhere near the eMac. Screenshots, console output and the daemon's
telemetry log are what you get back.

    C:\\Python310\\python.exe tools\\ruffle_run.py /games/backrooms/hello.swf --seconds 6 --shot run\\ruffle.png [--keys "ArrowUp:2000,Space:100"]

Keys: "Name:holdms" pairs, pressed in order after the movie has had 1.5 s.
Ruffle itself is loaded from jsdelivr; the SWF and its assets come from the
daemon at 127.0.0.1:9980, same as the eMac sees them.
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "host"))
import config  # noqa: E402

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<script src="https://cdn.jsdelivr.net/npm/@ruffle-rs/ruffle"></script>
<style>body{margin:0;background:#000}#c{width:1024px;height:768px}</style></head>
<body><div id="c"></div>
<script>
window.RufflePlayer = window.RufflePlayer || {};
window.RufflePlayer.config = { autoplay: "on", unmuteOverlay: "hidden", letterbox: "off", logLevel: "info",
  allowScriptAccess: true, warnOnUnsupportedContent: false, splashScreen: false, backgroundColor: "#000000" };
window.addEventListener("load", function () {
  var ruffle = window.RufflePlayer.newest();
  var player = ruffle.createPlayer();
  player.style.width = "1024px"; player.style.height = "768px";
  document.getElementById("c").appendChild(player);
  player.ruffle().load({ url: %(swf)r, allowScriptAccess: true }).then(function () { window.__loaded = true; });
  window.__player = player;
});
</script></body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("swf")
    ap.add_argument("--seconds", type=float, default=6)
    ap.add_argument("--shot", default="")
    ap.add_argument("--keys", default="")
    ap.add_argument("--shots-every", type=float, default=0)
    a = ap.parse_args()
    tlog = os.path.join(HERE, "..", "run", "telemetry.log")
    mark = os.path.getsize(tlog) if os.path.exists(tlog) else 0

    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        b = pw.chromium.launch(headless=True, args=["--autoplay-policy=no-user-gesture-required"])
        pg = b.new_page(viewport={"width": 1024, "height": 768})
        logs = []
        pg.on("console", lambda m: logs.append("%s: %s" % (m.type, m.text)))
        pg.on("pageerror", lambda e: logs.append("pageerror: %s" % e))
        pg.goto("http://127.0.0.1:%d/games/backrooms/_ruffle.html?swf=%s" % (config.HTTP_PORT, a.swf))
        pg.wait_for_function("window.__loaded === true", timeout=60000)
        pg.wait_for_timeout(1500)
        pg.mouse.click(512, 384)
        n = 0
        t_end = time.time() + a.seconds
        if a.keys:
            for pair in a.keys.split(","):
                name, hold = pair.split(":")
                pg.keyboard.down(name)
                pg.wait_for_timeout(int(hold))
                pg.keyboard.up(name)
                if a.shots_every and a.shot:
                    n += 1
                    pg.screenshot(path=a.shot.replace(".png", "_%02d.png" % n))
        while time.time() < t_end:
            pg.wait_for_timeout(500)
            if a.shots_every and a.shot and int(time.time() * 2) % int(a.shots_every * 2 or 1) == 0:
                pass
        if a.shot:
            pg.screenshot(path=a.shot)
        b.close()
    print("console lines: %d" % len(logs))
    for line in logs[-25:]:
        print("  " + line[:300])
    if os.path.exists(tlog):
        with open(tlog, encoding="utf-8", errors="replace") as f:
            f.seek(mark)
            new = f.read()
        print("telemetry since start:")
        for line in new.splitlines():
            print("  " + line[:400])


if __name__ == "__main__":
    main()
