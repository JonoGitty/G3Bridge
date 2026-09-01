"""HTML for the bridge.

Written for Safari 3 on Mac OS X 10.5 (2008). That means CSS2 only:
no flexbox, no border-radius, no box-shadow, no transitions, no gradients.
Layout is floats and tables. Fonts are limited to what ships on that machine.

Kept separate from g3d.py so the daemon stays about plumbing.
"""

import html
import os
import re
import time

CSS = """
 body { background:#0d1117; color:#e6edf3; margin:0;
        font:14px/1.55 "Lucida Grande",Geneva,Verdana,sans-serif; }
 a    { color:#58c8ff; text-decoration:none; }
 a:hover { text-decoration:underline; }
 .wrap{ padding:22px 30px 60px; }
 .bar { background:#161b26; border-bottom:1px solid #2b3550; padding:10px 30px; }
 .bar a { margin-right:20px; font-size:13px; color:#9fb3cc; }
 .bar a.on { color:#ffc23d; font-weight:bold; }
 .bar span.t { color:#4d5b73; font-size:12px; float:right; }
 h1   { font-size:25px; font-weight:normal; margin:0 0 3px; color:#58c8ff; }
 .sub { color:#7d8da5; font-size:12px; margin:0 0 24px; }
 h2   { font-size:13px; font-weight:normal; color:#ffc23d; margin:26px 0 8px;
        text-transform:uppercase; letter-spacing:.09em;
        border-bottom:1px solid #2b3550; padding-bottom:5px; }
 .col { width:48%; float:left; margin-right:2%; }
 .clr { clear:both; }
 .card{ border:1px solid #2b3550; background:#131926; padding:14px 16px;
        margin:0 0 14px; }
 .card h3 { margin:0 0 4px; font-size:16px; font-weight:normal; }
 .card p  { margin:0; color:#8b9bb4; font-size:12px; }
 .item{ margin:0 0 13px; }
 .item .h { font-size:13px; color:#e6edf3; }
 .item .s { color:#7d8da5; font-size:12px; margin-top:2px; }
 .item .w { color:#4d5b73; font-size:11px; }
 .warn{ color:#ff9d68; font-size:12px; }
 .ok  { color:#3ea55f; }
 tt   { color:#d8e2f0; font-family:Monaco,"Courier New",monospace; }
 .cmd { background:#000; color:#7dff9b; border:2px solid #ffc23d; padding:12px 14px;
        font:bold 15px Monaco,"Courier New",monospace; margin:10px 0; }
"""


def _shell(title, current, body, note=""):
    tabs = [("/", "Home"), ("/news", "News"), ("/games", "Games"),
            ("/web", "Web"), ("/claude-screen", "Claude"), ("/display", "Display"),
            ("/files", "Files"), ("/setup", "Setup")]
    nav = ""
    for href, label in tabs:
        cls = ' class="on"' if href == current else ""
        nav += '<a href="%s"%s>%s</a>' % (href, cls, label)
    return ("<html><head><title>%s</title><style type=\"text/css\">%s</style></head>"
            "<body><div class=\"bar\">%s<span class=\"t\">%s</span></div>"
            "<div class=\"wrap\">%s</div></body></html>"
            % (html.escape(title), CSS, nav, note or time.strftime("%a %d %b, %H:%M"), body))


