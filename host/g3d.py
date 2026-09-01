"""g3d -- the G3Bridge daemon.

Long-lived. Owns the socket to the Mac OS 9 machine so the connection survives
Claude Code restarting (the MCP server is a short-lived child process and must
not be the thing holding the link).

Listeners:
  :9990  0.0.0.0    the G3 agent dials in here over the Ethernet cable
  :9991  127.0.0.1  the MCP server issues commands here

Run it on WINDOWS Python, not WSL: WSL2 is NAT'd, so a machine on the far end
of a direct Ethernet cable cannot reach a listener inside it.

    C:\\Python310\\python.exe host\\g3d.py

Threading rule that matters: exactly ONE thread ever reads the agent socket
(the AgentHandler pump). Callers of Link.send() park on a per-sequence Event
and the pump wakes them. Two readers on one socket silently eat each other's
replies -- that bug cost an afternoon once already.
"""

import os
import socket
import base64
import http.server
import socketserver
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402
import devices  # noqa: E402
import protocol  # noqa: E402
import raster  # noqa: E402
import xfer  # noqa: E402

AGENT_PORT = config.AGENT_PORT
CONTROL_PORT = config.CONTROL_PORT
HTTP_PORT = config.HTTP_PORT
REPLY_TIMEOUT = config.REPLY_TIMEOUT

HERE = os.path.dirname(os.path.abspath(__file__))
RUN_DIR = os.path.join(HERE, "..", "run")
BOOT_DIR = os.path.join(HERE, "..", "g3")
TO_MAC = os.path.join(HERE, "..", config.TO_MAC_DIR)
FROM_MAC = os.path.join(HERE, "..", config.FROM_MAC_DIR)

# Commands that mutate the picture. These are mirrored host-side so that the
# Tier 0 browser display works even when no agent is installed on the Mac.
DRAW_VERBS = frozenset((
    "CLEAR", "PEN", "PENSIZE", "FONT", "MOVETO", "LINETO",
    "LINE", "PIXEL", "RECT", "OVAL", "TEXT",
))


def local_ipv4():
    found = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.add(info[4][0])
    except socket.gaierror:
        pass
    return found


def bind_addresses():
    """Which addresses to listen on.

    Preference is to bind the cable adapter specifically, so the house WiFi LAN
    cannot even see the bridge. But that address DISAPPEARS while the vintage
    machine is switched off -- Windows drops it when the link goes down -- and
    binding loopback-only then would mean restarting the daemon every time the
    Mac is powered on. That is a worse failure than a listening port.

    So: bind the cable address when it exists, otherwise fall back to all
    interfaces. Either way the real control is the allowlist -- every inbound
    connection, agent socket and HTTP alike, is matched against config.DEVICES
    by IP and refused if it is not a known machine.
    """
    if not config.BIND_TO_CABLE_ONLY:
        return ["0.0.0.0"]
    addrs = local_ipv4()
    if config.SUGGESTED_PC_IP in addrs:
        return [config.SUGGESTED_PC_IP, "127.0.0.1"]
    return ["0.0.0.0"]


