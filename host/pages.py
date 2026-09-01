"""HTML for the bridge.

Written for Safari 3 on Mac OS X 10.5 (2008). That means CSS2 only:
no flexbox, no border-radius, no box-shadow, no transitions, no gradients.
Layout is floats and tables. Fonts are limited to what ships on that machine.

Kept separate from g3d.py so the daemon stays about plumbing.
"""

import html
import os
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
            ("/display", "Display"), ("/files", "Files"), ("/setup", "Setup")]
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
        if i == 3:
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
