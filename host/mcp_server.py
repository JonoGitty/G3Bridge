"""G3Bridge MCP server -- exposes the iMac G3 to Claude Code as a set of tools.

Transport is MCP stdio: one JSON object per line on stdin/stdout. Nothing but
the standard library is used, so it runs on the stock Windows Python.

This process is short-lived (Claude Code spawns and kills it). It holds no
connection to the Mac; it forwards to the long-lived g3d daemon over loopback.

    C:\\Python310\\python.exe host\\mcp_server.py

Env:
    G3D_HOST  default 127.0.0.1
    G3D_PORT  default 9991
"""

import json
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol  # noqa: E402

# On Windows, text-mode stdout translates \n to \r\n, which corrupts the
# newline-delimited JSON framing. Pin it.
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(newline="\n")
    except AttributeError:
        pass

G3D_HOST = os.environ.get("G3D_HOST", "127.0.0.1")
G3D_PORT = int(os.environ.get("G3D_PORT", "9991"))
SERVER_VERSION = "0.1.0"
SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")

GRAMMAR = """Each command is one line. Coordinates are pixels, origin top-left.
Colours are 0-255 per channel.

  CLEAR [r g b]            erase the screen (default black)
  PEN r g b                set the drawing colour
  PENSIZE n                stroke width in pixels
  MOVETO x y               move the pen without drawing
  LINETO x y               draw from the pen to x,y, leaving the pen there
  LINE x1 y1 x2 y2         standalone segment
  RECT x1 y1 x2 y2 [FILL]  rectangle
  OVAL x1 y1 x2 y2 [FILL]  ellipse inscribed in that rectangle
  PIXEL x y                single pixel
  TEXT x y "string" [size] text, x,y is the LEFT BASELINE
  FONT name                typeface, e.g. Geneva, Chicago, Monaco
  FLUSH                    present the buffer (added automatically)"""


def log(msg):
    sys.stderr.write("[mcp] %s\n" % msg)
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# talking to g3d
# ---------------------------------------------------------------------------
class DaemonError(Exception):
    pass


def daemon_exec(lines):
    """Run command lines through g3d. Returns a list of (line, verb, args)."""
    try:
        s = socket.create_connection((G3D_HOST, G3D_PORT), timeout=20)
    except OSError as e:
        raise DaemonError(
            "cannot reach the g3d daemon at %s:%d (%s). Start it with:\n"
            "    C:\\Python310\\python.exe C:\\AI\\G3Bridge\\host\\g3d.py"
            % (G3D_HOST, G3D_PORT, e))
    out = []
    try:
        f = s.makefile("rwb", buffering=0)
        for i, line in enumerate(lines, 1):
            f.write(("%d %s\n" % (i, line)).encode("ascii", "replace"))
            raw = f.readline()
            if not raw:
                raise DaemonError("g3d closed the connection mid-batch")
            _, verb, args = protocol.decode(raw.decode("ascii", "replace"))
            out.append((line, verb, args))
    finally:
        s.close()
    return out


