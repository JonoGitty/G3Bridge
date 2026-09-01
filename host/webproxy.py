"""A read-only, sanitising web proxy for a machine with no internet.

The vintage Mac still has no route anywhere. It asks THIS PC for a page; the PC
fetches it, strips it down, and serves back plain HTML. Two reasons that is the
right design rather than a limitation:

  Safety   the Mac is a 20-year-old browser with no patches. Nothing executable
           reaches it: no JavaScript, no stylesheets, no iframes, no plugins,
           no remote anything. It never opens a connection to a stranger.

  Legibility  a 2026 website will not render in Safari 3 anyway. Reduced to
           headings, paragraphs, lists, tables and links, most of the web
           becomes readable on it again.

Every link is rewritten back through the proxy, so following one cannot escape
the arrangement.
"""

import html as _html
import io
import re
import urllib.parse
import urllib.request
from html.parser import HTMLParser

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120 Safari/537.36")
TIMEOUT = 20
MAX_BYTES = 4 * 1024 * 1024
MAX_IMAGE = 2 * 1024 * 1024

# Tags whose content is kept. Everything else is unwrapped (children kept) or,
# for the DROP set below, discarded entirely.
KEEP = set("""
 p br hr h1 h2 h3 h4 h5 h6 ul ol li dl dt dd blockquote pre code
 table thead tbody tfoot tr td th caption
 b strong i em u s small sup sub abbr a img figcaption
""".split())

# Discarded along with everything inside them.
DROP = set("""
 script style noscript iframe object embed applet svg canvas form input button
 select option textarea label link meta nav footer aside video audio source
 track picture map area param base template dialog
""".split())

ATTRS = {"a": ("href",), "img": ("src", "alt"),
         "td": ("colspan", "rowspan"), "th": ("colspan", "rowspan")}

# Void elements never emit an end tag. A DROP tag that is also void -- <link>,
# <meta>, <source> -- would otherwise increment the drop counter forever and
# swallow the entire rest of the document. That bug returned a 2-byte page.
VOID = set("""area base br col embed hr img input link meta param source track wbr""".split())


class Sanitiser(HTMLParser):
    def __init__(self, base_url, prefix):
        HTMLParser.__init__(self, convert_charrefs=True)
        self.base = base_url
        self.prefix = prefix            # e.g. "/web?u="
        self.out = io.StringIO()
        self.title = ""
        self._drop_depth = 0
        self._in_title = False

    # -- helpers --------------------------------------------------------
    def _abs(self, url):
        try:
            return urllib.parse.urljoin(self.base, (url or "").strip())
        except ValueError:
            return ""

    def _link(self, url):
        u = self._abs(url)
        if not u.lower().startswith(("http://", "https://")):
            return ""
        return self.prefix + urllib.parse.quote(u, safe="")

    # -- parser ---------------------------------------------------------
    def handle_starttag(self, tag, attrs):
        if tag in DROP:
            if tag not in VOID:
                self._drop_depth += 1
            return
        if self._drop_depth:
            return
        if tag == "title":
            self._in_title = True
            return
        if tag not in KEEP:
            return

        d = dict(attrs)
        if tag == "a":
            href = self._link(d.get("href"))
            if not href:
                return
            self.out.write('<a href="%s">' % _html.escape(href, quote=True))
            return
        if tag == "img":
            src = self._abs(d.get("src"))
            if not src.lower().startswith(("http://", "https://")):
                return
            alt = _html.escape(d.get("alt") or "", quote=True)[:120]
            self.out.write('<img src="/web?i=%s" alt="%s">'
                           % (urllib.parse.quote(src, safe=""), alt))
            return
        keep = ""
        for a in ATTRS.get(tag, ()):
            if a in d and (d[a] or "").isdigit():
                keep += ' %s="%s"' % (a, d[a])
        self.out.write("<%s%s>" % (tag, keep))

    def handle_endtag(self, tag):
        if tag in DROP:
            if tag not in VOID:
                self._drop_depth = max(0, self._drop_depth - 1)
            return
        if self._drop_depth:
            return
        if tag == "title":
            self._in_title = False
            return
        if tag in KEEP and tag not in ("br", "hr", "img"):
            self.out.write("</%s>" % tag)

    def handle_data(self, data):
        if self._in_title:
            self.title += data
            return
        if self._drop_depth:
            return
        self.out.write(_html.escape(data))

    def result(self):
        text = self.out.getvalue()
        text = re.sub(r"(\s*<br>\s*){3,}", "<br><br>", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text


def _get(url, limit=MAX_BYTES):
    if not url.lower().startswith(("http://", "https://")):
        raise ValueError("only http and https are proxied")
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    resp = urllib.request.urlopen(req, timeout=TIMEOUT)
    raw = resp.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("page is larger than %d bytes" % limit)
    return resp, raw


def fetch(url, prefix="/web?u="):
    """Returns (title, sanitised_html, final_url)."""
    resp, raw = _get(url)
    final = resp.geturl()
    ctype = (resp.headers.get("Content-Type") or "").lower()
    if "html" not in ctype:
        if ctype.startswith("text/"):
            return (final, "<pre>%s</pre>" % _html.escape(raw.decode("utf-8", "replace")[:200000]), final)
        raise ValueError("not a web page (%s)" % (ctype or "unknown type"))

    charset = "utf-8"
    m = re.search(r"charset=([\w-]+)", ctype)
    if m:
        charset = m.group(1)
    else:
        m = re.search(rb'charset=["\']?([\w-]+)', raw[:4000], re.I)
        if m:
            charset = m.group(1).decode("ascii", "replace")
    try:
        text = raw.decode(charset, "replace")
    except LookupError:
        text = raw.decode("utf-8", "replace")

    s = Sanitiser(final, prefix)
    try:
        s.feed(text)
    except Exception:
        pass
    return (s.title.strip() or final, s.result(), final)


def image(url):
    """Returns (content_type, bytes). Images are proxied so the Mac still never
    opens a connection to anyone but this PC."""
    resp, raw = _get(url, MAX_IMAGE)
    ctype = (resp.headers.get("Content-Type") or "application/octet-stream").split(";")[0]
    if not ctype.startswith("image/"):
        raise ValueError("not an image")
    return ctype, raw


_RESULT = re.compile(
    r'<a rel="nofollow" class="result__a" href="([^"]+)"[^>]*>(.*?)</a>', re.S)
_SNIP = re.compile(r'class="result__snippet"[^>]*>(.*?)</a>', re.S)


def search(query):
    """[(title, url, snippet)] from DuckDuckGo's no-JavaScript endpoint."""
    url = "https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(query)
    _resp, raw = _get(url)
    page = raw.decode("utf-8", "replace")

    titles = _RESULT.findall(page)
    snips = _SNIP.findall(page)

    def clean(t):
        t = re.sub(r"<[^>]+>", "", t)
        return re.sub(r"\s+", " ", _html.unescape(t)).strip()

    out = []
    for i, (href, title) in enumerate(titles[:20]):
        real = _html.unescape(href)
        # DDG wraps results in a redirect; unwrap it
        if "uddg=" in real:
            m = re.search(r"uddg=([^&]+)", real)
            if m:
                real = urllib.parse.unquote(m.group(1))
        if real.startswith("//"):
            real = "https:" + real
        snippet = clean(snips[i]) if i < len(snips) else ""
        out.append((clean(title), real, snippet[:260]))
    return out
