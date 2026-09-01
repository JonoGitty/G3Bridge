"""Stand in for the Mac's AppleScript applet.

Polls the bridge exactly as the real applet will, "runs" what it gets (really
just reports it), and posts the output back. Lets the command channel be tested
end to end with no Mac involved.

    python tools/fake_applet.py [--host 127.0.0.1] [--port 9980] [--mode post|get]
"""
import sys
import time
import urllib.parse
import urllib.request

host = "127.0.0.1"
port = 9980
mode = "post"
for i, a in enumerate(sys.argv):
    if a == "--host": host = sys.argv[i + 1]
    if a == "--port": port = int(sys.argv[i + 1])
    if a == "--mode": mode = sys.argv[i + 1]

B = "http://%s:%d" % (host, port)
sys.stderr.write("fake-applet: polling %s/cmd (return mode=%s)\n" % (B, mode))

while True:
    try:
        script = urllib.request.urlopen(B + "/cmd", timeout=10).read().decode("mac-roman")
    except Exception as e:
        sys.stderr.write("  poll failed: %s\n" % e)
        time.sleep(2)
        continue

    if not script.strip():
        time.sleep(1)
        continue

    sys.stderr.write("  <- %d chars of script\n" % len(script))
    # A real applet does: run script. We simulate a plausible result.
    lines = script.replace("\r", "\n").strip().split("\n")
    out = "simulated result of %d line(s)\nfirst line was: %s" % (len(lines), lines[0][:60])

    try:
        if mode == "post":
            req = urllib.request.Request(B + "/result", data=out.encode("mac-roman", "replace"),
                                         method="POST")
            req.add_header("Content-Type", "text/plain")
            urllib.request.urlopen(req, timeout=10).read()
        else:
            urllib.request.urlopen(
                B + "/result?out=" + urllib.parse.quote_plus(out), timeout=10).read()
        sys.stderr.write("  -> result returned (%s)\n" % mode)
    except Exception as e:
        sys.stderr.write("  result failed: %s\n" % e)
