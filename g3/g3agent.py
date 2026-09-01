# G3Bridge agent -- runs ON the Mac OS 9 machine.
#
# Requires MacPython-OS9 2.3.3 -- the last release for classic Mac OS.
# (2.3.5 is often cited as the last, but a check against primary sources
#  found no classic Mac OS build of it. Use 2.3.3.)
# Drop this in a folder on the Mac and double-click it, or open it in the
# MacPython IDE and hit Run.
#
# WRITTEN FOR PYTHON 2.3. Deliberately avoids everything newer:
#   no threads (MacPython-OS9 is built with WITH_THREAD undefined)
#   no json, no set(), no sorted(), no generator expressions,
#   no ternary expressions, no decorators, no "with"
#
# It must run in the FOREGROUND. Mac OS 9 is cooperatively multitasked; if this
# window goes behind another application the socket stalls until it returns.
# The host tolerates that, but the display will freeze.

import socket
import select
import sys
import time

try:
    from Carbon import Qd, Win, Evt, Fm, Events
    HAVE_CARBON = 1
except ImportError:
    HAVE_CARBON = 0

# ---------------------------------------------------------------- settings
HOST = "192.168.11.10"      # the PC. Run tools/netcheck.py there to confirm.
PORT = 9990
CANVAS_W = 800              # native on every iMac G3, fits Rev A's 2MB VRAM
CANVAS_H = 600
TITLE = "G3Bridge"
WINDOW_TOP = 40             # leave the menu bar visible
RECONNECT_WAIT = 3.0

everyEvent = -1


# ---------------------------------------------------------------- parsing
def parse_line(line):
    """Split a wire line into tokens, honouring "quoted strings" and \\ escapes.

    Hand-rolled rather than shlex: this runs on a 233MHz machine and shlex 2.3
    is slow enough to matter inside the draw loop.
    """
    toks = []
    cur = []
    in_q = 0
    esc = 0
    quoted = 0          # a quote starts a token even if it stays empty,
                        # so TEXT 0 0 "" arrives as an empty argument and
                        # not as a missing one
    for ch in line:
        if esc:
            cur.append(ch)
            esc = 0
        elif ch == "\\":
            esc = 1
        elif ch == '"':
            in_q = not in_q
            quoted = 1
        elif ch == " " and not in_q:
            if cur or quoted:
                toks.append("".join(cur))
                cur = []
                quoted = 0
        else:
            cur.append(ch)
    if cur or quoted:
        toks.append("".join(cur))
    return toks


def to_qd(v):
    """0-255 on the wire -> QuickDraw's 0-65535."""
    n = int(v)
    if n < 0:
        n = 0
    if n > 255:
        n = 255
    return n * 257


