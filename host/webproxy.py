"""The web translation layer: the modern web, rewritten for a 2008 browser.

The vintage Mac still has no route anywhere. It asks THIS PC for a page; the PC
fetches it, translates it, and serves back HTML that Safari 3 can render.
Every link, image, form and download is rewritten back through the PC, so
following one cannot escape the arrangement. The Mac never opens a connection
to anyone else.

What "translate" means, in order of how much it matters:

  forms         a site's own search box or login form is rewritten to submit
                through /web/f, GET or POST, with a cookie jar on the PC, so
                sessions and logins persist. This is most of what "functional"
                means.
  images        proxied AND converted. Safari 3 cannot decode WebP, AVIF or
                SVG, and a 4000px JPEG takes a G4 seconds to decode, so every
                image is re-encoded to JPEG/PNG/GIF at <= 900px wide and cached
                on disk. srcset, lazy-loading attributes and <noscript>
                fallbacks are resolved.
  structure     nav, header, footer and aside are collapsed into a strip of
                links rather than dropped, so site navigation still works but
                does not fill the screen. Hidden elements are removed.
  views         full (everything, linearised), reader (main content only),
                render (the PC runs the page's JavaScript first, for
                single-page apps), and picture (a screenshot with the links as
                a clickable image map, for sites that will not translate).
                "auto" picks fetched or rendered by looking at how much text
                came back.
  media         <video>, <audio> and embeds become links to /video (the PC
                transcodes) or to a download. YouTube addresses go straight to
                /video. Downloads stream through /web?d= so the Mac can pull a
                .sit or a PDF off the web.

Nothing executable survives: no script, no stylesheet, no iframe, no plugin.
Playwright, when it is used, runs on the PC.
"""

import hashlib
import html as _html
import io
import os
import re
import threading
import time
import urllib.parse
from collections import deque
from http.cookiejar import MozillaCookieJar

import requests
import lxml.html
from lxml import etree

import config
from render import RENDERER

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120 Safari/537.36")
TIMEOUT = 20
MAX_BYTES = 6 * 1024 * 1024
MAX_IMAGE = 8 * 1024 * 1024
MAX_OUT = 420000                 # chars of translated HTML per page
IMG_MAX_W = getattr(config, "WEB_IMAGE_MAX_W", 900)
MAX_DOWNLOAD = getattr(config, "WEB_MAX_DOWNLOAD_BYTES", 64 * 1024 * 1024)
STRIP_H = 1100                   # picture mode: height of one JPEG strip
VIEWS = ("full", "reader", "render", "pic")

CACHE_DIR = os.path.join(config.RUN_DIR_ABS, "webcache")

DOWNLOAD_EXT = set("""
 zip sit sitx hqx bin dmg img toast iso pdf mp3 m4a aiff aif wav mov mp4 m4v avi
 tar gz tgz bz2 rar 7z exe msi doc xls ppt docx xlsx pptx rtf epub cbz cbr smi
 pkg mpkg app ttf otf dfont
""".split())

VIDEO_HOSTS = ("youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
               "vimeo.com", "www.vimeo.com", "player.vimeo.com")

# Sites with a lighter, JavaScript-free front door. The translator does far
# better with these, and so does the G4.
HOST_REWRITES = {
    "www.reddit.com": "old.reddit.com",
    "reddit.com": "old.reddit.com",
    "m.reddit.com": "old.reddit.com",
}

_LOCK = threading.Lock()
RECENT = deque(maxlen=12)        # (title, url, when, engine)
PICTURES = {}                    # id -> meta for picture mode
_img_writes = 0


