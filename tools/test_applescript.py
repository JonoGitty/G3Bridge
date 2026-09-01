"""End-to-end test of the AppleScript command channel.

Starts the stand-in applet, drives it through the MCP server, and checks the
things that are easy to get wrong across this transport: chunk reassembly,
MacRoman decoding, and the compile-vs-runtime error distinction.

    python tools/test_applescript.py
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "host", "mcp_server.py")
APPLET = os.path.join(HERE, "fake_applet.py")

failures = []


def check(label, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + label + (("  -- " + detail) if detail else ""))
    if not cond:
        failures.append(label)


def main():
    applet = subprocess.Popen([sys.executable, APPLET],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)
    p = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, bufsize=1)

    def rpc(m, params=None, i=None):
        msg = {"jsonrpc": "2.0", "method": m}
        if i is not None:
            msg["id"] = i
        if params is not None:
            msg["params"] = params
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()
        if i is None:
            return None
        return json.loads(p.stdout.readline())

    def run(script, i, timeout=30):
        r = rpc("tools/call", {"name": "g3_applescript",
                               "arguments": {"script": script, "timeout": timeout}}, i)
        res = r.get("result", {})
        return res.get("content", [{}])[0].get("text", ""), res.get("isError")

    try:
        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "t", "version": "0"}}, 1)
        rpc("notifications/initialized")

        r = rpc("tools/call", {"name": "g3_applet_status", "arguments": {}}, 2)
        st = r["result"]["content"][0]["text"]
        check("applet is polling", "polls so far" in st and "never checked in" not in st, st.split("\n")[0])

        t, err = run("__PING__", 3)
        check("health check answers", err is False and "alive" in t, t[:60])

        t, err = run("syntax error here !!", 4)
        check("compile error is labelled CE", "[CE]" in t, t[:70])

        t, err = run("boom", 5)
        check("runtime error is labelled RE", "[RE]" in t, t[:70])

        t, err = run("accents", 6)
        want = "caf\u00e9 na\u00efve r\u00e9sum\u00e9"
        check("MacRoman decodes to the right code points", t.strip() == want,
              "got %r" % t.strip())

        t, err = run("long", 7)
        lines = [l for l in t.split("\n") if l.strip()]
        check("60-line result reassembles from ~17 chunks", len(lines) == 59,
              "%d lines" % len(lines))
        check("chunks are in the right order",
              lines[0].startswith("line 001") and lines[-1].startswith("line 059"),
              "%s .. %s" % (lines[0][:20], lines[-1][:20]))

        t, err = run("disks", 8)
        check("multi-line result splits on CR", "Macintosh HD" in t and "Audio CD" in t, t[:60])

        p.stdin.close()
    finally:
        applet.terminate()

    print()
    if failures:
        print("%d FAILED: %s" % (len(failures), ", ".join(failures)))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
