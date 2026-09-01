"""The agent parses wire lines with a hand-rolled splitter (shlex is too slow
on a 233MHz G3). This proves that splitter agrees with the host's encoder.

A disagreement here means text drawn on the Mac silently differs from what
Claude asked for, so it is worth its own test.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import protocol

AGENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "g3", "g3agent.py")

# lift parse_line out of the py2 source without importing the whole module
src = open(AGENT).read()
m = re.search(r"^def parse_line\(line\):.*?(?=^def |\Z)", src, re.S | re.M)
ns = {}
exec(compile(m.group(0), "g3agent.parse_line", "exec"), ns)
parse_line = ns["parse_line"]

CASES = [
    ["HELLO", "1"],
    ["TEXT", "20", "40", "Hello, G3!"],
    ["TEXT", "0", "0", "spaces   inside"],
    ["TEXT", "0", "0", 'has "quotes" inside'],
    ["TEXT", "0", "0", "back\\slash"],
    ["TEXT", "0", "0", "trailing space "],
    ["TEXT", "0", "0", "tab\there"],
    ["RECT", "0", "0", "100", "50", "FILL"],
    ["FONT", "Geneva"],
    ["TEXT", "0", "0", "MCP -> G3"],
    ["TEXT", "0", "0", "100% done; 50% left"],
]

fails = 0
for i, args in enumerate(CASES, 1):
    wire = protocol.encode(i, *args)
    got = parse_line(wire)
    want = [str(i)] + args
    ok = got == want
    if not ok:
        fails += 1
    print("%s  %s" % ("ok  " if ok else "FAIL", wire))
    if not ok:
        print("      host meant: %r" % (want,))
        print("      agent read: %r" % (got,))

# the empty-string case, called out separately because it is a real edge
wire = protocol.encode(99, "TEXT", "0", "0", "")
got = parse_line(wire)
want = ["99", "TEXT", "0", "0", ""]
print("%s  %s   (empty string)" % ("ok  " if got == want else "FAIL", wire))
if got != want:
    fails += 1
    print("      host meant: %r" % (want,))
    print("      agent read: %r" % (got,))

print()
print("%d/%d agreed" % (len(CASES) + 1 - fails, len(CASES) + 1))
sys.exit(1 if fails else 0)
