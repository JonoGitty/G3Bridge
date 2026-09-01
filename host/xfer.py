"""File transfer between the PC and the Mac OS 9 machine.

Two drop folders, no execution, no shares:
    transfer/to-mac/     PC -> Mac. Served over HTTP for the Mac to download.
    transfer/from-mac/   Mac -> PC. Written by uploads from the Mac.

Two problems this module exists to handle.

LINE ENDINGS. Classic Mac OS uses CR, Unix/Windows use LF/CRLF. A text file that
crosses untouched shows up as one giant line in SimpleText, or with visible
control characters. But converting the wrong file corrupts it, so the rule is
narrow and explicit rather than clever.

RESOURCE FORKS. Classic Mac files can carry a second data stream plus 4-byte
type/creator codes. HTTP moves only the data fork, so a Mac application or a
font suitcase arrives useless. We cannot fix that here -- we detect and warn.
"""

import os
import re

# Converted LF -> CR on the way to the Mac. Deliberately short: these are
# formats a human will open in SimpleText or Script Editor.
TEXT_TO_CONVERT = (".txt", ".md", ".csv", ".log", ".ini", ".cfg", ".scpt", ".applescript")

# Left exactly as-is. MacPython 2.3 reads LF source fine (universal newlines),
# and rewriting a script's line endings is a good way to break it subtly.
LEAVE_ALONE = (".py", ".pyc", ".html", ".htm", ".js", ".css", ".xml", ".json")

# Formats whose meaning lives partly or wholly in the resource fork. A plain
# HTTP transfer will not carry these intact in either direction.
FORK_DEPENDENT = (".sit", ".sea", ".app", ".rsrc", ".dfont", ".suit", ".cpt")


def safe_name(name):
    """Strip any path, keep it something both filesystems accept."""
    name = os.path.basename(name.replace("\\", "/")).strip()
    name = re.sub(r'[^A-Za-z0-9._ +-]', "_", name)
    return name[:200]


def classify(name):
    """Return (action, note) for a file heading to the Mac."""
    low = name.lower()
    ext = os.path.splitext(low)[1]
    if ext in FORK_DEPENDENT:
        return ("raw", "resource fork will NOT survive; expect this to arrive incomplete")
    if ext in TEXT_TO_CONVERT:
        return ("cr", "text: LF converted to CR for SimpleText")
    if ext in LEAVE_ALONE:
        return ("raw", "sent byte-for-byte")
    return ("raw", "sent byte-for-byte")


def to_mac_bytes(name, data):
    """Apply the outbound rule. Returns (bytes, note)."""
    action, note = classify(name)
    if action == "cr":
        data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r")
    return data, note


def from_mac_bytes(name, data):
    """Inbound: normalise a CR-only text file so the PC can read it."""
    ext = os.path.splitext(name.lower())[1]
    if ext in TEXT_TO_CONVERT or ext in (".py", ".html", ".htm"):
        if b"\r" in data and b"\n" not in data:
            data = data.replace(b"\r", b"\n")
            return data, "CR line endings converted to LF"
    return data, ""


def listing(directory):
    """[(name, size, note)] sorted by name. Missing directory is not an error."""
    out = []
    try:
        names = os.listdir(directory)
    except OSError:
        return out
    for n in sorted(names):
        p = os.path.join(directory, n)
        if not os.path.isfile(p):
            continue
        try:
            size = os.path.getsize(p)
        except OSError:
            size = 0
        out.append((n, size, classify(n)[1]))
    return out


def human(n):
    if n < 1024:
        return "%d B" % n
    if n < 1024 * 1024:
        return "%.0f KB" % (n / 1024.0)
    return "%.1f MB" % (n / (1024.0 * 1024))


# ---------------------------------------------------------------------------
# multipart/form-data
# ---------------------------------------------------------------------------
def parse_multipart(body, content_type, limit):
    """Minimal RFC 1867 parser. Returns [(filename, bytes)].

    Hand-rolled rather than using `cgi`: that module is deprecated in 3.11 and
    REMOVED in 3.13, and this has to keep working on whatever Python is around.
    """
    m = re.search(r'boundary="?([^";,]+)"?', content_type or "", re.I)
    if not m:
        raise ValueError("no multipart boundary in Content-Type")
    boundary = m.group(1).encode("ascii")
    sep = b"--" + boundary

    files = []
    total = 0
    for part in body.split(sep):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        if b"\r\n\r\n" not in part:
            continue
        head, data = part.split(b"\r\n\r\n", 1)
        head_s = head.decode("latin-1")
        fm = re.search(r'filename="([^"]*)"', head_s)
        if not fm:
            continue                                  # a non-file form field
        fname = fm.group(1)
        if not fname:
            continue                                  # empty file input
        data = data.rstrip(b"\r\n")
        total += len(data)
        if total > limit:
            raise ValueError("upload exceeds %d bytes" % limit)
        files.append((safe_name(fname), data))
    return files
