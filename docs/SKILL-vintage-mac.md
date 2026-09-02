---
name: vintage-mac
description: Drive Jono's vintage Macs (eMac G4 on Mac OS X 10.5, iMac G3 on Mac OS 9) from this PC over the G3Bridge MCP server — publish a page to the eMac's screen, draw graphics, run shell or AppleScript on it, move files, read its screen. Use when he says "put this on the eMac", "show it on the vintage mac", "on the old mac", "claude-screen", "the G3", or wants anything displayed on or run on those machines. Also covers the kill switch.
---

# The vintage Macs

Two old Apple machines sit on a **direct Ethernet cable** to this PC. They are
driven through the `g3bridge` MCP server (user scope, always available).

| name | machine | screen | reachable |
|---|---|---|---|
| `emac` | eMac G4 1.25GHz, **Mac OS X 10.5.6**, 1GB RAM, `192.168.11.3` | 1024x768 | SSH + browser. **The good one.** |
| `g3` | iMac G3, **Mac OS 9.2**, `192.168.11.2` | 800x600 | browser only; **thermal fault, often will not start** |

Repo: `C:\AI\G3Bridge`. Living notes: `STATUS.md`.

## The rule that governs everything

**These machines have no route to the internet, and that is deliberate.**
No gateway, no DNS. Jono asked for this explicitly — they are unpatched
25-year-old systems.

So: **never write a page for them that loads anything remote.** No CDN, no web
fonts, no remote images, no analytics. If they need something from the
internet, *this PC* fetches it and serves it down the cable. That is what
`/news` already does.

## Showing him something — use `g3_publish`

This is the main tool. It puts an HTML page at `/claude-screen` on the Mac,
which is the surface set aside for exactly this. The newest thing published is
what that URL shows, so he can leave it open and reload.

Write for **Safari 3 (2008) on a 1.25 GHz PowerPC**:

- **CSS2 only.** No flexbox, no grid, no `border-radius`, no `box-shadow`, no
  transitions, no gradients. Layout with floats and tables.
- **ES3/ES5 JavaScript.** No `let`/`const`, no arrow functions, no template
  literals, no `class`, no spread, no `for...of`, no `Promise`.
  No `requestAnimationFrame` — use `setInterval`.
- Fonts that exist there: `"Lucida Grande"`, `Geneva`, `Monaco`,
  `"Courier New"`. Nothing else is guaranteed. **No emoji** — poor coverage,
  they render as boxes.
- Canvas works and is fast enough for simple graphics.
- Keep it under ~1024px wide.

`g3_draw` is a different thing: it draws primitives (lines, rects, ovals, text)
onto a framebuffer. Use it for the **OS 9 machine** or for simple graphics.
For anything textual or layout-heavy, **publish a page instead**.

## The other tools

| tool | for |
|---|---|
| `g3_publish` | put an HTML page on the Mac's screen at `/claude-screen` |
| `g3_devices` | list the machines; call this if unsure which to target |
| `g3_status` | is a machine connected, what size is its screen |
| `g3_draw` | draw primitives on the framebuffer (`/display` on the Mac) |
| `g3_screenshot` | see what the framebuffer currently shows |
| `g3_clear` | wipe the framebuffer |
| `g3_send_file` / `g3_transfers` / `g3_read_received` | move files both ways |
| `g3_applescript` | run AppleScript **on the OS 9 machine** (needs its applet running) |
| `g3_events` | drain clicks and keypresses sent back from a Mac |
| `g3_suspend` / `g3_resume` | **kill switch** — see below |

Omit the `device` argument when only one machine is connected; the bridge picks
the one it has seen.

## The web, for the Macs (`/web`)

The site the PC serves at `http://192.168.11.10:9980/` has a browser page,
`/web`. The PC fetches a page and **translates** it for Safari 3, so the Macs
can use the modern web without ever touching it. It is more than a text-only
proxy, and worth knowing what it can do when he asks "can the eMac do X":

- **Forms work.** Site search boxes and login forms submit through the PC, GET
  or POST, with a cookie jar in `run/cookies.txt`, so sessions persist.
- **Images are re-encoded** on the PC: WebP, AVIF, SVG become JPEG/PNG, nothing
  wider than 900px, cached in `run/webcache/`.
- **Downloads stream through.** A `.sit`, a PDF, an MP3 on a page becomes a
  link that saves to the Mac's Downloads folder (64 MB cap). Macintosh Garden
  is usable.
- **YouTube addresses go to `/video`**, which transcodes on the PC.
- **Four views**, switchable from the header of every proxied page:
  `full` (everything, navigation folded into a link strip), `reader` (main
  text only), `render` (the PC runs the page's JavaScript in a headless
  Chromium first — auto-chosen when a page arrives nearly empty), `pic` (a
  screenshot with every link as a clickable image map, for sites that will not
  translate at all).
- Address shape: `/web?u=<url>`, `/web?view=reader&u=<url>`, `/web?d=<url>`
  for a download. To put a specific web page in front of him on the Mac,
  publish a page whose link points at one of those.

Known: old.reddit now demands a login in the UK; X/Twitter needs the picture
view; sites behind heavy bot walls will not come through.

## The clock (`/time`)

The Macs cannot reach a time server. `/time` shows the PC's clock and serves
the script that sets the Mac's zone and time: on the eMac,
`curl -s 192.168.11.10:9980/time?f=sh | sudo sh`. Linked from `/setup`.
`/time?f=date` gives the raw `mmddHHMMccyy.ss` that BSD `date` takes.

## Reaching the eMac directly

Mac OS X means a real shell. This is usually better than any of the tools:

```
ssh   -F C:\AI\G3Bridge\host\ssh\config emac   '<command>'
scp   -F C:\AI\G3Bridge\host\ssh\config <file> emac:<path>
```

Key auth, no password. Use the **Windows** `ssh.exe`
(`C:\Windows\System32\OpenSSH\ssh.exe`), not WSL's — WSL's OpenSSH has removed
`ssh-dss` outright. The config carries `HostKeyAlgorithms +ssh-rsa`, without
which a modern client refuses to talk to it at all.

`osascript` over SSH reaches the logged-in desktop session, so you can drive
Finder, Safari and the rest. **`screencapture` over SSH returns a black
frame** — it is not attached to the console's window server.

## The kill switch

`g3_suspend` stops the bridge doing anything at all: no pages, no drawing, no
file transfer, no news fetching, no web proxying (and it closes the headless
Chromium), no machine may connect. It **persists across a
daemon restart**. `g3_resume` switches it back on. Use it whenever he asks to
stop or pause the project.

## If nothing works

The daemon must be running on **Windows** Python, not WSL — WSL2 is NAT'd and a
device on the cable cannot reach a listener inside it.

```
C:\AI\G3Bridge\start.cmd                          launch it
C:\Python310\python.exe tools\netcheck.py         diagnose the link + isolation
C:\Python310\python.exe tools\discover.py         find a Mac that just appeared
```

The G3's thermal fault means it often will not start when warm and needs an
hour cooling. That is the machine, not the bridge. See `docs/IMAC-G3-triage.md`.