# ---------------------------------------------------------------- screen
class Screen:
    """QuickDraw drawing plus a display list, because QuickDraw does not retain.

    Every drawing command is appended to self.dlist so an updateEvt (window
    uncovered, or brought back to the front) can repaint from scratch.
    """

    def __init__(self):
        self.dlist = []
        self.pen = (65535, 65535, 65535)
        self.bg = (0, 0, 0)
        self.pensize = 1
        self.font = "Geneva"
        self.fontsize = 12
        self.cur = (0, 0)
        self.win = None
        self.port = None

    def open(self):
        if not HAVE_CARBON:
            return
        bounds = (0, WINDOW_TOP, CANVAS_W, WINDOW_TOP + CANVAS_H)
        # procID 8 = zoomDocProc (draggable, good for setup).
        # Change to 2 (plainDBox) once it works, for a borderless kiosk look.
        self.win = Win.NewCWindow(bounds, TITLE, 1, 8, -1, 1, 0)
        self.port = self.win.GetWindowPort()
        Qd.SetPort(self.port)
        self.clear(self.bg)
        self.flush()

    def _setpen(self):
        Qd.RGBForeColor(self.pen)
        Qd.PenSize(self.pensize, self.pensize)

    # -- individual primitives ------------------------------------------
    def clear(self, rgb):
        Qd.RGBBackColor(rgb)
        Qd.EraseRect((0, 0, CANVAS_W, CANVAS_H))

    def do(self, verb, a):
        """Execute one drawing command. Raises on bad arguments."""
        if verb == "CLEAR":
            if len(a) >= 3:
                self.bg = (to_qd(a[0]), to_qd(a[1]), to_qd(a[2]))
            else:
                self.bg = (0, 0, 0)
            self.clear(self.bg)
            self.dlist = []                      # a clear resets the history
            return
        if verb == "PEN":
            self.pen = (to_qd(a[0]), to_qd(a[1]), to_qd(a[2]))
            return
        if verb == "PENSIZE":
            self.pensize = max(1, int(a[0]))
            return
        if verb == "FONT":
            self.font = a[0]
            return
        if verb == "MOVETO":
            self.cur = (int(a[0]), int(a[1]))
            return

        self._setpen()
        if verb == "LINETO":
            x, y = int(a[0]), int(a[1])
            Qd.MoveTo(self.cur[0], self.cur[1])
            Qd.LineTo(x, y)
            self.cur = (x, y)
        elif verb == "LINE":
            Qd.MoveTo(int(a[0]), int(a[1]))
            Qd.LineTo(int(a[2]), int(a[3]))
        elif verb == "PIXEL":
            x, y = int(a[0]), int(a[1])
            Qd.PaintRect((x, y, x + 1, y + 1))
        elif verb == "RECT":
            r = (int(a[0]), int(a[1]), int(a[2]), int(a[3]))
            if len(a) > 4 and a[4].upper() == "FILL":
                Qd.PaintRect(r)
            else:
                Qd.FrameRect(r)
        elif verb == "OVAL":
            r = (int(a[0]), int(a[1]), int(a[2]), int(a[3]))
            if len(a) > 4 and a[4].upper() == "FILL":
                Qd.PaintOval(r)
            else:
                Qd.FrameOval(r)
        elif verb == "TEXT":
            size = self.fontsize
            if len(a) > 3:
                size = int(a[3])
            Qd.TextFont(Fm.GetFNum(self.font))
            Qd.TextSize(size)
            Qd.TextFace(0)
            Qd.MoveTo(int(a[0]), int(a[1]))       # y is the BASELINE
            Qd.DrawString(a[2][:255])             # Str255 limit
        else:
            raise ValueError("unknown verb %s" % verb)

    def replay(self):
        """Repaint everything after an update event."""
        if not HAVE_CARBON or self.win is None:
            return
        Qd.SetPort(self.port)
        saved = self.dlist
        self.dlist = []
        self.clear(self.bg)
        for verb, a in saved:
            try:
                self.do(verb, a)
            except Exception:
                pass
        self.dlist = saved
        self.flush()

    def flush(self):
        if not HAVE_CARBON or self.port is None:
            return
        try:
            if self.port.QDIsPortBuffered():
                self.port.QDFlushPortBuffer(None)
        except Exception:
            pass


