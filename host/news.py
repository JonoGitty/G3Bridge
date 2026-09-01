"""News for a machine that has no internet.

The PC fetches RSS over its own connection and serves the result to the
vintage Mac over the cable. The Mac never makes an outbound request to
anything except this bridge -- which is the whole point of the arrangement.

Feeds are fetched in a background thread on a TTL, so a page load never waits
on the network. A feed that fails keeps serving its last good copy and says so.
"""

import re
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET

TTL = 600.0            # seconds before a feed is considered stale
TIMEOUT = 12.0
PER_FEED = 9           # headlines kept per feed

FEEDS = [
    ("top",     "Top stories",  "https://feeds.bbci.co.uk/news/rss.xml"),
    ("world",   "World",        "https://feeds.bbci.co.uk/news/world/rss.xml"),
    ("uk",      "UK",           "https://www.theguardian.com/uk-news/rss"),
    ("tech",    "Technology",   "https://feeds.bbci.co.uk/news/technology/rss.xml"),
    ("science", "Science",      "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml"),
    ("hn",      "Hacker News",  "https://news.ycombinator.com/rss"),
    ("ars",     "Ars Technica", "https://feeds.arstechnica.com/arstechnica/index"),
    ("sky",     "Sky News",     "https://feeds.skynews.com/feeds/rss/home.xml"),
]

_lock = threading.Lock()
_cache = {}            # key -> {"items":[...], "fetched":ts, "error":str|None}
_thread = None

_TAG = re.compile(r"<[^>]+>")
_WS = re.compile(r"\s+")


def _clean(text, limit=240):
    if not text:
        return ""
    text = _TAG.sub(" ", text)
    for a, b in (("&amp;", "&"), ("&quot;", '"'), ("&#39;", "'"),
                 ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&apos;", "'")):
        text = text.replace(a, b)
    text = _WS.sub(" ", text).strip()
    if len(text) > limit:
        cut = text[:limit].rsplit(" ", 1)[0]
        text = cut + "..."
    return text


def _parse_date(text):
    """RSS dates come in several shapes. Return epoch seconds, or 0."""
    if not text:
        return 0
    text = text.strip()
    for fmt in ("%a, %d %b %Y %H:%M:%S %z", "%a, %d %b %Y %H:%M:%S %Z",
                "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%a, %d %b %Y %H:%M %z"):
        try:
            import datetime
            dt = datetime.datetime.strptime(text.replace("GMT", "+0000"), fmt)
            return dt.timestamp()
        except (ValueError, OverflowError):
            continue
    return 0


def _fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "G3Bridge/0.1 (vintage Mac bridge)"})
    raw = urllib.request.urlopen(req, timeout=TIMEOUT).read()
    root = ET.fromstring(raw)

    nodes = root.findall(".//item")
    atom = "{http://www.w3.org/2005/Atom}"
    if not nodes:
        nodes = root.findall(".//" + atom + "entry")

    items = []
    for n in nodes[:PER_FEED]:
        title = n.findtext("title") or n.findtext(atom + "title") or ""
        desc = (n.findtext("description") or n.findtext(atom + "summary")
                or n.findtext(atom + "content") or "")
        when = (n.findtext("pubDate") or n.findtext(atom + "updated")
                or n.findtext(atom + "published") or "")
        items.append({
            "title": _clean(title, 160),
            "summary": _clean(desc, 230),
            "ts": _parse_date(when),
        })
    return items


def refresh(force=False):
    """Fetch anything stale. Safe to call often."""
    now = time.time()
    for key, _label, url in FEEDS:
        with _lock:
            entry = _cache.get(key)
            fresh = entry and (now - entry["fetched"]) < TTL and entry.get("items")
        if fresh and not force:
            continue
        try:
            items = _fetch(url)
            with _lock:
                _cache[key] = {"items": items, "fetched": time.time(), "error": None}
        except Exception as e:
            with _lock:
                prev = _cache.get(key) or {"items": [], "fetched": 0}
                prev["error"] = "%s: %s" % (type(e).__name__, str(e)[:80])
                # keep whatever we had; a stale headline beats an empty page
                _cache[key] = prev


def start_background():
    """Keep the cache warm so a page load never waits on the network."""
    global _thread
    if _thread is not None:
        return

    def loop():
        while True:
            try:
                refresh()
            except Exception:
                pass
            time.sleep(120)

    _thread = threading.Thread(target=loop, name="news", daemon=True)
    _thread.start()


def sections():
    """[(key, label, items, age_seconds, error)] in FEEDS order."""
    now = time.time()
    out = []
    with _lock:
        for key, label, _url in FEEDS:
            e = _cache.get(key)
            if not e:
                out.append((key, label, [], None, None))
            else:
                age = now - e["fetched"] if e["fetched"] else None
                out.append((key, label, e["items"], age, e.get("error")))
    return out


def ago(ts):
    if not ts:
        return ""
    d = time.time() - ts
    if d < 0:
        return "just now"
    if d < 3600:
        return "%dm ago" % int(d / 60)
    if d < 86400:
        return "%dh ago" % int(d / 3600)
    return "%dd ago" % int(d / 86400)