# ---------------------------------------------------------------- home
def index_page(dev, games, news_ready):
    e = dev.enrolled
    who = ""
    if e:
        who = ("Enrolled as <tt>%s</tt> &middot; %s &middot; %s"
               % (html.escape(e.get("user", "?")), html.escape(e.get("os", "?")),
                  html.escape(e.get("model", "?"))))
    else:
        who = "Not yet enrolled &mdash; see <a href=\"/setup\">Setup</a>."

    cards = [
        ("/news", "News",
         "Today's headlines. Fetched by the PC over its own connection and served "
         "to you down the cable &mdash; this machine never touches the internet."),
        ("/games", "Games",
         "%d game%s, written to run on this browser. Keyboard controls, nothing to install."
         % (len(games), "" if len(games) == 1 else "s")),
        ("/web", "Web",
         "Search and browse the internet <i>through the PC</i>. It fetches the page, "
         "strips every script and remote resource, and sends back plain readable "
         "HTML. This machine still opens no connection to anyone but the PC."),
        ("/claude-screen", "Claude's screen",
         "Whatever Claude has published for this machine to display."),
        ("/display", "Display",
         "What Claude is drawing on this machine's canvas, %dx%d. Click the picture "
         "to send the coordinates back to the PC." % (dev.canvas[0], dev.canvas[1])),
        ("/files", "Files",
         "Collect files the PC has put out for you, or send one back with "
         "<a href=\"/upload\">Upload</a>."),
        ("/setup", "Setup",
         "Connect this machine to the PC, and lock down its networking."),
        ("/boot", "Bootstrap",
         "The agent and instructions, mainly for the Mac OS 9 machine."),
    ]
    body = ('<h1>G3Bridge</h1><p class="sub">%s &middot; this machine is <tt>%s</tt> '
            'at %s</p>' % (who, html.escape(dev.name), dev.ip))
    body += '<div class="col">'
    for i, (href, title, blurb) in enumerate(cards):
        if i == (len(cards) + 1) // 2:
            body += '</div><div class="col">'
        body += ('<div class="card"><h3><a href="%s">%s</a></h3><p>%s</p></div>'
                 % (href, title, blurb))
    body += '</div><div class="clr"></div>'
    if not news_ready:
        body += '<p class="warn">News is still loading its first fetch.</p>'
    return _shell("G3Bridge", "/", body)


# ---------------------------------------------------------------- news
def news_page(sections, ago):
    body = ('<h1>News</h1><p class="sub">Fetched by the PC. This machine has no '
            'route to the internet &mdash; the headlines came down the cable.</p>')
    left = ""
    right = ""
    for i, (key, label, items, age, err) in enumerate(sections):
        chunk = '<h2>%s' % html.escape(label)
        if age is not None:
            chunk += ' <span style="color:#4d5b73;text-transform:none;letter-spacing:0">&nbsp;%s</span>' % ago(time.time() - age)
        chunk += '</h2>'
        if err and not items:
            chunk += '<p class="warn">could not fetch: %s</p>' % html.escape(err)
        elif err:
            chunk += '<p class="warn">last fetch failed; showing the previous copy</p>'
        if not items:
            chunk += '<p class="sub">nothing yet</p>'
        for it in items:
            chunk += '<div class="item"><div class="h">%s</div>' % html.escape(it["title"])
            if it["summary"]:
                chunk += '<div class="s">%s</div>' % html.escape(it["summary"])
            w = ago(it["ts"]) if it["ts"] else ""
            if w:
                chunk += '<div class="w">%s</div>' % html.escape(w)
            chunk += '</div>'
        if i % 2 == 0:
            left += chunk
        else:
            right += chunk
    body += '<div class="col">%s</div><div class="col">%s</div><div class="clr"></div>' % (left, right)
    return _shell("News", "/news", body)


# ---------------------------------------------------------------- games
def games_page(games):
    body = ('<h1>Games</h1><p class="sub">Written for this browser: no plugins, '
            'nothing downloaded, all drawn on the fly.</p>')
    if not games:
        body += '<p class="warn">No games installed yet.</p>'
    body += '<div class="col">'
    for i, g in enumerate(games):
        if i == (len(games) + 1) // 2:
            body += '</div><div class="col">'
        body += ('<div class="card"><h3><a href="/games/%s">%s</a></h3>'
                 '<p>%s</p><p style="margin-top:6px;color:#4d5b73">%s</p></div>'
                 % (html.escape(g["file"]), html.escape(g["title"]),
                    html.escape(g["blurb"]), html.escape(g["controls"])))
    body += '</div><div class="clr"></div>'
    return _shell("Games", "/games", body)


