"""The web translation layer.

Offline: the translator over a fixture that exercises forms, lazy images,
srcset, noscript, hidden elements, navigation strips, media, downloads,
fragments, deep nesting and reader extraction. Needs lxml, so run it on
Windows Python:

    C:\\Python310\\python.exe tools\\test_webproxy.py

Live (only if the daemon is up on 127.0.0.1): the clock endpoints, a page, a
form submission, a WebP converted to JPEG, a download, and -- if Playwright is
installed -- a rendered view and a picture view. Network errors on the live
part are reported as skips, not failures.
"""
import os
import re
import socket
import sys
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "host"))
import config  # noqa: E402
import webproxy  # noqa: E402

FAILS = []


def check(cond, what):
    print("  %s  %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAILS.append(what)


FIX = """<!DOCTYPE html><html><head><title>Fixture &amp; Co</title>
<base href="https://site.example/dir/"></head>
<body><header><a href="/"><img alt="Site" src="logo.svg"></a><nav><a href="/a">Alpha</a><a href="b">Beta</a>
<form action="/search"><input type="search" name="q" placeholder="Search site"><button>Find</button></form></nav></header>
<main><article><h1 id="top">Story</h1><p>Para one with <a href="https://other.example/x.pdf">a PDF</a>
and <a href="#top">frag</a> and <a href="mailto:a@b">mail</a> and <a href="https://www.youtube.com/watch?v=abc">a video</a>.</p>
<p>%s</p><img src="data:image/gif;base64,R0lGOD" data-src="pic.webp" width="1200" height="800"><noscript><img src="ns.jpg"></noscript>
<img srcset="s-300.jpg 300w, s-800.jpg 800w, s-1600.jpg 1600w"><img src="t.gif" width="1" height="1">
<div hidden>SECRET1</div><div style="display:none">SECRET2</div><span class="sr-only">SECRET3</span><p aria-hidden="true">SECRET4</p>
<video poster="p.jpg"><source src="clip.mp4"></video><iframe src="https://www.youtube.com/embed/abc"></iframe>
<form method="post" action="https://site.example/login"><input name="user"><input type="password" name="pw">
<input type="hidden" name="tok" value="1"><button type="submit" name="do" value="go">Log in</button>
<select name="s"><option value="1" selected>One</option></select><textarea name="t">  x  </textarea>
<input type="file" name="f"><input type="checkbox" name="c" checked></form>
<pre>  keep   this  </pre><custom-el><b>bold</b></custom-el><script>alert(1)</script><!-- comment --><style>p{}</style>
<table><tr><td colspan="2">cell</td><td></td></tr></table><details><summary>More</summary>inside</details>
</article></main><aside><ul><li><a href="/r1">r1</a></li><li><a href="/r2">r2</a></li><li><a href="/r3">r3</a></li><li><a href="/r4">r4</a></li></ul></aside>
<footer><a href="/about">About</a></footer></body></html>""" % ("lorem ipsum " * 80)


def offline():
    print("offline: the translator")
    t = webproxy.Translator("https://site.example/dir/page", "full")
    title, body = t.run(FIX)
    check(title == "Fixture & Co", "title decoded")
    check(t.forms == 2 and body.count('action="/web/f"') == 2, "both forms rewritten through /web/f")
    check('method="post"' in body and 'name="_u" value="https://site.example/login"' in body,
          "POST form keeps its method and absolute action")
    check('<input type="password" name="pw">' in body, "password field kept")
    check('<input type="hidden" name="tok" value="1">' in body, "hidden field kept")
    check('<input type="submit" name="do" value="go">' in body, "button becomes a submit with its name and value")
    check('type="file"' not in body, "file input dropped")
    check('name="c" checked' in body, "checked checkbox kept")
    check('<option value="1" selected>One</option>' in body, "select/option kept")
    check("<textarea name=\"t\">  x  </textarea>" in body, "textarea keeps its whitespace")
    check('type="search"' not in body and '<input type="text" name="q" title="Search site">' in body,
          "search input becomes text, placeholder becomes title")
    check('class="strip"' in body and ">Alpha</a>" in body and ">Beta</a>" in body, "nav folded into a strip")
    check(body.index(">Alpha</a>") < body.index("Story"), "strip comes before the content")
    check('href="/web?u=https%3A%2F%2Fsite.example%2Fdir%2Fb"' in body, "relative link resolved against <base>")
    check('href="/web?d=https%3A%2F%2Fother.example%2Fx.pdf"' in body, "PDF link goes to download")
    check('href="#top"' in body and 'id="top"' in body, "fragment link and its target kept")
    check("mailto" not in body and ">mail<" not in body and "mail" in body, "mailto unwrapped to text")
    check('href="/video?u=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc"' in body, "YouTube link goes to /video")
    check("pic.webp" in body and "R0lGOD" not in body, "lazy image: data-src wins over a data: placeholder")
    check("s-800.jpg" in body and "s-1600" not in body and "s-300" not in body, "srcset: smallest candidate >= 600w")
    check("ns.jpg" in body, "noscript image kept")
    check("t.gif" not in body, "1x1 tracking pixel dropped")
    check('width="1200"' not in body, "oversize width attribute dropped")
    for i in range(1, 5):
        check("SECRET%d" % i not in body, "hidden element %d removed" % i)
    check('/video?u=https%3A%2F%2Fsite.example%2Fdir%2Fclip.mp4' in body and "p.jpg" in body,
          "<video> becomes poster + play-via-PC link")
    check("Embedded video" in body and "%2Fembed%2Fabc" in body, "YouTube iframe becomes a video link")
    check("<pre>  keep   this  </pre>" in body, "pre whitespace preserved")
    check("<b>bold</b>" in body and "custom-el" not in body, "custom element unwrapped")
    check("alert" not in body and "comment" not in body and "p{}" not in body, "script, comment, style gone")
    check('<td colspan="2">cell</td><td></td>' in body, "colspan kept, empty cell kept")
    check("<b>More</b>" in body and "inside" in body, "details/summary flattened")
    check(">Site</a>" in body and "logo.svg" not in body, "image-only link in a strip labelled by its alt")
    check(">About</a>" in body and ">r1</a>" in body, "footer and aside kept as strips")

    t = webproxy.Translator("https://site.example/dir/page", "reader")
    title, rbody = t.run(FIX)
    check("Story" in rbody and "lorem ipsum" in rbody, "reader keeps the article")
    check("Alpha" not in rbody and "r1" not in rbody and "About" not in rbody, "reader drops nav, aside, footer")
    check("pic.webp" in rbody and ">a PDF</a>" in rbody, "reader keeps the article's images and links")
    check(rbody.count("<h1") == 1, "reader does not duplicate the headline")

    print("offline: helpers")
    check(webproxy.normalise("example.com/x") == "https://example.com/x", "scheme added")
    check(webproxy.normalise("https://www.reddit.com/r/mac") == "https://old.reddit.com/r/mac", "reddit -> old.reddit")
    check(webproxy.is_video_url("https://youtu.be/abc") and not webproxy.is_video_url("https://www.youtube.com/"),
          "video URL detection")
    check(webproxy.link_for("https://a.example/f.zip").startswith("/web?d="), ".zip is a download")
    check(webproxy.link_for("https://a.example/", "reader") == "/web?view=reader&u=https%3A%2F%2Fa.example%2F",
          "reader view propagates through links")

    deep = "<html><body>" + "<div>" * 3000 + "deep" + "</div>" * 3000 + "</body></html>"
    try:
        _t, b = webproxy.Translator("https://x.example/", "full").run(deep)
        check("deep" in b, "3000-deep nesting does not overflow the stack")
    except RecursionError:
        check(False, "3000-deep nesting does not overflow the stack")

    big = "<html><body>" + "<p>%s</p>" % ("word " * 200) * 600 + "</body></html>"
    tr = webproxy.Translator("https://x.example/", "full")
    _t, b = tr.run(big)
    check(len(b) < webproxy.MAX_OUT + 400 and "truncated" in tr.notes, "over-long page truncated with a note")

    latin = ("<html><head><meta charset=\"iso-8859-1\"><title>caf\xe9</title></head>"
             "<body><p>na\xefve</p></body></html>").encode("latin-1")
    text = webproxy._decode(latin, "text/html")
    check("caf\xe9" in text and "na\xefve" in text, "meta charset honoured")


def daemon_up():
    try:
        socket.create_connection(("127.0.0.1", config.HTTP_PORT), timeout=1).close()
        return True
    except OSError:
        return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def get(path, timeout=90):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (config.HTTP_PORT, path))
    try:
        r = _OPENER.open(req, timeout=timeout)
        return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def live():
    if not daemon_up():
        print("live: daemon not running, skipped")
        return
    print("live: through the daemon")
    st, h, b = get("/time?f=date")
    check(st == 200 and re.match(rb"^\d{12}\.\d{2}$", b), "/time?f=date is mmddHHMMccyy.ss (%r)" % b[:20])
    st, h, b = get("/time?f=sh")
    check(b"systemsetup -settimezone %s" % config.TIMEZONE.encode() in b and b"date -f" in b,
          "/time?f=sh sets the zone and has the date fallback")
    st, h, b = get("/time")
    check(st == 200 and b"refresh" in b and b"/time?f=sh | sudo sh" in b, "/time page with the command")
    st, h, b = get("/setup")
    check(b"/time?f=sh | sudo sh" in b, "/setup carries the clock command")

    try:
        st, h, b = get("/web?u=https%3A//example.com")
        check(st == 200 and b"Example Domain" in b and b'class="webhead"' in b, "a plain page translates")
        check(b"fetched by the PC" in b, "engine reported")
        st, h, b = get("/web?view=reader&u=https%3A//en.wikipedia.org/wiki/EMac")
        check(st == 200 and b"eMac" in b and b"Main Page" not in b, "Wikipedia article in reader view drops the chrome")
        st, h, b = get("/web?u=https%3A//en.wikipedia.org/wiki/EMac")
        check(b'name="_u" value="https://en.wikipedia.org/w/index.php"' in b, "Wikipedia's search box rewritten as a form")
        st, h, b = get("/web/f?_u=https%3A//html.duckduckgo.com/html/&_m=get&q=vintage+macintosh")
        check(st == 200 and b.count(b'href="/web?u=') > 5, "a GET form submission through /web/f")
        st, h, b = get("/web?i=https%3A//www.gstatic.com/webp/gallery/1.webp")
        check(st == 200 and h.get("Content-Type") == "image/jpeg" and b[:2] == b"\xff\xd8", "WebP converted to JPEG")
        st, h, b = get("/web?d=https%3A//www.ietf.org/rfc/rfc1149.txt")
        check(st == 200 and "attachment" in h.get("Content-Disposition", "") and len(b) > 1000, "a download streams with attachment")
        st, h, b = get("/web?u=https%3A//www.youtube.com/watch%3Fv%3Daqz-KE-bpKQ")
        check(st == 302 and h.get("Location", "").startswith("/video?u="), "YouTube address redirects to /video")
        st, h, b = get("/web?u=https%3A//www.ietf.org/rfc/rfc1149.txt")
        check(st == 200 and b"<pre>" in b, "a text file shows as text")
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        print("  skip  network: %s" % e)

    if webproxy.RENDERER.available():
        try:
            st, h, b = get("/web?view=render&u=https%3A//example.com", timeout=120)
            check(st == 200 and b"rendered by the PC" in b and b"Example Domain" in b, "rendered view via Playwright")
            st, h, b = get("/web?view=pic&u=https%3A//example.com", timeout=120)
            check(st == 200 and b"usemap=" in b and b'<area shape="rect"' in b, "picture view has an image map")
            m = re.search(rb'/web\?p=([0-9a-f]+)&n=0', b)
            if m:
                st, h, s = get("/web?p=%s&n=0" % m.group(1).decode())
                check(st == 200 and s[:2] == b"\xff\xd8", "picture strip is a JPEG")
        except (urllib.error.URLError, socket.timeout, OSError) as e:
            print("  skip  renderer: %s" % e)
    else:
        print("  skip  Playwright not installed; rendered and picture views untested")


if __name__ == "__main__":
    offline()
    live()
    print("\n%d failure%s" % (len(FAILS), "" if len(FAILS) == 1 else "s"))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1 if FAILS else 0)
