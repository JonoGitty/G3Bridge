"""Stand in for the Mac's AppleScript applet, speaking the REAL contract.

Mirrors what the OS 9 applet actually does, so the PC side is tested against
the protocol it will really meet rather than a convenient approximation:

  GET /hello?t=<tag>                     once at launch
  GET /cmd?t=<tag>&q=<poll>              poll; body is "NONE" or raw script
  GET /r?i=&p=&n=&s=&t=&d=               result, percent-encoded, in chunks

Output is encoded as MacRoman, because classic AppleScript is MacRoman and
not UTF-8, and lines are CR-terminated.

    python tools/fake_applet.py [--host 127.0.0.1] [--port 9980] [--chunk 140]
"""
import sys
import time
import urllib.parse
import urllib.request

host, port, chunk = "127.0.0.1", 9980, 140
for i, a in enumerate(sys.argv):
    if a == "--host": host = sys.argv[i + 1]
    if a == "--port": port = int(sys.argv[i + 1])
    if a == "--chunk": chunk = int(sys.argv[i + 1])

B = "http://%s:%d" % (host, port)
TAG = 4242
SAFE = "-._~"


def get(url):
    return urllib.request.urlopen(url, timeout=15).read().decode("mac_roman")


def pct(text):
    """Escape everything except A-Za-z0-9-._~ , as the applet does."""
    out = []
    for b in text.encode("mac_roman", "replace"):
        c = chr(b)
        if c.isalnum() and b < 128 or c in SAFE:
            out.append(c)
        else:
            out.append("%%%02X" % b)
    return "".join(out)


def send_result(seq, status, text):
    enc = pct(text)
    # Split at fixed offsets ON PURPOSE, which can cut a %XX escape in half.
    # The real applet splits on token boundaries, but the host must not depend
    # on that -- this is the adversarial case.
    parts = [enc[i:i + chunk] for i in range(0, len(enc), chunk)] or [""]
    for idx, part in enumerate(parts, 1):
        get("%s/r?i=%d&p=%d&n=%d&s=%s&t=%d&d=%s"
            % (B, seq, idx, len(parts), status, TAG, part))
    sys.stderr.write("  -> %s in %d chunk(s), %d encoded chars\n"
                     % (status, len(parts), len(enc)))


def run_fake(script):
    """Stand in for `run script`. Recognises the reserved commands."""
    s = script.strip()
    if s == "__PING__":
        return "OK", "PC Link alive (simulated)"
    if "syntax error here !!" in s:
        return "CE", "-2741: Expected end of line but found identifier."
    if "boom" in s:
        return "RE", "-1728: Can't get every disk of application \"Finder\"."
    if "disks" in s:
        return "OK", "Macintosh HD\rG3 Backup\rAudio CD"
    if "accents" in s:
        return "OK", "caf\xe9 na\xefve r\xe9sum\xe9"      # MacRoman round-trip test
    if "long" in s:
        return "OK", "\r".join("line %03d of a long listing" % i for i in range(1, 60))
    return "OK", "ran %d character(s)" % len(s)


try:
    get("%s/hello?t=%d" % (B, TAG))
    sys.stderr.write("fake-applet: said hello to %s\n" % B)
except Exception as e:
    sys.stderr.write("fake-applet: hello failed: %s\n" % e)

seq, poll = 0, 0
while True:
    poll += 1
    try:
        body = get("%s/cmd?t=%d&q=%d" % (B, TAG, poll))
    except Exception as e:
        sys.stderr.write("  poll failed: %s\n" % e)
        time.sleep(2)
        continue
    if body.strip() == "NONE" or not body.strip():
        time.sleep(1)
        continue
    seq += 1
    sys.stderr.write("  <- %d chars of script\n" % len(body))
    status, out = run_fake(body)
    try:
        send_result(seq, status, out)
    except Exception as e:
        sys.stderr.write("  result failed: %s\n" % e)
