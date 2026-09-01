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

# Mac OS 9 is cooperatively multitasked. If the agent window goes behind
# another app its socket stalls until it comes back. Do not read a stall as
# a dead peer.
REPLY_TIMEOUT = 30.0
