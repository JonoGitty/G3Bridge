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

import base64
import json
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402
import protocol  # noqa: E402
import xfer  # noqa: E402

# On Windows, text-mode stdout translates \n to \r\n, which corrupts the
# newline-delimited JSON framing. Pin it.
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(newline="\n")
    except AttributeError:
        pass

HERE = os.path.dirname(os.path.abspath(__file__))

CLAUDE_DIR = os.path.join(HERE, "..", "www", "claude")
TO_MAC = os.path.join(HERE, "..", config.TO_MAC_DIR)
FROM_MAC = os.path.join(HERE, "..", config.FROM_MAC_DIR)

G3D_HOST = os.environ.get("G3D_HOST", "127.0.0.1")
G3D_PORT = int(os.environ.get("G3D_PORT", str(config.CONTROL_PORT)))
SERVER_VERSION = "0.1.0"
SUPPORTED_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")

DEVICE_ARG = {
    "device": {
        "type": "string",
        "description": ("Which machine, e.g. 'g3' or 'emac'. Omit it when only one "
                        "is connected -- the bridge picks that one. Use g3_devices to list."),
    },
}

GRAMMAR = """The canvas is %d x %d. Each command is one line.
Coordinates are pixels, origin top-left. Colours are 0-255 per channel.

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
  FONT name                Geneva, Chicago, Monaco, Courier
  FLUSH                    present the buffer (added automatically)""" % (
    config.CANVAS_W, config.CANVAS_H)


def log(msg):
    sys.stderr.write("[mcp] %s\n" % msg)
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# talking to g3d
# ---------------------------------------------------------------------------
class DaemonError(Exception):
    pass


