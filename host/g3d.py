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
import news  # noqa: E402
import pages  # noqa: E402
import video  # noqa: E402
import webproxy  # noqa: E402
import itunes  # noqa: E402
import weather  # noqa: E402
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
WWW_DIR = os.path.join(HERE, "..", "www")
GAMES_DIR = os.path.join(WWW_DIR, "games")
CLAUDE_DIR = os.path.join(WWW_DIR, "claude")
VIDEO_DIR = os.path.join(WWW_DIR, "video")
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
    # Ask the OS by TRYING to bind, rather than enumerating addresses.
    # getaddrinfo(gethostname()) does NOT return the manual addresses on this
    # adapter -- it reported only the WiFi address while 192.168.11.10 was
    # configured and usable -- so enumerating silently fell through to
    # 0.0.0.0 and made the "cable adapter only" guarantee untrue.
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind((config.SUGGESTED_PC_IP, 0))
        return [config.SUGGESTED_PC_IP, "127.0.0.1"]
    except OSError:
        return ["0.0.0.0"]
    finally:
        probe.close()


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


class Switch:
    """A kill switch for the whole bridge.

    Suspended, the bridge stops doing anything outward: no pages served, no
    agent connections accepted, no news fetched, no proxying. The control port
    stays alive on loopback so it can be switched back on -- a kill switch you
    cannot undo is a trap, not a safety feature.

    The state is written to disk so it survives a restart. If the bridge was
    suspended when the machine went down, it comes back suspended.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self.reason = ""
        self.since = None
        self._path = os.path.join(RUN_DIR, "suspended")
        self._suspended = False
        try:
            if os.path.exists(self._path):
                with open(self._path) as fh:
                    self.reason = fh.read().strip() or "(no reason recorded)"
                self._suspended = True
                self.since = os.path.getmtime(self._path)
        except OSError:
            pass

    @property
    def suspended(self):
        return self._suspended

    def suspend(self, reason=""):
        with self._lock:
            self._suspended = True
            self.reason = reason or "(no reason given)"
            self.since = time.time()
            try:
                if not os.path.isdir(RUN_DIR):
                    os.makedirs(RUN_DIR)
                with open(self._path, "w") as fh:
                    fh.write(self.reason)
            except OSError:
                pass
        log("SUSPENDED: %s" % self.reason)
        # drop any attached machine so nothing is left half-connected
        for d in REGISTRY:
            if d.link and d.link.alive:
                try:
                    d.link._sock.close()
                except (OSError, AttributeError):
                    pass

    def resume(self):
        with self._lock:
            self._suspended = False
            self.reason = ""
            self.since = None
            try:
                if os.path.exists(self._path):
                    os.remove(self._path)
            except OSError:
                pass
        log("RESUMED")

    def status(self):
        if not self._suspended:
            return ["state=running"]
        out = ["state=SUSPENDED", "reason=%s" % self.reason]
        if self.since:
            out.append("since=%ds_ago" % int(time.time() - self.since))
        return out


REGISTRY = devices.Registry()
SWITCH = None       # created in main(), after RUN_DIR exists

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
        if SWITCH is not None and SWITCH.suspended:
            log("refused agent connection: bridge is suspended")
            try:
                sock.sendall(b"0 ERR 503 \"bridge suspended\"\n")
            except OSError:
                pass
            return
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
            if verb == "SUSPEND":
                SWITCH.suspend(" ".join(args))
                webproxy.shutdown()
                self._reply("OK", seq, *SWITCH.status())
                continue
            if verb == "RESUME":
                SWITCH.resume()
                self._reply("OK", seq, *SWITCH.status())
                continue
            if verb == "SWITCH":
                self._reply("OK", seq, *SWITCH.status())
                continue

            if SWITCH.suspended and verb not in ("STATUS", "DEVICES"):
                self._reply("ERR", seq,
                            "bridge is SUSPENDED (%s). Resume it first." % SWITCH.reason)
                continue

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
                self._reply("OK", seq, *(SWITCH.status() + dev.describe() + dev.link.status()))
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


SUSPENDED_PAGE = """<html><head><title>Suspended</title></head>
<body bgcolor="#0d1117" text="#e6edf3"
      style="font:15px/1.6 'Lucida Grande',Geneva,sans-serif;padding:60px">
