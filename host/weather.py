"""A weather channel for the Mac, in the style of the one that used to be on
cable: Local on the 8s. Current conditions, the next twelve hours, the week
ahead, the rain radar, and an almanac page, cycling every twelve seconds.

All of it is fetched and drawn on the PC:

  forecast   Open-Meteo, no key, cached ten minutes
  radar      RainViewer's latest frame, in their "Weather Channel" colour
             scheme, composited over darkened OpenStreetMap tiles with Pillow
  icons      drawn with Pillow at startup -- the Mac gets PNGs, not fonts
  background the gradient, generated once as a PNG, because CSS2 has none

The Mac loads one HTML page and four images, all from the PC.
"""

import datetime
import io
import math
import threading
import time

import requests

import config

UA = "G3Bridge/1.0 (https://github.com/JonoGitty/G3Bridge)"
TTL = 600
LAT = getattr(config, "WEATHER_LAT", 51.4543)
LON = getattr(config, "WEATHER_LON", -0.9781)
NAME = getattr(config, "WEATHER_NAME", "Reading")
TZ = getattr(config, "TIMEZONE", "Europe/London")

_lock = threading.Lock()
_state = {"data": None, "when": 0, "error": "", "radar": None, "radar_when": 0, "radar_error": ""}
_icons = {}

# WMO weather interpretation codes -> (text, icon key)
CODES = {
    0: ("Clear", "sun"), 1: ("Mainly clear", "sun"), 2: ("Partly cloudy", "partly"),
    3: ("Overcast", "cloud"), 45: ("Fog", "fog"), 48: ("Freezing fog", "fog"),
    51: ("Light drizzle", "drizzle"), 53: ("Drizzle", "drizzle"), 55: ("Heavy drizzle", "rain"),
    56: ("Freezing drizzle", "sleet"), 57: ("Freezing drizzle", "sleet"),
    61: ("Light rain", "rain"), 63: ("Rain", "rain"), 65: ("Heavy rain", "rain"),
    66: ("Freezing rain", "sleet"), 67: ("Freezing rain", "sleet"),
    71: ("Light snow", "snow"), 73: ("Snow", "snow"), 75: ("Heavy snow", "snow"), 77: ("Snow grains", "snow"),
    80: ("Showers", "shower"), 81: ("Showers", "shower"), 82: ("Heavy showers", "rain"),
    85: ("Snow showers", "snow"), 86: ("Snow showers", "snow"),
    95: ("Thunderstorm", "storm"), 96: ("Thunderstorm, hail", "storm"), 99: ("Thunderstorm, hail", "storm"),
}


def describe(code, is_day=1):
    text, icon = CODES.get(int(code or 0), ("Unknown", "cloud"))
    if not is_day and icon in ("sun", "partly"):
        icon = "moon" if icon == "sun" else "partlynight"
    return text, icon


