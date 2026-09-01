"""Software rasteriser for the G3 command set.

Used in two places:
  * tools/fake_g3.py -- pretends to be the Mac so the host can be tested alone
  * host/g3d.py      -- keeps a MIRROR of what the real Mac is displaying, which
                        powers the Tier 0 browser display and screenshots

Uses Pillow when importable, and falls back to a dependency-free rasteriser so
it still runs on an interpreter without it (WSL here has no Pillow, Windows does).
"""

import math
import struct
import zlib

try:
    from PIL import Image, ImageDraw, ImageFont
    HAVE_PIL = True
except ImportError:
    HAVE_PIL = False


class RawCanvas:
    """No dependencies. Geometry only -- has no glyphs, so TEXT is a no-op."""

    has_text = False

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
        lo_x, hi_x = min(x0, x1), max(x0, x1)
        lo_y, hi_y = min(y0, y1), max(y0, y1)
        if fill:
            for y in range(lo_y, hi_y + 1):
                self.line(lo_x, y, hi_x, y, rgb)
        else:
            self.line(lo_x, lo_y, hi_x, lo_y, rgb, size)
            self.line(hi_x, lo_y, hi_x, hi_y, rgb, size)
            self.line(hi_x, hi_y, lo_x, hi_y, rgb, size)
            self.line(lo_x, hi_y, lo_x, lo_y, rgb, size)

    def oval(self, x0, y0, x1, y1, rgb, fill):
        cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
        rx, ry = abs(x1 - x0) / 2.0, abs(y1 - y0) / 2.0
        if rx < 0.5 or ry < 0.5:
            return
        if fill:
            for y in range(int(cy - ry), int(cy + ry) + 1):
                dy = (y - cy) / ry
                if abs(dy) > 1:
                    continue
                half = rx * math.sqrt(max(0.0, 1 - dy * dy))
                self.line(int(cx - half), y, int(cx + half), y, rgb)
        else:
            steps = max(24, int((rx + ry) * 2))
            prev = None
            for i in range(steps + 1):
                a = 2 * math.pi * i / steps
                pt = (int(round(cx + rx * math.cos(a))), int(round(cy + ry * math.sin(a))))
                if prev:
                    self.line(prev[0], prev[1], pt[0], pt[1], rgb)
                prev = pt

    def text(self, x, y, s, rgb, size):
        return False                              # no glyphs available

    def save(self, path):
        raw = bytearray()
        stride = self.w * 3
        for y in range(self.h):
            raw.append(0)
            raw += self.px[y * stride:(y + 1) * stride]

        def chunk(tag, data):
            c = struct.pack(">I", len(data)) + tag + data
            return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        with open(path, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n"
                    + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
                    + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
                    + chunk(b"IEND", b""))


class PilCanvas:
    has_text = True

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("RGB", (w, h), (0, 0, 0))
        self.d = ImageDraw.Draw(self.img)
        self._fontname = None

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
        font = None
        for cand in ([self._fontname] if self._fontname else []) + ["arial.ttf", "cour.ttf"]:
            try:
                font = ImageFont.truetype(cand, size)
                break
            except (OSError, IOError):
                continue
        if font is None:
            font = ImageFont.load_default()
        # the protocol says x,y is the LEFT BASELINE; PIL anchors top-left
        self.d.text((x, y - size), s, fill=tuple(rgb), font=font)
        return True

    def set_font(self, name):
        self._fontname = {"monaco": "cour.ttf", "courier": "cour.ttf",
                          "geneva": "arial.ttf", "chicago": "arial.ttf"}.get(name.lower())

    def save(self, path):
        if path.lower().endswith(".gif"):
            # GIF with the 216-colour WEB-SAFE palette, not an adaptive one.
            # Mac OS 9.0-9.0.3 shipped Internet Explorer 4.5, which has no PNG
            # support at all, and Netscape 4 dithers adaptive palettes badly on
            # an 8-bit display. Web-safe renders correctly on all of them.
            # DITHERING OFF is not a detail. Pillow dithers by default, which
            # on flat vector artwork sprays noise across every solid area and
            # destroys LZW compression: measured 135KB dithered vs 17KB not,
            # on the same 800x600 frame. On a 233MHz Mac that 8x is the
            # difference between a ~20 second refresh and a usable one.
            try:
                pal = Image.WEB
            except AttributeError:
                pal = Image.ADAPTIVE
            try:
                nodither = Image.Dither.NONE
            except AttributeError:
                nodither = 0                      # older Pillow
            self.img.convert("P", palette=pal, dither=nodither).save(path)
        else:
            self.img.save(path)


def new_canvas(w, h):
    return PilCanvas(w, h) if HAVE_PIL else RawCanvas(w, h)


class Screen:
    """A canvas plus the pen state the command set mutates."""

    def __init__(self, w=800, h=600):
        self.w, self.h = w, h
        self.canvas = new_canvas(w, h)
        self.pen = (255, 255, 255)
        self.pensize = 1
        self.fontsize = 12
        self.cur = (0, 0)
        self.ops = 0

    def apply(self, verb, a):
        """Execute one protocol command. Returns extra reply args, or raises."""
        c = self.canvas
        if verb == "CLEAR":
            c.clear(tuple(int(v) for v in a[:3]) if len(a) >= 3 else (0, 0, 0))
        elif verb == "PEN":
            self.pen = tuple(int(v) for v in a[:3])
        elif verb == "PENSIZE":
            self.pensize = max(1, int(a[0]))
        elif verb == "FONT":
            if hasattr(c, "set_font"):
                c.set_font(a[0])
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
            c.text(int(a[0]), int(a[1]), a[2], self.pen, size)
        else:
            return None                            # not a drawing command
        self.ops += 1
        return []

    def save(self, path):
        self.canvas.save(path)