<h1 style="color:#ff9d68;font-weight:normal">The bridge is suspended</h1>
<p style="color:#8b9bb4;max-width:36em">Everything is switched off at the PC.
No pages, no drawing, no file transfer, and no machine can connect until it is
switched back on.</p>
<p style="color:#8b9bb4"><b>Reason:</b> %s</p>
</body></html>"""


def html_escape(t):
    return (t or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


CLOCK_SCRIPT = """#!/bin/sh
# Served by the PC at %(iso)s. Sets this Mac's time zone and clock to the PC's.
#   curl -s %(pc)s:%(port)d/time?f=sh | sudo sh
systemsetup -settimezone %(tz)s >/dev/null 2>&1 || echo "could not set the time zone (run it with sudo)"
if date %(stamp)s >/dev/null 2>&1; then
  echo "clock set: `date`"
elif date -f '%%Y-%%m-%%d %%H:%%M:%%S' '%(iso)s' >/dev/null 2>&1; then
  echo "clock set: `date`"
else
  echo "could not set the clock (run it with sudo)"
fi
"""


RC_QUEUES = {}          # device name -> [command lines] for /rc


def _now_for_macs():
    """(now, zone name, note). The zone comes from config.TIMEZONE; if the PC
    has no zone database for it, the PC's own local time is used and said so."""
    import datetime
    tz = getattr(config, "TIMEZONE", "") or ""
    if tz:
        try:
            from zoneinfo import ZoneInfo
            return datetime.datetime.now(ZoneInfo(tz)), tz, ""
        except Exception:
            pass
    now = datetime.datetime.now().astimezone()
    note = ("the PC's own local time; it has no zone data for %s" % tz) if tz else ""
    return now, tz or (now.tzname() or "local"), note


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


HARDEN_SCRIPT = """#!/bin/sh
# G3Bridge hardening for a Mac OS X machine on the isolated cable.
# Run with sudo:   curl -s %(pc)s:%(port)d/h | sudo sh
#
# Everything here is reversible in System Preferences > Network.
# It does NOT touch your files, accounts, or anything outside networking.

SVC="Ethernet"
IP="%(ip)s"
MASK="255.255.255.0"

echo "G3Bridge hardening"
echo

# 1. Correct the subnet mask. A /16 makes the Mac treat the whole of
#    192.168.x.x as directly reachable, including the house LAN range.
echo "1. subnet mask -> $MASK"
networksetup -setmanual "$SVC" "$IP" "$MASK" "" 2>/dev/null && echo "   done" || echo "   FAILED (need sudo?)"

# 2. IPv6 off. Left on Automatic it will accept a Router Advertisement and
#    install a default route, which would defeat the whole arrangement.
echo "2. IPv6 -> off"
networksetup -setv6off "$SVC" 2>/dev/null && echo "   done" || echo "   FAILED"

# 3. Disable the interfaces that could reach another network.
for s in "Internal Modem" "FireWire"; do
  echo "3. disabling network service: $s"
  networksetup -setnetworkserviceenabled "$s" off 2>/dev/null && echo "   done" || echo "   not present / failed"
done

# 4. Stop it looking for updates or time servers it can never reach.
echo "4. software update + network time off"
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false 2>/dev/null && echo "   software update: off"
systemsetup -setusingnetworktime off >/dev/null 2>&1 && echo "   network time: off" || echo "   network time: unchanged"

echo
echo "--- result ---"
networksetup -getinfo "$SVC" 2>/dev/null | grep -E "IP address|Subnet|Router|IPv6:"
echo
echo "default route (should be link-scoped, no gateway address):"
netstat -rn -f inet | grep -w default || echo "  none"
echo
echo "reachability test (both should fail):"
ping -c 1 -t 3 8.8.8.8 >/dev/null 2>&1 && echo "  !! REACHED 8.8.8.8 -- NOT ISOLATED" || echo "  ok: cannot reach 8.8.8.8"
ping -c 1 -t 3 apple.com >/dev/null 2>&1 && echo "  !! RESOLVED apple.com -- NOT ISOLATED" || echo "  ok: cannot resolve apple.com"
echo
echo "Done."
"""


