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

# Only accept an agent connection from this address. None = accept any.
ALLOWED_G3_IP = SUGGESTED_G3_IP

# --- file transfer ---------------------------------------------------------
# Two drop folders. Nothing is executed, only stored and served.
TO_MAC_DIR = "transfer/to-mac"       # PC -> Mac. Served over HTTP.
FROM_MAC_DIR = "transfer/from-mac"   # Mac -> PC. Written by uploads.
MAX_UPLOAD_BYTES = 64 * 1024 * 1024

# Mac OS 9 is cooperatively multitasked. If the agent window goes behind
# another app its socket stalls until it comes back. Do not read a stall as
# a dead peer.
REPLY_TIMEOUT = 30.0
