"""G3Bridge wire protocol.

Line-oriented ASCII. Deliberately primitive: the far end is a 1999 Macintosh
running an interpreter that predates the `json` module, so every line must be
parseable with `shlex.split` and nothing else.

    <seq> <VERB> [arg ...]

Sequence numbers are host-assigned, monotonic, and echoed in the reply so
replies can be matched without any framing beyond the newline.

Direction is not encoded in the line; it is implied by the socket. Host sends
commands, the G3 agent sends replies and events.
"""

import shlex

PROTO_VERSION = 1

# ---- host -> G3 -------------------------------------------------------------
# Geometry is in pixels, origin top-left, matching QuickDraw's local coords.
# Colours are 0-255 per channel; the agent scales to QuickDraw's 0-65535.
COMMANDS = {
    "HELLO":  "<proto> -- open the session, agent replies with its screen size",
    "CLEAR":  "[r g b] -- erase the canvas, default black",
    "PEN":    "r g b -- set the drawing colour",
    "PENSIZE": "n -- set stroke width in pixels",
    "MOVETO": "x y -- move the pen without drawing",
    "LINETO": "x y -- draw from the pen to x,y and leave the pen there",
    "LINE":   "x1 y1 x2 y2 -- draw a standalone segment",
    "RECT":   "x1 y1 x2 y2 [FILL] -- rectangle",
    "OVAL":   "x1 y1 x2 y2 [FILL] -- ellipse inscribed in the rect",
    "PIXEL":  "x y -- set a single pixel",
    "TEXT":   "x y <string> [size] -- draw text with x,y as the left baseline",
    "FONT":   "<name> -- set the typeface, e.g. Geneva, Chicago, Monaco",
    "BLIT":   "x y w h <base64-rows> -- paint a raw image block",
    "FLUSH":  "-- present the offscreen buffer to the screen",
    "PING":   "-- liveness check",
    "BYE":    "-- close the session",
}

# ---- G3 -> host -------------------------------------------------------------
REPLIES = {
    "OK":    "<seq> [extra ...]",
    "ERR":   "<seq> <message>",
    "READY": "<agent> <width> <height> <depth> -- sent once after HELLO",
    "PONG":  "<seq>",
    "EVENT": "KEY <code> | CLICK <x> <y> | QUIT",
}


class ProtocolError(Exception):
    pass


def encode(seq, verb, *args):
    """Build one wire line. Args containing spaces are quoted."""
    parts = [str(seq), verb.upper()]
    for a in args:
        s = str(a)
        # shlex.quote is overzealous for our purposes but always correct.
        if s == "" or any(c in s for c in ' \t"\'\\'):
            s = '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
        parts.append(s)
    return " ".join(parts)


def decode(line):
    """Parse one wire line into (seq, verb, args).

    seq is an int, or None for unsequenced traffic such as READY and EVENT.
    """
    line = line.strip()
    if not line:
        raise ProtocolError("empty line")
    try:
        toks = shlex.split(line)
    except ValueError as e:
        raise ProtocolError("unparseable line: %s" % e)
    if not toks:
        raise ProtocolError("empty line")

    if toks[0].isdigit():
        if len(toks) < 2:
            raise ProtocolError("sequence number with no verb")
        return int(toks[0]), toks[1].upper(), toks[2:]
    return None, toks[0].upper(), toks[1:]