def daemon_exec(lines, device=None):
    """Run command lines through g3d. Returns a list of (line, verb, args).

    A device name is sent as a leading USE, which sets the target for the rest
    of the connection. Omitted, the daemon picks the only machine it has seen.
    """
    if device:
        lines = ["USE %s" % device] + list(lines)
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
            if line.startswith("USE ") and verb != "OK":
                raise DaemonError(" ".join(args))
            if not line.startswith("USE "):
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
        "name": "g3_devices",
        "description": (
            "List the vintage machines the bridge knows about, their addresses, "
            "screen sizes, and whether each is connected. Call this first if you "
            "are unsure which machine to target."),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "g3_publish",
        "description": (
            "Put a page on the vintage Mac's screen. This is the main way to SHOW "
            "something to that machine: a chart, a summary, a reference sheet, a "
            "dashboard, a plan, anything you can write as HTML.\n\n"
            "It appears immediately at http://<pc>:9980/claude-screen on the Mac. "
            "The newest thing published is what that URL shows, so the user can "
            "leave it open and reload.\n\n"
            "WRITE FOR A 2008 BROWSER. Safari 3 on a 1.25GHz PowerPC G4, 1024x768. "
            "CSS2 only: no flexbox, no grid, no border-radius, no box-shadow, no "
            "transitions. JavaScript must be ES3/ES5 -- no let/const, no arrow "
            "functions, no template literals, no class. NOTHING may be loaded from "
            "the internet: no CDN, no web fonts, no remote images. The machine has "
            "no route off the cable. Fonts available: 'Lucida Grande', Geneva, "
            "Monaco, 'Courier New'."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string",
                         "description": "Short file name, e.g. 'weather' or 'budget-summary'. .html is added."},
                "html": {"type": "string",
                         "description": "The complete HTML page, including <html>, <head><title>, and <body>."},
            },
            "required": ["name", "html"],
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_suspend",
        "description": (
            "KILL SWITCH. Stops the bridge doing anything: no pages served to the "
            "Mac, no drawing, no file transfer, no news fetching, and no machine "
            "may connect. The state persists across a restart of the daemon.\n\n"
            "Use when the user asks to stop, pause, or shut the project down. "
            "Reverse it with g3_resume."),
        "inputSchema": {
            "type": "object",
            "properties": {"reason": {"type": "string", "description": "Why, shown to anyone who hits the bridge."}},
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_resume",
        "description": "Switch the bridge back on after g3_suspend.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "g3_status",
        "description": (
            "Check whether the Mac OS 9 iMac G3 is connected to the bridge, and "
            "report its screen size and colour depth. Call this first if a draw "
            "fails, or to confirm the machine is on the other end of the cable."),
        "inputSchema": {"type": "object", "properties": dict(DEVICE_ARG), "additionalProperties": False},
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
                "device": dict(DEVICE_ARG)["device"],
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
                "device": dict(DEVICE_ARG)["device"],
                "r": {"type": "integer", "minimum": 0, "maximum": 255, "default": 0},
                "g": {"type": "integer", "minimum": 0, "maximum": 255, "default": 0},
                "b": {"type": "integer", "minimum": 0, "maximum": 255, "default": 0},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_screenshot",
        "description": (
            "Look at what is currently displayed on the iMac G3's screen. Returns "
            "the image. Use this to check your own drawing came out right, or to "
            "see the current state before adding to it."),
        "inputSchema": {"type": "object", "properties": dict(DEVICE_ARG), "additionalProperties": False},
    },
    {
        "name": "g3_send_file",
        "description": (
            "Stage a file on the PC so the Mac can download it. The Mac fetches it "
            "from the bridge's file page in its browser -- nothing is pushed. Text "
            "files get their line endings converted to classic Mac CR so they open "
            "properly in SimpleText. Note that only the data fork crosses: "
            "applications, fonts and StuffIt archives will arrive incomplete."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "device": dict(DEVICE_ARG)["device"],
                "path": {"type": "string", "description": "Path to the file on the PC."},
                "rename": {"type": "string", "description": "Optional name to give it on the Mac."},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_transfers",
        "description": (
            "List files waiting to go to the Mac and files the Mac has sent to the PC."),
        "inputSchema": {"type": "object", "properties": dict(DEVICE_ARG), "additionalProperties": False},
    },
    {
        "name": "g3_read_received",
        "description": (
            "Read a file the Mac uploaded to the PC. Text is returned directly; "
            "anything binary reports its size and location instead."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "device": dict(DEVICE_ARG)["device"],
                "name": {"type": "string", "description": "Filename as listed by g3_transfers."},
            },
            "required": ["name"],
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_applescript",
        "description": (
            "Run AppleScript on the Mac and get the output back. This is the main "
            "way to CONTROL the machine as opposed to drawing on it: list and read "
            "files, move and delete them, launch and quit applications, read system "
            "information, restart or shut down.\n\n"
            "Requires the G3Bridge applet to be running on the Mac (it polls this PC "
            "for work). Use g3_applet_status to check.\n\n"
            "Classic Mac OS 9 AppleScript only. Paths are colon-separated, e.g.\n"
            "  \"Macintosh HD:System Folder:\"\n"
            "There is NO `do shell script`, no POSIX paths and no System Events -- "
            "those are all Mac OS X. Examples that do work:\n"
            "  tell application \"Finder\" to get name of every disk\n"
            "  tell application \"Finder\" to get name of every item of disk 1\n"
            "  return (system attribute \"sysv\")"),
        "inputSchema": {
            "type": "object",
            "properties": {
                "device": dict(DEVICE_ARG)["device"],
                "script": {"type": "string", "description": "AppleScript source, OS 9 dialect."},
                "timeout": {"type": "number", "default": 60,
                            "description": "Seconds to wait for the Mac to reply."},
            },
            "required": ["script"],
            "additionalProperties": False,
        },
    },
    {
        "name": "g3_applet_status",
        "description": (
            "Check whether the AppleScript applet on the Mac is alive and polling, "
            "and how long ago it last checked in."),
        "inputSchema": {"type": "object", "properties": dict(DEVICE_ARG), "additionalProperties": False},
    },
    {
        "name": "g3_events",
        "description": (
            "Drain input events the iMac G3 has sent back since the last call "
            "(mouse clicks, key presses, quit). Returns them oldest first."),
        "inputSchema": {"type": "object", "properties": dict(DEVICE_ARG), "additionalProperties": False},
    },
]


