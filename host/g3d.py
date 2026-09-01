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
import http.server
import socketserver
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402
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
FRAME_GIF = os.path.join(RUN_DIR, "frame.gif")
FRAME_PNG = os.path.join(RUN_DIR, "frame.png")
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

    The G3 must only ever be able to reach this PC, and the rest of the house
    LAN must not be able to reach the bridge. So we bind the CABLE adapter
    specifically rather than 0.0.0.0, plus loopback so the test harness and the
    MCP server still work.
    """
    if not config.BIND_TO_CABLE_ONLY:
        return ["0.0.0.0"]
    addrs = local_ipv4()
    if config.SUGGESTED_PC_IP in addrs:
        return [config.SUGGESTED_PC_IP, "127.0.0.1"]
    return ["127.0.0.1"]


def peer_allowed(addr):
    """True if this address may drive the display."""
    ip = addr[0]
    if ip == "127.0.0.1":
        return True                       # the simulator and local tests
    if config.ALLOWED_G3_IP is None:
        return True
    return ip == config.ALLOWED_G3_IP


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


LINK = Link()
MIRROR = raster.Screen(config.CANVAS_W, config.CANVAS_H)
FRAME_SEQ = [0]
MIRROR_LOCK = threading.Lock()


def present():
    """Write the mirror out for the HTTP display to serve."""
    if not os.path.isdir(RUN_DIR):
        os.makedirs(RUN_DIR)
    with MIRROR_LOCK:
        FRAME_SEQ[0] += 1
        MIRROR.save(FRAME_PNG)
        if raster.HAVE_PIL:
            MIRROR.save(FRAME_GIF)   # GIF: guaranteed to render in a 1999 browser


class AgentHandler(socketserver.BaseRequestHandler):
    """The one and only reader of the agent socket."""

    def handle(self):
        sock = self.request
        if not peer_allowed(self.client_address):
            log("REFUSED agent connection from %s:%d (expected %s)"
                % (self.client_address[0], self.client_address[1], config.ALLOWED_G3_IP))
            try:
                sock.sendall(b"0 ERR 403 \"not the expected machine\"\n")
            except OSError:
                pass
            return
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        LINK.attach(sock, self.client_address)
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
                        LINK.dispatch(text)
        finally:
            LINK.detach(sock)


class ControlHandler(socketserver.StreamRequestHandler):
    """Local-only. The MCP server speaks the same line protocol to us."""

    def handle(self):
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

            if verb == "STATUS":
                self._reply("OK", seq, *LINK.status())
                continue
            if verb == "EVENTS":
                self._reply("OK", seq, *["|".join(e) for e in LINK.drain_events()])
                continue

            # Draw into the host-side mirror regardless of whether the Mac
            # is attached, so Tier 0 (browser as the display) works with
            # nothing installed on the Mac.
            mirrored = False
            if verb in DRAW_VERBS:
                try:
                    with MIRROR_LOCK:
                        MIRROR.apply(verb, args)
                    mirrored = True
                except Exception as e:
                    self._reply("ERR", seq, "mirror rejected %s: %s" % (verb, e))
                    continue
            elif verb == "FLUSH":
                present()
                mirrored = True

            if not LINK.alive:
                if mirrored:
                    self._reply("OK", seq, "mirror-only", "no-agent-attached")
                else:
                    self._reply("ERR", seq, "no G3 agent connected")
                continue

            try:
                rverb, rargs = LINK.send(verb, *args)
                self._reply(rverb, seq, *rargs)
            except IOError as e:
                self._reply("ERR", seq, str(e))

    def _reply(self, verb, seq, *args):
        self.wfile.write((protocol.encode(seq, verb, *args) + "\n").encode("ascii", "replace"))


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
        log("http %s" % (fmt % a))

    def _send(self, code, ctype, body, extra=None):
        if isinstance(body, str):
            body = body.encode("ascii", "replace")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # Netscape 4 and IE 4.5/5 cache aggressively and inconsistently. Send
        # all three headers AND vary the URL (see the frame counter) -- either
        # alone is not enough in practice.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        query = self.path.split("?", 1)[1] if "?" in self.path else ""

        if path in ("/", "/index.html"):
            ext = "gif" if raster.HAVE_PIL and os.path.exists(FRAME_GIF) else "png"
            self._send(200, "text/html", DISPLAY_PAGE % {
                "refresh": "2", "ext": ext, "seq": FRAME_SEQ[0],
                "w": MIRROR.w, "h": MIRROR.h})
            return

        # /f/000123.gif -- the counter only exists to defeat the cache; any
        # value serves the current frame.
        if path.startswith("/f/") or path in ("/frame.gif", "/frame.png"):
            fn = FRAME_GIF if path.endswith("gif") else FRAME_PNG
            if not os.path.exists(fn):
                present()
            try:
                with open(fn, "rb") as f:
                    body = f.read()
            except OSError:
                self._send(404, "text/plain", "no frame yet")
                return
            self._send(200, "image/gif" if fn.endswith("gif") else "image/png", body)
            return

        if path == "/click":
            # ismap sends "?x,y"; turn it into an event for the host
            xy = query.replace(",", " ").split()
            if len(xy) == 2 and all(v.isdigit() for v in xy):
                LINK.events.append(["CLICK", xy[0], xy[1]])
                log("browser click at %s,%s" % (xy[0], xy[1]))
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
            if name.endswith((".txt", ".scpt")):
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

    def do_POST(self):
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

    present()
    for name, srv in servers:
        threading.Thread(target=srv.serve_forever, name=name, daemon=True).start()

    log("listening on %s -- agent :%d, http :%d; control 127.0.0.1:%d"
        % (", ".join(binds), AGENT_PORT, HTTP_PORT, CONTROL_PORT))
    if config.SUGGESTED_PC_IP not in binds:
        log("NOTE: the cable adapter (%s) is not up yet, so nothing is exposed"
            % config.SUGGESTED_PC_IP)
        log("      beyond loopback. Set the static IP and restart to reach the Mac.")
    else:
        log("bound to the cable adapter only -- the WiFi LAN cannot reach the bridge")
    if config.ALLOWED_G3_IP:
        log("only %s may drive the display" % config.ALLOWED_G3_IP)
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