# =====================================================================
# session: one cookie jar, on disk, shared by fetch, forms and the renderer
# =====================================================================
class _Session:
    def __init__(self):
        self.s = requests.Session()
        self.s.headers.update({
            "User-Agent": UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-GB,en;q=0.8",
        })
        self.path = os.path.join(config.RUN_DIR_ABS, "cookies.txt")
        jar = MozillaCookieJar(self.path)
        try:
            jar.load(ignore_discard=True, ignore_expires=True)
        except Exception:
            pass
        self.s.cookies = jar
        self._lock = threading.Lock()

    def save(self):
        with self._lock:
            try:
                os.makedirs(os.path.dirname(self.path), exist_ok=True)
                self.s.cookies.save(ignore_discard=True)
            except Exception:
                pass

    def open(self, url, method="GET", data=None):
        """Headers only; the body is streamed by the caller."""
        if not url.lower().startswith(("http://", "https://")):
            raise ValueError("only http and https are proxied")
        return self.s.request(method, url, data=data, stream=True, timeout=TIMEOUT,
                              allow_redirects=True)

    def body(self, resp, limit):
        buf = bytearray()
        for chunk in resp.iter_content(65536):
            buf += chunk
            if len(buf) > limit:
                resp.close()
                raise ValueError("larger than %d MB" % (limit // (1024 * 1024)))
        return bytes(buf)

    def playwright_cookies(self, url):
        """The jar, in the shape Playwright wants, for one site."""
        host = urllib.parse.urlsplit(url).hostname or ""
        out = []
        for c in self.s.cookies:
            dom = (c.domain or "").lstrip(".")
            if dom and (host == dom or host.endswith("." + dom)):
                out.append({"name": c.name, "value": c.value, "domain": c.domain,
                            "path": c.path or "/", "secure": bool(c.secure)})
        return out[:60]


SESSION = _Session()


# =====================================================================
# URL helpers
# =====================================================================
def normalise(url):
    url = (url or "").strip()
    if not url:
        raise ValueError("no address")
    if not re.match(r"^[a-z][a-z0-9+.-]*://", url, re.I):
        url = "https://" + url.lstrip("/")
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    if host in HOST_REWRITES:
        netloc = HOST_REWRITES[host]
        url = urllib.parse.urlunsplit((parts.scheme, netloc, parts.path or "/",
                                       parts.query, parts.fragment))
    return url


def is_video_url(url):
    p = urllib.parse.urlsplit(url)
    host = (p.hostname or "").lower()
    if host not in VIDEO_HOSTS:
        return False
    if host.endswith("youtube.com"):
        return p.path.startswith(("/watch", "/shorts/", "/embed/", "/v/"))
    return True


def is_download_url(url):
    path = urllib.parse.urlsplit(url).path.lower()
    ext = path.rsplit(".", 1)[-1] if "." in path.rsplit("/", 1)[-1] else ""
    return ext in DOWNLOAD_EXT


def link_for(url, view=""):
    """The /web address for a URL, choosing download or video where obvious."""
    if is_video_url(url):
        return "/video?u=" + urllib.parse.quote(url, safe="")
    if is_download_url(url):
        return "/web?d=" + urllib.parse.quote(url, safe="")
    v = "view=%s&" % view if view in ("reader", "pic", "render") else ""
    return "/web?%su=%s" % (v, urllib.parse.quote(url, safe=""))


# =====================================================================
# the translator
# =====================================================================
KEEP = set("""
 p br hr h1 h2 h3 h4 h5 h6 ul ol li dl dt dd blockquote pre code
 table thead tbody tfoot tr td th caption
 b strong i em u s small sup sub abbr tt kbd samp var cite q dfn ins del center
 div span form select option optgroup textarea label fieldset legend
""".split())

RENAME = {
    "section": "div", "article": "div", "main": "div", "figure": "div",
    "figcaption": "div", "details": "div", "hgroup": "div", "address": "div",
    "search": "div", "summary": "b", "mark": "b", "big": "b", "strike": "s",
    "acronym": "abbr", "menu": "ul", "dir": "ul", "listing": "pre", "xmp": "pre",
    "plaintext": "pre", "font": None, "nobr": None, "wbr": None, "data": None,
    "time": None, "output": None, "meter": None, "progress": None, "ruby": None,
    "rt": None, "rp": None, "bdi": None, "bdo": None, "slot": None,
}

GONE = set("""
 script style template head title link meta base param source track map area
 object embed applet canvas math dialog frameset frame noframes
""".split())

STRIPS = ("nav", "header", "footer", "aside")
# Reader view walks down from <body> while one child holds most of the text.
# It only steps INTO containers: stepping into the largest <p> would keep one
# paragraph and lose the headline, the pictures and every other paragraph.
DESCEND_INTO = set("div section article main td center form table tbody tr body span".split())

ATTRS = {
    "a": ("title",), "td": ("colspan", "rowspan"), "th": ("colspan", "rowspan"),
    "select": ("name", "multiple", "size"), "option": ("value", "selected"),
    "optgroup": ("label",), "textarea": ("name", "rows", "cols"),
    "label": ("for",), "abbr": ("title",), "ol": ("start",), "li": ("value",),
    "table": ("border",),
}
ID_TAGS = set("h1 h2 h3 h4 h5 h6 div table p li dt".split())
INPUT_TEXT = set("text search email url number tel date time month week color datetime-local".split())
HIDDEN_CLASSES = re.compile(r"\b(sr-only|visually-hidden|visuallyhidden|screen-reader-text|screen-reader-only)\b")
HIDDEN_STYLE = re.compile(r"display\s*:\s*none|visibility\s*:\s*hidden", re.I)
PLACEHOLDER_IMG = re.compile(r"(placeholder|spacer|blank\.|1x1|pixel\.|transparent\.)", re.I)
_WS = re.compile(r"\s+")
_PARSER = lxml.html.HTMLParser(huge_tree=True)
_ID_OK = re.compile(r"^[A-Za-z][\w.:-]{0,80}$")


def _esc(s):
    return _html.escape(s or "", quote=True)


def _plain(el):
    try:
        return _WS.sub(" ", el.text_content()).strip()
    except Exception:
        return ""


def _link_len(el):
    n = 0
    for a in el.iter("a"):
        n += len(_plain(a))
    return n


class Translator:
    def __init__(self, base_url, view="full"):
        self.base = base_url
        self.view = view if view in VIEWS else "full"
        self.out = []
        self.text_chars = 0
        self.notes = []
        self._pre = 0
        self.forms = 0
        self.images = 0
        self.links = 0

    # -- entry ----------------------------------------------------------
    def run(self, text):
        """Returns (title, body_html)."""
        text = re.sub(r"^\s*<\?xml[^>]*\?>", "", text)
        try:
            # huge_tree lifts libxml2's 256-level nesting cap. A page of
            # unclosed <li> or <p> tags nests one level per tag, and without
            # this everything past the cap is silently thrown away.
            doc = lxml.html.document_fromstring(text, parser=_PARSER)
        except Exception:
            doc = lxml.html.document_fromstring("<html><body><pre>%s</pre></body></html>" % _esc(text[:100000]))
        base_el = doc.find(".//base")
        if base_el is not None and base_el.get("href"):
            self.base = self._abs(base_el.get("href")) or self.base
        title = _WS.sub(" ", doc.findtext(".//title") or "").strip()
        body = doc.find("body")
        if body is None:
            body = doc
        root = body
        if self.view == "reader":
            root = self._content_root(body)
            self._thin_link_boxes(root)
            if root.find(".//h1") is None and title:
                self.out.append("<h1>%s</h1>" % _esc(title))
        self._walk(root)
        return title, self._finish()

    # -- helpers --------------------------------------------------------
    def _abs(self, url):
        try:
            return urllib.parse.urljoin(self.base, (url or "").strip())
        except ValueError:
            return ""

    def _http(self, url):
        u = self._abs(url)
        return u if u.lower().startswith(("http://", "https://")) else ""

    def _text(self, s):
        if not s:
            return
        if self._pre:
            self.out.append(_html.escape(s))
            self.text_chars += len(s)
            return
        s = _WS.sub(" ", s)
        if s == " ":
            if self.out and not self.out[-1].endswith((" ", ">")):
                self.out.append(" ")
            return
        self.text_chars += len(s.strip())
        self.out.append(_html.escape(s))

    def _hidden(self, node):
        a = node.attrib
        if "hidden" in a and node.tag != "input":
            return True
        if a.get("aria-hidden") == "true":
            return True
        st = a.get("style")
        if st and HIDDEN_STYLE.search(st):
            return True
        cls = a.get("class")
        if cls and HIDDEN_CLASSES.search(cls):
            return True
        return False

    # -- walking (iterative: real pages nest deeper than Python recurses) --
    def _walk(self, root):
        stack = [("open", root)]
        while stack:
            kind, item = stack.pop()
            if kind == "close":
                closing, pre = item
                if pre:
                    self._pre -= 1
                self.out.append(closing)
            elif kind == "tail":
                self._text(item.tail)
            else:
                node = item
                r = self._enter(node)
                if r is None:
                    continue
                closing, pre, children = r
                if pre:
                    self._pre += 1
                self._text(node.text)
                stack.append(("close", (closing, pre)))
                if children:
                    for child in reversed(list(node)):
                        stack.append(("tail", child))
                        stack.append(("open", child))

    def _enter(self, node):
        tag = node.tag
        if not isinstance(tag, str):
            return None                      # comment or processing instruction
        tag = tag.lower()
        if tag in GONE:
            return None
        if self._hidden(node):
            return None
        if tag == "noscript" or tag == "picture":
            return ("", False, True)         # what a browser without scripts should see
        if tag == "iframe":
            self._embed(node)
            return None
        if tag in ("video", "audio"):
            self._media(node, tag)
            return None
        if tag == "svg":
            t = node.findtext(".//title") or node.findtext(".//{http://www.w3.org/2000/svg}title")
            if t and t.strip():
                self.out.append("<span>%s</span>" % _esc(t.strip()[:80]))
            return None
        if tag in STRIPS:
            if self.view != "reader":
                self._strip(node)
            return None
        if tag == "a":
            return self._anchor(node)
        if tag == "img":
            self._img(node)
            return None
        if tag == "form":
            return self._form(node)
        if tag == "input":
            self._input(node)
            return None
        if tag == "button":
            self._button(node)
            return None
        if tag in RENAME:
            new = RENAME[tag]
            if new is None:
                return ("", False, True)
            tag = new
        if tag not in KEEP:
            return ("", False, True)         # unknown or custom element: keep its children
        if tag in ("br", "hr"):
            self.out.append("<%s>" % tag)
            return ("", False, False)
        attrs = self._attrs(tag, node)
        self.out.append("<%s%s>" % (tag, attrs))
        return ("</%s>" % tag, tag in ("pre", "textarea"), True)

    def _attrs(self, tag, node):
        keep = ""
        for a in ATTRS.get(tag, ()):
            v = node.get(a)
            if v is None:
                continue
            if a in ("colspan", "rowspan", "size", "rows", "cols", "start", "value", "border"):
                if not v.isdigit():
                    continue
            elif a in ("multiple", "selected"):
                keep += " " + a
                continue
            keep += ' %s="%s"' % (a, _esc(v[:200]))
        if tag in ID_TAGS:
            i = node.get("id")
            if i and _ID_OK.match(i):
                keep += ' id="%s"' % _esc(i)
        return keep

    # -- links ----------------------------------------------------------
    def _anchor(self, node):
        href = (node.get("href") or "").strip()
        ident = node.get("id") or node.get("name")
        idattr = ' id="%s"' % _esc(ident) if ident and _ID_OK.match(ident) else ""
        if href.startswith("#"):
            target = href if _ID_OK.match(href[1:]) else ""
        else:
            u = self._http(href)
            target = link_for(u, self.view) if u else ""
        if not target:
            if idattr:
                self.out.append("<a%s>" % idattr)
                return ("</a>", False, True)
            return ("", False, True)
        title = node.get("title")
        t = ' title="%s"' % _esc(title[:160]) if title else ""
        self.links += 1
        self.out.append('<a href="%s"%s%s>' % (_esc(target), idattr, t))
        return ("</a>", False, True)

    # -- images ---------------------------------------------------------
    def _pick_src(self, node):
        src = (node.get("src") or "").strip()
        lazy = ""
        for key in ("data-src", "data-lazy-src", "data-original", "data-url", "data-hi-res-src"):
            v = (node.get(key) or "").strip()
            if v and not v.startswith("data:"):
                lazy = v
                break
        if src.startswith("data:") or not src or PLACEHOLDER_IMG.search(src):
            src = lazy or ""
        if not src:
            srcset = node.get("srcset") or node.get("data-srcset") or ""
            best, best_w = "", 10 ** 9
            for cand in srcset.split(","):
                bits = cand.strip().split()
                if not bits:
                    continue
                w = 10 ** 8
                if len(bits) > 1 and bits[1].endswith("w") and bits[1][:-1].isdigit():
                    w = int(bits[1][:-1])
                # the smallest candidate that is still at least 600 wide
                key = (0 if w >= 600 else 1, w if w >= 600 else -w)
                if best == "" or key < best_w:
                    best, best_w = bits[0], key
            src = best
        return src

    def _img(self, node):
        src = self._http(self._pick_src(node))
        if not src:
            return
        w, h = node.get("width") or "", node.get("height") or ""
        dims = ""
        if w.isdigit() and h.isdigit():
            w, h = int(w), int(h)
            if w <= 2 or h <= 2:
                return                       # a tracking pixel
            if w <= IMG_MAX_W:
                dims = ' width="%d" height="%d"' % (w, h)
        alt = _esc((node.get("alt") or "")[:160])
        self.images += 1
        self.out.append('<img src="/web?i=%s" alt="%s"%s>'
                        % (urllib.parse.quote(src, safe=""), alt, dims))

    # -- media and embeds -----------------------------------------------
    def _embed(self, node):
        src = self._http(node.get("src") or node.get("data-src"))
        if not src:
            return
        if is_video_url(src):
            self.out.append('<div class="embed">Embedded video &mdash; <a href="%s">play it via the PC</a></div>'
                            % _esc(link_for(src)))
        else:
            host = urllib.parse.urlsplit(src).hostname or src
            self.out.append('<div class="embed">Embedded page from %s &mdash; <a href="%s">open it</a></div>'
                            % (_esc(host), _esc(link_for(src, self.view))))

    def _media(self, node, tag):
        src = node.get("src") or node.get("data-src") or ""
        if not src:
            for s in node.iter("source"):
                src = s.get("src") or s.get("data-src") or ""
                if src:
                    break
        src = self._http(src)
        poster = self._http(node.get("poster")) if tag == "video" else ""
        if poster:
            self.out.append('<img src="/web?i=%s" alt="video">' % urllib.parse.quote(poster, safe=""))
        if not src:
            self.out.append('<div class="embed">%s (no address the PC can fetch)</div>' % tag.capitalize())
            return
        dl = "/web?d=" + urllib.parse.quote(src, safe="")
        if tag == "video":
            self.out.append('<div class="embed">Video &mdash; <a href="/video?u=%s">play it via the PC</a>'
                            ' &middot; <a href="%s">download</a></div>'
                            % (urllib.parse.quote(src, safe=""), _esc(dl)))
        else:
            self.out.append('<div class="embed">Audio &mdash; <a href="%s">download</a> (QuickTime plays it)</div>'
                            % _esc(dl))

    # -- navigation strips ----------------------------------------------
    def _strip(self, node):
        seen, links = set(), []
        for a in node.iter("a"):
            href = (a.get("href") or "").strip()
            if href.startswith("#"):
                continue
            u = self._http(href)
            if not u:
                continue
            target = link_for(u, self.view)
            if target in seen:
                continue
            label = _plain(a)
            if not label:
                img = a.find(".//img")
                label = (img.get("alt") or "").strip() if img is not None else ""
            if not label:
                path = urllib.parse.urlsplit(u).path.rstrip("/")
                label = path.rsplit("/", 1)[-1] or (urllib.parse.urlsplit(u).hostname or "")
            label = label[:40]
            if not label:
                continue
            seen.add(target)
            links.append('<a href="%s">%s</a>' % (_esc(target), _esc(label)))
            if len(links) >= 60:
                break
        forms = [f for f in node.iter("form")]
        if not links and not forms:
            return
        self.out.append('<div class="strip">')
        if links:
            self.out.append(" &middot; ".join(links))
        for f in forms:
            self._walk(f)
        self.out.append("</div>")

    # -- forms ----------------------------------------------------------
    def _form(self, node):
        action = self._http(node.get("action") or self.base)
        if not action:
            return ("", False, True)
        method = "post" if (node.get("method") or "").lower() == "post" else "get"
        self.forms += 1
        self.out.append('<form action="/web/f" method="%s">'
                        '<input type="hidden" name="_u" value="%s">'
                        '<input type="hidden" name="_m" value="%s">'
                        '<input type="hidden" name="_v" value="%s">'
                        % (method, _esc(action), method, self.view))
        return ("</form>", False, True)

    def _input(self, node):
        t = (node.get("type") or "text").lower()
        name = node.get("name") or ""
        value = node.get("value")
        if t in INPUT_TEXT:
            t = "text"
        if t in ("file", "reset", "button", "range"):
            return
        if t == "image":
            t, value = "submit", (node.get("alt") or "Go")
        if t == "hidden":
            if not name:
                return
            self.out.append('<input type="hidden" name="%s" value="%s">' % (_esc(name), _esc(value or "")))
            return
        if t not in ("text", "password", "checkbox", "radio", "submit"):
            t = "text"
        attrs = ' type="%s"' % t
        if name:
            attrs += ' name="%s"' % _esc(name)
        if value is not None:
            attrs += ' value="%s"' % _esc(value[:500])
        elif t == "submit":
            attrs += ' value="Go"'
        if t in ("checkbox", "radio") and node.get("checked") is not None:
            attrs += " checked"
        for a in ("size", "maxlength"):
            v = node.get(a)
            if v and v.isdigit():
                attrs += ' %s="%s"' % (a, v)
        ph = node.get("placeholder") or node.get("aria-label")
        if ph and t in ("text", "password"):
            attrs += ' title="%s"' % _esc(ph[:80])
        self.out.append("<input%s>" % attrs)

    def _button(self, node):
        t = (node.get("type") or "submit").lower()
        label = _plain(node) or node.get("value") or node.get("aria-label") or ""
        if t != "submit":
            return                            # a JavaScript button does nothing here
        name = node.get("name") or ""
        value = node.get("value")
        attrs = ' type="submit"'
        if name:
            attrs += ' name="%s"' % _esc(name)
            attrs += ' value="%s"' % _esc((value if value is not None else label)[:200])
        else:
            attrs += ' value="%s"' % _esc((label or "Go")[:80])
        self.out.append("<input%s>" % attrs)

    # -- reader view ----------------------------------------------------
    def _content_root(self, body):
        def own(el):
            return len(_plain(el)) - _link_len(el)

        body_own = max(own(body), 1)
        arts = [a for a in body.iter("article")]
        if arts:
            best = max(arts, key=own)
            if own(best) >= 0.3 * body_own:
                return self._descend(best)
        main = body.find(".//main")
        if main is not None and own(main) >= 0.3 * body_own:
            return self._descend(main)
        return self._descend(body)

    def _descend(self, node):
        def own(el):
            return len(_plain(el)) - _link_len(el)
        for _ in range(14):
            total = own(node)
            if total <= 0:
                break
            best, best_own = None, 0
            for child in node:
                if not isinstance(child.tag, str):
                    continue
                if child.tag in STRIPS or child.tag in GONE or child.tag not in DESCEND_INTO:
                    continue
                c = own(child)
                if c > best_own:
                    best, best_own = child, c
            if best is not None and best_own >= 0.6 * total:
                node = best
            else:
                break
        return node

    def _thin_link_boxes(self, root):
        """Related-links boxes, tag clouds, share bars: mostly links, little text."""
        doomed = []
        for el in root.iter("ul", "ol", "div", "table"):
            if el is root:
                continue
            n_links = sum(1 for _ in el.iter("a"))
            if n_links < 4:
                continue
            plain = len(_plain(el))
            if plain and _link_len(el) / float(plain) > 0.75 and plain - _link_len(el) < 300:
                doomed.append(el)
        for el in doomed:
            parent = el.getparent()
            if parent is not None:
                parent.remove(el)

    # -- output ---------------------------------------------------------
    def _finish(self):
        s = "".join(self.out)
        empty = r"<(div|span|p|li|ul|ol|b|i|em|strong|small|center|blockquote|label|form)(?: [^>]*)?>\s*</\1>"
        for _ in range(4):
            s2 = re.sub(empty, "", s)
            if s2 == s:
                break
            s = s2
        s = re.sub(r"(?:\s*<br>\s*){3,}", "<br><br>", s)
        s = re.sub(r"(?:\s*<hr>\s*){2,}", "<hr>", s)
        if len(s) > MAX_OUT:
            cut = s.rfind("<", 0, MAX_OUT)
            s = s[:cut] + ('<p class="warn">[The PC stopped here: the page went past %d KB '
                           'of text, which is more than this machine should be asked to lay out.]</p>'
                           % (MAX_OUT // 1000))
            self.notes.append("truncated")
        return s


# =====================================================================
# fetching
# =====================================================================
class Page:
    def __init__(self, **kw):
        self.kind = "page"        # page | file | image | video | text
        self.title = ""
        self.body = ""
        self.url = ""
        self.engine = "fetched"
        self.elapsed = 0.0
        self.notes = []
        self.ctype = ""
        self.size = -1
        self.view = "full"
        self.forms = self.images = self.links = 0
        self.__dict__.update(kw)


def _decode(raw, ctype):
    enc = None
    m = re.search(r'charset=["\']?([\w-]+)', ctype or "", re.I)
    if m:
        enc = m.group(1)
    if not enc:
        m = re.search(rb'<meta[^>]+charset=["\']?([\w-]+)', raw[:8000], re.I)
        if m:
            enc = m.group(1).decode("ascii", "replace")
    if enc:
        try:
            return raw.decode(enc, "replace")
        except LookupError:
            pass
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        pass
    try:
        from charset_normalizer import from_bytes
        best = from_bytes(raw[:200000]).best()
        if best is not None and best.encoding:
            return raw.decode(best.encoding, "replace")
    except Exception:
        pass
    return raw.decode("utf-8", "replace")


def _translate(text, final, view):
    t = Translator(final, view)
    title, body = t.run(text)
    return Page(kind="page", title=title or final, body=body, url=final, view=t.view,
                notes=t.notes, forms=t.forms, images=t.images, links=t.links,
                text_chars=t.text_chars)


def _looks_thin(page, raw_len):
    if page.text_chars >= 600:
        return False
    if raw_len > 12000:
        return True
    low = page.body.lower()
    return ("enable javascript" in low or "javascript is required" in low
            or "requires javascript" in low or "javascript is disabled" in low)


def _rendered(url, view):
    final, html_text, title = RENDERER.render(url, SESSION.playwright_cookies(url))
    page = _translate(html_text, final, "reader" if view == "reader" else "full")
    page.engine = "rendered"
    if title and (not page.title or page.title == final):
        page.title = title
    return page


def _exchange(url, method="GET", data=None, view="full", t0=None):
    """One HTTP exchange, translated. Shared by fetch() and submit()."""
    t0 = t0 or time.time()
    resp = SESSION.open(url, method, data)
    final = resp.url
    ctype = (resp.headers.get("Content-Type") or "").lower()
    kind = ctype.split(";")[0].strip()
    textual = (kind.startswith("text/") or kind in ("", "application/xhtml+xml", "application/json",
               "application/xml", "application/javascript", "application/x-javascript")
               or kind.endswith(("+xml", "+json")))
    if "html" not in kind and not textual:
        size = int(resp.headers.get("Content-Length") or -1)
        resp.close()
        if kind.startswith("image/"):
            return Page(kind="image", url=final, title=final.rsplit("/", 1)[-1] or final,
                        ctype=kind, size=size, elapsed=time.time() - t0)
        return Page(kind="file", url=final, title=final.rsplit("/", 1)[-1] or final,
                    ctype=kind, size=size, elapsed=time.time() - t0)
    raw = SESSION.body(resp, MAX_BYTES)
    SESSION.save()
    if "html" not in kind and kind != "application/xhtml+xml" and kind != "":
        # plain text, JSON, XML: shown as-is in a <pre>
        text = _decode(raw, ctype)
        return Page(kind="page", title=final, url=final, engine="fetched",
                    body="<pre>%s</pre>" % _html.escape(text[:200000]), elapsed=time.time() - t0)
    text = _decode(raw, ctype)
    page = _translate(text, final, view)
    page.engine = "fetched"
    if view == "" and _looks_thin(page, len(raw)) and RENDERER.available() \
            and getattr(config, "WEB_RENDER", True):
        try:
            page = _rendered(final, view)
            page.notes.append("the plain fetch came back nearly empty, so the PC ran the page's scripts")
        except Exception as e:
            page.notes.append("this page wanted JavaScript and the renderer failed: %s" % str(e)[:120])
    page.elapsed = time.time() - t0
    return page


def fetch(url, view=""):
    """The main entry. view: '' (auto) | full | reader | render."""
    t0 = time.time()
    url = normalise(url)
    if is_video_url(url):
        return Page(kind="video", url=url, title=url, elapsed=0)
    if view == "render":
        try:
            page = _rendered(url, view)
            page.elapsed = time.time() - t0
            return page
        except Exception as e:
            page = _exchange(url, view="full", t0=t0)
            page.notes.append("the renderer failed (%s), so this is the plain fetch" % str(e)[:120])
            return page
    return _exchange(url, view=view, t0=t0)


def submit(action, method, fields, view=""):
    """A form the Mac filled in. fields is {name: [values]}."""
    action = normalise(action)
    flat = [(k, v) for k, vs in fields.items() for v in vs]
    if method.lower() == "post":
        return _exchange(action, "POST", flat, view=view)
    parts = urllib.parse.urlsplit(action)
    target = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path,
                                      urllib.parse.urlencode(flat), ""))
    return _exchange(target, view=view)


def remember(page):
    with _LOCK:
        for i, (t, u, w, e) in enumerate(list(RECENT)):
            if u == page.url:
                del RECENT[i]
                break
        RECENT.appendleft((page.title[:80], page.url, time.time(), page.engine))


def recent():
    with _LOCK:
        return list(RECENT)


def shutdown():
    RENDERER.close()


# =====================================================================
# images: proxied, converted, cached
# =====================================================================
BLANK_GIF = (b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,"
             b"\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")


def _cache_path(sub, key, ext):
    d = os.path.join(CACHE_DIR, sub)
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, key + "." + ext)


def _evict(sub, keep=1500):
    d = os.path.join(CACHE_DIR, sub)
    try:
        names = os.listdir(d)
    except OSError:
        return
    if len(names) <= keep:
        return
    paths = sorted((os.path.getmtime(os.path.join(d, n)), n) for n in names)
    for _m, n in paths[: len(names) - keep]:
        try:
            os.remove(os.path.join(d, n))
        except OSError:
            pass


def image(url):
    """Returns (content_type, bytes) in a format Safari 3 decodes, no wider
    than IMG_MAX_W. Cached on disk under run/webcache/img."""
    global _img_writes
    key = hashlib.sha1(url.encode("utf-8", "replace")).hexdigest()
    for ext, ct in (("jpg", "image/jpeg"), ("png", "image/png"), ("gif", "image/gif")):
        p = os.path.join(CACHE_DIR, "img", key + "." + ext)
        if os.path.isfile(p):
            with open(p, "rb") as f:
                return ct, f.read()

    resp = SESSION.open(url)
    ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip().lower()
    raw = SESSION.body(resp, MAX_IMAGE)
    if not ctype.startswith("image/") and not is_image_bytes(raw):
        raise ValueError("not an image (%s)" % (ctype or "unknown type"))

    ext, ct, data = _convert(raw, ctype)
    with open(_cache_path("img", key, ext), "wb") as f:
        f.write(data)
    _img_writes += 1
    if _img_writes % 200 == 0:
        _evict("img")
    return ct, data


def is_image_bytes(raw):
    return raw[:4] in (b"\x89PNG", b"GIF8", b"RIFF") or raw[:2] == b"\xff\xd8" \
        or b"<svg" in raw[:600].lower()


def _convert(raw, ctype):
    from PIL import Image
    if b"<svg" in raw[:600].lower() or "svg" in ctype:
        if RENDERER.available():
            try:
                return "png", "image/png", RENDERER.svg(raw, IMG_MAX_W)
            except Exception:
                pass
        return "gif", "image/gif", BLANK_GIF
    if ctype == "image/gif" or raw[:4] == b"GIF8":
        return "gif", "image/gif", raw          # animated GIFs stay animated
    try:
        im = Image.open(io.BytesIO(raw))
        im.load()
    except Exception:
        return "gif", "image/gif", BLANK_GIF
    if im.width > IMG_MAX_W:
        im.thumbnail((IMG_MAX_W, IMG_MAX_W * 6))
    alpha = im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info)
    small_png = (ctype == "image/png" or raw[:4] == b"\x89PNG") and im.width <= 400
    buf = io.BytesIO()
    if alpha or small_png:
        im.convert("RGBA" if alpha else "RGB").save(buf, "PNG", optimize=True)
        return "png", "image/png", buf.getvalue()
    im.convert("RGB").save(buf, "JPEG", quality=72, optimize=True)
    return "jpg", "image/jpeg", buf.getvalue()


