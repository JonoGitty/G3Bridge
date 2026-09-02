"""A headless Chromium on the PC, owned by one thread, for the pages that will
not translate from their raw HTML.

Three jobs, all on the PC side, never on the Mac:

  render(url)    run the page's JavaScript and hand back the DOM that results,
                 with hidden elements already removed and lazy images resolved.
                 This is what turns a single-page app into something the
                 translator can work with.
  picture(url)   a full-page screenshot plus the position of every link on it,
                 so the Mac can be given a clickable picture of a site that
                 cannot be translated at all.
  svg(bytes)     rasterise an SVG, which nothing in Pillow can do.

Playwright's sync API is bound to the thread that started it and the daemon
answers HTTP on many threads, so one worker thread owns the browser and everyone
else queues a job and waits. The browser is closed after IDLE_SECONDS without
work: a Chromium sitting idle for hours on someone's PC is not a good neighbour,
and relaunching costs a couple of seconds.

The Mac never sees any of this. It gets HTML, JPEG and PNG down the cable.
"""

import queue
import threading
import time
import base64

try:
    from playwright.sync_api import sync_playwright
    HAVE = True
except Exception:          # not installed, or a broken install
    sync_playwright = None
    HAVE = False

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120 Safari/537.36")
VIEWPORT_W = 980            # fits a 1024-wide CRT with the browser chrome
VIEWPORT_H = 720
IDLE_SECONDS = 300
JOB_TIMEOUT = 45
NAV_TIMEOUT_MS = 20000
SETTLE_MS = 1200            # after DOMContentLoaded, give scripts a moment
MAX_SHOT_HEIGHT = 8000

# Runs inside the page after it has settled. Removes what the page itself has
# hidden -- menus, cookie walls that were dismissed, the second and third copies
# of a responsive layout -- and pins every image to the source the browser
# actually chose, so lazy loaders and srcset are already resolved when the
# translator sees the DOM. Hidden form inputs are exempt: they are display:none
# by the browser's own stylesheet and forms do not work without them.
PRUNE_JS = r"""
() => {
  const doomed = [];
  const all = document.body ? document.body.querySelectorAll('*') : [];
  for (const el of all) {
    const tag = el.tagName;
    if (tag === 'INPUT' && (el.type || '').toLowerCase() === 'hidden') continue;
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TEMPLATE' || tag === 'NOSCRIPT') { doomed.push(el); continue; }
    const cs = window.getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') { doomed.push(el); continue; }
  }
  for (const el of doomed) { if (el.parentNode) el.parentNode.removeChild(el); }
  for (const img of document.querySelectorAll('img')) {
    const chosen = img.currentSrc || img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.src;
    if (chosen && chosen.indexOf('data:') !== 0) img.setAttribute('src', chosen);
    img.removeAttribute('srcset');
  }
  for (const a of document.querySelectorAll('a[href]')) {
    try { a.setAttribute('href', a.href); } catch (e) {}
  }
  return document.documentElement.outerHTML;
}
"""

# Every visible link and where it is on the page, in page coordinates.
BOXES_JS = r"""
() => {
  const out = [];
  for (const a of document.querySelectorAll('a[href]')) {
    const r = a.getBoundingClientRect();
    if (r.width < 3 || r.height < 3) continue;
    const href = a.href || '';
    if (!/^https?:/.test(href)) continue;
    out.push([Math.round(r.left + window.scrollX), Math.round(r.top + window.scrollY),
              Math.round(r.width), Math.round(r.height), href,
              (a.textContent || a.getAttribute('aria-label') || '').trim().slice(0, 80)]);
    if (out.length >= 1500) break;
  }
  return { boxes: out,
           w: Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0),
           h: Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0),
           title: document.title || '' };
}
"""


class _Job:
    def __init__(self, fn):
        self.fn = fn
        self.done = threading.Event()
        self.result = None
        self.error = None


_CLOSE = object()