def render_results(results):
    ok = sum(1 for _, v, _ in results if v in ("OK", "PONG"))
    body = []
    for line, verb, args in results:
        if verb in ("OK", "PONG"):
            extra = (" " + " ".join(args)) if args else ""
            body.append("ok   %s%s" % (line, extra))
        else:
            body.append("FAIL %s  -> %s" % (line, " ".join(args)))
    head = "%d/%d commands succeeded" % (ok, len(results))
    return head + "\n" + "\n".join(body), ok != len(results)


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------
TOOLS = [
    {
        "name": "g3_status",
        "description": (
            "Check whether the Mac OS 9 iMac G3 is connected to the bridge, and "
            "report its screen size and colour depth. Call this first if a draw "
            "fails, or to confirm the machine is on the other end of the cable."),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "g3_draw",
        "description": (
            "Draw on the iMac G3's screen using native QuickDraw. Takes a list of "
            "drawing commands executed in order, then presents the result.\n\n"
            + GRAMMAR
            + "\n\nExample commands: [\"CLEAR 0 0 40\", \"PEN 255 190 0\", "
              "\"RECT 20 20 300 200\", \"TEXT 40 120 \\\"Hello G3\\\" 24\"]"),
        "inputSchema": {
            "type": "object",
            "properties": {
                "commands": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Drawing commands, one per element, in the grammar above.",
                },
                "clear_first": {
                    "type": "boolean",
                    "default": False,
                    "description": "Erase the screen to black before drawing.",
                },
                "present": {
                    "type": "boolean",
                    "default": True,
                    "description": "Append FLUSH so the drawing appears. Set false to build up a frame across calls.",
                },
            },
            "required": ["commands"],
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_clear",
        "description": "Erase the iMac G3's screen to a solid colour (default black).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "r": {"type": "integer", "minimum": 0, "maximum": 255, "default": 0},
                "g": {"type": "integer", "minimum": 0, "maximum": 255, "default": 0},
                "b": {"type": "integer", "minimum": 0, "maximum": 255, "default": 0},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_events",
        "description": (
            "Drain input events the iMac G3 has sent back since the last call "
            "(mouse clicks, key presses, quit). Returns them oldest first."),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]


def call_tool(name, args):
    """Returns (text, is_error)."""
    if name == "g3_status":
        results = daemon_exec(["STATUS"])
        _, verb, vals = results[0]
        if verb != "OK":
            return "Bridge error: %s" % " ".join(vals), True
        info = dict(v.split("=", 1) for v in vals if "=" in v)
        if info.get("state") != "connected":
            return ("No G3 connected. The daemon is running and listening on :9990, "
                    "but the Mac has not dialled in.\n"
                    "Check: the Ethernet cable, the Mac's TCP/IP control panel "
                    "(static IP 192.168.77.2, mask 255.255.255.0), and that the "
                    "agent is running on the Mac."), False
        return ("G3 connected.\n" + "\n".join("  %s: %s" % kv for kv in sorted(info.items()))), False

    if name == "g3_clear":
        rgb = (args.get("r", 0), args.get("g", 0), args.get("b", 0))
        text, err = render_results(daemon_exec(["CLEAR %d %d %d" % rgb, "FLUSH"]))
        return text, err

    if name == "g3_draw":
        cmds = list(args.get("commands") or [])
        if not cmds:
            return "No commands given.", True
        if args.get("clear_first"):
            cmds.insert(0, "CLEAR 0 0 0")
        if args.get("present", True) and cmds[-1].strip().upper() != "FLUSH":
            cmds.append("FLUSH")
        text, err = render_results(daemon_exec(cmds))
        return text, err

    if name == "g3_events":
        results = daemon_exec(["EVENTS"])
        _, verb, vals = results[0]
        if verb != "OK":
            return "Bridge error: %s" % " ".join(vals), True
        if not vals:
            return "No events pending.", False
        return "\n".join(v.replace("|", " ") for v in vals), False

    return "Unknown tool: %s" % name, True


# ---------------------------------------------------------------------------
# JSON-RPC plumbing
# ---------------------------------------------------------------------------
def reply(msg_id, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")

    if method == "initialize":
        want = (msg.get("params") or {}).get("protocolVersion")
        version = want if want in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
        reply(msg_id, {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "g3bridge", "version": SERVER_VERSION},
            "instructions": (
                "Drives a 1999 Apple iMac G3 running Mac OS 9 as a graphics display "
                "over a direct Ethernet cable. Use g3_status to confirm the machine "
                "is connected before drawing."),
        })
        return

    if method in ("notifications/initialized", "notifications/cancelled"):
        return                                    # notifications take no reply

    if method == "ping":
        reply(msg_id, {})
        return

    if method == "tools/list":
        reply(msg_id, {"tools": TOOLS})
        return

    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            text, is_error = call_tool(name, args)
        except DaemonError as e:
            text, is_error = str(e), True
        except Exception as e:                    # never kill the server on a bad call
            log("tool %s raised %s: %s" % (name, type(e).__name__, e))
            text, is_error = "%s: %s" % (type(e).__name__, e), True
        reply(msg_id, {"content": [{"type": "text", "text": text}], "isError": is_error})
        return

    if msg_id is not None:
        reply(msg_id, error={"code": -32601, "message": "method not found: %s" % method})


def main():
    log("g3bridge MCP server up; daemon at %s:%d" % (G3D_HOST, G3D_PORT))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError as e:
            log("bad JSON on stdin: %s" % e)
            continue
        try:
            handle(msg)
        except Exception as e:
            log("handler crashed: %s: %s" % (type(e).__name__, e))
            if msg.get("id") is not None:
                reply(msg["id"], error={"code": -32603, "message": str(e)})


if __name__ == "__main__":
    main()
