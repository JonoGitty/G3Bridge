"""Shared settings. Edit here, not in the individual modules."""

# Canvas. 800x600 is a native mode on every iMac G3 CRT and fits in the 2MB
# VRAM of even a Rev A at Millions (1.83MB). 1024x768x32 needs 3.0MB and a
# Rev A cannot do it. It is also 4x fewer pixels than 1024x768, which is
# roughly 4x the frame rate on the browser display path.
CANVAS_W = 800
CANVAS_H = 600

AGENT_PORT = 9990        # the Mac dials in here
CONTROL_PORT = 9991      # loopback only; the MCP server talks to this
HTTP_PORT = 9980         # Tier 0 display + bootstrap downloads

# The Mac must be given a static address by hand -- a direct cable has no DHCP.
# Do NOT use 192.168.1.x: that collides with the WiFi LAN this PC is already on.
SUGGESTED_PC_IP = "192.168.11.10"
SUGGESTED_G3_IP = "192.168.11.2"
SUGGESTED_MASK = "255.255.255.0"

# --- isolation -------------------------------------------------------------
# The G3 is a 1999 machine with no security patches. It must only ever see this
# PC. Two halves to that:
#   outbound  the Mac has no gateway and no DNS, so it cannot route off-subnet
#   inbound   we bind our listeners to the CABLE adapter only, so the rest of
#             the house LAN cannot reach the bridge either
# Set BIND_TO_CABLE_ONLY = False only for local testing with no Mac attached.
BIND_TO_CABLE_ONLY = True
LOOPBACK_ALWAYS_OK = True     # keep 127.0.0.1 usable for the test harness

# Only machines listed in DEVICES may connect. Anything else is refused.
ALLOWED_G3_IP = SUGGESTED_G3_IP        # kept for older callers

# --- the machines ----------------------------------------------------------
# Keyed by a short name used in tool calls. `ip` is how an inbound connection
# is identified, so it must match what the machine is actually configured with.
# Add a machine here and the bridge picks it up on restart.
DEVICES = {
    "g3": {
        "ip": "192.168.11.2",
        "canvas": (800, 600),          # native on the iMac G3 CRT
        "os": "macos9",
        "label": "iMac G3 - Mac OS 9.2",
    },
    "emac": {
        "ip": "192.168.11.3",
        "canvas": (1024, 768),         # eMac standard; the 17in CRT maxes at 1280x960
        "os": "macosx",                # OpenSSH_5.1 banner => Mac OS X 10.5 Leopard
        "label": "eMac",
    },
}
DEFAULT_DEVICE = "g3"

# --- Tier 0 browser display ------------------------------------------------
# How often the Mac's browser reloads the page. Every reload is a full page
# teardown and rebuild in a browser with a FIXED memory partition, so this is
# the main lever on stability, not just speed. Raise it if the Mac is unhappy.
REFRESH_SECONDS = 5

# --- file transfer ---------------------------------------------------------
# Two drop folders. Nothing is executed, only stored and served.
TO_MAC_DIR = "transfer/to-mac"       # PC -> Mac. Served over HTTP.
FROM_MAC_DIR = "transfer/from-mac"   # Mac -> PC. Written by uploads.
MAX_UPLOAD_BYTES = 64 * 1024 * 1024

# --- the web translation layer --------------------------------------------
# /web fetches pages on the PC and rewrites them for Safari 3. When a page
# comes back nearly empty (a single-page app), the PC can run its JavaScript
# in a headless Chromium first. That needs Playwright in Windows Python:
#   C:\Python310\python.exe -m pip install playwright && playwright install chromium
WEB_RENDER = True
WEB_IMAGE_MAX_W = 900                  # every proxied image is re-encoded no wider than this
WEB_MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
# Converted images and picture-mode strips live under run/webcache. Delete it
# whenever you like; it is only a cache.

# --- weather channel ---------------------------------------------------------
# /weather is a Weather-Channel-style display for the Mac. Open-Meteo for the
# forecast (no key), RainViewer for the radar, OpenStreetMap for the base map.
WEATHER_LAT = 51.4543
WEATHER_LON = -0.9781
WEATHER_NAME = "Reading, Berkshire"

# --- clock -----------------------------------------------------------------
# The Macs cannot reach a time server, so /time lets them set their clock from
# the PC. This is the Olson zone name they are told to use.
TIMEZONE = "Europe/London"

import os as _os
RUN_DIR_ABS = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "..", "run")

# Mac OS 9 is cooperatively multitasked. If the agent window goes behind
# another app its socket stalls until it comes back. Do not read a stall as
# a dead peer.
REPLY_TIMEOUT = 30.0
