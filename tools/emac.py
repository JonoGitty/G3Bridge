"""Drive a game page on the eMac from the PC, for testing.

    C:\\Python310\\python.exe tools\\emac.py open /games/backrooms.html?rc=1
    C:\\Python310\\python.exe tools\\emac.py rc "key 38 500" "snap"
    C:\\Python310\\python.exe tools\\emac.py js "document.getElementById('bk').g3('state',0)"
    C:\\Python310\\python.exe tools\\emac.py wait "bench=done" 120        # seconds
    C:\\Python310\\python.exe tools\\emac.py tail 12                       # telemetry lines
    C:\\Python310\\python.exe tools\\emac.py snap                          # newest snapshot path

open: navigates Safari on the eMac (osascript over SSH). rc: queues lines the
SWF reads from /rc. js: runs JavaScript in Safari's front document and prints
the result. wait: polls run/telemetry.log for a marker.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(ROOT, "host"))
import config  # noqa: E402

SSH = r"C:\Windows\System32\OpenSSH\ssh.exe"
CFG = os.path.join(ROOT, "host", "ssh", "config")
TLOG = os.path.join(ROOT, "run", "telemetry.log")
PC = "http://%s:%d" % (config.SUGGESTED_PC_IP, config.HTTP_PORT)


def ssh(cmd, timeout=60):
    r = subprocess.run([SSH, "-F", CFG, "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", "emac", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return (r.stdout + r.stderr).strip()


def osa(lines):
    return ssh("osascript " + " ".join('-e "%s"' % l.replace('"', '\\"') for l in lines))


def cmd_open(path):
    url = path if path.startswith("http") else PC + path
    print(osa(['tell application "Safari"', "activate", 'set URL of document 1 to "%s"' % url, "end tell"]))


def cmd_rc(lines):
    import urllib.request
    body = "\n".join(lines).encode("utf-8")
    r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%d/rc?dev=emac" % config.HTTP_PORT, data=body), timeout=10)
    print(r.read().decode())


def cmd_js(code):
    esc = code.replace("\\", "\\\\").replace('"', '\\"')
    print(osa(['tell application "Safari" to do JavaScript "%s" in document 1' % esc]))


def cmd_wait(marker, seconds):
    start = os.path.getsize(TLOG) if os.path.exists(TLOG) else 0
    t_end = time.time() + float(seconds)
    while time.time() < t_end:
        if os.path.exists(TLOG):
            with open(TLOG, encoding="utf-8", errors="replace") as f:
                f.seek(start)
                new = f.read()
            if marker in new:
                print("found: " + marker)
                return 0
        time.sleep(1)
    print("timeout waiting for " + marker)
    return 1


def cmd_tail(n):
    if not os.path.exists(TLOG):
        return
    lines = open(TLOG, encoding="utf-8", errors="replace").read().splitlines()[-int(n):]
    for l in lines:
        print(l.replace("&", " ")[:220])


def cmd_snap():
    d = os.path.join(ROOT, "run")
    snaps = sorted((os.path.getmtime(os.path.join(d, f)), f) for f in os.listdir(d) if f.startswith("snap_emac_"))
    print(os.path.join(d, snaps[-1][1]) if snaps else "no snapshots")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__); sys.exit(2)
    c = a[0]
    if c == "open": cmd_open(a[1])
    elif c == "rc": cmd_rc(a[1:])
    elif c == "js": cmd_js(a[1])
    elif c == "wait": sys.exit(cmd_wait(a[1], a[2] if len(a) > 2 else 60))
    elif c == "tail": cmd_tail(a[1] if len(a) > 1 else 12)
    elif c == "snap": cmd_snap()
    else: print(__doc__)
