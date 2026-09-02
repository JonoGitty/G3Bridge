#!/usr/bin/env python3
"""Core purity and rule checks for the Backrooms Tape sources (CONTRACT section 6).

    C:\\Python310\\python.exe tools\\backrooms_check.py        (Windows)
    python3 tools/backrooms_check.py                          (WSL)
    python3 tools/backrooms_check.py <dir>                    (check another tree, e.g. a stubs dir)

FAIL (exit 1):
  - a core class file contains "flash."   (core classes import nothing from the Flash API)
  - a core class file contains "Dynamic"  (no Dynamic in core)
WARN (printed, exit 0):
  - "new " inside a function named update / render / apply / draw / pump / cast* in ANY class
    (rule 4: no allocation in the frame loop), reported as file:line

Comments and string literals are stripped before matching so a "// SKELETON" note or a
telemetry key cannot trigger a hit. Standard library only; runs on Python 3.6+.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
SRC = os.path.join(ROOT, "src", "backrooms")

CORE = [
    "Rng", "Cells", "Chunk", "ChunkGen", "World", "RayHits", "Raycaster", "MapMemory",
    "Path", "Player", "Entity", "Watcher", "Hound", "Director", "Tape", "Quality", "Bot",
]

# functions whose bodies must not allocate (the contract's list; "cast" also matches castRays)
HOT_FUNCS = ("update", "render", "apply", "draw", "pump", "cast")
FUNC_RE = re.compile(r"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
NEW_RE = re.compile(r"\bnew\s+[A-Za-z_]")


def strip_code(text):
    """Blank out comments and string literals, keeping line structure and length."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            if j < 0:
                j = n
            out.append(" " * (j - i))
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            seg = text[i:j]
            out.append("".join("\n" if ch == "\n" else " " for ch in seg))
            i = j
        elif c == '"' or c == "'":
            q = c
            j = i + 1
            while j < n and text[j] != q:
                if text[j] == "\\":
                    j += 1
                j += 1
            j = min(j + 1, n)
            seg = text[i:j]
            out.append(q + "".join("\n" if ch == "\n" else " " for ch in seg[1:-1]) + q if len(seg) >= 2 else seg)
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def is_hot(name):
    return any(name == f or name.startswith(f) for f in HOT_FUNCS)


def hot_allocations(path, code):
    """Yield (line, text) for every `new ` inside a hot function body."""
    lines = code.split("\n")
    hits = []
    for m in FUNC_RE.finditer(code):
        name = m.group(1)
        if not is_hot(name):
            continue
        # find the opening brace of the body (skip signatures that are `function f():T return ...;`)
        k = code.find("{", m.end())
        semi = code.find(";", m.end())
        if k < 0 or (0 <= semi < k and "return" in code[m.end():semi]):
            # expression-bodied: check up to the semicolon
            body_start, body_end = m.end(), (semi if semi >= 0 else len(code))
        else:
            depth = 0
            j = k
            while j < len(code):
                if code[j] == "{":
                    depth += 1
                elif code[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            body_start, body_end = k, j
        for nm in NEW_RE.finditer(code, body_start, body_end):
            line = code.count("\n", 0, nm.start()) + 1
            hits.append((line, name, lines[line - 1].strip()))
    return hits


def main():
    global SRC
    if len(sys.argv) > 1:
        SRC = os.path.abspath(sys.argv[1])   # test hook: check another tree
    fails = 0
    warns = 0
    if not os.path.isdir(SRC):
        print("no such directory: " + SRC)
        return 1
    files = sorted(f for f in os.listdir(SRC) if f.endswith(".hx"))
    for f in files:
        path = os.path.join(SRC, f)
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        code = strip_code(text)
        cls = f[:-3]
        rel = os.path.relpath(path, ROOT)
        if cls in CORE:
            for lineno, line in enumerate(code.split("\n"), 1):
                if "flash." in line:
                    print("FAIL %s:%d: core class uses flash.: %s" % (rel, lineno, text.split("\n")[lineno - 1].strip()))
                    fails += 1
                if re.search(r"\bDynamic\b", line):
                    print("FAIL %s:%d: core class uses Dynamic: %s" % (rel, lineno, text.split("\n")[lineno - 1].strip()))
                    fails += 1
        for lineno, fn, line in hot_allocations(path, code):
            print("WARN %s:%d: allocation in %s(): %s" % (rel, lineno, fn, text.split("\n")[lineno - 1].strip()))
            warns += 1
    missing = [c for c in CORE if c + ".hx" not in files]
    for c in missing:
        print("FAIL missing core class file: src/backrooms/%s.hx" % c)
        fails += 1
    print("backrooms_check: %d file(s), %d fail, %d warn" % (len(files), fails, warns))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
