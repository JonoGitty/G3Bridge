"""Queue remote-control commands for a game running on a Mac.

    C:\\Python310\\python.exe tools\\rc.py "key 38 400" "key 37 200" [--dev emac]

Each argument is one line the SWF will read from /rc on its next poll. The
game defines the vocabulary; the convention is:  key <code> <holdms>,
snap, state, seed <n>, die, map, fs.
"""
import sys
import urllib.request

HERE = __import__("os").path.dirname(__import__("os").path.abspath(__file__))
sys.path.insert(0, HERE + "/../host")
import config  # noqa: E402

args = [a for a in sys.argv[1:] if not a.startswith("--")]
dev = "emac"
for i, a in enumerate(sys.argv):
    if a == "--dev" and i + 1 < len(sys.argv):
        dev = sys.argv[i + 1]
body = "\n".join(args).encode("utf-8")
r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%d/rc?dev=%s" % (config.HTTP_PORT, dev), data=body), timeout=10)
print(r.read().decode())
