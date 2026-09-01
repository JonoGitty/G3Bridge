# G3Bridge — Status

Created 2026-09-01.

## Goal
Claude Code on the PC sends drawing/exec commands; an iMac G3 running Mac OS 9
receives them over Ethernet and renders them natively.

## Open questions (blocking exact G3-side steps)
- [ ] Exact machine: iMac G3 model (tray-load / slot-load) — decides ports available
- [ ] Exact OS version — "9.7" is not a real Mac OS release (real: 9.0, 9.0.4, 9.1, 9.2.1, 9.2.2)
- [x] ~~Is the G3 on the same LAN?~~ **DIRECT ETHERNET CABLE, PC <-> iMac, no router** (Jono, 1 Sep)
- [ ] What is already installed on it? (browser version, any dev tools, StuffIt)

## Design decisions locked
- **Transport = Ethernet/TCP, direct cable.** The iMac G3 has no serial/ADB/floppy; USB on OS 9 is awkward. Ethernet is built in.
- **Static IPs, no DHCP.** A direct cable means nothing is handing out addresses. PC `192.168.77.1`, iMac `192.168.77.2`, mask `255.255.255.0`, no gateway.
- **The daemon runs on WINDOWS Python (`C:\Python310`), not WSL.** WSL2 sits behind NAT, so a device on a direct cable cannot reach a listener inside it. The MCP server runs in WSL and reaches the daemon over loopback.
- **G3 dials out to the host.** Avoids configuring inbound services on the Mac.
- **No JSON on the G3 side.** Target runtime is old Python 2.x, which predates the `json` module. Line protocol parsed with `shlex` instead.
- **Two tiers**, so it works before anything is installed on the Mac:
  - Tier 0 — zero install: the Mac's browser points at the host's HTTP server.
  - Tier 1 — full fidelity: a small agent on the Mac drawing with native QuickDraw.

## Build board
- [x] Repo scaffold
- [x] Protocol spec (`host/protocol.py`) - round-trip tested incl. quoting/escapes
- [x] `tools/fake_g3.py` simulated client - rasterises to PNG, Pillow or dependency-free
- [x] `tools/drive.py` manual command driver
- [x] `host/g3d.py` daemon - verified end-to-end, 22/22 demo commands OK
- [ ] `host/mcp_server.py` MCP stdio server
- [ ] Register MCP server with Claude Code
- [ ] HTTP listener (:9980) for Tier 0 + bootstrap
- [ ] G3-side agent + install instructions
- [ ] Static IP setup on both ends, cable test

## Verified working (1 Sep)
Ran the whole chain on Windows Python 3.10 (the production layout):
`drive.py -> g3d :9991 -> :9990 -> fake_g3 -> screen_win.png`.
All primitives render: CLEAR/PEN/PENSIZE/RECT/OVAL/LINE/MOVETO/LINETO/TEXT/PIXEL/FLUSH.
Artefacts: `run/screen.png` (WSL, no glyphs), `run/screen_win.png` (Windows, with text).

## Bugs found and fixed
- **Two readers on one socket.** The agent-handler pump and `Link.send()` both
  called read on the G3 socket, so the pump ate replies and every command after
  the first failed with "agent closed the connection". Fixed: the pump is now the
  only reader and wakes per-sequence waiters via `threading.Event`.
