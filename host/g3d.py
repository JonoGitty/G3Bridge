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
import socketserver
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol  # noqa: E402

AGENT_PORT = 9990
CONTROL_PORT = 9991
REPLY_TIMEOUT = 15.0


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
        with self._state:
            state = "connected" if self._sock is not None else "waiting"
            out = ["state=%s" % state]
            for k in ("agent", "width", "height", "depth", "peer"):
                if k in self.info:
                    out.append("%s=%s" % (k, self.info[k]))
            if self.connected_at:
                out.append("uptime=%ds" % int(time.time() - self.connected_at))
        return out


LINK = Link()


class AgentHandler(socketserver.BaseRequestHandler):
    """The one and only reader of the agent socket."""

    def handle(self):
        sock = self.request
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

            try:
                rverb, rargs = LINK.send(verb, *args)
                self._reply(rverb, seq, *rargs)
            except IOError as e:
                self._reply("ERR", seq, str(e))

    def _reply(self, verb, seq, *args):
        self.wfile.write((protocol.encode(seq, verb, *args) + "\n").encode("ascii", "replace"))


class Reusable(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    agent_srv = Reusable(("0.0.0.0", AGENT_PORT), AgentHandler)
    control_srv = Reusable(("127.0.0.1", CONTROL_PORT), ControlHandler)
    for name, srv in (("agent", agent_srv), ("control", control_srv)):
        threading.Thread(target=srv.serve_forever, name=name, daemon=True).start()

    log("listening: agent 0.0.0.0:%d  control 127.0.0.1:%d" % (AGENT_PORT, CONTROL_PORT))
    log("waiting for the G3 to dial in")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        log("shutting down")


if __name__ == "__main__":
    main()