def compass(deg):
    pts = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return pts[int((float(deg or 0) + 11.25) // 22.5) % 16]


# ---------------------------------------------------------------- forecast
def fetch():
    params = {
        "latitude": LAT, "longitude": LON, "timezone": TZ, "forecast_days": 7,
        "wind_speed_unit": "mph",
        "current": "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,"
                   "weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m",
        "hourly": "temperature_2m,precipitation_probability,precipitation,weather_code,wind_speed_10m,is_day",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_sum,"
                 "precipitation_probability_max,wind_speed_10m_max,uv_index_max",
    }
    r = requests.get("https://api.open-meteo.com/v1/forecast", params=params,
                     headers={"User-Agent": UA}, timeout=20)
    r.raise_for_status()
    return r.json()


def data():
    """The forecast, at most ten minutes old. Never raises: returns the last
    good copy and an error string."""
    with _lock:
        stale = time.time() - _state["when"] > TTL
        if stale or _state["data"] is None:
            try:
                _state["data"] = fetch()
                _state["when"] = time.time()
                _state["error"] = ""
            except Exception as e:
                _state["error"] = "%s: %s" % (type(e).__name__, str(e)[:120])
                if _state["data"] is None:
                    return None, _state["error"]
        return _state["data"], _state["error"]


def hourly_from_now(d, hours=12):
    """The next `hours` rows of the hourly table, starting at the current hour."""
    h = d["hourly"]
    now = datetime.datetime.now().strftime("%Y-%m-%dT%H:00")
    times = h["time"]
    try:
        i = times.index(now)
    except ValueError:
        i = 0
    out = []
    for k in range(i, min(i + hours, len(times))):
        t = times[k]
        out.append({"hour": datetime.datetime.strptime(t, "%Y-%m-%dT%H:%M").strftime("%H:%M"),
                    "temp": h["temperature_2m"][k], "pop": h["precipitation_probability"][k],
                    "rain": h["precipitation"][k], "code": h["weather_code"][k],
                    "wind": h["wind_speed_10m"][k], "day": h.get("is_day", [1] * len(times))[k]})
    return out


def daily(d):
    dd = d["daily"]
    out = []
    for k, t in enumerate(dd["time"]):
        day = datetime.datetime.strptime(t, "%Y-%m-%d")
        out.append({"name": "Today" if k == 0 else day.strftime("%a"), "date": day.strftime("%d %b"),
                    "code": dd["weather_code"][k], "hi": dd["temperature_2m_max"][k], "lo": dd["temperature_2m_min"][k],
                    "rain": dd["precipitation_sum"][k], "pop": dd["precipitation_probability_max"][k],
                    "wind": dd["wind_speed_10m_max"][k], "uv": dd["uv_index_max"][k],
                    "sunrise": dd["sunrise"][k][-5:], "sunset": dd["sunset"][k][-5:]})
    return out


# ---------------------------------------------------------------- pictures
def background(w=1024, h=768):
    """The vertical gradient: deep navy to a lighter blue, with a band of
    orange at the very bottom for the status bar."""
    from PIL import Image
    im = Image.new("RGB", (1, h))
    px = im.load()
    for y in range(h):
        f = y / float(h)
        r = int(8 + 30 * f)
        g = int(18 + 60 * f)
        b = int(78 + 110 * f)
        px[0, y] = (r, g, b)
    im = im.resize((w, h))
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def icon(key, size=112):
    """Simple, bold weather glyphs drawn with Pillow. Cached."""
    if (key, size) in _icons:
        return _icons[(key, size)]
    from PIL import Image, ImageDraw
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    s = size / 112.0
    Y = (255, 210, 60, 255)
    W = (245, 248, 255, 255)
    G = (200, 208, 224, 255)
    B = (110, 170, 255, 255)
    DK = (150, 160, 190, 255)

    def sun(cx, cy, r):
        for a in range(0, 360, 45):
            x1 = cx + math.cos(math.radians(a)) * r * 1.35
            y1 = cy + math.sin(math.radians(a)) * r * 1.35
            x2 = cx + math.cos(math.radians(a)) * r * 1.8
            y2 = cy + math.sin(math.radians(a)) * r * 1.8
            d.line((x1, y1, x2, y2), fill=Y, width=max(2, int(5 * s)))
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=Y)

    def moon(cx, cy, r):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=W)
        d.ellipse((cx - r * 0.45, cy - r * 1.05, cx + r * 1.15, cy + r * 0.55), fill=(0, 0, 0, 0))

    def cloud(cx, cy, w, col):
        h = w * 0.55
        d.ellipse((cx - w * 0.5, cy - h * 0.2, cx - w * 0.5 + h, cy + h * 0.8), fill=col)
        d.ellipse((cx - w * 0.25, cy - h * 0.7, cx - w * 0.25 + h * 1.25, cy + h * 0.55), fill=col)
        d.ellipse((cx + w * 0.05, cy - h * 0.35, cx + w * 0.05 + h * 1.0, cy + h * 0.65), fill=col)
        d.rectangle((cx - w * 0.5 + h * 0.5, cy + h * 0.25, cx + w * 0.05 + h * 0.5, cy + h * 0.8), fill=col)

    def drops(cx, cy, n, col, length):
        for i in range(n):
            x = cx + (i - (n - 1) / 2.0) * 16 * s
            d.line((x, cy, x - 5 * s, cy + length), fill=col, width=max(2, int(4 * s)))

    def flakes(cx, cy, n):
        for i in range(n):
            x = cx + (i - (n - 1) / 2.0) * 18 * s
            y = cy + (i % 2) * 8 * s
            r = 4 * s
            d.ellipse((x - r, y - r, x + r, y + r), fill=W)

    c = size / 2.0
    if key == "sun":
        sun(c, c, 24 * s)
    elif key == "moon":
        moon(c, c, 26 * s)
    elif key == "partly":
        sun(c - 18 * s, c - 18 * s, 18 * s)
        cloud(c + 4 * s, c + 12 * s, 70 * s, W)
    elif key == "partlynight":
        moon(c - 18 * s, c - 18 * s, 18 * s)
        cloud(c + 4 * s, c + 12 * s, 70 * s, G)
    elif key == "cloud":
        cloud(c, c, 84 * s, W)
    elif key == "fog":
        cloud(c, c - 12 * s, 70 * s, G)
        for i in range(3):
            y = c + (18 + i * 11) * s
            d.line((c - 34 * s, y, c + 34 * s, y), fill=DK, width=max(2, int(4 * s)))
    elif key in ("rain", "drizzle", "shower", "sleet"):
        cloud(c, c - 14 * s, 76 * s, G if key != "shower" else W)
        if key == "shower":
            sun(c - 30 * s, c - 34 * s, 12 * s)
            cloud(c, c - 14 * s, 76 * s, W)
        drops(c, c + 20 * s, 3 if key == "drizzle" else 4, B if key != "sleet" else W, (14 if key == "drizzle" else 22) * s)
    elif key == "snow":
        cloud(c, c - 14 * s, 76 * s, G)
        flakes(c, c + 28 * s, 4)
    elif key == "storm":
        cloud(c, c - 16 * s, 78 * s, DK)
        d.polygon([(c + 2 * s, c + 2 * s), (c - 12 * s, c + 26 * s), (c - 1 * s, c + 26 * s),
                   (c - 8 * s, c + 48 * s), (c + 14 * s, c + 18 * s), (c + 3 * s, c + 18 * s),
                   (c + 10 * s, c + 2 * s)], fill=Y)
    else:
        cloud(c, c, 84 * s, W)
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    _icons[(key, size)] = buf.getvalue()
    return _icons[(key, size)]


