# G3Bridge

Turn this PC into a **host computer for a Mac OS 9 iMac G3**, driven by Claude Code.

Claude issues a tool call on the modern machine; the G3 executes it and draws on
its own CRT with native QuickDraw. The G3 becomes an output device Claude can program.

```
Claude Code ──MCP stdio──► mcp_server.py ──loopback :9991──► g3d daemon
                                                                │
                                        ┌───────────────────────┼──────────────────┐
                                        │                       │                  │
                                   :9990 TCP              :9980 HTTP        mirror framebuffer
                                        │                       │                  │
                                 Tier 1 agent            Tier 0 browser      g3_screenshot
                                 (QuickDraw)             (no install)
                                        └──── direct Ethernet cable ────┘
                                                    iMac G3, Mac OS 9
```

## Two tiers

**Tier 0 — nothing installed on the Mac.** Point the Mac's browser at
`http://<pc>:9980/`. The host keeps a mirror of the canvas, renders it as a
web-safe GIF, and the browser refreshes it. Clicking the picture sends the
coordinates back via a server-side image map. Roughly 1–3 fps: a slideshow,
but it works on a completely untouched machine.

**Tier 1 — `g3agent.py` running on the Mac under MacPython 2.3.** Real
QuickDraw calls, sharp text, and mouse/keyboard events back to the host.

Both tiers take the same commands, so Claude's tools are identical either way.

## Quick start

```
start.cmd                                    # on the PC
C:\Python310\python.exe tools\netcheck.py    # tells you what's still wrong
```
Then restart Claude Code so it picks up the MCP server, and see
`docs/SETUP.md` and `g3/README-G3.txt`.

## Tools Claude gets

| Tool | Does |
|---|---|
| `g3_status` | is the Mac connected, what size is its screen |
| `g3_draw` | run a list of drawing commands and present them |
| `g3_clear` | wipe the screen |
| `g3_screenshot` | look at what's currently displayed |
| `g3_events` | drain clicks and keypresses from the Mac |

## Layout

| Path | What |
|---|---|
| `host/config.py` | canvas size, ports, addresses — edit here |
| `host/protocol.py` | the wire protocol, and the only place framing lives |
| `host/g3d.py` | the long-lived daemon: agent socket, control socket, HTTP display |
| `host/raster.py` | software rasteriser, shared by the mirror and the simulator |
| `host/mcp_server.py` | MCP stdio server, stdlib only |
| `g3/g3agent.py` | runs **on the Mac**. Python 2.3, no threads, Carbon QuickDraw |
| `g3/README-G3.txt` | what to do at the Mac, in plain text |
| `tools/fake_g3.py` | a simulated Mac, so the host can be developed with no hardware |
| `tools/drive.py` | send raw commands by hand |
| `tools/netcheck.py` | diagnose the cable, addresses, ports and firewall |
| `tools/lint_py23.py` | catch anything in the agent that MacPython 2.3 can't run |
| `tools/test_mcp.py` | drive the MCP server over real JSON-RPC |
| `tools/test_parser_interop.py` | prove the Mac's parser agrees with the host's encoder |
| `docs/DESIGN-from-research.md` | the full research pass this was built from |

## Why the daemon runs on Windows Python and not WSL

WSL's Hyper-V firewall defaults to `DefaultInboundAction = Block`, so a LAN
device reaching a WSL listener needs an elevated firewall rule that doesn't
exist here. Windows Defender already permits `C:\python310\python.exe` inbound
on any TCP port on the Public profile, which is the active profile. Windows
Python also already has Pillow; WSL's Python 3.14 has no pip at all.