def scan_games(directory):
    """Games are whatever .html files are in www/games, with their metadata
    read from a sidecar .txt so the index needs no database."""
    out = []
    try:
        names = os.listdir(directory)
    except OSError:
        return out
    names.sort()
    for n in names:
        if not n.endswith(".html"):
            continue
        meta = {"file": n, "title": n[:-5].replace("_", " ").title(),
                "blurb": "", "controls": ""}
        side = os.path.join(directory, n[:-5] + ".txt")
        if os.path.isfile(side):
            try:
                fh = open(side, encoding="utf-8")
                for line in fh:
                    if "=" in line:
                        k, v = line.strip().split("=", 1)
                        if k in meta:
                            meta[k] = v
                fh.close()
            except OSError:
                pass
        out.append(meta)
    return out


# ---------------------------------------------------------------- claude screen
def artefact_placeholder():
    body = ('<h1>Claude&rsquo;s screen</h1>'
            '<p class="sub">Nothing published yet.</p>'
            '<div class="card"><p>This page is a surface Claude publishes to. '
            'Ask for something &mdash; a chart, a summary, a reference sheet, a '
            'plan &mdash; and it appears here for this machine to display.</p>'
            '<p style="margin-top:10px">Leave it open and reload when you want '
            'the latest, or open <a href="/claude-screen/index">the list</a> to '
            'see everything published so far.</p></div>')
    return _shell("Claude's screen", "/claude-screen", body)


def artefact_index(items):
    """items: [(name, title, size, mtime)] newest first."""
    body = ('<h1>Claude&rsquo;s screen</h1>'
            '<p class="sub">Everything published to this machine, newest first. '
            '<a href="/claude-screen">Current</a></p>')
    if not items:
        body += '<p class="warn">Nothing published yet.</p>'
    for name, title, size, mtime in items:
        body += ('<div class="card"><h3><a href="/claude-screen/%s">%s</a></h3>'
                 '<p>%s &middot; %s &middot; <tt>%s</tt></p></div>'
                 % (html.escape(name), html.escape(title),
                    time.strftime("%a %d %b %H:%M", time.localtime(mtime)),
                    _size(size), html.escape(name)))
    return _shell("Claude's screen", "/claude-screen", body)


def _size(n):
    if n < 1024:
        return "%d B" % n
    if n < 1024 * 1024:
        return "%.0f KB" % (n / 1024.0)
    return "%.1f MB" % (n / (1024.0 * 1024))


def scan_artefacts(directory):
    """[(name, title, size, mtime)] newest first."""
    out = []
    try:
        names = os.listdir(directory)
    except OSError:
        return out
    for n in names:
        if not n.endswith(".html"):
            continue
        fn = os.path.join(directory, n)
        try:
            st = os.stat(fn)
        except OSError:
            continue
        title = n[:-5].replace("_", " ").replace("-", " ").strip()
        try:
            fh = open(fn, encoding="utf-8", errors="replace")
            head = fh.read(4096)
            fh.close()
            m = re.search(r"<title>(.*?)</title>", head, re.S | re.I)
            if m:
                title = re.sub(r"\s+", " ", m.group(1)).strip()
        except OSError:
            pass
        out.append((n, title or n, st.st_size, st.st_mtime))
    out.sort(key=lambda r: r[3], reverse=True)
    return out


# ---------------------------------------------------------------- web proxy
SEARCH_BOX = ('<form action="/web" method="get">'
              '<input type="text" name="q" value="%s" size="52" '
              'style="background:#0a0d15;color:#e6edf3;border:1px solid #2b3550;'
              'padding:7px 9px;font:14px \'Lucida Grande\',Geneva,sans-serif">'
              ' <input type="submit" value="Search" '
              'style="background:#1d2740;color:#e6edf3;border:1px solid #3a4a6b;'
              'padding:7px 15px;font:13px \'Lucida Grande\',sans-serif">'
              '</form>')


