"""Flag constructs that MacPython 2.3 on Mac OS 9 cannot run.

There is no Python 2.3 on this machine, and Python 3 is NOT a substitute:
3.14 happily parses `except Exception, e` as a tuple of exception classes, so
a py3 syntax check silently passes py2 code and silently mis-reads it. Hence
this lint.

    python tools/lint_py23.py g3/g3agent.py
"""
import re
import sys

# (regex, why it fails on 2.3)
RULES = [
    (r'\bf"', 'f-strings are 3.6+'),
    (r"\bf'", 'f-strings are 3.6+'),
    (r'^\s*with\s+.*:', '"with" is 2.5+'),
    (r'\bexcept\s+\w+\s+as\s+\w+', '"except X as e" is 2.6+; use "except X, e"'),
    (r'\bset\(', 'set() builtin is 2.4+; use sets.Set or a dict'),
    (r'\bsorted\(', 'sorted() is 2.4+; use lst.sort()'),
    (r'\breversed\(', 'reversed() is 2.4+'),
    (r'\bany\(|\ball\(', 'any()/all() are 2.5+'),
    (r'\.format\(', 'str.format is 2.6+; use %'),
    (r'^\s*@\w+', 'decorators are 2.4+'),
    (r'\bsubprocess\b', 'subprocess is 2.4+'),
    (r'\bjson\b', 'json is 2.6+'),
    (r'\bcollections\b', 'collections is 2.4+'),
    (r'\bthreading\b|\bimport thread\b', 'MacPython-OS9 is built WITHOUT threads'),
    (r'\bTkinter\b|\btkinter\b', 'no working Carbon Tk on MacPython 2.3'),
    (r'\{[^{}]*\bfor\b[^{}]*\}', 'dict/set comprehensions are 2.7+'),
    (r'\bprint\s*\(.*,\s*\w+\s*=', 'print() keyword args are py3'),
    (r'\bos\.walk\b.*followlinks', 'followlinks is 2.6+'),
    (r'\btry\b:[\s\S]{0,400}?\bexcept\b[\s\S]{0,400}?\bfinally\b', 'try/except/finally together is 2.5+'),
]

# generator expressions: "(expr for x in" but NOT a call like sum(x for ...) which is also 2.4
GENEXP = re.compile(r'\(\s*[^()]*\s+for\s+\w+\s+in\s')


def lint(path):
    src = open(path).read()
    lines = src.split("\n")
    problems = []
    for i, line in enumerate(lines, 1):
        stripped = line.split("#")[0]
        if not stripped.strip():
            continue
        for pat, why in RULES:
            if re.search(pat, stripped):
                problems.append((i, why, line.strip()[:70]))
        if GENEXP.search(stripped):
            problems.append((i, 'generator expressions are 2.4+', line.strip()[:70]))

    # ternary needs whole-line context
    for i, line in enumerate(lines, 1):
        s = line.split("#")[0].strip()
        if s.startswith(("if ", "elif ", "while ")) or s.endswith(":"):
            continue
        if re.search(r'\S\s+if\s+\S.*\s+else\s+\S', s):
            problems.append((i, 'ternary "a if b else c" is 2.5+', s[:70]))

    print("%s: %d line(s)" % (path, len(lines)))
    if not problems:
        print("  clean for Python 2.3")
        return 0
    for ln, why, text in problems:
        print("  line %-4d %s" % (ln, why))
        print("           %s" % text)
    return 1


if __name__ == "__main__":
    rc = 0
    for p in sys.argv[1:]:
        rc |= lint(p)
    sys.exit(rc)
