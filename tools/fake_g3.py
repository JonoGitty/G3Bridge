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
import struct
import sys
import time
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import protocol  # noqa: E402

WIDTH, HEIGHT, DEPTH = 640, 480, 8   # a plausible iMac G3 mode

try:
    from PIL import Image, ImageDraw, ImageFont
    HAVE_PIL = True
except ImportError:
    HAVE_PIL = False


# --------------------------------------------------------------------------
# Dependency-free raster fallback
# --------------------------------------------------------------------------
class RawCanvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = bytearray(w * h * 3)

    def clear(self, rgb):
        self.px = bytearray(bytes(rgb) * (self.w * self.h))

    def point(self, x, y, rgb):
        if 0 <= x < self.w and 0 <= y < self.h:
            i = (y * self.w + x) * 3
            self.px[i:i + 3] = bytes(rgb)

    def line(self, x0, y0, x1, y1, rgb, size=1):
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        while True:
            for ox in range(size):
                for oy in range(size):
                    self.point(x0 + ox, y0 + oy, rgb)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def rect(self, x0, y0, x1, y1, rgb, fill, size=1):
        if fill:
            for y in range(min(y0, y1), max(y0, y1) + 1):
                self.line(min(x0, x1), y, max(x0, x1), y, rgb)
        else:
            self.line(x0, y0, x1, y0, rgb, size)
            self.line(x1, y0, x1, y1, rgb, size)
            self.line(x1, y1, x0, y1, rgb, size)
            self.line(x0, y1, x0, y0, rgb, size)

    def oval(self, x0, y0, x1, y1, rgb, fill):
        cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
        rx, ry = abs(x1 - x0) / 2.0, abs(y1 - y0) / 2.0
        if rx < 0.5 or ry < 0.5:
            return
        steps = max(16, int((rx + ry) * 2))
        import math
        pts = []
        for i in range(steps + 1):
            a = 2 * math.pi * i / steps
            pts.append((int(round(cx + rx * math.cos(a))), int(round(cy + ry * math.sin(a)))))
        if fill:
            for y in range(int(cy - ry), int(cy + ry) + 1):
                dy = (y - cy) / ry
                if abs(dy) > 1:
                    continue
                half = rx * (1 - dy * dy) ** 0.5
                self.line(int(cx - half), y, int(cx + half), y, rgb)
        else:
            for i in range(len(pts) - 1):
                self.line(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], rgb)

    def save_png(self, path):
        raw = bytearray()
        stride = self.w * 3
        for y in range(self.h):
            raw.append(0)
            raw += self.px[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            c = struct.pack(">I", len(data)) + tag + data
            return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        png = (b"\x89PNG\r\n\x1a\n"
               + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
               + chunk(b"IEND", b""))
        with open(path, "wb") as f:
            f.write(png)


class PilCanvas:
    def __init__(self, w, h):
        self.img = Image.new("RGB", (w, h), (0, 0, 0))
        self.d = ImageDraw.Draw(self.img)
        self.w, self.h = w, h

    def clear(self, rgb):
        self.d.rectangle([0, 0, self.w, self.h], fill=tuple(rgb))

    def point(self, x, y, rgb):
        self.d.point((x, y), fill=tuple(rgb))

    def line(self, x0, y0, x1, y1, rgb, size=1):
        self.d.line([x0, y0, x1, y1], fill=tuple(rgb), width=size)

    def rect(self, x0, y0, x1, y1, rgb, fill, size=1):
        box = [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]
        if fill:
            self.d.rectangle(box, fill=tuple(rgb))
        else:
            self.d.rectangle(box, outline=tuple(rgb), width=size)

    def oval(self, x0, y0, x1, y1, rgb, fill):
        box = [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]
        if fill:
            self.d.ellipse(box, fill=tuple(rgb))
        else:
            self.d.ellipse(box, outline=tuple(rgb))

    def text(self, x, y, s, rgb, size):
        try:
            font = ImageFont.truetype("arial.ttf", size)
        except (OSError, IOError):
            font = ImageFont.load_default()
        # protocol says x,y is the LEFT BASELINE, PIL wants the top-left
        self.d.text((x, y - size), s, fill=tuple(rgb), font=font)

    def save_png(self, path):
        self.img.save(path)


# --------------------------------------------------------------------------
class FakeG3:
    def __init__(self, out):
        self.out = out
        self.canvas = PilCanvas(WIDTH, HEIGHT) if HAVE_PIL else RawCanvas(WIDTH, HEIGHT)
        self.pen = (255, 255, 255)
        self.pensize = 1
        self.fontsize = 12
        self.cur = (0, 0)
        self.count = 0

    def execute(self, verb, a):
        c = self.canvas
        if verb == "HELLO":
            return ("OK", ["proto=%d" % protocol.PROTO_VERSION])
        if verb == "PING":
            return ("PONG", [])
        if verb == "BYE":
            raise SystemExit(0)
        if verb == "CLEAR":
            c.clear(tuple(int(v) for v in a[:3]) if len(a) >= 3 else (0, 0, 0))
        elif verb == "PEN":
            self.pen = tuple(int(v) for v in a[:3])
        elif verb == "PENSIZE":
            self.pensize = max(1, int(a[0]))
        elif verb == "FONT":
            pass
        elif verb == "MOVETO":
            self.cur = (int(a[0]), int(a[1]))
        elif verb == "LINETO":
            x, y = int(a[0]), int(a[1])
            c.line(self.cur[0], self.cur[1], x, y, self.pen, self.pensize)
            self.cur = (x, y)
        elif verb == "LINE":
            c.line(int(a[0]), int(a[1]), int(a[2]), int(a[3]), self.pen, self.pensize)
        elif verb == "PIXEL":
            c.point(int(a[0]), int(a[1]), self.pen)
        elif verb == "RECT":
            c.rect(int(a[0]), int(a[1]), int(a[2]), int(a[3]), self.pen,
                   len(a) > 4 and a[4].upper() == "FILL", self.pensize)
        elif verb == "OVAL":
            c.oval(int(a[0]), int(a[1]), int(a[2]), int(a[3]), self.pen,
                   len(a) > 4 and a[4].upper() == "FILL")
        elif verb == "TEXT":
            size = int(a[3]) if len(a) > 3 else self.fontsize
            if hasattr(c, "text"):
                c.text(int(a[0]), int(a[1]), a[2], self.pen, size)
            else:
                sys.stderr.write("  (no glyphs in fallback raster) TEXT %r\n" % a[2])
        elif verb == "FLUSH":
            c.save_png(self.out)
            return ("OK", ["presented=%s" % os.path.basename(self.out)])
        else:
            return ("ERR", ["unknown verb %s" % verb])
        self.count += 1
        return ("OK", [])


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
                     % (host, port, "PIL" if HAVE_PIL else "raw"))
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