SETUP_SCRIPT = """#!/bin/sh
# G3Bridge enrolment. Run on the Mac; safe to run twice.
#
# 1. installs the bridge's public key so the PC can log in without a password
# 2. reports this machine's user, OS version and model back to the PC
#
# To undo everything this does:  rm ~/.ssh/authorized_keys

set -e
BRIDGE="http://%(pc)s:%(port)d"

echo "G3Bridge enrolment"
echo "  bridge: $BRIDGE"
echo "  user  : `whoami`"
echo

mkdir -p ~/.ssh
chmod 700 ~/.ssh

KEY=`curl -fsS "$BRIDGE/boot/id_g3bridge.pub"`
if [ -z "$KEY" ]; then
  echo "Could not fetch the key. Is the cable in and the bridge running?"
  exit 1
fi

if grep -q "g3bridge@pc" ~/.ssh/authorized_keys 2>/dev/null; then
  echo "Key is already installed - leaving it alone."
else
  echo "$KEY" >> ~/.ssh/authorized_keys
  echo "Key installed."
fi
chmod 600 ~/.ssh/authorized_keys

OSV=`sw_vers -productVersion 2>/dev/null || echo unknown`
MODEL=`sysctl -n hw.model 2>/dev/null || echo unknown`
CPU=`sysctl -n hw.cpufrequency 2>/dev/null || echo 0`
curl -fsS "$BRIDGE/enrol?user=`whoami`&os=$OSV&model=$MODEL&cpu=$CPU&host=`hostname`" || true
echo
echo "Done. Tell Claude it is enrolled."
"""


