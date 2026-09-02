"""iTunes, back online -- through the PC.

iTunes 8 on the eMac cannot look anything up: Gracenote's CDDB and Apple's
artwork service both need an internet the machine does not have, and the
endpoints iTunes 8 knew are dead anyway. So a CD rips as "Track 01" in
"Unknown Album", and there is nothing to find a cover FOR.

This module does what iTunes used to do, from the PC, over SSH:

  toc()          read the audio CD's table of contents from the Mac
                 (/Volumes/Audio CD/.TOC.plist -- Mac OS X mounts one for
                 every audio CD)
  discid(toc)    the MusicBrainz disc ID, the same SHA-1 the real clients use
  lookup(toc)    MusicBrainz: exact disc ID first, fuzzy TOC second
  cover(rel)     Cover Art Archive, then the iTunes Search API as a fallback
  library()      the tracks iTunes has, from its XML
  covers(a, b)   candidate covers for an album already in the library
  apply(job)     push names, album, year, genre and the cover INTO iTunes with
                 AppleScript. CD tracks are named before they are imported so
                 iTunes rips them with the right names; already-imported
                 tracks are found by persistent ID and renamed.

Two things the real eMac taught: a CD is a *source* in iTunes' object model,
not a playlist (`every audio CD playlist` at the top level finds nothing), and
artwork must be coerced `as JPEG picture` -- `as picture` reads fine and then
fails inside iTunes with error -116.

Everything textual crosses to the Mac as a UTF-16 file the AppleScript reads
with `as Unicode text`, so the script itself is pure ASCII and no encoding
guesswork happens on a 2009 osascript. Nothing is installed on the Mac.

CLI (Windows Python):
  itunes.py cd                 identify the disc in the drive
  itunes.py cd --apply [N]     name it in iTunes (candidate N, default best)
  itunes.py library            what iTunes has, and which albums lack art
  itunes.py covers ARTIST ALBUM
  itunes.py cover-apply ARTIST ALBUM [N]
"""

import base64
import hashlib
import io
import json
import os
import plistlib
import re
import subprocess
import sys
import time
import urllib.parse

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
SSH = r"C:\Windows\System32\OpenSSH\ssh.exe"
SSH_CONFIG = os.path.join(HERE, "ssh", "config")
HOST = "emac"
UA = "G3Bridge/1.0 (https://github.com/JonoGitty/G3Bridge)"
MB = "https://musicbrainz.org/ws/2"
CAA = "https://coverartarchive.org"
ITUNES_API = "https://itunes.apple.com/search"
XML_PATH = "~/Music/iTunes/iTunes Music Library.xml"
TOC_PATH = "/Volumes/Audio CD/.TOC.plist"
COVER_PX = 600

_cache = {}


