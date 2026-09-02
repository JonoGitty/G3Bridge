"""The weather channel. Offline: WMO code text, compass points, tile maths,
every icon draws, the background draws. Live: one Open-Meteo fetch, reported
as a skip on a network error.

    C:\\Python310\\python.exe tools\\test_weather.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "host"))
import weather  # noqa: E402

FAILS = []


def check(cond, what):
    print("  %s  %s" % ("ok  " if cond else "FAIL", what))
    if not cond:
        FAILS.append(what)


def offline():
    print("offline")
    check(weather.describe(0) == ("Clear", "sun") and weather.describe(0, 0) == ("Clear", "moon"), "clear by day and night")
    check(weather.describe(95)[1] == "storm" and weather.describe(999)[0] == "Unknown", "storm, and an unknown code")
    check(weather.compass(0) == "N" and weather.compass(225) == "SW" and weather.compass(359) == "N", "compass points")
    x, y = weather._tile_xy(51.4543, -0.9781, 7)
    check(int(x) == 63 and int(y) == 42, "tile maths puts Reading in 63/42 at zoom 7 (%d/%d)" % (int(x), int(y)))
    for key in ("sun", "moon", "partly", "partlynight", "cloud", "fog", "rain", "drizzle", "shower", "sleet", "snow", "storm"):
        png = weather.icon(key, 64)
        check(png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) > 150, "icon %s draws" % key)
    bg = weather.background(200, 100)
    check(bg[:8] == b"\x89PNG\r\n\x1a\n", "background draws")


def live():
    print("live")
    try:
        d = weather.fetch()
    except Exception as e:
        print("  skip  network: %s" % e)
        return
    check("current" in d and "temperature_2m" in d["current"], "Open-Meteo answers with current conditions")
    check(len(weather.daily(d)) == 7 and len(weather.hourly_from_now(d)) == 12, "7 days and 12 hours")


if __name__ == "__main__":
    offline()
    live()
    print("\n%d failure%s" % (len(FAILS), "" if len(FAILS) == 1 else "s"))
    sys.exit(1 if FAILS else 0)
