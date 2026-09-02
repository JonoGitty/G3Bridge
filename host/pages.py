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
            ("/web", "Web"), ("/video", "Video"),
            ("/claude-screen", "Claude"), ("/display", "Display"),
            ("/itunes", "iTunes"), ("/weather", "Weather"), ("/files", "Files"), ("/setup", "Setup")]
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
        ("/video", "Video",
         "Paste a video address. The PC downloads it and re-encodes it to "
         "something a 1.25GHz G4 can actually decode, then serves it down the "
         "cable for QuickTime to play."),
        ("/weather", "Weather",
         "A weather channel: current conditions, the next twelve hours, the week, "
         "the rain radar. Cycles like the one that used to be on cable."),
        ("/itunes", "iTunes",
         "Name the CD in the drive and fetch album covers. The PC does the lookups "
         "Gracenote and Apple used to, and pushes the results into iTunes."),
        ("/claude-screen", "Claude's screen",
         "Whatever Claude has published for this machine to display."),
        ("/display", "Display",
         "What Claude is drawing on this machine's canvas, %dx%d. Click the picture "
         "to send the coordinates back to the PC." % (dev.canvas[0], dev.canvas[1])),
        ("/files", "Files",
         "Collect files the PC has put out for you, or send one back with "
         "<a href=\"/upload\">Upload</a>."),
        ("/setup", "Setup",
         "Connect this machine to the PC, lock down its networking, and set its <a href=\"/time\">clock</a>."),
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


WEB_CSS = """
 .reader { max-width:56em; }
 .reader h1,.reader h2,.reader h3,.reader h4 { color:#e6edf3; font-weight:normal;
     text-transform:none; letter-spacing:0; border:0; margin:22px 0 8px; }
 .reader h1 { font-size:22px; } .reader h2 { font-size:18px; } .reader h3 { font-size:15px; }
 .reader h4 { font-size:14px; font-weight:bold; }
 .reader p, .reader li, .reader dd, .reader dt { color:#c3cede; font-size:14px; }
 .reader img { max-width:100%; border:1px solid #2b3550; }
 .reader table { border-collapse:collapse; margin:12px 0; }
 .reader td,.reader th { border:1px solid #2b3550; padding:5px 9px; font-size:13px;
     vertical-align:top; }
 .reader pre { background:#0a0d15; border:1px solid #2b3550; padding:10px;
     overflow:auto; font:12px Monaco,"Courier New",monospace; }
 .reader blockquote { border-left:3px solid #2b3550; margin:10px 0; padding-left:14px;
     color:#8b9bb4; }
 .reader input, .reader select, .reader textarea { background:#0a0d15; color:#e6edf3;
     border:1px solid #3a4a6b; padding:4px 6px; font:13px "Lucida Grande",Geneva,sans-serif;
     margin:2px 0; }
 .reader input[type=submit] { background:#1d2740; padding:4px 12px; cursor:pointer; }
 .reader form { margin:8px 0; }
 .reader fieldset { border:1px solid #2b3550; padding:8px 12px; margin:10px 0; }
 .reader legend { color:#ffc23d; font-size:12px; }
 .strip { font-size:12px; color:#4d5b73; line-height:1.9; margin:0 0 12px; padding:6px 10px;
     background:#0f131c; border:1px solid #1f2738; }
 .strip a { color:#9fb3cc; }
 .embed { border:1px dashed #3a4a6b; padding:8px 12px; margin:10px 0; color:#8b9bb4;
     font-size:13px; }
 .webhead { border-bottom:1px solid #2b3550; padding-bottom:10px; margin-bottom:18px; }
 .webhead h1 { font-size:21px; margin:8px 0 2px; }
 .webhead .sub { margin:0; }
 .webhead .sub a.on { color:#ffc23d; font-weight:bold; }
 .addr { background:#0a0d15; color:#e6edf3; border:1px solid #2b3550; padding:5px 8px;
     font:13px Monaco,"Courier New",monospace; width:640px; }
 .go { background:#1d2740; color:#e6edf3; border:1px solid #3a4a6b; padding:5px 12px;
     font:13px "Lucida Grande",sans-serif; }
 .note { color:#8b9bb4; font-size:12px; margin:4px 0; }
 .pic { display:block; border:0; margin:0 0 2px; }
"""


