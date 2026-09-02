# G3Bridge — status

Built 1–2 Sep 2026.

## The machines

| | `emac` | `g3` |
|---|---|---|
| hardware | eMac G4 1.25 GHz, 1 GB RAM, `PowerMac6,4` | iMac G3 |
| OS | Mac OS X 10.5.6 (build 9G66), Darwin 9.6.0 PPC | Mac OS 9.2 |
| address | `192.168.11.3` | `192.168.11.2` |
| screen | 1024×768 (CRT max 1280×960) | 800×600 |
| access | **SSH, key-based, working**; user `mac`; iTunes 8.0.2 | browser; agent written but unrun |
| state | working | **thermal fault — will not start when warm** |

PC is `192.168.11.10` on a Realtek 2.5GbE adapter. Straight-through cable is
fine: every 1000/2500BASE-T PHY does auto-MDI-X, so no crossover is needed.

## Working and verified

- **SSH to the eMac** — key auth, `scp` both ways, `osascript` reaching the
  logged-in desktop session (returns the disk name and frontmost app).
- **The site** — `/`, `/news` (8 feeds, 72 headlines), `/games` (4), `/web`,
  `/video`, `/claude-screen`, `/display`, `/files`, `/setup`, `/boot`.
- **Web translation layer** (`/web`, 2 Sep) — forms submit through the PC
  (GET and POST verified round-trip; cookie jar on disk), images re-encoded
  (a WebP arrives as JPEG; nothing wider than 900px; disk cache), navigation
  folded into link strips, downloads streamed with `Content-Disposition`,
  YouTube redirected to `/video`. Four views: full, reader, rendered
  (headless Chromium on the PC, auto-chosen when a page arrives nearly empty),
  picture (screenshot + image map). Measured through the daemon: BBC News
  56 KB / 52 images / 0.1 s; Hacker News with its login form; Wikipedia 117 KB
  with both search boxes working; Macintosh Garden with 34 download links;
  Reddit and YouTube's home rendered on the PC in 4–12 s. 61 checks in
  `tools/test_webproxy.py`.
- **Clock** (`/time`) — the PC's time in `date`'s `mmddHHMMccyy.ss` form, an
  ISO form, and a script that sets the Mac's zone and clock. Linked from
  `/setup`.
- **iTunes through the PC** (`/itunes`, 2 Sep) — **verified on the real eMac,
  the first feature beyond SSH to be.** A CD ripping as "Track 01" in "Unknown
  Album" was identified from `/Volumes/Audio CD/.TOC.plist` (MusicBrainz disc
  ID computed on the PC and checked against two IDs MusicBrainz published),
  fuzzy-matched to *Queens of the Stone Age — Songs for the Deaf* (2002), and
  15 imported tracks were named, dated and given the Cover Art Archive cover
  by AppleScript over SSH. Album-cover lookup for the rest of the library uses
  the iTunes Search API. 15 checks in `tools/test_itunes.py`.
- **Weather channel** (`/weather`, 2 Sep) — five screens cycling every 12 s:
  current, next 12 hours, 7 days, rain radar (RainViewer frame over darkened
  OpenStreetMap tiles, composited with Pillow in 0.7 s), almanac. Icons and
  the gradient are PNGs drawn on the PC. Layout checked in Chromium at
  1024x740, not on the CRT.
- **Video** — 10-minute 1080p source → 480×360 MPEG-4 Part 2 + AAC in 63 s,
  816 kbps, `+faststart`.
- **Multi-device** — two machines render to separate 800×600 and 1024×768
  framebuffers; unknown device names are clean errors.
- **Kill switch** — `g3_suspend` gives 503 on HTTP, refuses control verbs,
  refuses agent connections, persists across a daemon restart, resumes cleanly.
- **Isolation** — five Windows controls pass; the sixth (WSL2) reports a real
  finding. From the Mac: `ping 8.8.8.8` 100% loss, `apple.com` unresolvable.
- **Tests** — `tools/test_all.py`, 7 suites, all green.

## Not done / unknown

- **The OS 9 agent has never run.** `g3/g3agent.py` and `g3/PCLink.applescript`
  are written against verified API shapes and lint clean for Python 2.3, but no
  code has executed on the G3. `g3agent.py selftest` draws with no network and
  is the right first test.
- **Nothing has been seen on a real CRT.** Every page is written for Safari 3
  but has only been checked by fetching it. Layout on a 1024×768 CRT is unverified.
- **`screencapture` over SSH returns a black frame** — it is not attached to
  the console's window server on 10.5. Fix is `launchctl bsexec`, needs sudo.