def log(msg):
    sys.stderr.write("[g3d %s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


class Link:
    """The single live connection to the G3, plus its request/reply plumbing."""

    def __init__(self):
        self._send_lock = threading.Lock()   # serialises writers
        self._state = threading.Lock()       # guards the fields below
        self._sock = None
        self._seq = 0
        self._pending = {}                   # seq -> [Event, reply_or_None]
        self.info = {}
        self.events = []
        self.connected_at = None

    # -- lifecycle ----------------------------------------------------------
    def attach(self, sock, addr):
        with self._state:
            old = self._sock
            self._sock = sock
            self.info = {"peer": "%s:%d" % addr}
            self.connected_at = time.time()
        if old is not None:
            log("displacing previous agent connection")
            try:
                old.close()
            except OSError:
                pass
        log("agent attached from %s:%d" % addr)

    def detach(self, sock):
        with self._state:
            if self._sock is not sock:
                return                        # a newer connection already won
            self._sock = None
            self.connected_at = None
            waiters = list(self._pending.values())
            self._pending.clear()
        for w in waiters:                     # never leave a caller parked
            w[1] = ("ERR", ["agent disconnected"])
            w[0].set()
        log("agent detached")

    @property
    def alive(self):
        return self._sock is not None

    # -- traffic ------------------------------------------------------------
    def send(self, verb, *args):
        """Send one command and block for its OK/ERR. Returns (verb, args)."""
        with self._send_lock:
            with self._state:
                sock = self._sock
                if sock is None:
                    raise IOError("no G3 agent connected")
                self._seq += 1
                seq = self._seq
                slot = [threading.Event(), None]
                self._pending[seq] = slot

            line = protocol.encode(seq, verb, *args) + "\n"
            try:
                sock.sendall(line.encode("ascii", "replace"))
            except OSError as e:
                with self._state:
                    self._pending.pop(seq, None)
                raise IOError("write failed: %s" % e)

            if not slot[0].wait(REPLY_TIMEOUT):
                with self._state:
                    self._pending.pop(seq, None)
                raise IOError("timed out after %gs waiting for reply to seq %d"
                              % (REPLY_TIMEOUT, seq))
            return slot[1]

    def dispatch(self, line):
        """Called ONLY by the pump thread, for every line the agent sends."""
        try:
            seq, verb, args = protocol.decode(line)
        except protocol.ProtocolError as e:
            log("dropping malformed line from agent: %s" % e)
            return

        if seq is None:
            if verb == "READY":
                self._absorb_ready(args)
            elif verb == "EVENT":
                with self._state:
                    self.events.append(args)
                log("event: %s" % " ".join(args))
            else:
                log("unsolicited %s %s" % (verb, " ".join(args)))
            return

        with self._state:
            slot = self._pending.pop(seq, None)
        if slot is None:
            log("ignoring stale reply for seq %d" % seq)
            return
        slot[1] = (verb, args)
        slot[0].set()

    def _absorb_ready(self, args):
        keys = ("agent", "width", "height", "depth")
        with self._state:
            for k, v in zip(keys, args):
                self.info[k] = int(v) if v.isdigit() else v
            snapshot = dict(self.info)
        log("agent ready: %s" % snapshot)

    def drain_events(self):
        with self._state:
            pending, self.events = self.events, []
        return pending

    def status(self):
        # Only report agent details while the agent is actually attached --
        # stale width/height alongside state=waiting reads as a live machine.
        with self._state:
            if self._sock is None:
                return ["state=waiting"]
            out = ["state=connected"]
            for k in ("agent", "width", "height", "depth", "peer"):
                if k in self.info:
                    out.append("%s=%s" % (k, self.info[k]))
            if self.connected_at:
                out.append("uptime=%ds" % int(time.time() - self.connected_at))
        return out


class CommandQueue:
    """One-at-a-time command channel for the AppleScript applet.

    The applet is a pure HTTP client -- it cannot listen, so it polls. It asks
    GET /cmd, gets a script or nothing, runs it, and posts the output back to
    /result. Only one command is outstanding at a time, which removes any need
    for ids or matching on the Mac side, where the scripting is awkward.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._pending = None          # script text waiting to be collected
        self._inflight = None         # collected, awaiting a result
        self._done = threading.Event()
        self._result = None
        self._status = "OK"
        self._chunks = {}
        self.last_poll = None
        self.polls = 0

    def submit(self, script, timeout=60.0):
        with self._lock:
            if self._pending is not None or self._inflight is not None:
                raise IOError("a command is already outstanding")
            self._pending = script
            self._result = None
            self._status = "OK"
            self._chunks = {}
            self._done.clear()
        if not self._done.wait(timeout):
            with self._lock:
                self._pending = None
                self._inflight = None
            raise IOError(
                "no reply within %gs. Is the applet running on the Mac? "
                "It has polled %d time(s)%s."
                % (timeout, self.polls,
                   "" if not self.last_poll
                   else ", last %ds ago" % int(time.time() - self.last_poll)))
        with self._lock:
            if self._status and self._status != "OK":
                return "[%s] %s" % (self._status, self._result or "")
            return self._result

    def collect(self):
        """Called by GET /cmd."""
        with self._lock:
            self.polls += 1
            self.last_poll = time.time()
            if self._pending is None:
                return None
            self._inflight = self._pending
            self._pending = None
            return self._inflight

    def deliver(self, text, status="OK"):
        """Called by the result endpoint once a whole result has arrived."""
        with self._lock:
            if self._inflight is None:
                return False
            self._result = text
            self._status = status
            self._inflight = None
            self._chunks = {}
        self._done.set()
        return True

    def add_chunk(self, seq, part, total, status, raw):
        """Accumulate one chunk of a chunked result.

        The Mac returns output by smuggling it through GET query strings, in
        pieces, because URL Access Scripting has no dependable HTTP upload.
        Chunks are idempotent: a retry carries the same part number and simply
        overwrites.

        Chunks are stored STILL PERCENT-ENCODED and decoded once at the end.
        Decoding each chunk separately loses characters whenever a split lands
        in the middle of a %XX escape -- which cost a line of output the first
        time this was tested. Joining first makes the host correct no matter
        how the Mac chooses to split.
        """
        with self._lock:
            self._chunks[part] = raw
            got = len(self._chunks)
            if got < total:
                return False, got
            keys = list(self._chunks.keys())
            keys.sort()
            joined = "".join([self._chunks[k] for k in keys])
        self.deliver(_pct(joined), status)
        return True, total

    def status(self):
        with self._lock:
            state = "idle"
            if self._pending is not None:
                state = "queued"
            elif self._inflight is not None:
                state = "running"
            age = "never"
            if self.last_poll:
                age = "%ds ago" % int(time.time() - self.last_poll)
            return ["applet=%s" % state, "polls=%d" % self.polls, "last_poll=%s" % age]


REGISTRY = devices.Registry()
for _d in REGISTRY:
    _d.link = Link()
    _d.queue = CommandQueue()


def present_all():
    for d in REGISTRY:
        d.present()


class AgentHandler(socketserver.BaseRequestHandler):
    """The one and only reader of the agent socket."""

    def handle(self):
        sock = self.request
        dev = REGISTRY.for_peer(self.client_address[0])
        if dev is None:
            log("REFUSED agent connection from %s:%d -- not a known machine (%s)"
                % (self.client_address[0], self.client_address[1],
                   ", ".join("%s=%s" % (d.name, d.ip) for d in REGISTRY)))
            try:
                sock.sendall(b"0 ERR 403 \"not a known machine\"\n")
            except OSError:
                pass
            return
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        dev.touch()
        log("agent for '%s' connecting" % dev.name)
        dev.link.attach(sock, self.client_address)
        buf = b""
        try:
            while True:
                try:
                    chunk = sock.recv(4096)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    text = raw.decode("ascii", "replace").strip()
                    if text:
                        dev.link.dispatch(text)
        finally:
            dev.link.detach(sock)


class ControlHandler(socketserver.StreamRequestHandler):
    """Local-only. The MCP server speaks the same line protocol to us."""

    def handle(self):
        dev = REGISTRY.resolve(None)
        for raw in self.rfile:
            line = raw.decode("ascii", "replace").strip()
            if not line:
                continue
            try:
                seq, verb, args = protocol.decode(line)
            except protocol.ProtocolError as e:
                self._reply("ERR", 0, str(e))
                continue
            seq = seq or 0

            # USE <name> picks which machine the rest of this connection is
            # talking to. Without it, the bridge picks the only machine that
            # has been seen, or the configured default.
            if verb == "USE":
                target = REGISTRY.by_name(args[0]) if args else None
                if target is None:
                    self._reply("ERR", seq, "unknown device %r; known: %s"
                                % (args[0] if args else "", ", ".join(REGISTRY.names())))
                    continue
                dev = target
                self._reply("OK", seq, "device=%s" % dev.name)
                continue

            if verb == "DEVICES":
                out = []
                for d in REGISTRY:
                    out.append("%s|%s|%dx%d|%s|%s" % (
                        d.name, d.ip, d.canvas[0], d.canvas[1], d.os,
                        "connected" if (d.link and d.link.alive) else
                        ("seen" if d.last_seen else "never")))
                self._reply("OK", seq, *out)
                continue

            if verb == "STATUS":
                self._reply("OK", seq, *(dev.describe() + dev.link.status()))
                continue
            if verb == "APPLESCRIPT":
                try:
                    body = base64.b64decode(args[0]).decode("utf-8")
                    timeout = float(args[1]) if len(args) > 1 else 60.0
                except Exception as e:
                    self._reply("ERR", seq, "bad APPLESCRIPT request: %s" % e)
                    continue
                try:
                    out = dev.queue.submit(body, timeout)
                except IOError as e:
                    self._reply("ERR", seq, str(e))
                    continue
                self._reply("OK", seq, base64.b64encode(
                    (out or "").encode("utf-8")).decode("ascii"))
                continue

            if verb == "APPLETSTATUS":
                self._reply("OK", seq, *dev.queue.status())
                continue

            if verb == "EVENTS":
                self._reply("OK", seq, *["|".join(e) for e in dev.link.drain_events()])
                continue

            # Draw into the host-side mirror regardless of whether the Mac
            # is attached, so Tier 0 (browser as the display) works with
            # nothing installed on the Mac.
            mirrored = False
            if verb in DRAW_VERBS:
                try:
                    with dev.mirror_lock:
                        dev.mirror.apply(verb, args)
                    mirrored = True
                except Exception as e:
                    self._reply("ERR", seq, "mirror rejected %s: %s" % (verb, e))
                    continue
            elif verb == "FLUSH":
                dev.present()
                mirrored = True

            if not dev.link.alive:
                if mirrored:
                    self._reply("OK", seq, "mirror-only", "no-agent-attached",
                                "device=%s" % dev.name)
                else:
                    self._reply("ERR", seq, "no G3 agent connected")
                continue

            try:
                rverb, rargs = dev.link.send(verb, *args)
                self._reply(rverb, seq, *rargs)
            except IOError as e:
                self._reply("ERR", seq, str(e))

    def _reply(self, verb, seq, *args):
        self.wfile.write((protocol.encode(seq, verb, *args) + "\n").encode("ascii", "replace"))


def _q(query, key):
    """One query parameter, undecoded."""
    for pair in query.split("&"):
        if pair.startswith(key + "="):
            return pair[len(key) + 1:]
    return None


def _pct(text):
    """Percent-decode, then read as MacRoman with CR line endings.

    Classic AppleScript writes MacRoman, not UTF-8, and terminates lines with
    CR. Decoding as UTF-8 mangles every accented character.
    """
    from urllib.parse import unquote_to_bytes
    try:
        raw = unquote_to_bytes(text.replace("+", "%20"))
    except Exception:
        return text
    try:
        out = raw.decode("mac_roman")
    except (UnicodeDecodeError, LookupError):
        out = raw.decode("latin-1", "replace")
    return out.replace("\r\n", "\n").replace("\r", "\n")


DISPLAY_PAGE = """<html><head><title>G3Bridge</title>
<meta http-equiv="refresh" content="%(refresh)s">
</head>
<body bgcolor="#000000" text="#FFFFFF" link="#00CCFF" vlink="#00CCFF"
      topmargin="0" leftmargin="0" marginwidth="0" marginheight="0">
<center>
<a href="/click"><img src="/f/%(seq)06d.%(ext)s" border="0" ismap
     width="%(w)d" height="%(h)d" alt="G3Bridge display"></a>
</center>
</body></html>"""


UPLOAD_PAGE = """<html><head><title>Send a file to the PC</title></head>
<body bgcolor="#FFFFFF">
<h2>Send a file to the PC</h2>
<form action="/upload" method="POST" enctype="multipart/form-data">
<p>Choose a file on this Mac:</p>
<p><input type="file" name="f"></p>
<p><input type="submit" value="Send to the PC"></p>
</form>
<p><font size="-1">Only the data fork is sent. Applications, fonts and anything
whose contents live in a resource fork will arrive incomplete &mdash; put those
in a StuffIt archive first.</font></p>
<p><a href="/menu">Back</a></p>
</body></html>"""


class DisplayHandler(http.server.BaseHTTPRequestHandler):
    """Tier 0: the Mac's browser IS the display. Also serves the bootstrap files.

    Deliberately HTML 3.2 -- meta refresh, ismap, table-free, no CSS, no
    JavaScript -- because the client may be Netscape 4 or IE 5 on Mac OS 9.
    """

    server_version = "G3Bridge/0.1"
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *a):
        log("http %s %s" % (self.client_address[0], fmt % a))

    def _send(self, code, ctype, body, extra=None, cacheable=False):
        if isinstance(body, str):
            body = body.encode("ascii", "replace")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if cacheable:
            # A frame URL carries a counter that only advances when the picture
            # actually changes, so each URL is immutable and can be cached hard.
            # This is the difference between the Mac re-downloading and
            # re-decoding a whole image every few seconds and it doing nothing
            # at all while the screen is unchanged -- which is most of the time.
            self.send_header("Cache-Control", "public, max-age=31536000")
        else:
            # Netscape 4 and IE 4.5/5 cache aggressively and inconsistently, so
            # the page itself gets all three headers.
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _device(self):
        d = REGISTRY.for_peer(self.client_address[0])
        if d is not None:
            d.touch()
        return d

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        dev = self._device()
        if dev is None:
            self._send(403, "text/plain",
                       "This bridge only serves the machines it knows about.")
            return

        if path in ("/", "/index.html"):
            ext = "gif" if raster.HAVE_PIL and os.path.exists(dev.frame_path("gif")) else "png"
            if dev.frame_seq == 0:
                dev.present()
            self._send(200, "text/html", DISPLAY_PAGE % {
                "refresh": str(config.REFRESH_SECONDS), "ext": ext, "seq": dev.frame_seq,
                "w": dev.mirror.w, "h": dev.mirror.h})
            return

        # /f/000123.gif -- the counter only exists to defeat the cache; any
        # value serves the current frame.
        if path.startswith("/f/") or path in ("/frame.gif", "/frame.png"):
            fn = dev.frame_path("gif" if path.endswith("gif") else "png")
            if not os.path.exists(fn):
                dev.present()
            try:
                with open(fn, "rb") as f:
                    body = f.read()
            except OSError:
                self._send(404, "text/plain", "no frame yet")
                return
            self._send(200, "image/gif" if fn.endswith("gif") else "image/png", body,
                       cacheable=True)
            return

        if path == "/click":
            # ismap sends "?x,y"; turn it into an event for the host
            xy = query.replace(",", " ").split()
            if len(xy) == 2 and all(v.isdigit() for v in xy):
                dev.link.events.append(["CLICK", xy[0], xy[1]])
                log("browser click on %s at %s,%s" % (dev.name, xy[0], xy[1]))
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return

        if path.startswith("/boot/"):
            name = os.path.basename(path[len("/boot/"):])
            fn = os.path.join(BOOT_DIR, name)
            if not name or not os.path.isfile(fn):
                self._send(404, "text/plain", "no such bootstrap file: %s" % name)
                return
            with open(fn, "rb") as f:
                body = f.read()
            # SimpleText and Script Editor want CR line endings. Do NOT do
            # this to .py -- MacPython reads LF source fine and a botched
            # conversion would break the agent.
            if name.endswith((".txt", ".scpt", ".applescript")):
                body = body.replace(b"\r\n", b"\n").replace(b"\n", b"\r")
            self._send(200, "application/octet-stream", body,
                       {"Content-Disposition": 'attachment; filename="%s"' % name})
            return

        if path == "/menu":
            self._send(200, "text/html",
                "<html><head><title>G3Bridge</title></head>"
                "<body bgcolor=#FFFFFF><h2>G3Bridge</h2><ul>"
                "<li><a href=\"/\">Display</a> &mdash; what Claude is drawing</li>"
                "<li><a href=\"/files\">Files from the PC</a> &mdash; download to this Mac</li>"
                "<li><a href=\"/upload\">Send a file to the PC</a></li>"
                "<li><a href=\"/boot\">Bootstrap</a> &mdash; the agent and its instructions</li>"
                "</ul></body></html>")
            return

        if path == "/files":
            rows = xfer.listing(TO_MAC)
            if rows:
                items = "".join(
                    '<li><a href="/files/%s">%s</a> &nbsp; <font size=-1>%s &mdash; %s</font></li>'
                    % (n, n, xfer.human(sz), note) for n, sz, note in rows)
            else:
                items = "<li>(nothing staged)</li>"
            self._send(200, "text/html",
                "<html><head><title>Files from the PC</title></head><body bgcolor=#FFFFFF>"
                "<h2>Files from the PC</h2><ul>%s</ul>"
                "<p><a href=\"/menu\">Back</a></p></body></html>" % items)
            return

        if path.startswith("/files/"):
            name = xfer.safe_name(path[len("/files/"):])
            fn = os.path.join(TO_MAC, name)
            if not name or not os.path.isfile(fn):
                self._send(404, "text/plain", "no such file: %s" % name)
                return
            with open(fn, "rb") as f:
                body = f.read()
            body, note = xfer.to_mac_bytes(name, body)
            log("sent %s to the Mac (%s)" % (name, note))
            self._send(200, "application/octet-stream", body,
                       {"Content-Disposition": 'attachment; filename="%s"' % name})
            return

        if path == "/hello":
            log("%s: applet started (tag=%s)" % (dev.name, _q(query, "t")))
            self._send(200, "text/plain", "OK\r")
            return

        if path == "/cmd":
            script = dev.queue.collect()
            if script is None:
                # NEVER an empty body: a zero-length download can raise
                # kURLFileEmptyError (-30783) on the Mac.
                self._send(200, "text/plain", "NONE\r")
                return
            # Classic Mac wants CR. Compiling a LF-only string on OS 9 is
            # asking for trouble.
            body = script.replace("\r\n", "\n").replace("\n", "\r")
            log("%s: dispatched %d chars of script" % (dev.name, len(script)))
            self._send(200, "text/plain", body)
            return

        if path == "/r":
            # The Mac returns output smuggled through GET query strings, in
            # chunks, because URL Access Scripting has no dependable HTTP
            # upload. Chunks are idempotent: a retry overwrites its part.
            try:
                seq = int(_q(query, "i") or "0")
                part = int(_q(query, "p") or "1")
                total = int(_q(query, "n") or "1")
            except ValueError:
                self._send(200, "text/plain", "OK\r")
                return
            status = (_q(query, "s") or "OK").upper()
            raw = _q(query, "d") or ""
            done, got = dev.queue.add_chunk(seq, part, total, status, raw)
            log("%s: result chunk %d/%d (%s, %d encoded chars)%s"
                % (dev.name, part, total, status, len(raw),
                   "  COMPLETE" if done else ""))
            self._send(200, "text/plain", "OK\r")
            return

        if path.startswith("/put"):
            # Diagnostic catch-all. URL Access Scripting's `upload` behaviour
            # over http:// is undocumented; if it is ever tried, this records
            # exactly what it sent so the question can be settled by evidence.
            log("%s: /put GET path=%s headers=%s"
                % (dev.name, path, list(dict(self.headers).keys())))
            self._send(200, "text/plain", "OK\r")
            return

        if path == "/result":
            ok = dev.queue.deliver(_pct(_q(query, "out") or ""))
            self._send(200, "text/plain", "OK\r" if ok else "NONE\r")
            return

        if path == "/upload":
            self._send(200, "text/html", UPLOAD_PAGE)
            return

        if path == "/boot":
            try:
                names = sorted(os.listdir(BOOT_DIR))
            except OSError:
                names = []
            items = "".join('<li><a href="/boot/%s">%s</a></li>' % (n, n) for n in names)
            self._send(200, "text/html",
                       "<html><body bgcolor=#FFFFFF><h2>G3Bridge bootstrap</h2>"
                       "<ul>%s</ul></body></html>" % (items or "<li>(nothing yet)</li>"))
            return

        self._send(404, "text/plain", "not found")

    def do_PUT(self):
        self.do_POST()

    def do_POST(self):
        dev = self._device()
        if dev is None:
            self._send(403, "text/plain", "unknown machine")
            return
        if self.path.split("?", 1)[0] == "/result":
            # Accept whatever the applet sends -- raw text, a PUT body, or a
            # multipart part. We do not control what URL Access Scripting
            # emits, so be liberal and strip a multipart wrapper if present.
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            raw = self.rfile.read(length) if length > 0 else b""
            ctype = self.headers.get("Content-Type") or ""
            if "multipart/" in ctype.lower():
                try:
                    parts = xfer.parse_multipart(raw, ctype, config.MAX_UPLOAD_BYTES)
                    if parts:
                        raw = parts[0][1]
                except ValueError:
                    pass
            text = raw.decode("mac-roman", "replace").replace("\r\n", "\n").replace("\r", "\n")
            ok = dev.queue.deliver(text)
            log("result from the Mac: %d chars%s"
                % (len(text), "" if ok else " (nothing was outstanding)"))
            self._send(200, "text/plain", "ok" if ok else "nothing was outstanding")
            return

        if self.path.split("?", 1)[0].startswith("/put"):
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            body = self.rfile.read(length) if length > 0 else b""
            log("%s: /put %s path=%s ctype=%r bytes=%d first=%r"
                % (dev.name, self.command, self.path,
                   self.headers.get("Content-Type"), len(body), body[:60]))
            self._send(200, "text/plain", "OK\r")
            return

        if self.path.split("?", 1)[0] != "/upload":
            self._send(404, "text/plain", "not found")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            self._result("Nothing arrived. The browser sent no data.")
            return
        if length > config.MAX_UPLOAD_BYTES:
            self._result("Too big: %s. Limit is %s."
                         % (xfer.human(length), xfer.human(config.MAX_UPLOAD_BYTES)))
            return
        body = self.rfile.read(length)
        try:
            files = xfer.parse_multipart(body, self.headers.get("Content-Type"),
                                         config.MAX_UPLOAD_BYTES)
        except ValueError as e:
            self._result("Could not read the upload: %s" % e)
            return
        if not files:
            self._result("No file was chosen.")
            return

        if not os.path.isdir(FROM_MAC):
            os.makedirs(FROM_MAC)
        saved = []
        for name, data in files:
            data, note = xfer.from_mac_bytes(name, data)
            dest = os.path.join(FROM_MAC, name)
            with open(dest, "wb") as f:
                f.write(data)
            saved.append((name, len(data), note))
            log("received %s from the Mac, %s%s"
                % (name, xfer.human(len(data)), (" (%s)" % note) if note else ""))
        rows = "".join("<li>%s &mdash; %s%s</li>"
                       % (n, xfer.human(sz), (" &mdash; " + note) if note else "")
                       for n, sz, note in saved)
        self._result("<b>Received:</b><ul>%s</ul>"
                     "<p>They are in <tt>transfer\\from-mac\\</tt> on the PC.</p>" % rows)

    def _result(self, html):
        self._send(200, "text/html",
                   "<html><head><title>Upload</title></head><body bgcolor=#FFFFFF>"
                   "<h2>Send a file to the PC</h2>%s"
                   "<p><a href=\"/upload\">Send another</a> &nbsp; "
                   "<a href=\"/menu\">Back</a></p></body></html>" % html)


class Reusable(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    for d in (RUN_DIR, TO_MAC, FROM_MAC):
        if not os.path.isdir(d):
            os.makedirs(d)

    binds = bind_addresses()
    servers = []
    for addr in binds:
        servers.append(("agent@%s" % addr, Reusable((addr, AGENT_PORT), AgentHandler)))
        servers.append(("http@%s" % addr, Reusable((addr, HTTP_PORT), DisplayHandler)))
    servers.append(("control", Reusable(("127.0.0.1", CONTROL_PORT), ControlHandler)))

    present_all()
    for name, srv in servers:
        threading.Thread(target=srv.serve_forever, name=name, daemon=True).start()

    log("listening on %s -- agent :%d, http :%d; control 127.0.0.1:%d"
        % (", ".join(binds), AGENT_PORT, HTTP_PORT, CONTROL_PORT))
    if config.SUGGESTED_PC_IP not in binds:
        log("NOTE: the cable adapter (%s) is down, probably because the Mac is off."
            % config.SUGGESTED_PC_IP)
        log("      Listening on all interfaces so it works the moment you switch on.")
        log("      Only the addresses below are accepted; everything else gets 403.")
    else:
        log("bound to the cable adapter only -- the WiFi LAN cannot reach the bridge")
    for d in REGISTRY:
        log("  device '%s'  %-15s %dx%d  %s" % (d.name, d.ip, d.canvas[0], d.canvas[1], d.label))
    log("only those addresses may connect")
    log("Tier 0 display for the Mac: http://%s:%d/  (or whatever address"
        % (config.SUGGESTED_PC_IP, HTTP_PORT))
    log("  tools/netcheck.py reports for the cable adapter)")
    log("waiting for the G3 to dial in")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        log("shutting down")


if __name__ == "__main__":
    main()
