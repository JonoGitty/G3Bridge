# G3Bridge — Status

Created 2026-09-01.

## Goal
Claude Code on the PC sends drawing/exec commands; an iMac G3 running Mac OS 9
receives them over Ethernet and renders them natively.

## Open questions (blocking exact G3-side steps)
- [ ] Exact machine: iMac G3 model (tray-load / slot-load) — decides ports available
- [ ] Exact OS version — "9.7" is not a real Mac OS release (real: 9.0, 9.0.4, 9.1, 9.2.1, 9.2.2)
- [ ] Is the G3 on the same LAN as this PC? (Ethernet is the only sane transport — iMac G3 has no serial port)
- [ ] What is already installed on it? (browser version, any dev tools, StuffIt)

## Design decisions locked
- **Transport = Ethernet/TCP.** The iMac G3 has no serial/ADB/floppy; USB on OS 9 is awkward. Ethernet is built in.
- **G3 dials out to the host.** Avoids configuring inbound services on the Mac.
- **No JSON on the G3 side.** Target runtime is old Python 2.x, which predates the `json` module. Line protocol parsed with `shlex` instead.
- **Two tiers**, so it works before anything is installed on the Mac:
  - Tier 0 — zero install: the Mac's browser points at the host's HTTP server.
  - Tier 1 — full fidelity: a small agent on the Mac drawing with native QuickDraw.

## Build board
- [x] Repo scaffold
- [ ] Protocol spec
- [ ] `tools/fake_g3.py` simulated client
- [ ] `host/g3d.py` daemon
- [ ] `host/mcp_server.py` MCP stdio server
- [ ] Register MCP server with Claude Code
- [ ] G3-side agent + install instructions
