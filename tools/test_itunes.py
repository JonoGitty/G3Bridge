"""iTunes-through-the-PC. Offline: the MusicBrainz disc ID against two discs
whose IDs MusicBrainz itself published (recorded here so the test needs no
network), release parsing, the unnamed-track matcher, and the AppleScript's
hygiene (pure ASCII, no reserved words used as variables). Live, if the eMac
answers over SSH: read its CD's table of contents.

    C:\\Python310\\python.exe tools\\test_itunes.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "host"))
import itunes  # noqa: E402

FAILS = []


def check(cond, what):
    print("  %s  %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAILS.append(what)


# Two discs of Queens of the Stone Age - Songs for the Deaf, as MusicBrainz
# publishes them (ws/2/release/<id>?inc=discids), with the IDs it computed.
VECTORS = [
    ("18QvTLdwKmtqEw2lrGTwlKtin6I-", 315750,
     [7022, 21472, 42372, 57255, 83682, 111875, 117827, 131795, 145830, 158595, 176957, 204330, 219022, 249227, 274575, 290955, 302640]),
    ("z6LIalLr2DnR_K9KI8HSFa9dhCw-", 296333,
     [150, 14650, 35553, 50431, 76864, 105055, 111004, 124978, 139011, 151774, 170137, 197507, 212178, 240642, 267789, 284324, 293763]),
]


def offline():
    print("offline")
    for did, sectors, offsets in VECTORS:
        t = {"first": 1, "last": len(offsets), "leadout": sectors, "offsets": offsets}
        check(itunes.discid(t) == did, "disc id %s" % did)
    rel = {"id": "r1", "title": "Album", "date": "2002-08-27", "country": "GB", "status": "Official",
           "artist-credit": [{"name": "Band", "joinphrase": " & "}, {"name": "Friend"}],
           "release-group": {"id": "rg1"},
           "media": [{"position": 1, "track-count": 2, "discs": [{"id": "X"}],
                      "tracks": [{"position": 1, "title": "One", "length": 1000, "recording": {"artist-credit": [{"name": "Band"}]}},
                                 {"position": 2, "title": "Two", "recording": {"title": "Two", "length": 2000}}]}]}
    r = itunes._release(rel, {"offsets": [150, 5000]}, "X")
    check(r["artist"] == "Band & Friend" and r["year"] == 2002 and r["rg"] == "rg1", "release credit, year, group")
    check([x["title"] for x in r["tracks"]] == ["One", "Two"] and r["tracks"][0]["artist"] == "Band",
          "track titles and per-track credit")
    lib = {"tracks": [{"name": "Track 03", "album": "", "artist": "", "pid": "P3"},
                      {"name": "Track 04", "album": "Named", "artist": "", "pid": "P4"},
                      {"name": "Song", "album": "", "artist": "", "pid": "P5"}]}
    check(itunes.unnamed(lib) == {3: "P3"}, "only 'Track NN' with no album counts as unnamed")
    scr = itunes.APPLESCRIPT
    check(all(ord(ch) < 128 for ch in scr), "AppleScript is pure ASCII (osascript on 10.5 guesses encodings otherwise)")
    check(not re.search(r"\bset (named|art|name|track|source|kind) to\b", scr), "no reserved words used as variables")
    check("as JPEG picture" in scr and "as picture" not in scr.replace("as JPEG picture", ""),
          "artwork coerced as JPEG picture (as picture fails with -116 in iTunes)")
    check("every source" in scr and "kind of src" in scr, "CD found as a source, not a playlist")
    opened = sum(1 for ln in scr.splitlines() if ln.strip() == "try")
    closed = sum(1 for ln in scr.splitlines() if ln.strip() == "end try")
    check(opened == closed and opened > 0, "try blocks balanced (%d)" % opened)


def live():
    if not itunes.reachable():
        print("live: eMac not answering over SSH, skipped")
        return
    print("live: the eMac")
    t = itunes.toc()
    if t is None:
        print("  skip  no audio CD in the drive")
        return
    check(t["first"] == 1 and len(t["offsets"]) == t["last"] and t["leadout"] > t["offsets"][-1],
          "TOC read from /Volumes/Audio CD: %d tracks" % len(t["offsets"]))
    did = itunes.discid(t)
    check(re.match(r"^[A-Za-z0-9._-]{28}$", did) is not None, "disc id well-formed: %s" % did)


if __name__ == "__main__":
    offline()
    live()
    print("\n%d failure%s" % (len(FAILS), "" if len(FAILS) == 1 else "s"))
    sys.exit(1 if FAILS else 0)