def _tile_xy(lat, lon, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def radar(size=640, zoom=7):
    """A JPEG: the latest RainViewer frame over darkened OpenStreetMap tiles,
    centred on the configured location, with a marker. Cached ten minutes."""
    with _lock:
        if _state["radar"] is not None and time.time() - _state["radar_when"] < TTL:
            return _state["radar"], _state["radar_error"]
    try:
        img = _radar(size, zoom)
        with _lock:
            _state["radar"], _state["radar_when"], _state["radar_error"] = img, time.time(), ""
        return img, ""
    except Exception as e:
        err = "%s: %s" % (type(e).__name__, str(e)[:120])
        with _lock:
            _state["radar_error"] = err
            return _state["radar"], err


def _radar(size, zoom):
    from PIL import Image, ImageDraw, ImageEnhance
    meta = requests.get("https://api.rainviewer.com/public/weather-maps.json",
                        headers={"User-Agent": UA}, timeout=20).json()
    frames = (meta.get("radar") or {}).get("past") or []
    if not frames:
        raise RuntimeError("RainViewer returned no frames")
    frame = frames[-1]
    host = meta.get("host", "https://tilecache.rainviewer.com")
    fx, fy = _tile_xy(LAT, LON, zoom)
    cx, cy = int(fx), int(fy)
    tiles = 3
    T = 256
    canvas = Image.new("RGB", (T * tiles, T * tiles), (10, 20, 60))
    overlay = Image.new("RGBA", (T * tiles, T * tiles), (0, 0, 0, 0))
    sess = requests.Session()
    sess.headers["User-Agent"] = UA
    for j in range(tiles):
        for i in range(tiles):
            tx, ty = cx - 1 + i, cy - 1 + j
            try:
                r = sess.get("https://tile.openstreetmap.org/%d/%d/%d.png" % (zoom, tx, ty), timeout=15)
                if r.status_code == 200:
                    canvas.paste(Image.open(io.BytesIO(r.content)).convert("RGB"), (i * T, j * T))
            except Exception:
                pass
            try:
                # colour scheme 4 is RainViewer's "The Weather Channel"; 1_1 = smoothed, snow shown
                r = sess.get("%s%s/%d/%d/%d/%d/4/1_1.png" % (host, frame["path"], T, zoom, tx, ty), timeout=15)
                if r.status_code == 200:
                    overlay.paste(Image.open(io.BytesIO(r.content)).convert("RGBA"), (i * T, j * T))
            except Exception:
                pass
    canvas = ImageEnhance.Brightness(canvas).enhance(0.42)
    canvas = ImageEnhance.Color(canvas).enhance(0.35)
    canvas = canvas.convert("RGBA")
    canvas.alpha_composite(overlay)
    # marker at the location
    px = int((fx - (cx - 1)) * T)
    py = int((fy - (cy - 1)) * T)
    d = ImageDraw.Draw(canvas)
    d.ellipse((px - 7, py - 7, px + 7, py + 7), outline=(255, 210, 60, 255), width=3)
    d.line((px - 14, py, px + 14, py), fill=(255, 210, 60, 255), width=2)
    d.line((px, py - 14, px, py + 14), fill=(255, 210, 60, 255), width=2)
    # crop to a square around the marker
    half = T * tiles // 2
    box = (max(0, min(px - half, T * tiles - 2 * half)), max(0, min(py - half, T * tiles - 2 * half)))
    canvas = canvas.crop((box[0], box[1], box[0] + 2 * half, box[1] + 2 * half))
    canvas = canvas.convert("RGB").resize((size, size), Image.LANCZOS)
    stamp = datetime.datetime.fromtimestamp(frame["time"]).strftime("%H:%M")
    d = ImageDraw.Draw(canvas)
    d.rectangle((0, size - 22, size, size), fill=(10, 18, 50))
    d.text((8, size - 18), "radar %s   RainViewer / OpenStreetMap" % stamp, fill=(255, 210, 60))
    buf = io.BytesIO()
    canvas.save(buf, "JPEG", quality=80, optimize=True)
    return buf.getvalue()
