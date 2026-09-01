"""Send commands to a running g3d and print the replies.

    python tools/drive.py "CLEAR 0 0 40" "PEN 255 200 0" "RECT 20 20 300 200 FILL" FLUSH
    python tools/drive.py --script demo.g3      # one command per line, # comments ok
    echo "STATUS" | python tools/drive.py -
"""
import os
import socket
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import protocol  # noqa: E402

HOST, PORT = "127.0.0.1", 9991


def gather():
    if "--script" in sys.argv:
        path = sys.argv[sys.argv.index("--script") + 1]
        with open(path) as f:
            return [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]
    if sys.argv[1:2] == ["-"]:
        return [l.strip() for l in sys.stdin if l.strip()]
    return [a for a in sys.argv[1:] if not a.startswith("--")]


def main():
    cmds = gather()
    if not cmds:
        print(__doc__)
        return 2
    s = socket.create_connection((HOST, PORT), timeout=20)
    f = s.makefile("rwb", buffering=0)
    failures = 0
    for i, c in enumerate(cmds, 1):
        f.write((("%d " % i) + c + "\n").encode("ascii", "replace"))
        reply = f.readline().decode("ascii", "replace").strip()
        _, verb, args = protocol.decode(reply)
        mark = "ok " if verb in ("OK", "PONG") else "ERR"
        if verb not in ("OK", "PONG"):
            failures += 1
        print("%s  %-42s %s" % (mark, c, " ".join(args)))
    f.write(b"")
    s.close()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
