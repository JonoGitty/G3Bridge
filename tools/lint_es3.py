"""Parse JavaScript as ECMAScript 3 with a real parser, because Safari 3
(2008) is an ES3 engine and a modern Node or Chromium will happily run syntax
it cannot read. acorn is loaded from cdnjs inside Playwright's browser, so
nothing needs installing.

    C:\\Python310\\python.exe tools\\lint_es3.py www\\games\\backrooms.html [more files]

HTML files have their <script> blocks extracted (external src files under the
same directory are linted too). Exit code 1 on any parse error, plus a report
of ES5+/DOM features Safari 3 lacks (Object.keys, JSON, bind, typed arrays,
requestAnimationFrame, localStorage, Date.now, trim, isArray, getters).
"""
import os
import re
import sys

ACORN = "https://cdnjs.cloudflare.com/ajax/libs/acorn/8.14.1/acorn.min.js"

MISSING = [
    (r"\bObject\.keys\b", "Object.keys (ES5; Safari 5)"),
    (r"\bObject\.create\b", "Object.create (ES5)"),
    (r"\bObject\.defineProperty\b", "Object.defineProperty (ES5)"),
    (r"\bJSON\.", "JSON (Safari 4)"),
    (r"\.bind\s*\(", "Function.prototype.bind (Safari 5.1)"),
    (r"\bArray\.isArray\b", "Array.isArray (ES5)"),
    (r"\.trim\s*\(\)", "String.prototype.trim (ES5)"),
    (r"\bDate\.now\b", "Date.now (Safari 4)"),
    (r"\b(Uint8|Uint16|Uint32|Int8|Int16|Int32|Float32|Float64)(Clamped)?Array\b", "typed arrays (Safari 5.1)"),
    (r"\b(webkit)?[rR]equestAnimationFrame\b", "requestAnimationFrame (Safari 6)"),
    (r"\blocalStorage\b|\bsessionStorage\b", "Web Storage (Safari 4)"),
    (r"\bArrayBuffer\b|\bDataView\b", "ArrayBuffer (Safari 5.1)"),
    (r"\bMath\.(trunc|sign|cbrt|hypot|log2|log10)\b", "ES6 Math"),
    (r"\bNumber\.(isNaN|isInteger|isFinite)\b", "ES6 Number"),
    (r"\bperformance\.now\b", "performance.now (Safari 8)"),
    (r"\bpointerLockElement\b|requestPointerLock", "pointer lock (Safari 10)"),
    (r"\bAudioContext\b|webkitAudioContext", "Web Audio (Safari 6)"),
    (r"\.(reduce|reduceRight|lastIndexOf)\s*\(", "reduce/lastIndexOf (Safari 3 lacks reduce)"),
    (r"\bclassList\b", "classList (Safari 5.1)"),
    (r"\bquerySelector(All)?\b", "querySelector (Safari 3.1: yes, 3.0: no)"),
    (r"\baddEventListener\([^)]*\{\s*passive", "passive listeners"),
]


def scripts_from(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    if not path.lower().endswith((".html", ".htm")):
        return [(path, text)]
    out = []
    base = os.path.dirname(path)
    for m in re.finditer(r"<script\b([^>]*)>(.*?)</script>", text, re.S | re.I):
        attrs, body = m.group(1), m.group(2)
        src = re.search(r'src=["\']([^"\']+)["\']', attrs)
        if src:
            p = os.path.join(base, src.group(1).split("?")[0])
            if os.path.isfile(p):
                out.append((p, open(p, encoding="utf-8", errors="replace").read()))
            else:
                out.append((src.group(1), "/* external script not found locally */"))
        elif body.strip():
            line = text[:m.start(2)].count("\n") + 1
            out.append(("%s:<script>@%d" % (path, line), body))
    return out


def main(paths):
    from playwright.sync_api import sync_playwright
    units = []
    for p in paths:
        units.extend(scripts_from(p))
    bad = 0
    with sync_playwright() as pw:
        b = pw.chromium.launch(headless=True)
        pg = b.new_page()
        pg.set_content("<html><body></body></html>")
        pg.add_script_tag(url=ACORN)
        pg.wait_for_function("typeof acorn !== 'undefined'", timeout=30000)
        for name, src in units:
            r = pg.evaluate("""([src]) => { try { acorn.parse(src, {ecmaVersion: 3, allowReserved: false}); return null; }
                catch (e) { return String(e.message); } }""", [src])
            if r:
                bad += 1
                print("  ES3 PARSE ERROR  %s: %s" % (name, r))
            else:
                print("  es3 ok           %s (%d chars)" % (name, len(src)))
            for pat, what in MISSING:
                for m in re.finditer(pat, src):
                    line = src[:m.start()].count("\n") + 1
                    print("  MISSING IN SAFARI 3  %s:%d  %s" % (name, line, what))
                    bad += 1
        b.close()
    print("%d problem%s" % (bad, "" if bad == 1 else "s"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