class Renderer:
    def __init__(self):
        self._q = queue.Queue()
        self._thread = None
        self._lock = threading.Lock()
        self.launches = 0
        self.jobs = 0
        self.last_error = ""

    # -- public ---------------------------------------------------------
    def available(self):
        return HAVE

    def status(self):
        alive = self._thread is not None and self._thread.is_alive()
        return {"installed": HAVE, "worker": alive, "launches": self.launches,
                "jobs": self.jobs, "last_error": self.last_error}

    def close(self):
        """Shut the browser (the worker thread stays, idle). Used by the kill
        switch and by the idle timer."""
        if self._thread is not None and self._thread.is_alive():
            self._q.put(_CLOSE)

    def run(self, fn, timeout=JOB_TIMEOUT):
        """fn(context) runs on the worker thread with a live browser context."""
        if not HAVE:
            raise RuntimeError("Playwright is not installed on the PC "
                               "(C:\\Python310\\python.exe -m pip install playwright && playwright install chromium)")
        self._ensure_thread()
        job = _Job(fn)
        self._q.put(job)
        if not job.done.wait(timeout):
            raise TimeoutError("the renderer took longer than %ds" % timeout)
        if job.error is not None:
            raise job.error
        return job.result

    def render(self, url, cookies=None, block_images=True):
        """Returns (final_url, html, title) after the page's scripts have run."""
        def job(ctx):
            if cookies:
                try:
                    ctx.add_cookies(cookies)
                except Exception:
                    pass
            page = ctx.new_page()
            try:
                blocked = {"media", "font"} | ({"image"} if block_images else set())
                page.route("**/*", lambda r: r.abort()
                           if r.request.resource_type in blocked else r.continue_())
                page.goto(url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT_MS)
                _settle(page)
                html = page.evaluate(PRUNE_JS)
                return page.url, html, page.title()
            finally:
                page.close()
        return self.run(job)

    def picture(self, url, cookies=None, width=VIEWPORT_W):
        """Returns dict(url, title, png, boxes, w, h). png is the full page."""
        def job(ctx):
            if cookies:
                try:
                    ctx.add_cookies(cookies)
                except Exception:
                    pass
            page = ctx.new_page()
            try:
                page.set_viewport_size({"width": width, "height": VIEWPORT_H})
                page.route("**/*", lambda r: r.abort()
                           if r.request.resource_type in ("media", "font") else r.continue_())
                page.goto(url, wait_until="domcontentloaded", timeout=NAV_TIMEOUT_MS)
                _settle(page, images=True)
                info = page.evaluate(BOXES_JS)
                h = min(int(info["h"] or VIEWPORT_H), MAX_SHOT_HEIGHT)
                png = page.screenshot(full_page=True, type="png",
                                      clip={"x": 0, "y": 0, "width": width, "height": h})
                return {"url": page.url, "title": info["title"], "png": png,
                        "boxes": info["boxes"], "w": width, "h": h}
            finally:
                page.close()
        return self.run(job, timeout=JOB_TIMEOUT + 15)

    def svg(self, data, max_w=900):
        """Rasterise an SVG to PNG bytes with a transparent background."""
        def job(ctx):
            page = ctx.new_page()
            try:
                b64 = base64.b64encode(data).decode("ascii")
                page.set_content('<html><body style="margin:0;background:transparent">'
                                 '<img id="i" src="data:image/svg+xml;base64,%s"></body></html>' % b64)
                page.wait_for_selector("#i")
                size = page.evaluate("() => { const i=document.getElementById('i');"
                                     " return [i.naturalWidth||i.width||0, i.naturalHeight||i.height||0]; }")
                w = int(size[0] or 300)
                h = int(size[1] or 150)
                if w > max_w:
                    h = max(1, int(h * max_w / w))
                    w = max_w
                page.evaluate("([w,h]) => { const i=document.getElementById('i');"
                              " i.width=w; i.height=h; }", [w, h])
                return page.locator("#i").screenshot(type="png", omit_background=True)
            finally:
                page.close()
        return self.run(job, timeout=20)

    # -- worker ---------------------------------------------------------
    def _ensure_thread(self):
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._loop, name="renderer", daemon=True)
                self._thread.start()

    def _loop(self):
        pw = browser = ctx = None

        def shut():
            nonlocal pw, browser, ctx
            for closer in ((ctx.close if ctx else None), (browser.close if browser else None),
                           (pw.stop if pw else None)):
                if closer:
                    try:
                        closer()
                    except Exception:
                        pass
            pw = browser = ctx = None

        while True:
            try:
                job = self._q.get(timeout=IDLE_SECONDS)
            except queue.Empty:
                shut()
                continue
            if job is _CLOSE:
                shut()
                continue
            try:
                if browser is None or not browser.is_connected():
                    shut()
                    pw = sync_playwright().start()
                    browser = pw.chromium.launch(headless=True)
                    self.launches += 1
                if ctx is None:
                    ctx = browser.new_context(viewport={"width": VIEWPORT_W, "height": VIEWPORT_H},
                                              user_agent=UA, locale="en-GB")
                    ctx.set_default_navigation_timeout(NAV_TIMEOUT_MS)
                    ctx.set_default_timeout(NAV_TIMEOUT_MS)
                self.jobs += 1
                job.result = job.fn(ctx)
            except Exception as e:
                job.error = e
                self.last_error = "%s: %s" % (type(e).__name__, str(e)[:200])
                if browser is not None and not browser.is_connected():
                    shut()
            finally:
                job.done.set()


def _settle(page, images=False):
    """Wait for the page to become quiet, but never for long: a page that is
    still streaming ads after 8 seconds is as rendered as it is going to get."""
    try:
        page.wait_for_load_state("networkidle", timeout=8000)
    except Exception:
        pass
    page.wait_for_timeout(SETTLE_MS)
    if images:
        # Scroll through so lazy loaders fire, then back to the top.
        try:
            page.evaluate("""async () => {
              const h = document.documentElement.scrollHeight;
              for (let y = 0; y < Math.min(h, %d); y += 600) {
                window.scrollTo(0, y); await new Promise(r => setTimeout(r, 60));
              }
              window.scrollTo(0, 0);
            }""" % MAX_SHOT_HEIGHT)
            page.wait_for_timeout(500)
        except Exception:
            pass


RENDERER = Renderer()