# ---------------------------------------------------------------- agent
class Agent:
    def __init__(self):
        self.screen = Screen()
        self.sock = None
        self.buf = ""
        self.running = 1
        self.events_on = 1

    def log(self, msg):
        sys.stderr.write("g3agent: %s\n" % msg)

    # -- link -----------------------------------------------------------
    def connect(self):
        self.log("dialling %s:%d ..." % (HOST, PORT))
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect((HOST, PORT))
        self.sock = s
        self.buf = ""
        depth = 32
        self.send("READY macpython/%s %d %d %d"
                  % (sys.version.split()[0], CANVAS_W, CANVAS_H, depth))
        self.log("connected")

    def send(self, line):
        if self.sock is None:
            return
        try:
            self.sock.send(line + "\n")
        except Exception, e:                      # py2 except syntax
            self.log("send failed: %s" % e)
            self.drop()

    def drop(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except Exception:
                pass
        self.sock = None

    # -- command handling -----------------------------------------------
    def handle(self, line):
        # Strip a trailing CR so a CRLF-emitting host cannot break the link.
        if line[-1:] == "\r":
            line = line[:-1]
        if not line:
            return
        toks = parse_line(line)
        if not toks:
            return
        seq = "0"
        if toks[0].isdigit():
            seq = toks[0]
            toks = toks[1:]
        if not toks:
            return
        verb = toks[0].upper()
        a = toks[1:]

        if verb == "HELLO":
            self.send("%s OK proto=1 agent=macpython" % seq)
            return
        if verb == "PING":
            self.send("%s PONG" % seq)
            return
        if verb == "BYE":
            self.send("%s OK bye" % seq)
            self.running = 0
            return
        if verb == "FLUSH":
            self.screen.flush()
            self.send("%s OK presented" % seq)
            return

        try:
            self.screen.do(verb, a)
            self.screen.dlist.append((verb, a))
            self.send("%s OK" % seq)
        except ValueError, e:
            self.send('%s ERR 404 "%s"' % (seq, e))
        except Exception, e:
            self.send('%s ERR 500 "%s: %s"' % (seq, e.__class__.__name__, e))

    def pump_socket(self):
        if self.sock is None:
            return
        try:
            r, w, x = select.select([self.sock], [], [], 0)
        except Exception:
            self.drop()
            return
        if not r:
            return
        try:
            chunk = self.sock.recv(4096)
        except Exception:
            self.drop()
            return
        if not chunk:
            self.log("host closed the link")
            self.drop()
            return
        self.buf = self.buf + chunk
        while "\n" in self.buf:
            i = self.buf.index("\n")
            line = self.buf[:i]
            self.buf = self.buf[i + 1:]
            self.handle(line)

    # -- mac events ------------------------------------------------------
    def pump_events(self):
        if not HAVE_CARBON:
            return
        got, ev = Evt.WaitNextEvent(everyEvent, 1)
        if not got:
            return
        what, message, when, where, mods = ev
        if what == Events.updateEvt:
            self.screen.replay()
        elif what == Events.mouseDown and self.events_on:
            self.send("EVENT CLICK %d %d %d" % (where[0], where[1], mods))
        elif what == Events.keyDown and self.events_on:
            code = (message >> 8) & 0xFF
            char = message & 0xFF
            if char == 27:                        # esc quits
                self.send("EVENT QUIT")
                self.running = 0
            else:
                self.send("EVENT KEY %d %d %d" % (code, char, mods))

    # -- main ------------------------------------------------------------
    def run(self):
        if not HAVE_CARBON:
            self.log("WARNING: Carbon not importable -- running headless.")
            self.log("On Mac OS 9 this means MacPython is not the OS 9 build.")
        self.screen.open()
        last_try = 0.0
        while self.running:
            if self.sock is None:
                now = time.time()
                if now - last_try > RECONNECT_WAIT:
                    last_try = now
                    try:
                        self.connect()
                    except Exception, e:
                        self.log("connect failed: %s" % e)
            self.pump_socket()
            self.pump_events()
        self.drop()
        self.log("stopped")


# ---------------------------------------------------------------- selftest
def selftest():
    """Draw locally with no network, to prove MacPython + Carbon work."""
    s = Screen()
    s.open()
    seq = [
        ("CLEAR", ["0", "0", "50"]),
        ("PEN", ["255", "200", "0"]),
        ("RECT", ["20", "20", str(CANVAS_W - 20), str(CANVAS_H - 20)]),
        ("PEN", ["0", "220", "255"]),
        ("OVAL", ["250", "180", "550", "420", "FILL"]),
        ("PEN", ["255", "255", "255"]),
        ("TEXT", ["60", "520", "G3BRIDGE SELFTEST OK", "24"]),
    ]
    for verb, a in seq:
        s.do(verb, a)
        s.dlist.append((verb, a))
    s.flush()
    sys.stderr.write("selftest drawn. Carbon=%d\n" % HAVE_CARBON)
    if HAVE_CARBON:
        sys.stderr.write("Click the window or wait 10s.\n")
        t = time.time()
        while time.time() - t < 10:
            Evt.WaitNextEvent(everyEvent, 6)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        selftest()
    else:
        Agent().run()