def _web_shell(title, body):
    page = _shell(title, "/web", body)
    return page.replace("</style>", WEB_CSS + "</style>")


def _addr(url, view=""):
    import urllib.parse as _u
    hidden = '<input type="hidden" name="view" value="%s">' % view if view else ""
    return ('<form action="/web" method="get" style="margin:0">%s'
            '<input type="text" name="u" value="%s" class="addr"> '
            '<input type="submit" value="Go" class="go"> '
            '<a href="/web" style="font-size:12px;margin-left:10px">search</a></form>'
            % (hidden, html.escape(url, quote=True)))


def _views(url, current, can_render):
    import urllib.parse as _u
    q = _u.quote(url, safe="")
    items = [("full", "Full"), ("reader", "Reader")]
    if can_render:
        items += [("render", "Rendered"), ("pic", "Picture")]
    out = []
    for key, label in items:
        cls = ' class="on"' if key == current else ""
        href = "/web?view=%s&u=%s" % (key, q)
        out.append('<a href="%s"%s>%s</a>' % (href, cls, label))
    out.append('<a href="/web?d=%s">Download</a>' % q)
    return " | ".join(out)


def web_home(recent=None, can_render=False):
    body = ('<h1>Web</h1><p class="sub">This machine has no route to the internet. '
            'The PC fetches each page, translates it for this browser, and sends it '
            'down the cable. Forms, logins, images and downloads work; nothing '
            'executable gets through.</p>')
    body += SEARCH_BOX % ""
    body += ('<div class="card" style="margin-top:22px"><p>Or go straight to an address:</p>'
             + _addr("https://") + '</div>')
    if recent:
        body += '<h2>Recent</h2>'
        import urllib.parse as _u
        for title, url, when, engine in recent:
            body += ('<div class="item"><div class="h"><a href="/web?u=%s">%s</a></div>'
                     '<div class="w">%s &middot; %s</div></div>'
                     % (_u.quote(url, safe=""), html.escape(title or url), html.escape(url[:96]), engine))
    body += ('<h2>Try</h2><p>'
            + " &nbsp;&middot;&nbsp; ".join(
                '<a href="/web?u=%s">%s</a>' % (u, n) for n, u in [
                    ("Wikipedia", "https%3A//en.wikipedia.org/wiki/Main_Page"),
                    ("BBC News", "https%3A//www.bbc.co.uk/news"),
                    ("Hacker News", "https%3A//news.ycombinator.com/"),
                    ("Macintosh Garden", "https%3A//macintoshgarden.org/"),
                    ("Reddit", "https%3A//old.reddit.com/"),
                    ("Low-tech Magazine", "https%3A//solar.lowtechmagazine.com/"),
                ]) + '</p>')
    body += ('<h2>Views</h2><p class="note"><b>Full</b> keeps everything, with site '
             'navigation folded into a strip of links. <b>Reader</b> keeps only the main '
             'text. ')
    if can_render:
        body += ('<b>Rendered</b> has the PC run the page&rsquo;s JavaScript first, for '
                 'sites that arrive empty. <b>Picture</b> sends a screenshot with every '
                 'link clickable, for sites that will not translate at all. ')
    else:
        body += ('Rendered and Picture views need Playwright on the PC and are off. ')
    body += ('Any file &mdash; a PDF, a .sit, an MP3 &mdash; downloads through the PC '
             'to this Mac. YouTube addresses go to <a href="/video">Video</a>.</p>')
    return _web_shell("Web", body)


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
    return _web_shell("Search: " + query, body)