- **eMac hardening not applied** — `/h` is written and served but needs an admin
  password nobody has to hand. Two gaps stand: subnet mask is `255.255.0.0`
  (a /16, so the Mac treats the whole of 192.168.x.x as local, including the
  house LAN range) and IPv6 is `Automatic` and would accept a router
  advertisement. Neither is an active hole; nothing can currently get out.
- **WSL2 forwards** — `ip_forward=1` with an interface on the cable subnet and
  another on the internet with a default route. The surgical fix (an `iptables`
  FORWARD drop that leaves Docker working) is printed by `netcheck.py` but not
  applied; it needs sudo.
- **Video playback smoothness on the actual G4** is untested. Big Buck Bunny is
  converted and waiting as the first experiment.
- **The eMac's clock reads Jan 1**, so its PRAM battery is probably flat.
  `/time?f=sh` fixes it from the PC but needs sudo, so it is untested there.
- **Translated forms and picture-mode image maps have not been exercised in
  Safari 3 itself.** Both are HTML 3.2-era features and should work; verified
  only by fetching.
- **old.reddit demands a login from the UK** (Online Safety Act), so the
  Reddit rewrite lands on a login wall. The form is there; logging in through
  it is untested. X/Twitter is JavaScript-only: picture view or nothing.
- **Playwright's first launch takes ~16 s** on this PC; later pages 2–5 s. The
  browser is closed after five idle minutes and relaunched on demand.
- **iTunes' CD-track count reads 0** even though the CD's tracks end up named:
  iTunes links CD tracks to their imports, so renaming the imports renames the
  CD. The effect is real; the counter is not to be trusted.
- **The iTunes XML lags** behind edits by a while, so anything that matches
  tracks by name must do it live inside iTunes (the AppleScript does) rather
  than from the XML.

## Bugs found and fixed

Each of these was found by testing, not by review.

| bug | consequence |
|---|---|
| Two threads reading the same socket | The pump ate replies; every command after the first failed. |
| Empty quoted string dropped by the agent parser | `TEXT 0 0 ""` arrived with a missing argument and would have thrown on the Mac. |
| A Python 3 syntax check cannot validate Python 2.3 | 3.14 parses `except Exception, e` as a *tuple of exception classes* and passes silently. Hence `tools/lint_py23.py`. |
| Pillow dithers by default | Flat artwork encoded to 135 KB instead of 15 KB, and a browser reloading that every 2 s crashed the G3. |
| Frame URLs were uncacheable | The Mac re-downloaded an unchanged image every cycle; now 373 bytes instead of 135 KB. |
| `bind_addresses()` enumerated instead of probing | `getaddrinfo` never returned the manual addresses, so the "cable adapter only" guarantee was silently false. |
| Void tags in the sanitiser's drop set | `<link>` and `<meta>` emit no end tag, so the drop counter never decremented — Wikipedia came back as a **2-byte page**. |
| Chunks decoded before joining | A split landing inside a `%0D` escape ate a character; cost a line of a 59-line listing. |
| Stale `STATUS` fields | Reported agent width/height while saying `state=waiting`. |
| Duplicate `os=` key | Config and machine-reported values collided; whichever parsed last silently won. |
| libxml2's 256-level nesting cap | A page of unclosed `<li>` or `<p>` tags nests one level per tag; past 256 everything was silently thrown away. `huge_tree=True`. |
| Reader view descended into the biggest paragraph | Kept one `<p>`, lost the headline and pictures. It now only steps into containers. |
| `named` as an AppleScript variable | Reserved word; the script would not compile (`-2741`). |
| Artwork `as picture` | Reads fine, then iTunes fails with `-116`. It wants `as JPEG picture`. |
| A CD is a *source*, not a playlist | `every audio CD playlist` at the top level finds nothing; walk `every source` and take the one whose kind is `audio CD`. |
| Invented test vectors | The first offline disc-ID test used offsets typed from memory and failed; the real ones from MusicBrainz pass. |
| YouTube 403 on AV1 streams | yt-dlp's default pick for a 720p source was AV1, which YouTube refused to serve. The selector now prefers H.264. |
| Truncated failure text | The video job kept the last 220 chars of stderr, which was the Python-3.10 deprecation nag, not the error. |

## Corrections to earlier conclusions

- **MacPython 2.3.5 has no classic Mac OS build.** The first research pass called
  it the last release; an adversarial check found no such build. It is **2.3.3**.
- **The G3's fault is not confidently diagnosed.** "Thermal capacitors, near
  certain" was overconfident. `docs/IMAC-G3-triage.md` puts "alive but stuck" at
  ~40% against ~30% for the power/analogue board, and notes that no-chime is
  weak evidence because chime volume lives in PRAM, and that RAM faults on this
  model are *audible*.
- **The eMac is `PowerMac6,4`**, which cannot boot OS 9 at all — so Mac OS X and
  SSH were always the only path for it.