# ---------------------------------------------------------------- ssh
def ssh(cmd, timeout=90, stdin=None):
    """(rc, stdout bytes, stderr text). BatchMode so a missing key fails fast
    instead of prompting."""
    r = subprocess.run([SSH, "-F", SSH_CONFIG, "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
                        HOST, cmd], input=stdin, capture_output=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr.decode("utf-8", "replace")


def put(data, remote):
    rc, _o, err = ssh("cat > '%s'" % remote, stdin=data)
    if rc != 0:
        raise RuntimeError("could not write %s on the Mac: %s" % (remote, err.strip()[:200]))


def reachable():
    try:
        rc, out, _e = ssh("echo ok", timeout=15)
        return rc == 0 and out.strip() == b"ok"
    except Exception:
        return False


# ---------------------------------------------------------------- the disc
def toc():
    """None if no audio CD is in the drive."""
    rc, out, _e = ssh("cat '%s' 2>/dev/null" % TOC_PATH, timeout=30)
    if rc != 0 or not out.strip():
        return None
    pl = plistlib.loads(out)
    sess = pl["Sessions"][0]
    first, last = int(sess["First Track"]), int(sess["Last Track"])
    starts = {}
    for t in sess["Track Array"]:
        if t.get("Data"):
            continue                       # an enhanced CD's data track
        starts[int(t["Point"])] = int(t["Start Block"]) + 150
    nums = [n for n in range(first, last + 1) if n in starts]
    if not nums:
        return None
    return {"first": nums[0], "last": nums[-1], "leadout": int(sess["Leadout Block"]) + 150,
            "offsets": [starts[n] for n in nums]}


def discid(t):
    """MusicBrainz disc ID: SHA-1 of first, last, lead-out, then 99 offsets,
    base64 with . _ - for + / =."""
    h = hashlib.sha1()
    h.update(("%02X" % t["first"]).encode())
    h.update(("%02X" % t["last"]).encode())
    h.update(("%08X" % t["leadout"]).encode())
    offs = list(t["offsets"]) + [0] * (99 - len(t["offsets"]))
    for o in offs[:99]:
        h.update(("%08X" % o).encode())
    return base64.b64encode(h.digest()).decode("ascii").replace("+", ".").replace("/", "_").replace("=", "-")


def _credit(ac):
    return "".join((c.get("name") or c.get("artist", {}).get("name", "")) + (c.get("joinphrase") or "")
                   for c in (ac or [])).strip()


def _release(rel, t, did):
    media = rel.get("media") or []
    chosen = None
    for m in media:
        if any(d.get("id") == did for d in (m.get("discs") or [])):
            chosen = m
            break
    if chosen is None:
        for m in media:
            if int(m.get("track-count") or len(m.get("tracks") or [])) == len(t["offsets"]):
                chosen = m
                break
    if chosen is None and media:
        chosen = media[0]
    tracks = []
    for tr in (chosen or {}).get("tracks") or []:
        rec = tr.get("recording") or {}
        tracks.append({"n": int(tr.get("position") or tr.get("number") or len(tracks) + 1),
                       "title": tr.get("title") or rec.get("title") or "",
                       "artist": _credit(tr.get("artist-credit") or rec.get("artist-credit")),
                       "ms": tr.get("length") or rec.get("length") or 0})
    date = rel.get("date") or ""
    return {"id": rel["id"], "title": rel.get("title") or "", "artist": _credit(rel.get("artist-credit")),
            "date": date, "year": int(date[:4]) if date[:4].isdigit() else 0,
            "country": rel.get("country") or "", "status": rel.get("status") or "",
            "rg": (rel.get("release-group") or {}).get("id", ""),
            "disc": int((chosen or {}).get("position") or 1), "discs": max(1, len(media)),
            "tracks": tracks, "barcode": rel.get("barcode") or ""}


def lookup(t):
    """(discid, exact, [release]) -- best candidate first."""
    did = discid(t)
    key = ("lookup", did)
    if key in _cache:
        return _cache[key]
    inc = "recordings+artist-credits+release-groups"
    rels, exact = [], False
    r = requests.get("%s/discid/%s" % (MB, did), params={"inc": inc, "fmt": "json"},
                     headers={"User-Agent": UA}, timeout=25)
    if r.status_code == 200:
        rels = r.json().get("releases") or []
        exact = bool(rels)
    if not rels:
        tocp = "+".join(str(x) for x in [t["first"], t["last"], t["leadout"]] + list(t["offsets"]))
        r = requests.get("%s/discid/-" % MB, params={"toc": tocp, "inc": inc, "fmt": "json"},
                         headers={"User-Agent": UA}, timeout=25)
        if r.status_code == 200:
            rels = r.json().get("releases") or []
    out = [_release(x, t, did) for x in rels]
    n = len(t["offsets"])

    def rank(rel):
        return (0 if len(rel["tracks"]) == n else 1,
                0 if rel["country"] in ("GB", "XE", "XW") else 1,
                0 if rel["status"] == "Official" else 1,
                rel["year"] or 9999)
    out.sort(key=rank)
    _cache[key] = (did, exact, out)
    return _cache[key]


# ---------------------------------------------------------------- covers
def _jpeg(raw, px=COVER_PX):
    from PIL import Image
    im = Image.open(io.BytesIO(raw))
    im.load()
    if im.width > px or im.height > px:
        im.thumbnail((px, px))
    buf = io.BytesIO()
    im.convert("RGB").save(buf, "JPEG", quality=86, optimize=True)
    return buf.getvalue()


def _get_image(url):
    r = requests.get(url, headers={"User-Agent": UA}, timeout=30, allow_redirects=True)
    if r.status_code != 200 or not r.content:
        return None
    return r.content


def itunes_covers(artist, album, limit=5):
    """[(artist, album, url600, year)] from the iTunes Search API. No key."""
    term = ("%s %s" % (artist, album)).strip()
    r = requests.get(ITUNES_API, params={"term": term, "entity": "album", "limit": limit,
                                         "media": "music"}, headers={"User-Agent": UA}, timeout=20)
    out = []
    if r.status_code != 200:
        return out
    for x in r.json().get("results") or []:
        url = (x.get("artworkUrl100") or "").replace("100x100bb", "600x600bb")
        if url:
            out.append((x.get("artistName", ""), x.get("collectionName", ""), url,
                        (x.get("releaseDate") or "")[:4]))
    return out


def cover(rel):
    """JPEG bytes or None. Cover Art Archive by release, then release group,
    then the iTunes Search API."""
    for url in ("%s/release/%s/front-500" % (CAA, rel["id"]),
                "%s/release-group/%s/front-500" % (CAA, rel["rg"]) if rel.get("rg") else None):
        if not url:
            continue
        try:
            raw = _get_image(url)
            if raw:
                return _jpeg(raw), url
        except Exception:
            pass
    for _a, _b, url, _y in itunes_covers(rel["artist"], rel["title"], 3):
        try:
            raw = _get_image(url)
            if raw:
                return _jpeg(raw), url
        except Exception:
            pass
    return None, ""


# ---------------------------------------------------------------- the library
def library():
    """{'tracks': [...], 'albums': [...]} from the iTunes XML on the Mac."""
    rc, out, err = ssh("cat %s" % XML_PATH.replace(" ", "\\ "), timeout=60)
    if rc != 0:
        raise RuntimeError("could not read the iTunes library: %s" % err.strip()[:200])
    pl = plistlib.loads(out)
    tracks = []
    for tid, t in (pl.get("Tracks") or {}).items():
        if (t.get("Track Type") or "File") != "File":
            continue
        tracks.append({"pid": t.get("Persistent ID", ""), "name": t.get("Name", ""),
                       "artist": t.get("Artist", ""), "album": t.get("Album", ""),
                       "album_artist": t.get("Album Artist", ""), "n": int(t.get("Track Number") or 0),
                       "ms": int(t.get("Total Time") or 0), "art": int(t.get("Artwork Count") or 0) > 0,
                       "kind": t.get("Kind", ""), "year": int(t.get("Year") or 0)})
    tracks.sort(key=lambda x: (x["album_artist"] or x["artist"], x["album"], x["n"]))
    albums = {}
    for t in tracks:
        k = ((t["album_artist"] or t["artist"]).strip(), t["album"].strip())
        a = albums.setdefault(k, {"artist": k[0], "album": k[1], "tracks": 0, "with_art": 0,
                                  "pids": [], "year": t["year"]})
        a["tracks"] += 1
        a["with_art"] += 1 if t["art"] else 0
        a["pids"].append(t["pid"])
    return {"tracks": tracks, "albums": list(albums.values()), "count": len(tracks)}


def unnamed(lib):
    """Imported tracks still called 'Track NN' with no album: {n: pid}."""
    out = {}
    for t in lib["tracks"]:
        m = re.match(r"^Track (\d+)$", t["name"] or "")
        if m and not t["album"] and not t["artist"]:
            out[int(m.group(1))] = t["pid"]
    return out


# ---------------------------------------------------------------- apply
APPLESCRIPT = r'''
set f to (POSIX file "/tmp/g3names.txt")
set txt to read f as Unicode text
set AppleScript's text item delimiters to (ASCII character 10)
set lns to text items of txt
set AppleScript's text item delimiters to tab
set hdr to text items of (item 2 of lns)
set theAlbum to item 1 of hdr
set theAlbumArtist to item 2 of hdr
set theYear to (item 3 of hdr) as integer
set theCount to (item 4 of hdr) as integer
set theDisc to (item 5 of hdr) as integer
set theDiscs to (item 6 of hdr) as integer
set theGenre to item 7 of hdr
set doCD to (item 8 of hdr) is "1"
set doCover to (item 9 of hdr) is "1"
set doRename to (item 10 of hdr) is "1"
set pic to missing value
if doCover then
  try
    set pic to (read (POSIX file "/tmp/g3cover.jpg") as JPEG picture)
  end try
end if
set nLib to 0
set nArt to 0
set nCD to 0
tell application "iTunes"
  -- the CD is a SOURCE, not a playlist of the library
  set cdp to missing value
  if doCD then
    try
      repeat with src in (every source)
        if (kind of src) is audio CD then
          set cdp to playlist 1 of src
          exit repeat
        end if
      end repeat
    end try
  end if
  repeat with i from 3 to (count of lns)
    set ln to item i of lns
    if (length of ln) > 3 then
      set parts to text items of ln
      set n to (item 1 of parts) as integer
      set ttl to item 2 of parts
      set artName to item 3 of parts
      set pid to item 4 of parts
      set nn to n as text
      if n < 10 then set nn to "0" & nn
      if cdp is not missing value then
        try
          set t to track n of cdp
          set name of t to ttl
          set nCD to nCD + 1
          try
            set artist of t to artName
            set album of t to theAlbum
          end try
          try
            set album artist of t to theAlbumArtist
          end try
          try
            if theYear > 0 then set year of t to theYear
            if theGenre is not "" then set genre of t to theGenre
          end try
          try
            set track number of t to n
            set track count of t to theCount
            set disc number of t to theDisc
            set disc count of t to theDiscs
          end try
        end try
      end if
      -- library tracks: matched LIVE in iTunes, not from the XML (which lags)
      set found to {}
      if pid is not "" then
        try
          set found to found & (every file track of library playlist 1 whose persistent ID is pid)
        end try
      end if
      if doRename then
        try
          set found to found & (every file track of library playlist 1 whose name is ("Track " & nn) and album is "")
        end try
      end if
      try
        set found to found & (every file track of library playlist 1 whose album is theAlbum and track number is n)
      end try
      set seen to {}
      repeat with ft in found
        set dbid to database ID of ft
        if dbid is not in seen then
          set end of seen to dbid
          try
            if doRename then
              set name of ft to ttl
              set artist of ft to artName
              set album of ft to theAlbum
              set album artist of ft to theAlbumArtist
              if theYear > 0 then set year of ft to theYear
              if theGenre is not "" then set genre of ft to theGenre
              set track number of ft to n
              set track count of ft to theCount
              set disc number of ft to theDisc
              set disc count of ft to theDiscs
              set nLib to nLib + 1
            end if
            if pic is not missing value then
              if (count of artworks of ft) is 0 then
                set data of artwork 1 of ft to pic
                set nArt to nArt + 1
              end if
            end if
          end try
        end if
      end repeat
    end if
  end repeat
end tell
return (nCD as text) & " CD tracks named, " & (nLib as text) & " library tracks named, " & (nArt as text) & " covers added"
'''


def apply(rel, pids_by_n, cover_bytes=None, touch_cd=True, genre="", rename=True):
    """Push a release's names (and cover) into iTunes. pids_by_n maps track
    number -> persistent ID of an already-imported file track."""
    def clean(s):
        return (s or "").replace("\t", " ").replace("\n", " ").replace("\r", " ")
    lines = ["bom"]
    lines.append("\t".join([clean(rel["title"]), clean(rel["artist"]), str(rel.get("year") or 0),
                            str(len(rel["tracks"])), str(rel.get("disc") or 1), str(rel.get("discs") or 1),
                            clean(genre), "1" if touch_cd else "0", "1" if cover_bytes else "0",
                            "1" if rename else "0"]))
    for tr in rel["tracks"]:
        lines.append("\t".join([str(tr["n"]), clean(tr["title"]), clean(tr["artist"] or rel["artist"]),
                                pids_by_n.get(tr["n"], "")]))
    data = ("\ufeff" + "\n".join(lines) + "\n").encode("utf-16-be")
    put(data, "/tmp/g3names.txt")
    if cover_bytes:
        put(cover_bytes, "/tmp/g3cover.jpg")
    put(APPLESCRIPT.encode("ascii"), "/tmp/g3names.applescript")
    rc, out, err = ssh("osascript /tmp/g3names.applescript", timeout=180)
    if rc != 0:
        raise RuntimeError("AppleScript failed: %s" % (err.strip() or out.decode("utf-8", "replace").strip())[:400])
    return out.decode("utf-8", "replace").strip()


def apply_cover(artist, album, pids, cover_bytes):
    """Just the artwork, onto the given library tracks."""
    rel = {"title": album, "artist": artist, "year": 0, "disc": 1, "discs": 1,
           "tracks": [{"n": i + 1, "title": "", "artist": artist} for i in range(len(pids))]}
    # names are not touched: the script sets them to what it is given, so give it the existing ones
    lib = library()
    by_pid = {t["pid"]: t for t in lib["tracks"]}
    rel["tracks"] = []
    pmap = {}
    for i, pid in enumerate(pids):
        t = by_pid.get(pid)
        if not t:
            continue
        rel["tracks"].append({"n": t["n"] or (i + 1), "title": t["name"], "artist": t["artist"] or artist})
        pmap[t["n"] or (i + 1)] = pid
        rel["year"] = t["year"] or rel["year"]
    rel["disc"], rel["discs"] = 1, 1
    return apply(rel, pmap, cover_bytes, touch_cd=False, rename=False)


# ---------------------------------------------------------------- one-shot
def identify():
    """The disc in the drive, looked up. None if no disc."""
    t = toc()
    if not t:
        return None
    did, exact, rels = lookup(t)
    return {"toc": t, "discid": did, "exact": exact, "releases": rels}


def _main(argv):
    cmd = argv[1] if len(argv) > 1 else "cd"
    if cmd == "cd":
        info = identify()
        if not info:
            print("no audio CD in the eMac's drive (or the eMac is off)")
            return 1
        print("disc id %s  (%s)  %d tracks" % (info["discid"], "exact match" if info["exact"] else "fuzzy TOC match",
                                               len(info["toc"]["offsets"])))
        for i, r in enumerate(info["releases"][:8]):
            print("  [%d] %s - %s (%s %s, %d tracks, disc %d/%d)" % (i, r["artist"], r["title"], r["year"] or "?",
                                                                    r["country"] or "?", len(r["tracks"]), r["disc"], r["discs"]))
        if not info["releases"]:
            print("  nothing on MusicBrainz for this disc")
            return 1
        if "--apply" in argv:
            pick = 0
            for a in argv[2:]:
                if a.isdigit():
                    pick = int(a)
            rel = info["releases"][pick]
            for tr in rel["tracks"]:
                print("   %2d. %s" % (tr["n"], tr["title"]))
            jpeg, src = cover(rel)
            print("cover: %s" % (src or "none found"))
            lib = library()
            pmap = unnamed(lib)
            print("unnamed imported tracks: %d" % len(pmap))
            print(apply(rel, pmap, jpeg))
        return 0
    if cmd == "library":
        lib = library()
        print("%d tracks" % lib["count"])
        for a in lib["albums"]:
            print("  %-30s %-40s %2d tracks, %2d with art" % (a["artist"][:30], a["album"][:40], a["tracks"], a["with_art"]))
        return 0
    if cmd == "covers":
        for i, c in enumerate(itunes_covers(argv[2], argv[3])):
            print("  [%d] %s - %s (%s)  %s" % (i, c[0], c[1], c[3], c[2]))
        return 0
    if cmd == "cover-apply":
        artist, album = argv[2], argv[3]
        pick = int(argv[4]) if len(argv) > 4 else 0
        cands = itunes_covers(artist, album)
        raw = _get_image(cands[pick][2])
        lib = library()
        pids = [t["pid"] for t in lib["tracks"] if t["album"] == album and (t["album_artist"] or t["artist"]) == artist]
        print(apply_cover(artist, album, pids, _jpeg(raw)))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