def web_page(page, can_render=False):
    stats = "%d links" % page.links
    if page.images:
        stats += ", %d images" % page.images
    if page.forms:
        stats += ", %d form%s" % (page.forms, "" if page.forms == 1 else "s")
    head = ('<div class="webhead">' + _addr(page.url, page.view if page.view != "full" else "")
            + '<h1>%s</h1><p class="sub">%s by the PC in %.1fs &middot; %s &middot; View: %s</p>'
            % (html.escape(page.title[:120]), page.engine, page.elapsed, stats,
               _views(page.url, page.view, can_render)))
    for n in page.notes:
        head += '<p class="warn" style="margin:4px 0 0">%s</p>' % html.escape(n)
    head += '</div>'
    body = head + '<div class="reader">' + page.body + '</div>'
    return _web_shell(page.title[:60] or "Web", body)


def web_file(page):
    import urllib.parse as _u
    q = _u.quote(page.url, safe="")
    size = _size(page.size) if page.size >= 0 else "size unknown"
    body = ('<div class="webhead">' + _addr(page.url)
            + '<h1>%s</h1><p class="sub">%s &middot; %s</p></div>'
            % (html.escape(page.title[:120]), html.escape(page.ctype), size))
    if page.kind == "image":
        body += ('<div class="reader"><img src="/web?i=%s" alt=""></div>' % q)
        body += ('<p class="note">Shown re-encoded for this browser. '
                 '<a href="/web?d=%s">Download the original</a> instead.</p>' % q)
    else:
        body += ('<div class="card"><h3><a href="/web?d=%s">Download it to this Mac</a></h3>'
                 '<p>This address is a file, not a page. The PC will fetch it and stream it '
                 'down the cable; Safari saves it to your Downloads folder. '
                 'Limit %d MB.</p></div>' % (q, 64))
    return _web_shell(page.title[:60] or "File", body)


def web_picture(meta, can_render=True):
    import urllib.parse as _u
    body = ('<div class="webhead">' + _addr(meta["url"], "pic")
            + '<h1>%s</h1><p class="sub">screenshot by the PC, %dx%d, %d strips &middot; '
              'every link is clickable &middot; View: %s</p></div>'
            % (html.escape(meta["title"][:120]), meta["w"], meta["h"], len(meta["strips"]),
               _views(meta["url"], "pic", can_render)))
    for s in meta["strips"]:
        n = s["n"]
        body += ('<img src="/web?p=%s&n=%d" width="%d" height="%d" usemap="#m%d" class="pic" alt="">'
                 % (meta["id"], n, s["w"], s["h"], n))
        body += '<map name="m%d">' % n
        for (x1, y1, x2, y2, href, label) in s["areas"]:
            import webproxy as _wp
            body += ('<area shape="rect" coords="%d,%d,%d,%d" href="%s" alt="%s" title="%s">'
                     % (x1, y1, x2, y2, html.escape(_wp.link_for(href, "pic"), quote=True),
                        html.escape(label, quote=True), html.escape(label, quote=True)))
        body += '</map>'
    return _web_shell(meta["title"][:60] or "Picture", body)


def web_error(what, detail):
    body = ('<h1>Could not load that</h1>' + (SEARCH_BOX % "")
            + '<div class="card" style="margin-top:20px"><p class="warn">%s</p>'
              '<p style="margin-top:8px">%s</p></div>'
            % (html.escape(what), html.escape(detail[:300])))
    return _web_shell("Web", body)


