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
- [x] Protocol spec (`host/protocol.py`)
- [x] `tools/fake_g3.py` simulated client
- [x] `tools/drive.py` manual driver
- [x] `host/g3d.py` daemon
- [x] `host/raster.py` shared rasteriser + host-side mirror
- [x] `host/mcp_server.py` MCP stdio server (5 tools)
- [x] Registered with Claude Code (`claude mcp get g3bridge` -> Connected)
- [x] HTTP listener :9980 - Tier 0 display + bootstrap downloads
- [x] `g3/g3agent.py` Mac OS 9 agent (Python 2.3 / Carbon)
- [x] `g3/README-G3.txt` + `docs/SETUP.md`
- [ ] **Untested on real hardware** - see Risks
- [ ] Animated-GIF path for Tier 0 motion (research says this is the big win)
- [ ] Tier 0.5: AppleScript + URL Access Scripting stay-open applet

## Verified working (1 Sep, simulated Mac)
- Full chain on Windows Python 3.10: MCP JSON-RPC -> g3d -> agent -> pixels. 48/48 commands.
- `tools/test_mcp.py` 14/14 checks pass.
- `tools/test_parser_interop.py` 12/12 - the Mac's parser agrees with the host's encoder.
- `tools/lint_py23.py` - agent clean for Python 2.3.
- Tier 0 with NO agent attached: draws to the mirror, serves a real GIF87a,
  ismap click round-trips to an event.
- Bootstrap serves .txt CR-converted and .py left as LF.

## Bugs found and fixed
- **Two readers on one socket.** The agent pump and `Link.send()` both read the
  G3 socket, so replies were eaten and every command after the first failed.
  Single-reader pump with per-sequence waiters now.
- **Empty quoted string dropped by the agent parser.** `TEXT 0 0 ""` arrived with
  a missing argument and would have thrown on the Mac. Caught by the interop test.
- **A Python 3 syntax check cannot validate Python 2.3.** 3.14 parses
  `except Exception, e` as a tuple of exception classes and passes it silently.
  Hence `tools/lint_py23.py`.
- **Stale STATUS.** Reported agent width/height while saying `state=waiting`.

## Risks / still unknown
- **Nothing has touched the real machine yet.** The Carbon calls in `g3agent.py`
  follow verified API shapes but are unrun. `g3agent.py selftest` draws with no
  network, which is the right first test.
- **Which iMac G3 and which OS version.** "9.7" is not a real release. If it is
  9.0.x the bundled browser is IE 4.5 (no PNG at all - hence GIF everywhere) and
  CarbonLib may be below MacPython's 1.3 floor.
- **Cable type.** The iMac G3 likely has no auto-MDI-X. A modern gigabit NIC
  usually compensates, but a switch between the two removes the doubt.
- **Frame rate on Tier 0** is estimated at 1-3 fps, not measured.
