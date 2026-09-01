"""A simulated Mac OS 9 agent.

Speaks the exact wire protocol the real G3 agent will speak, but rasterises to
a PNG instead of QuickDraw. Lets the whole host side be built and tested with
no vintage hardware plugged in.

    python tools/fake_g3.py [host] [port] [--out screen.png]

Uses Pillow when it is importable and falls back to a dependency-free
rasteriser otherwise, so it runs under either interpreter on this machine.
"""

import os
import socket
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import protocol  # noqa: E402
import raster  # noqa: E402

WIDTH, HEIGHT, DEPTH = 800, 600, 32  # native iMac G3 mode; see host/config.py


# --------------------------------------------------------------------------
class FakeG3:
    def __init__(self, out):
        self.out = out
        self.screen = raster.Screen(WIDTH, HEIGHT)
        self.count = 0

    def execute(self, verb, a):
        if verb == "HELLO":
            return ("OK", ["proto=%d" % protocol.PROTO_VERSION])
        if verb == "PING":
            return ("PONG", [])
        if verb == "BYE":
            raise SystemExit(0)
        if verb == "FLUSH":
            self.screen.save(self.out)
            return ("OK", ["presented=%s" % os.path.basename(self.out)])
        if self.screen.apply(verb, a) is not None:
            self.count += 1
            return ("OK", [])
        return ("ERR", ["unknown verb %s" % verb])


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    host = args[0] if args else "127.0.0.1"
    port = int(args[1]) if len(args) > 1 else 9990
    out = "screen.png"
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]

    g3 = FakeG3(out)
    s = socket.create_connection((host, port), timeout=10)
    f = s.makefile("rwb", buffering=0)
    sys.stderr.write("fake-g3: connected to %s:%d (renderer=%s)\n"
                     % (host, port, "PIL" if raster.HAVE_PIL else "raw"))
    f.write(("READY fake-g3 %d %d %d\n" % (WIDTH, HEIGHT, DEPTH)).encode("ascii"))

    while True:
        raw = f.readline()
        if not raw:
            break
        line = raw.decode("ascii", "replace").strip()
        if not line:
            continue
        try:
            seq, verb, a = protocol.decode(line)
        except protocol.ProtocolError as e:
            continue
        sys.stderr.write("  <- %s\n" % line)
        try:
            rverb, rargs = g3.execute(verb, a)
        except SystemExit:
            f.write((protocol.encode(seq, "OK", "bye") + "\n").encode("ascii"))
            break
        except Exception as e:
            rverb, rargs = "ERR", ["%s: %s" % (type(e).__name__, e)]
        f.write((protocol.encode(seq, rverb, *rargs) + "\n").encode("ascii"))
    sys.stderr.write("fake-g3: link closed after %d ops\n" % g3.count)


if __name__ == "__main__":
    main()