# ---------------------------------------------------------------- weather channel
WEATHER_CSS = """
 body { margin:0; background:#0a1a5c url(/weather/bg.png?v=1) no-repeat top left; color:#fff;
        font-family:"Helvetica Neue",Helvetica,Arial,sans-serif; overflow:hidden; }
 a { color:#ffd23f; text-decoration:none; }
 .top { width:100%; border-collapse:collapse; }
 .top td { padding:16px 30px 6px; vertical-align:bottom; }
 .title { font-size:34px; font-weight:bold; color:#ffd23f; letter-spacing:.06em; text-transform:uppercase; }
 .where { text-align:right; font-size:20px; color:#fff; }
 .where .clock { font-size:30px; font-weight:bold; color:#fff; }
 .where .date { font-size:15px; color:#c9d4ff; }
 .rule { height:4px; background:#ffd23f; margin:0 30px; }
 .main { padding:22px 30px 0; height:560px; }
 .big { font-size:130px; font-weight:bold; line-height:1; color:#fff; }
 .cond { font-size:36px; color:#ffd23f; margin:6px 0 18px; }
 .facts { font-size:22px; border-collapse:collapse; }
 .facts td { padding:6px 26px 6px 0; }
 .facts td.k { color:#c9d4ff; }
 .cols { width:100%; border-collapse:collapse; text-align:center; }
 .cols td { padding:8px 4px; vertical-align:top; }
 .cols .h { font-size:22px; font-weight:bold; color:#ffd23f; }
 .cols .d { font-size:14px; color:#c9d4ff; }
 .cols .t { font-size:34px; font-weight:bold; }
 .cols .lo { font-size:22px; color:#c9d4ff; }
 .cols .c { font-size:15px; color:#fff; }
 .cols .p { font-size:15px; color:#8fd3ff; }
 .bottom { position:absolute; left:0; bottom:0; width:100%; background:#f7931e; color:#1a1030; }
 .bottom td { padding:9px 30px; font-size:18px; font-weight:bold; }
 .bottom td.nav { text-align:right; font-size:13px; font-weight:normal; }
 .bottom td.nav a { color:#1a1030; margin-left:10px; }
 .bottom td.nav a.on { text-decoration:underline; }
 .err { color:#ffb1a6; font-size:20px; }
"""

WEATHER_TITLES = {1: "Current Conditions", 2: "Next 12 Hours", 3: "7 Day Forecast",
                  4: "Rain Radar", 5: "Almanac"}