SETUP_PAGE = """<html><head><title>G3Bridge setup</title>
<style type="text/css">
 body { background:#101420; color:#e8ecf4; font:14px/1.55 "Lucida Grande",Geneva,sans-serif;
        margin:0; padding:26px 34px 60px; }
 h1   { font-size:26px; margin:0 0 2px; color:#57d2ff; font-weight:normal; }
 .sub { color:#8b98ad; font-size:12px; margin:0 0 26px; }
 .step{ border-left:3px solid #2b3550; padding:2px 0 2px 18px; margin:0 0 30px; }
 .step.on   { border-left-color:#ffc23d; }
 .step.done { border-left-color:#3ea55f; }
 h2   { font-size:15px; margin:0 0 6px; color:#ffc23d; font-weight:normal;
        text-transform:uppercase; letter-spacing:.08em; }
 .step.done h2 { color:#3ea55f; }
 p    { max-width:58em; color:#b9c4d6; margin:6px 0; }
 .cmd { background:#000; color:#7dff9b; border:2px solid #ffc23d; padding:13px 15px;
        font:bold 16px Monaco,"Courier New",monospace; margin:12px 0 6px; max-width:58em; }
 .step.done .cmd { border-color:#2b3550; color:#5f7a68; font-weight:normal; }
 pre  { background:#0a0d15; border:1px solid #2b3550; color:#93a4c0; padding:11px 13px;
        font:11px/1.45 Monaco,"Courier New",monospace; overflow:auto; max-width:58em; }
 .note{ color:#8b98ad; font-size:12px; }
 .tick{ color:#3ea55f; font-weight:bold; }
 b.warn { color:#ff9d68; }
 hr   { border:0; border-top:1px solid #2b3550; margin:26px 0; }
 tt   { color:#d8e2f0; }
</style></head><body>
<h1>G3Bridge &mdash; %(dev)s</h1>
<p class="sub">You are reading this on the Mac. The PC is at %(pc)s.
Terminal is in Applications &rsaquo; Utilities.</p>

<div class="step %(c1)s">
<h2>Step 1 &mdash; connect it %(t1)s</h2>
<p>%(s1)s</p>
<div class="cmd">curl -s %(pc)s:%(port)d/s | sh</div>
<p class="note">Adds the PC's key to <tt>~/.ssh/authorized_keys</tt> so it can log in
without a password, and reports this machine's details back. Undo with
<tt>rm ~/.ssh/authorized_keys</tt>. Safe to run twice.</p>
</div>

<div class="step %(c2)s">
<h2>Step 2 &mdash; lock it down</h2>
<p>Fixes the subnet mask, turns IPv6 off, disables the modem and FireWire
network services, and stops software update and network time. Then it
<b>tests</b> whether the machine can still reach the internet and tells you.</p>
<div class="cmd">curl -s %(pc)s:%(port)d/h | sudo sh</div>
<p class="note"><b class="warn">sudo</b> will ask for your account password.
That is you typing it &mdash; the PC never sees it. All of it is reversible in
System Preferences &rsaquo; Network.</p>
</div>

<div class="step">
<h2>Clock</h2>
<p>With no internet this Mac cannot set its own clock, but the PC can set it.
This sets the time zone and the time, to the second:</p>
<div class="cmd">curl -s %(pc)s:%(port)d/time?f=sh | sudo sh</div>
<p class="note">Needs <b class="warn">sudo</b>, like Step 2. Or open
<a href="/time">/time</a> for a big clock to copy into Date &amp; Time by hand
&mdash; the Mac OS 9 machine has to do it that way.</p>
</div>

<hr>
<h2>Step 2, in full</h2>
<p class="note">Exactly what <tt>/h</tt> serves. Read it first if you like.</p>
<pre>%(harden)s</pre>

<h2>Step 1, in full</h2>
<pre>%(script)s</pre>

<hr>
<p class="note">This Mac has no gateway and no DNS, so it can reach the PC and
nothing else. Step 2 makes that harder to undo by accident.</p>
</body></html>"""


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
            # UTF-8, not ascii-replace: news headlines are full of curly quotes,
            # dashes and accents that would otherwise arrive as "?".
            body = body.encode("utf-8", "replace")
            if ctype.startswith("text/") and "charset" not in ctype:
                ctype += "; charset=utf-8"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if extra and "Cache-Control" in extra:
            pass                          # the caller chose its own caching
        elif cacheable:
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

    # -- the web translation layer -------------------------------------
    def _redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _serve_web(self, dev, u, view):
        import time as _t
        t0 = _t.time()
        if view == "pic":
            try:
                meta = webproxy.picture(u)
                log("%s: pictured %s (%d strips, %.1fs)"
                    % (dev.name, meta["url"][:70], len(meta["strips"]), _t.time() - t0))
                self._send(200, "text/html", pages.web_picture(meta, True))
            except Exception as e:
                log("%s: picture failed for %s: %s" % (dev.name, u[:60], e))
                self._send(200, "text/html",
                           pages.web_error("Could not picture that page.", str(e)))
            return
        try:
            page = webproxy.fetch(u, view)
        except Exception as e:
            log("%s: proxy failed for %s: %s" % (dev.name, u[:60], e))
            self._send(200, "text/html", pages.web_error("Could not fetch that page.", str(e)))
            return
        self._serve_page(dev, page)

    def _serve_page(self, dev, page):
        from urllib.parse import quote
        if page.kind == "video":
            log("%s: %s is a video, handing it to /video" % (dev.name, page.url[:60]))
            self._redirect("/video?u=" + quote(page.url, safe=""))
            return
        if page.kind in ("file", "image"):
            log("%s: %s is a %s (%s)" % (dev.name, page.url[:60], page.kind, page.ctype))
            self._send(200, "text/html", pages.web_file(page))
            return
        webproxy.remember(page)
        log("%s: %s %s (%d chars, %d links, %d forms, %s view, %.1fs)"
            % (dev.name, page.engine, page.url[:70], len(page.body), page.links,
               page.forms, page.view, page.elapsed))
        self._send(200, "text/html", pages.web_page(page, webproxy.RENDERER.available()))

    def _serve_form(self, dev, fields):
        u = (fields.pop("_u", None) or [""])[0]
        m = (fields.pop("_m", None) or ["get"])[0]
        v = (fields.pop("_v", None) or [""])[0]
        if not u:
            self._send(200, "text/html", pages.web_error("That form had no address.", "missing _u"))
            return
        try:
            page = webproxy.submit(u, m, fields, v if v in webproxy.VIEWS else "")
            log("%s: form %s %s (%d fields)" % (dev.name, m.upper(), u[:60], len(fields)))
        except Exception as e:
            log("%s: form to %s failed: %s" % (dev.name, u[:60], e))
            self._send(200, "text/html", pages.web_error("The site did not accept that.", str(e)))
            return
        self._serve_page(dev, page)

    def _stream_download(self, dev, d):
        try:
            resp, name, size, ctype = webproxy.download(d)
        except Exception as e:
            log("%s: download failed for %s: %s" % (dev.name, d[:60], e))
            self._send(200, "text/html", pages.web_error("Could not download that.", str(e)))
            return
        ascii_name = name.encode("ascii", "replace").decode("ascii").replace('"', "")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % ascii_name)
        if size >= 0:
            self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        sent = 0
        try:
            for chunk in resp.iter_content(64 * 1024):
                sent += len(chunk)
                if sent > webproxy.MAX_DOWNLOAD:
                    break
                self.wfile.write(chunk)
        except OSError:
            pass
        finally:
            resp.close()
        log("%s: downloaded %s -> %s (%d bytes)" % (dev.name, d[:60], name, sent))

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        if SWITCH is not None and SWITCH.suspended:
            self._send(503, "text/html", SUSPENDED_PAGE % html_escape(SWITCH.reason))
            return
        dev = self._device()
        if dev is None:
            self._send(403, "text/plain",
                       "This bridge only serves the machines it knows about.")
            return

        if path in ("/", "/index.html"):
            self._send(200, "text/html",
                       pages.index_page(dev, pages.scan_games(GAMES_DIR),
                                        any(x[2] for x in news.sections())))
            return

        if path in ("/claude-screen", "/claude-screen/"):
            items = pages.scan_artefacts(CLAUDE_DIR)
            if not items:
                self._send(200, "text/html", pages.artefact_placeholder())
                return
            # Serve the newest artefact directly, whole page, no wrapper, so it
            # can be anything at all -- including something interactive.
            with open(os.path.join(CLAUDE_DIR, items[0][0]), "rb") as f:
                self._send(200, "text/html", f.read())
            return

        if path == "/claude-screen/index":
            self._send(200, "text/html", pages.artefact_index(pages.scan_artefacts(CLAUDE_DIR)))
            return

        if path.startswith("/claude-screen/"):
            name = os.path.basename(path[len("/claude-screen/"):])
            fn = os.path.join(CLAUDE_DIR, name)
            if not name.endswith(".html") or not os.path.isfile(fn):
                self._send(404, "text/plain", "no such artefact: %s" % name)
                return
            with open(fn, "rb") as f:
                self._send(200, "text/html", f.read())
            return

        if path == "/video":
            from urllib.parse import unquote
            u = unquote(_q(query, "u") or "")
            prof = (_q(query, "p") or video.DEFAULT_PROFILE)
            if u:
                try:
                    j = video.submit(u, prof, VIDEO_DIR)
                    log("%s: video queued %r as %s" % (dev.name, u[:60], prof))
                except ValueError as e:
                    log("%s: video rejected: %s" % (dev.name, e))
            self._send(200, "text/html",
                       pages.video_page(video.PROFILES, video.DEFAULT_PROFILE,
                                        video.jobs(), video.library(VIDEO_DIR),
                                        news.ago, video.available()))
            return

        if path.startswith("/video/"):
            name = os.path.basename(path[len("/video/"):])
            fn = os.path.join(VIDEO_DIR, name)
            if not name.endswith(".mp4") or not os.path.isfile(fn):
                self._send(404, "text/plain", "no such video: %s" % name)
                return
            # Streamed rather than read into memory: these are tens of megabytes
            # and the daemon should not hold one per request.
            size = os.path.getsize(fn)
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", 'inline; filename="%s"' % name)
            self.end_headers()
            with open(fn, "rb") as f:
                while True:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except OSError:
                        break
            return

        if path == "/web":
            from urllib.parse import unquote
            view = (_q(query, "view") or "").strip()
            if view not in webproxy.VIEWS:
                view = ""
            q = _pct(_q(query, "q") or "")
            u = unquote(_q(query, "u") or "")
            i = unquote(_q(query, "i") or "")
            d = unquote(_q(query, "d") or "")
            p = _q(query, "p") or ""

            if i:
                try:
                    ctype, blob = webproxy.image(i)
                    self._send(200, ctype, blob, cacheable=True)
                except Exception as e:
                    log("%s: image failed %s: %s" % (dev.name, i[:60], e))
                    self._send(200, "image/gif", webproxy.BLANK_GIF)
                return

            if p:
                try:
                    blob = webproxy.strip(p, _q(query, "n") or "0")
                    self._send(200, "image/jpeg", blob, cacheable=True)
                except Exception:
                    self._send(404, "text/plain", "no such picture strip")
                return

            if d:
                self._stream_download(dev, d)
                return

            if u:
                self._serve_web(dev, u, view)
                return

            if q:
                try:
                    results = webproxy.search(q)
                    log("%s: searched %r -> %d results" % (dev.name, q[:50], len(results)))
                    self._send(200, "text/html", pages.web_results(q, results))
                except Exception as e:
                    self._send(200, "text/html", pages.web_results(q, [], str(e)))
                return

            self._send(200, "text/html",
                       pages.web_home(webproxy.recent(), webproxy.RENDERER.available()))
            return

        if path == "/web/f":
            # A form on a proxied page, submitted with GET. POST lands in do_POST.
            from urllib.parse import parse_qs
            self._serve_form(dev, parse_qs(query, keep_blank_values=True))
            return

        if path == "/weather":
            try:
                screen = int(_q(query, "s") or 1)
            except ValueError:
                screen = 1
            screen = screen if 1 <= screen <= 5 else 1
            hold = bool(_q(query, "hold"))
            d, err = weather.data()
            hourly = weather.hourly_from_now(d) if d else []
            days = weather.daily(d) if d else []
            self._send(200, "text/html",
                       pages.weather_page(screen, d, err, hold, hourly, days,
                                          weather.describe, weather.compass, weather.NAME))
            return

        if path == "/weather/bg.png":
            self._send(200, "image/png", weather.background(), cacheable=True)
            return

        if path.startswith("/weather/icon/"):
            key = os.path.basename(path)[:-4] if path.endswith(".png") else ""
            try:
                size = max(32, min(320, int(_q(query, "z") or 112)))
            except ValueError:
                size = 112
            if key not in ("sun", "moon", "partly", "partlynight", "cloud", "fog", "rain",
                           "drizzle", "shower", "sleet", "snow", "storm"):
                self._send(404, "text/plain", "no such icon")
                return
            self._send(200, "image/png", weather.icon(key, size), cacheable=True)
            return

        if path == "/weather/radar.jpg":
            img, err = weather.radar()
            if img:
                self._send(200, "image/jpeg", img)
            else:
                self._send(503, "text/plain", "radar: %s" % err)
            return

        if path == "/itunes":
            from urllib.parse import unquote_plus
            do = (_q(query, "do") or "").strip()
            a = unquote_plus(_q(query, "a") or "")
            b = unquote_plus(_q(query, "b") or "")
            msg, err, cands, info, lib = "", "", None, None, None
            try:
                pick = int(_q(query, "pick") or 0)
                n = int(_q(query, "n") or 0)
            except ValueError:
                pick = n = 0
            if not itunes.reachable():
                self._send(200, "text/html", pages.itunes_page(None, None, "", None, a, b,
                           "The eMac is not answering over SSH, so the PC cannot reach iTunes."))
                return
            try:
                if do == "apply":
                    info = itunes.identify()
                    if not info or not info["releases"]:
                        err = "No identified CD to apply."
                    else:
                        rel = info["releases"][min(pick, len(info["releases"]) - 1)]
                        jpeg, src = itunes.cover(rel)
                        pmap = itunes.unnamed(itunes.library())
                        msg = "%s - %s: %s%s" % (rel["artist"], rel["title"], itunes.apply(rel, pmap, jpeg),
                                                 "" if jpeg else " (no cover found anywhere)")
                        log("%s: itunes apply %s" % (dev.name, msg))
                elif do == "covers":
                    cands = itunes.itunes_covers(a, b)
                elif do == "cover":
                    cands = itunes.itunes_covers(a, b)
                    if 0 <= n < len(cands):
                        raw = itunes._get_image(cands[n][2])
                        lib0 = itunes.library()
                        pids = [t["pid"] for t in lib0["tracks"]
                                if t["album"] == b and (t["album_artist"] or t["artist"]) == a]
                        msg = "%s - %s: %s" % (a, b, itunes.apply_cover(a, b, pids, itunes._jpeg(raw)))
                        log("%s: itunes cover %s" % (dev.name, msg))
                        cands = None
                if info is None:
                    info = itunes.identify()
                lib = itunes.library()
            except Exception as e:
                err = "%s: %s" % (type(e).__name__, str(e)[:300])
                log("%s: itunes error %s" % (dev.name, err))
            self._send(200, "text/html", pages.itunes_page(info, lib, msg, cands, a, b, err))
            return

        if path == "/time":
            f = (_q(query, "f") or "").strip()
            now, tz, note = _now_for_macs()
            if f == "date":
                self._send(200, "text/plain", now.strftime("%m%d%H%M%Y.%S"))
            elif f == "iso":
                self._send(200, "text/plain", now.strftime("%Y-%m-%d %H:%M:%S"))
            elif f == "unix":
                self._send(200, "text/plain", str(int(now.timestamp())))
            elif f == "sh":
                log("%s: fetched the clock script" % dev.name)
                self._send(200, "text/plain", CLOCK_SCRIPT % {
                    "pc": config.SUGGESTED_PC_IP, "port": HTTP_PORT, "tz": tz,
                    "stamp": now.strftime("%m%d%H%M%Y.%S"),
                    "iso": now.strftime("%Y-%m-%d %H:%M:%S")})
            else:
                self._send(200, "text/html",
                           pages.time_page(now, tz, note, config.SUGGESTED_PC_IP, HTTP_PORT))
            return

        if path == "/news":
            self._send(200, "text/html", pages.news_page(news.sections(), news.ago))
            return

        if path == "/games":
            self._send(200, "text/html", pages.games_page(pages.scan_games(GAMES_DIR)))
            return

        if path.startswith("/games/"):
            rel = os.path.normpath(path[len("/games/"):]).replace("\\", "/")
            if rel.startswith("..") or rel.startswith("/") or ":" in rel:
                self._send(404, "text/plain", "no")
                return
            fn = os.path.join(GAMES_DIR, rel)
            if not os.path.isfile(fn):
                self._send(404, "text/plain", "no such game file: %s" % rel)
                return
            import mimetypes
            ctype = mimetypes.guess_type(fn)[0] or "application/octet-stream"
            if fn.endswith(".js"):
                ctype = "application/x-javascript"
            elif fn.endswith(".mp3"):
                ctype = "audio/mpeg"
            with open(fn, "rb") as f:
                data = f.read()
            if fn.endswith(".html") or fn.endswith(".swf"):
                # pages and the SWF itself: never cached, so a rebuild is what
                # the Mac gets on the next load
                self._send(200, ctype, data)
            else:
                # assets: short cache so a game can be iterated on without the
                # Mac holding a stale copy for a year
                self._send(200, ctype, data, extra={"Cache-Control": "max-age=120"})
            return

        if path == "/rc":
            # Remote control for a game under test: the SWF polls this and gets
            # whatever the PC queued (one command per line), then the queue clears.
            q = RC_QUEUES.get(dev.name) or []
            RC_QUEUES[dev.name] = []
            self._send(200, "text/plain", "\n".join(q))
            return

        if path == "/telemetry":
            # A game or probe page on the Mac reports back with an <img> ping.
            from urllib.parse import unquote_plus
            msg = unquote_plus(query)[:4000]
            log("%s: telemetry %s" % (dev.name, msg[:300]))
            try:
                with open(os.path.join(RUN_DIR, "telemetry.log"), "a", encoding="utf-8") as f:
                    f.write("%s %s %s\n" % (time.strftime("%H:%M:%S"), dev.name, msg))
            except OSError:
                pass
            self._send(200, "image/gif", webproxy.BLANK_GIF)
            return

        if path in ("/display", "/display.html"):
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
            self.send_header("Location", "/display")
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
                "<li><a href=\"/setup\">Set this Mac up</a> &mdash; connect it to the PC</li>"
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

        if path in ("/h", "/harden.sh"):
            body = HARDEN_SCRIPT % {"pc": config.SUGGESTED_PC_IP, "port": HTTP_PORT,
                                    "ip": dev.ip}
            log("%s: fetched the hardening script" % dev.name)
            self._send(200, "text/plain", body)
            return

        if path in ("/s", "/setup.sh"):
            body = SETUP_SCRIPT % {"pc": config.SUGGESTED_PC_IP, "port": HTTP_PORT}
            log("%s: fetched the setup script" % dev.name)
            self._send(200, "text/plain", body)
            return

        if path == "/setup":
            def esc(t):
                return t.replace("&", "&amp;").replace("<", "&lt;")
            fmt = {"pc": config.SUGGESTED_PC_IP, "port": HTTP_PORT, "ip": dev.ip}
            enrolled = bool(dev.enrolled)
            body = SETUP_PAGE % {
                "pc": config.SUGGESTED_PC_IP, "port": HTTP_PORT, "dev": dev.name,
                "c1": "done" if enrolled else "on",
                "t1": "<span class=\"tick\">&#10003; done</span>" if enrolled else "",
                "s1": ("Already done &mdash; this machine enrolled as <tt>%s</tt>, "
                       "%s. Re-run it only if you reinstall."
                       % (dev.enrolled.get("user", "?"), dev.enrolled.get("os", "?")))
                      if enrolled else
                      "Installs the PC's key so it can log in, and tells the PC "
                      "what this machine is.",
                "c2": "on" if enrolled else "",
                "script": esc(SETUP_SCRIPT % fmt),
                "harden": esc(HARDEN_SCRIPT % fmt),
            }
            self._send(200, "text/html", body)
            return

        if path == "/enrol":
            # A machine introducing itself. Whatever key=value pairs it sends
            # get recorded, so one pasted command on the Mac can report its
            # user, OS version and model without anyone typing them back.
            info = {}
            for pair in query.split("&"):
                if "=" in pair:
                    k, v = pair.split("=", 1)
                    info[k] = _pct(v).strip()
            if info:
                dev.enrolled = info
                log("%s ENROLLED: %s" % (dev.name,
                    "  ".join("%s=%s" % kv for kv in sorted(info.items()))))
                try:
                    with open(os.path.join(RUN_DIR, "enrol_%s.txt" % dev.name), "w") as fh:
                        for k in sorted(info):
                            fh.write("%s=%s\n" % (k, info[k]))
                except OSError:
                    pass
            self._send(200, "text/plain", "enrolled: %s\n" % dev.name)
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
        if self.path.split("?", 1)[0] == "/web/f":
            if SWITCH is not None and SWITCH.suspended:
                self._send(503, "text/html", SUSPENDED_PAGE % html_escape(SWITCH.reason))
                return
            from urllib.parse import parse_qs
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            raw = self.rfile.read(length) if length > 0 else b""
            self._serve_form(dev, parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True))
            return
        if self.path.split("?", 1)[0] == "/rc":
            # The PC (loopback) queues commands for a device: body = lines, ?dev=name
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            body = (self.rfile.read(length) if length > 0 else b"").decode("utf-8", "replace")
            target = _q(self.path.split("?", 1)[1] if "?" in self.path else "", "dev") or "emac"
            RC_QUEUES.setdefault(target, []).extend([l for l in body.splitlines() if l.strip()])
            self._send(200, "text/plain", "queued %d for %s" % (len(body.splitlines()), target))
            return
        if self.path.split("?", 1)[0] == "/snap":
            import base64
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            raw = self.rfile.read(length) if length > 0 else b""
            if raw[:4] == b"\x89PNG":
                # Flash posts the PNG bytes as-is
                n = int(time.time())
                fn = os.path.join(RUN_DIR, "snap_%s_%d.png" % (dev.name, n))
                with open(fn, "wb") as f:
                    f.write(raw)
                log("%s: snapshot %d bytes -> %s" % (dev.name, len(raw), os.path.basename(fn)))
                self._send(200, "text/plain", "ok")
                return
            body = raw.decode("ascii", "replace")
            if body.startswith("data="):
                body = body[5:]
            from urllib.parse import unquote_plus
            body = unquote_plus(body)
            if "," in body[:40]:
                body = body.split(",", 1)[1]
            try:
                png = base64.b64decode(body)
            except Exception:
                png = b""
            n = int(time.time())
            fn = os.path.join(RUN_DIR, "snap_%s_%d.png" % (dev.name, n))
            if png[:4] == b"\x89PNG":
                with open(fn, "wb") as f:
                    f.write(png)
                log("%s: snapshot %d bytes -> %s" % (dev.name, len(png), os.path.basename(fn)))
            else:
                log("%s: snapshot was not a PNG (%d bytes)" % (dev.name, len(raw)))
            self._send(200, "text/plain", "ok")
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
    for d in (RUN_DIR, TO_MAC, FROM_MAC, GAMES_DIR, CLAUDE_DIR, VIDEO_DIR):
        if not os.path.isdir(d):
            os.makedirs(d)

    binds = bind_addresses()
    servers = []
    for addr in binds:
        servers.append(("agent@%s" % addr, Reusable((addr, AGENT_PORT), AgentHandler)))
        servers.append(("http@%s" % addr, Reusable((addr, HTTP_PORT), DisplayHandler)))
    servers.append(("control", Reusable(("127.0.0.1", CONTROL_PORT), ControlHandler)))

    global SWITCH
    SWITCH = Switch()
    news.start_background(lambda: SWITCH is not None and SWITCH.suspended)
    present_all()
    for name, srv in servers:
        threading.Thread(target=srv.serve_forever, name=name, daemon=True).start()

    if SWITCH.suspended:
        log("!! STARTING SUSPENDED: %s" % SWITCH.reason)
        log("   nothing will be served until it is resumed")
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
