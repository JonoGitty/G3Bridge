"""Run every test. One command, one exit code.

    C:\\Python310\\python.exe tools\\test_all.py

Some suites need the daemon running; they are marked and skipped with a clear
message rather than failing misleadingly if it is not.
"""
import os
import socket
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "host"))
import config  # noqa: E402

SUITES = [
    ("wire protocol interop", "test_parser_interop.py", False,
     "the Mac's hand-rolled parser agrees with the host's encoder"),
    ("Python 2.3 lint", None, False,
     "the OS 9 agent uses nothing MacPython 2.3 cannot run"),
    ("MCP over JSON-RPC", "test_mcp.py", True,
     "the tool surface, the handshake, and every error path"),
    ("AppleScript channel", "test_applescript.py", True,
     "chunked results, MacRoman, compile vs runtime errors"),
    ("web translation layer", "test_webproxy.py", False,
     "forms, images, strips, reader, links; live pass when the daemon is up"),
]


def daemon_up():
    try:
        socket.create_connection(("127.0.0.1", config.CONTROL_PORT), timeout=1).close()
        return True
    except OSError:
        return False


def main():
    up = daemon_up()
    print("G3Bridge test suite")
    print("  daemon: %s\n" % ("running" if up else "NOT RUNNING - some suites will be skipped"))

    failed, skipped, passed = [], [], []
    for name, script, needs_daemon, blurb in SUITES:
        if needs_daemon and not up:
            print("  SKIP  %-24s %s" % (name, blurb))
            skipped.append(name)
            continue
        if script is None:
            cmd = [sys.executable, os.path.join(HERE, "lint_py23.py"),
                   os.path.join(HERE, "..", "g3", "g3agent.py")]
        else:
            cmd = [sys.executable, os.path.join(HERE, script)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 0:
            print("  PASS  %-24s %s" % (name, blurb))
            passed.append(name)
        else:
            print("  FAIL  %-24s %s" % (name, blurb))
            for line in (r.stdout or "").splitlines()[-8:]:
                print("        " + line)
            failed.append(name)

    print()
    print("%d passed, %d failed, %d skipped" % (len(passed), len(failed), len(skipped)))
    if skipped:
        print("Start the daemon with start.cmd to run the skipped suites.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