# =====================================================================
# downloads: streamed through the PC with a byte cap
# =====================================================================
def download(url):
    """Returns (response, filename, size, content_type). Caller streams
    response.iter_content and closes it."""
    url = normalise(url)
    resp = SESSION.open(url)
    ctype = (resp.headers.get("Content-Type") or "application/octet-stream").split(";")[0].strip()
    size = int(resp.headers.get("Content-Length") or -1)
    if size > MAX_DOWNLOAD:
        resp.close()
        raise ValueError("%d MB is over the %d MB limit" % (size // 2 ** 20, MAX_DOWNLOAD // 2 ** 20))
    name = ""
    cd = resp.headers.get("Content-Disposition") or ""
    m = re.search(r"filename\*=(?:UTF-8|utf-8)''([^;]+)", cd) or re.search(r'filename="?([^";]+)"?', cd)
    if m:
        name = urllib.parse.unquote(m.group(1)).strip()
    if not name:
        name = urllib.parse.unquote(urllib.parse.urlsplit(resp.url).path.rsplit("/", 1)[-1])
    name = re.sub(r"[^\w.\- ()]+", "_", name).strip("._ ") or "download"
    return resp, name[:120], size, ctype


# =====================================================================
# picture mode: a screenshot the Mac can click on
# =====================================================================
def picture(url):
    """Renders url on the PC and slices the screenshot into JPEG strips with an
    image map of every link. Returns the picture id; strips come from strip()."""
    from PIL import Image
    url = normalise(url)
    info = RENDERER.picture(url, SESSION.playwright_cookies(url))
    pid = hashlib.sha1(("%s|%f" % (url, time.time())).encode()).hexdigest()[:12]
    im = Image.open(io.BytesIO(info["png"]))
    im.load()
    w, h = im.size
    strips = []
    d = os.path.join(CACHE_DIR, "pic", pid)
    os.makedirs(d, exist_ok=True)
    n = 0
    for top in range(0, h, STRIP_H):
        bottom = min(h, top + STRIP_H)
        part = im.crop((0, top, w, bottom)).convert("RGB")
        with open(os.path.join(d, "%d.jpg" % n), "wb") as f:
            part.save(f, "JPEG", quality=66, optimize=True)
        areas = []
        for (x, y, bw, bh, href, label) in info["boxes"]:
            if y >= bottom or y + bh <= top:
                continue
            y1 = max(0, y - top)
            y2 = min(bottom - top, y - top + bh)
            areas.append((x, y1, x + bw, y2, href, label))
            if len(areas) >= 400:
                break
        strips.append({"n": n, "w": w, "h": bottom - top, "areas": areas})
        n += 1
    meta = {"id": pid, "url": info["url"], "title": info["title"] or info["url"],
            "strips": strips, "w": w, "h": h, "when": time.time()}
    with _LOCK:
        PICTURES[pid] = meta
        if len(PICTURES) > 24:
            oldest = min(PICTURES, key=lambda k: PICTURES[k]["when"])
            PICTURES.pop(oldest, None)
    return meta


def strip(pid, n):
    p = os.path.join(CACHE_DIR, "pic", re.sub(r"[^0-9a-f]", "", pid)[:12], "%d.jpg" % int(n))
    with open(p, "rb") as f:
        return f.read()


# =====================================================================
# search
# =====================================================================
_RESULT = re.compile(
    r'<a rel="nofollow" class="result__a" href="([^"]+)"[^>]*>(.*?)</a>', re.S)
_SNIP = re.compile(r'class="result__snippet"[^>]*>(.*?)</a>', re.S)


def search(query):
    """[(title, url, snippet)] from DuckDuckGo's no-JavaScript endpoint."""
    url = "https://html.duckduckgo.com/html/?q=" + urllib.parse.quote(query)
    resp = SESSION.open(url)
    raw = SESSION.body(resp, MAX_BYTES)
    page = raw.decode("utf-8", "replace")

    titles = _RESULT.findall(page)
    snips = _SNIP.findall(page)

    def clean(t):
        t = re.sub(r"<[^>]+>", "", t)
        return re.sub(r"\s+", " ", _html.unescape(t)).strip()

    out = []
    for i, (href, title) in enumerate(titles[:20]):
        real = _html.unescape(href)
        if "uddg=" in real:
            m = re.search(r"uddg=([^&]+)", real)
            if m:
                real = urllib.parse.unquote(m.group(1))
        if real.startswith("//"):
            real = "https:" + real
        snippet = clean(snips[i]) if i < len(snips) else ""
        out.append((clean(title), real, snippet[:260]))
    return out