def weather_page(screen, d, err, hold, hourly, days, describe, compass, name):
    import datetime
    now = datetime.datetime.now()
    nxt = 1 if screen >= 5 else screen + 1
    head = ('<html><head><title>Weather</title>%s<style type="text/css">%s</style></head><body>'
            % ("" if hold else '<meta http-equiv="refresh" content="12; url=/weather?s=%d">' % nxt, WEATHER_CSS))
    top = ('<table class="top"><tr><td class="title">%s</td><td class="where">'
           '<span class="clock">%s</span><br>%s<br><span class="date">%s</span></td></tr></table>'
           '<div class="rule"></div>'
           % (WEATHER_TITLES[screen], now.strftime("%H:%M"), html.escape(name), now.strftime("%A %d %B %Y")))
    body = ""
    ticker = "Forecast unavailable"
    if d is None:
        body = '<div class="main"><p class="err">No forecast: %s</p></div>' % html.escape(err or "unknown")
    else:
        c = d["current"]
        ctext, cicon = describe(c["weather_code"], c["is_day"])
        day0 = days[0] if days else {}
        ticker = ("Now %d&deg; %s &middot; feels like %d&deg; &middot; wind %s %d mph &middot; humidity %d%% "
                  "&middot; %d mb" % (round(c["temperature_2m"]), html.escape(ctext), round(c["apparent_temperature"]),
                                     compass(c["wind_direction_10m"]), round(c["wind_speed_10m"]),
                                     round(c["relative_humidity_2m"]), round(c["pressure_msl"])))
        if screen == 1:
            body = ('<div class="main"><table cellpadding="0" cellspacing="0"><tr>'
                    '<td style="vertical-align:top;padding-right:40px"><img src="/weather/icon/%s.png?z=260&v=1" width="260" height="260" alt=""></td>'
                    '<td style="vertical-align:top"><div class="big">%d&deg;</div><div class="cond">%s</div>'
                    '<table class="facts">'
                    '<tr><td class="k">Feels like</td><td>%d&deg;</td><td class="k">Humidity</td><td>%d%%</td></tr>'
                    '<tr><td class="k">Wind</td><td>%s %d mph</td><td class="k">Gusts</td><td>%d mph</td></tr>'
                    '<tr><td class="k">Pressure</td><td>%d mb</td><td class="k">Cloud</td><td>%d%%</td></tr>'
                    '<tr><td class="k">Sunrise</td><td>%s</td><td class="k">Sunset</td><td>%s</td></tr>'
                    '<tr><td class="k">Today</td><td colspan="3">high %d&deg; low %d&deg;, %d%% chance of rain</td></tr>'
                    '</table></td></tr></table></div>'
                    % (cicon, round(c["temperature_2m"]), html.escape(ctext), round(c["apparent_temperature"]),
                       round(c["relative_humidity_2m"]), compass(c["wind_direction_10m"]), round(c["wind_speed_10m"]),
                       round(c["wind_gusts_10m"]), round(c["pressure_msl"]), round(c["cloud_cover"]),
                       day0.get("sunrise", "--:--"), day0.get("sunset", "--:--"),
                       round(day0.get("hi", 0)), round(day0.get("lo", 0)), round(day0.get("pop", 0) or 0)))
        elif screen == 2:
            body = '<div class="main">'
            for row in (hourly[:6], hourly[6:12]):
                body += '<table class="cols"><tr>'
                for h in row:
                    t, ic = describe(h["code"], h["day"])
                    body += ('<td><div class="h">%s</div><img src="/weather/icon/%s.png?z=96&v=1" width="96" height="96" alt="">'
                             '<div class="t">%d&deg;</div><div class="c">%s</div><div class="p">%d%% rain &middot; %d mph</div></td>'
                             % (h["hour"], ic, round(h["temp"]), html.escape(t), round(h["pop"] or 0), round(h["wind"])))
                body += '</tr></table>'
            body += '</div>'
        elif screen == 3:
            body = '<div class="main"><table class="cols"><tr>'
            for x in days[:7]:
                t, ic = describe(x["code"])
                body += ('<td><div class="h">%s</div><div class="d">%s</div>'
                         '<img src="/weather/icon/%s.png?z=112&v=1" width="112" height="112" alt="">'
                         '<div class="t">%d&deg;</div><div class="lo">%d&deg;</div><div class="c">%s</div>'
                         '<div class="p">%d%% rain</div></td>'
                         % (x["name"], x["date"], ic, round(x["hi"]), round(x["lo"]), html.escape(t), round(x["pop"] or 0)))
            body += '</tr></table></div>'
        elif screen == 4:
            body = ('<div class="main"><table cellpadding="0" cellspacing="0"><tr>'
                    '<td style="padding-right:36px"><img src="/weather/radar.jpg?t=%d" width="540" height="540" alt="radar"></td>'
                    '<td style="vertical-align:top;font-size:22px;line-height:1.6">Latest rain radar over southern England, '
                    'from the PC.<br><br><span style="color:#c9d4ff">The yellow cross is %s.</span><br><br>'
                    'Colours: light rain in green through to heavy in red; snow in blue.</td></tr></table></div>'
                    % (int(now.timestamp()) // 600, html.escape(name)))
        else:
            body = '<div class="main"><table class="facts" style="font-size:24px">'
            if days:
                body += ('<tr><td class="k">Sunrise today</td><td>%s</td><td class="k">Sunset</td><td>%s</td></tr>'
                         % (days[0]["sunrise"], days[0]["sunset"]))
                if len(days) > 1:
                    body += ('<tr><td class="k">Sunrise tomorrow</td><td>%s</td><td class="k">Sunset</td><td>%s</td></tr>'
                             % (days[1]["sunrise"], days[1]["sunset"]))
                body += ('<tr><td class="k">UV index today</td><td>%s</td><td class="k">Max wind</td><td>%d mph</td></tr>'
                         % (days[0]["uv"], round(days[0]["wind"])))
                body += ('<tr><td class="k">Rain this week</td><td colspan="3">%.0f mm over 7 days</td></tr>'
                         % sum((x["rain"] or 0) for x in days))
                warm = max(days, key=lambda x: x["hi"])
                cold = min(days, key=lambda x: x["lo"])
                body += ('<tr><td class="k">Warmest</td><td>%s, %d&deg;</td><td class="k">Coldest</td><td>%s, %d&deg;</td></tr>'
                         % (warm["name"], round(warm["hi"]), cold["name"], round(cold["lo"])))
            body += '</table></div>'
    nav = "".join('<a href="/weather?s=%d%s"%s>%s</a>' % (i, "&hold=1" if hold else "", ' class="on"' if i == screen else "", i)
                  for i in range(1, 6))
    nav += ('<a href="/weather?s=%d">auto</a>' % screen) if hold else ('<a href="/weather?s=%d&hold=1">hold</a>' % screen)
    nav += '<a href="/">site</a>'
    bottom = ('<table class="bottom" cellpadding="0" cellspacing="0"><tr><td>%s</td><td class="nav">%s</td></tr></table>'
              % (ticker, nav))
    return head + top + body + bottom + "</body></html>"


# ---------------------------------------------------------------- iTunes
def itunes_page(info, lib, msg, cands, a, b, error=""):
    import urllib.parse as _u
    body = ('<h1>iTunes</h1><p class="sub">iTunes 8 cannot look anything up any more: Gracenote and '
            'Apple&rsquo;s artwork service need an internet this Mac does not have. The PC does '
            'those lookups instead and pushes the results into iTunes over the cable.</p>')
    if error:
        body += '<div class="card"><p class="warn">%s</p></div>' % html.escape(error)
    if msg:
        body += '<div class="card" style="border-color:#3ea55f"><p class="ok">%s</p></div>' % html.escape(msg)

    body += '<h2>The CD in the drive</h2>'
    if not info:
        body += ('<p class="note">No audio CD is in the drive. Put one in, then '
                 '<a href="/itunes">reload this page</a>: the PC reads its table of contents '
                 'and looks it up on MusicBrainz before you press Import.</p>')
    elif not info["releases"]:
        body += ('<p class="warn">MusicBrainz has nothing for this disc (id <tt>%s</tt>, %d tracks).</p>'
                 % (html.escape(info["discid"]), len(info["toc"]["offsets"])))
    else:
        best = info["releases"][0]
        cover_url = ""
        if best.get("rg"):
            cover_url = "/web?i=" + _u.quote("https://coverartarchive.org/release-group/%s/front-250" % best["rg"], safe="")
        body += '<div class="card"><table cellpadding="0" cellspacing="0"><tr>'
        if cover_url:
            body += '<td style="padding-right:18px;vertical-align:top"><img src="%s" width="160" height="160" alt=""></td>' % cover_url
        body += ('<td style="vertical-align:top"><h3 style="font-size:19px">%s &mdash; %s</h3>'
                 '<p>%s%s &middot; %d tracks &middot; %s match on MusicBrainz</p>'
                 % (html.escape(best["artist"]), html.escape(best["title"]),
                    best["year"] or "", (" " + best["country"]) if best["country"] else "",
                    len(best["tracks"]), "exact" if info["exact"] else "table-of-contents"))
        body += ('<p style="margin-top:12px"><a href="/itunes?do=apply&pick=0" style="background:#1d2740;'
                 'border:1px solid #ffc23d;color:#ffc23d;padding:6px 14px">Name it in iTunes and add the cover</a></p>'
                 '<p class="note" style="margin-top:8px">Names the CD&rsquo;s tracks (so an import picks them up) '
                 'and any tracks already imported as &ldquo;Track NN&rdquo;. Safe to run again after the import finishes.</p>'
                 '</td></tr></table></div>')
        body += '<ol style="margin:8px 0 0 22px">'
        for tr in best["tracks"]:
            body += '<li style="font-size:13px;color:#c3cede">%s%s</li>' % (
                html.escape(tr["title"]),
                (' <span class="w">&middot; %s</span>' % html.escape(tr["artist"])) if tr["artist"] and tr["artist"] != best["artist"] else "")
        body += '</ol>'
        if len(info["releases"]) > 1:
            body += '<p class="note" style="margin-top:14px">Other releases with this table of contents:</p>'
            for i, r in enumerate(info["releases"][1:8], 1):
                body += ('<div class="item"><div class="h">%s &mdash; %s <span class="w">%s %s, %d tracks, disc %d of %d</span> '
                         '&nbsp; <a href="/itunes?do=apply&pick=%d">use this one</a></div></div>'
                         % (html.escape(r["artist"]), html.escape(r["title"]), r["year"] or "", html.escape(r["country"]),
                            len(r["tracks"]), r["disc"], r["discs"], i))

    body += '<h2>The library</h2>'
    if lib is None:
        body += '<p class="note">Could not read the library.</p>'
    else:
        unnamed = sum(1 for t in lib["tracks"] if (t["name"] or "").startswith("Track ") and not t["album"])
        body += '<p class="sub">%d tracks, %d albums.%s</p>' % (
            lib["count"], len(lib["albums"]),
            (' <span class="warn">%d imported tracks are still called &ldquo;Track NN&rdquo; &mdash; '
             'apply the CD above again once the import has finished.</span>' % unnamed) if unnamed else "")
        if lib["albums"]:
            body += '<table cellpadding="0" cellspacing="0" style="border-collapse:collapse;width:100%">'
            for al in lib["albums"]:
                q = "a=%s&b=%s" % (_u.quote(al["artist"], safe=""), _u.quote(al["album"], safe=""))
                art = ('<span class="ok">cover on %d of %d</span>' % (al["with_art"], al["tracks"])
                       if al["with_art"] else '<span class="warn">no cover</span>')
                body += ('<tr><td style="padding:5px 8px;border-bottom:1px solid #1f2738">%s</td>'
                         '<td style="padding:5px 8px;border-bottom:1px solid #1f2738">%s</td>'
                         '<td style="padding:5px 8px;border-bottom:1px solid #1f2738;color:#7d8da5;font-size:12px">%d tracks</td>'
                         '<td style="padding:5px 8px;border-bottom:1px solid #1f2738;font-size:12px">%s</td>'
                         '<td style="padding:5px 8px;border-bottom:1px solid #1f2738;font-size:12px"><a href="/itunes?do=covers&%s">find a cover</a></td></tr>'
                         % (html.escape(al["artist"] or "(no artist)"), html.escape(al["album"] or "(no album)"),
                            al["tracks"], art, q))
            body += '</table>'

    if cands is not None:
        body += '<h2>Covers for %s &mdash; %s</h2>' % (html.escape(a), html.escape(b))
        if not cands:
            body += '<p class="note">The iTunes Search API found nothing. Try a shorter album name.</p>'
        q = "a=%s&b=%s" % (_u.quote(a, safe=""), _u.quote(b, safe=""))
        for i, (ca, cb, url, yr) in enumerate(cands):
            thumb = "/web?i=" + _u.quote(url.replace("600x600bb", "200x200bb"), safe="")
            body += ('<div class="card" style="float:left;width:180px;margin-right:14px;text-align:center">'
                     '<img src="%s" width="160" height="160" alt=""><p style="margin-top:6px">%s<br>%s %s</p>'
                     '<p style="margin-top:6px"><a href="/itunes?do=cover&%s&n=%d">use this</a></p></div>'
                     % (thumb, html.escape(ca[:40]), html.escape(cb[:40]), html.escape(yr), q, i))
        body += '<div class="clr"></div>'
    body += ('<p class="note" style="margin-top:26px">From the PC: <tt>C:\Python310\python.exe host\itunes.py cd --apply</tt> '
             'does the same as the button. <a href="/itunes">Reload</a>.</p>')
    return _shell("iTunes", "/itunes", body)


# ---------------------------------------------------------------- clock
def time_page(now, tz, note, pc, port):
    body = ('<h1>Clock</h1><p class="sub">The PC&rsquo;s time, refreshed every 20 seconds. '
            'This machine cannot reach a time server, so this is how it finds out.</p>'
            '<div style="font:bold 72px Monaco,\'Courier New\',monospace;color:#7dff9b;'
            'letter-spacing:2px;margin:10px 0 0">%s</div>'
            '<div style="font-size:22px;color:#e6edf3;margin:2px 0 6px">%s</div>'
            '<p class="sub">%s%s</p>'
            % (now.strftime("%H:%M:%S"), now.strftime("%A %d %B %Y"), html.escape(tz),
               (" &middot; " + html.escape(note)) if note else ""))
    body += ('<h2>Set this Mac&rsquo;s clock from the PC (Mac OS X)</h2>'
             '<div class="cmd">curl -s %s:%d/time?f=sh | sudo sh</div>'
             '<p class="note">Sets the time zone to %s and the time to the second, then '
             'prints the result. Needs the account password for <tt>sudo</tt>; the PC '
             'never sees it.</p>' % (pc, port, html.escape(tz)))
    body += ('<h2>Mac OS 9</h2><p class="note">No shell there. Open the Date &amp; Time '
             'control panel and copy the clock above.</p>')
    body += ('<h2>Raw</h2><p class="note">'
             '<a href="/time?f=date">/time?f=date</a> &rarr; <tt>%s</tt> (what <tt>date</tt> takes) &middot; '
             '<a href="/time?f=iso">/time?f=iso</a> &rarr; <tt>%s</tt> &middot; '
             '<a href="/time?f=unix">/time?f=unix</a> &rarr; seconds since 1970 &middot; '
             '<a href="/time?f=sh">/time?f=sh</a> &rarr; the script</p>'
             % (now.strftime("%m%d%H%M%Y.%S"), now.strftime("%Y-%m-%d %H:%M:%S")))
    page = _shell("Clock", "/setup", body)
    return page.replace("<head>", '<head><meta http-equiv="refresh" content="20">', 1)


# ---------------------------------------------------------------- video
def video_page(profiles, default, jobs, lib, ago, available):
    body = ('<h1>Video</h1><p class="sub">The PC fetches it and re-encodes it for '
            'this machine. MPEG-4 Part 2 by default &mdash; it is what QuickTime on '
            'PowerPC was built around and costs a fraction of the CPU that H.264 '
            'does.</p>')
    if not available:
        body += ('<p class="warn">ffmpeg or yt-dlp is missing on the PC, so nothing '
                 'can be converted.</p>')
        return _shell("Video", "/video", body)

    opts = ""
    for key in ("small", "normal", "large", "sharp"):
        if key not in profiles:
            continue
        sel = ' selected="selected"' if key == default else ""
        opts += '<option value="%s"%s>%s</option>' % (key, sel, html.escape(profiles[key][4]))
    body += ('<form action="/video" method="get">'
             '<p><input type="text" name="u" size="54" value="" '
             'style="background:#0a0d15;color:#e6edf3;border:1px solid #2b3550;padding:7px 9px">'
             ' <select name="p" style="background:#0a0d15;color:#e6edf3;border:1px solid #2b3550;padding:6px">%s</select>'
             ' <input type="submit" value="Convert"></p></form>' % opts)

    if jobs:
        body += '<h2>Conversions</h2>'
        for j in jobs[:8]:
            if j.state == "ready":
                line = ('<div class="h"><a href="/video/%s">%s</a></div>'
                        '<div class="w"><span class="ok">ready</span> &middot; %s &middot; '
                        'took %ds</div>'
                        % (html.escape(j.filename), html.escape(j.title[:78]),
                           _size(j.size), int((j.finished or 0) - j.started)))
            elif j.state == "failed":
                line = ('<div class="h">%s</div><div class="w warn">failed &mdash; %s</div>'
                        % (html.escape(j.title[:78]), html.escape(j.message[:150])))
            else:
                line = ('<div class="h">%s</div><div class="w">%s&hellip; '
                        '(reload to check)</div>'
                        % (html.escape(j.title[:78]), html.escape(j.state)))
            body += '<div class="item">%s</div>' % line

    if lib:
        body += '<h2>Ready to watch</h2>'
        for name, size, mtime in lib:
            body += ('<div class="item"><div class="h"><a href="/video/%s">%s</a></div>'
                     '<div class="w">%s &middot; %s</div></div>'
                     % (html.escape(name), html.escape(name[:-4].replace("_", " ")),
                        _size(size), time.strftime("%a %d %b %H:%M", time.localtime(mtime))))
        body += ('<p class="sub" style="margin-top:18px">Clicking one hands it to '
                 'QuickTime Player. If it stutters, convert it again at a smaller '
                 'size.</p>')
    elif not jobs:
        body += '<p class="sub" style="margin-top:20px">Nothing converted yet.</p>'
    return _shell("Video", "/video", body)