def call_tool(name, args):
    """Returns (text, is_error)."""
    dev = args.get("device")

    if name == "g3_devices":
        results = daemon_exec(["DEVICES"])
        _, verb, vals = results[0]
        if verb != "OK":
            return " ".join(vals), True
        lines = ["%-8s %-15s %-10s %-8s %s" % ("NAME", "ADDRESS", "SCREEN", "OS", "STATE")]
        for v in vals:
            parts = v.split("|")
            if len(parts) == 5:
                lines.append("%-8s %-15s %-10s %-8s %s" % tuple(parts))
        lines.append("")
        lines.append("Omit the device argument when only one machine is connected.")
        return "\n".join(lines), False

    if name == "g3_publish":
        raw = args.get("name") or ""
        fname = xfer.safe_name(raw)
        if not fname:
            return "Give it a name.", True
        if not fname.endswith(".html"):
            fname += ".html"
        body = args.get("html") or ""
        if "<" not in body:
            return "That does not look like HTML.", True
        if not os.path.isdir(CLAUDE_DIR):
            os.makedirs(CLAUDE_DIR)
        with open(os.path.join(CLAUDE_DIR, fname), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        return ("Published %s (%s).\n"
                "On the Mac it is now at  http://%s:%d/claude-screen\n"
                "and permanently at       http://%s:%d/claude-screen/%s"
                % (fname, xfer.human(len(body.encode("utf-8"))),
                   config.SUGGESTED_PC_IP, config.HTTP_PORT,
                   config.SUGGESTED_PC_IP, config.HTTP_PORT, fname)), False

    if name == "g3_suspend":
        results = daemon_exec(["SUSPEND %s" % (args.get("reason") or "asked to stop")])
        _, verb, vals = results[0]
        if verb != "OK":
            return " ".join(vals), True
        return ("Bridge SUSPENDED. Nothing is served, nothing may connect.\n"
                "%s\nResume with g3_resume." % " ".join(vals)), False

    if name == "g3_resume":
        results = daemon_exec(["RESUME"])
        _, verb, vals = results[0]
        if verb != "OK":
            return " ".join(vals), True
        return "Bridge resumed. %s" % " ".join(vals), False

    if name == "g3_status":
        results = daemon_exec(["STATUS"], dev)
        _, verb, vals = results[0]
        if verb != "OK":
            return "Bridge error: %s" % " ".join(vals), True
        info = dict(v.split("=", 1) for v in vals if "=" in v)
        if info.get("state") != "connected":
            return ("%s (%s) is not connected. The daemon is listening on :9990, "
                    % (info.get("device", "?"), info.get("ip", "?")) +
                    "but that machine has not dialled in.\n"
                    "Tier 0 (its browser pointed at the bridge) still works without "
                    "an agent -- g3_draw will render to the mirror either way."), False
        return ("G3 connected.\n" + "\n".join("  %s: %s" % kv for kv in sorted(info.items()))), False

    if name == "g3_clear":
        rgb = (args.get("r", 0), args.get("g", 0), args.get("b", 0))
        text, err = render_results(daemon_exec(["CLEAR %d %d %d" % rgb, "FLUSH"], dev))
        return text, err

    if name == "g3_draw":
        cmds = list(args.get("commands") or [])
        if not cmds:
            return "No commands given.", True
        if args.get("clear_first"):
            cmds.insert(0, "CLEAR 0 0 0")
        if args.get("present", True) and cmds[-1].strip().upper() != "FLUSH":
            cmds.append("FLUSH")
        text, err = render_results(daemon_exec(cmds, dev))
        return text, err

    if name == "g3_screenshot":
        # The daemon writes each device's mirror out on every FLUSH.
        daemon_exec(["FLUSH"], dev)
        which = dev
        if not which:
            res = daemon_exec(["STATUS"], None)
            info = dict(v.split("=", 1) for v in res[0][2] if "=" in v)
            which = info.get("device", config.DEFAULT_DEVICE)
        frame = os.path.join(HERE, "..", "run", "frame_%s.png" % which)
        if not os.path.exists(frame):
            return "Nothing has been drawn on %s yet." % which, True
        with open(frame, "rb") as fh:
            data = base64.b64encode(fh.read()).decode("ascii")
        return {"image": data, "mime": "image/png"}, False

    if name == "g3_send_file":
        src = args.get("path") or ""
        if not os.path.isfile(src):
            return "No such file on the PC: %s" % src, True
        dest_name = xfer.safe_name(args.get("rename") or os.path.basename(src))
        if not os.path.isdir(TO_MAC):
            os.makedirs(TO_MAC)
        with open(src, "rb") as fh:
            data = fh.read()
        with open(os.path.join(TO_MAC, dest_name), "wb") as fh:
            fh.write(data)
        action, note = xfer.classify(dest_name)
        return ("Staged %s (%s) -- %s\n"
                "On the Mac, open  http://%s:%d/files  and click it."
                % (dest_name, xfer.human(len(data)), note,
                   config.SUGGESTED_PC_IP, config.HTTP_PORT)), False

    if name == "g3_transfers":
        out = []
        rows = xfer.listing(TO_MAC)
        out.append("Waiting for the Mac to collect (%d):" % len(rows))
        for n, sz, note in rows:
            out.append("  %-30s %8s  %s" % (n, xfer.human(sz), note))
        if not rows:
            out.append("  (nothing)")
        rows = xfer.listing(FROM_MAC)
        out.append("")
        out.append("Sent up by the Mac (%d):" % len(rows))
        for n, sz, note in rows:
            out.append("  %-30s %8s" % (n, xfer.human(sz)))
        if not rows:
            out.append("  (nothing)")
        return "\n".join(out), False

    if name == "g3_read_received":
        fn = os.path.join(FROM_MAC, xfer.safe_name(args.get("name") or ""))
        if not os.path.isfile(fn):
            return "Not found. Use g3_transfers to see what the Mac has sent.", True
        with open(fn, "rb") as fh:
            data = fh.read()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            try:
                text = data.decode("mac-roman")     # what a classic Mac writes
            except (UnicodeDecodeError, LookupError):
                return ("%s is binary, %s. It is at %s on the PC."
                        % (os.path.basename(fn), xfer.human(len(data)), fn)), False
        if "\x00" in text:
            return ("%s looks binary, %s. It is at %s on the PC."
                    % (os.path.basename(fn), xfer.human(len(data)), fn)), False
        return text, False

    if name == "g3_applescript":
        src = args.get("script") or ""
        if not src.strip():
            return "No script given.", True
        timeout = float(args.get("timeout") or 60)
        enc = base64.b64encode(src.encode("utf-8")).decode("ascii")
        results = daemon_exec(["APPLESCRIPT %s %g" % (enc, timeout)], dev)
        _, verb, vals = results[0]
        if verb != "OK":
            return " ".join(vals), True
        if not vals:
            return "(the Mac returned nothing)", False
        try:
            out = base64.b64decode(vals[0]).decode("utf-8")
        except Exception as e:
            return "could not decode the Mac's reply: %s" % e, True
        return out if out.strip() else "(the script ran and returned nothing)", False

    if name == "g3_applet_status":
        results = daemon_exec(["APPLETSTATUS"], dev)
        _, verb, vals = results[0]
        if verb != "OK":
            return " ".join(vals), True
        info = dict(v.split("=", 1) for v in vals if "=" in v)
        if info.get("polls") == "0":
            return ("The applet has never checked in. Start G3Bridge Agent on the Mac.\n"
                    "If it is running, check it points at %s:%d."
                    % (config.SUGGESTED_PC_IP, config.HTTP_PORT)), False
        return ("Applet state: %s\n  polls so far: %s\n  last checked in: %s"
                % (info.get("applet"), info.get("polls"), info.get("last_poll"))), False

    if name == "g3_events":
        results = daemon_exec(["EVENTS"], dev)
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
                "G3Bridge drives Jono's vintage Macs from this PC over a direct "
                "Ethernet cable. Two machines: 'emac' (Mac OS X 10.5.6, 1024x768, "
                "the good one) and 'g3' (iMac G3, Mac OS 9.2, 800x600, has a "
                "thermal fault and is often not running).\n\n"
                "THE MACHINES HAVE NO INTERNET. No gateway, no DNS, deliberately. "
                "Anything they need, this PC fetches and serves down the cable. "
                "Never write a page for them that loads anything remote.\n\n"
                "TO SHOW SOMETHING ON THE VINTAGE MAC'S SCREEN, use g3_publish. It "
                "puts an HTML page at /claude-screen, which is the surface set "
                "aside for exactly this. Write for Safari 3 (2008): CSS2 only, "
                "ES3/ES5 JavaScript, no external resources.\n\n"
                "g3_draw is different -- it draws primitives on a framebuffer, for "
                "the OS 9 machine or for simple graphics. For anything textual or "
                "layout-heavy, publish a page instead.\n\n"
                "Call g3_devices if unsure which machine to target; omit the "
                "device argument when only one is connected. g3_suspend is a kill "
                "switch that stops the whole bridge."),
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
        if isinstance(text, dict) and "image" in text:
            content = [{"type": "image", "data": text["image"], "mimeType": text["mime"]}]
        else:
            content = [{"type": "text", "text": text}]
        reply(msg_id, {"content": content, "isError": is_error})
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