def web_home(recent=None):
    body = ('<h1>Web</h1><p class="sub">This machine has no route to the internet. '
            'The PC fetches the page, strips out every script, stylesheet and '
            'remote resource, and sends back plain readable HTML.</p>')
    body += SEARCH_BOX % ""
    body += ('<div class="card" style="margin-top:22px"><p>Or go straight to an address:</p>'
             '<form action="/web" method="get">'
             '<input type="text" name="u" value="https://" size="52" '
             'style="background:#0a0d15;color:#e6edf3;border:1px solid #2b3550;padding:7px 9px">'
             ' <input type="submit" value="Open"></form></div>')
    body += ('<h2>Try</h2><p>'
            + " &nbsp;&middot;&nbsp; ".join(
                '<a href="/web?u=%s">%s</a>' % (u, n) for n, u in [
                    ("Wikipedia", "https%3A//en.wikipedia.org/wiki/Main_Page"),
                    ("BBC News", "https%3A//www.bbc.co.uk/news"),
                    ("Hacker News", "https%3A//news.ycombinator.com/"),
                    ("Low-tech Magazine", "https%3A//solar.lowtechmagazine.com/"),
                ]) + '</p>')
    return _shell("Web", "/web", body)


def web_results(query, results, error=None):
    body = '<h1>Search</h1>' + (SEARCH_BOX % html.escape(query, quote=True))
    if error:
        body += '<p class="warn">%s</p>' % html.escape(error)
    elif not results:
        body += '<p class="sub">Nothing found.</p>'
    body += '<div style="margin-top:20px">'
    for title, url, snippet in results:
        import urllib.parse as _u
        body += ('<div class="item"><div class="h"><a href="/web?u=%s">%s</a></div>'
                 '<div class="w">%s</div>'
                 % (_u.quote(url, safe=""), html.escape(title or url), html.escape(url[:96])))
        if snippet:
            body += '<div class="s">%s</div>' % html.escape(snippet)
        body += '</div>'
    body += '</div>'
    return _shell("Search: " + query, "/web", body)


def web_page(title, content, final_url, elapsed):
    import urllib.parse as _u
    body = ('<div style="border-bottom:1px solid #2b3550;padding-bottom:10px;margin-bottom:20px">'
            '<h1 style="font-size:21px;margin-bottom:2px">%s</h1>'
            '<p class="sub" style="margin:0">%s &middot; fetched by the PC in %.1fs '
            '&middot; scripts and remote content removed &middot; '
            '<a href="/web">new search</a></p></div>'
            % (html.escape(title[:120]), html.escape(final_url[:110]), elapsed))
    body += '<div class="reader">' + content + '</div>'
    extra = """
 .reader { max-width:52em; }
 .reader h1,.reader h2,.reader h3 { color:#e6edf3; font-weight:normal;
     text-transform:none; letter-spacing:0; border:0; margin:22px 0 8px; }
 .reader h1 { font-size:22px; } .reader h2 { font-size:18px; } .reader h3 { font-size:15px; }
 .reader p, .reader li { color:#c3cede; font-size:14px; }
 .reader img { max-width:100%; border:1px solid #2b3550; }
 .reader table { border-collapse:collapse; margin:12px 0; }
 .reader td,.reader th { border:1px solid #2b3550; padding:5px 9px; font-size:13px; }
 .reader pre { background:#0a0d15; border:1px solid #2b3550; padding:10px;
     overflow:auto; font:12px Monaco,"Courier New",monospace; }
 .reader blockquote { border-left:3px solid #2b3550; margin:10px 0; padding-left:14px;
     color:#8b9bb4; }
"""
    page = _shell(title[:60], "/web", body)
    return page.replace("</style>", extra + "</style>")


def web_error(what, detail):
    body = ('<h1>Could not load that</h1>' + (SEARCH_BOX % "")
            + '<div class="card" style="margin-top:20px"><p class="warn">%s</p>'
              '<p style="margin-top:8px">%s</p></div>'
            % (html.escape(what), html.escape(detail[:300])))
    return _shell("Web", "/web", body)
