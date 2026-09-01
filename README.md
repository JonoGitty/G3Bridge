# G3Bridge

Turn a modern PC into a host for vintage Macintoshes, driven by Claude Code.

Two old Apple machines sit on a direct Ethernet cable to a Windows PC. They have
**no route to the internet** — no gateway, no DNS, deliberately. Anything they
need, the PC fetches and serves down the cable. The PC exposes them to Claude as
an MCP server, so an AI assistant can draw on their screens, run commands on
them, move files, and publish pages to them.

```
Claude Code ──MCP stdio──► mcp_server.py ──loopback :9991──► g3d daemon
                                                                 │
                          ┌──────────────────────────────────────┼───────────────┐
                          │                    │                 │               │
                    :9990 TCP            :9980 HTTP        mirror framebuffer   SSH
                    agent socket      site + proxy + API      + screenshots      │
                          └──────────── direct Ethernet cable ───────────────────┘
                                    ┌──────────────┴──────────────┐
                              eMac G4, OS X 10.5          iMac G3, Mac OS 9.2
```

| | machine | screen | how it's driven |
|---|---|---|---|
| `emac` | eMac G4 1.25 GHz, Mac OS X 10.5.6, 1 GB | 1024×768 | SSH + browser |
| `g3` | iMac G3, Mac OS 9.2 | 800×600 | browser, or a Python agent over TCP |

## What the old machines get

A small site the PC serves at `http://192.168.11.10:9980/`, written for
**Safari 3 (2008)** — CSS2 only, no flexbox, ES3-era JavaScript, nothing loaded
from anywhere but the PC.

| page | what it does |
|---|---|
| `/news` | 8 RSS feeds, fetched by the PC on a background thread |
| `/games` | Snake, Breakout, Tetris, Asteroids — canvas, keyboard, no plugins |
| `/web` | a **sanitising proxy**: the PC fetches, strips every script, stylesheet, iframe and remote resource, rewrites all links back through itself |
| `/video` | paste an address; `yt-dlp` fetches it and `ffmpeg` re-encodes it to MPEG-4 Part 2 at 480×360, which is what a G4 can actually decode |
| `/claude-screen` | a surface Claude publishes HTML to |
| `/display` | a framebuffer Claude draws primitives on |
| `/files`, `/upload` | file transfer both ways |
| `/setup` | connect and harden a newly plugged-in machine |

## What Claude gets

Thirteen MCP tools. `g3_publish` puts a page on a Mac's screen; `g3_draw` draws
primitives; `g3_applescript` runs AppleScript on the OS 9 machine;
`g3_screenshot`, `g3_send_file`, `g3_transfers`, `g3_read_received`,
`g3_events`, `g3_devices`, `g3_status`, `g3_clear`, and a kill switch —
`g3_suspend` / `g3_resume`.

Also documented as a skill at `~/.claude/skills/vintage-mac/`, so other sessions
know how to use it. Copy in `docs/SKILL-vintage-mac.md`.

## Running it

```
start.cmd                                       the daemon (WINDOWS Python, see below)
C:\Python310\python.exe tools\netcheck.py       diagnose the link and the isolation
C:\Python310\python.exe tools\discover.py       find a machine that just appeared
C:\Python310\python.exe tools\test_all.py       every test, one exit code
```

**The daemon must run on Windows Python, not WSL.** WSL2 is NAT'd, so a device
on the far end of the cable cannot reach a listener inside it. Windows Defender
already permits `C:\Python310\python.exe` inbound on the active profile, and
Windows Python has Pillow; WSL's Python has no pip at all.

## Isolation

The vintage machines must never reach the internet. That is enforced in two
independent places, and **verified rather than asserted**:

- **On the Mac** — no default gateway and no DNS, so it cannot address anything
  off its own subnet. `ping 8.8.8.8` gives 100% loss; `apple.com` will not
  resolve.
- **On the PC** — `host/isolation.py` checks six controls: IPv4 forwarding,
  `IPEnableRouter`, Internet Connection Sharing (via the `HNetCfg` COM
  interface, because the service merely *running* proves nothing), a network
  bridge, RRAS, and **WSL2's second IP stack** — which every Windows-side query
  is blind to, and which was found forwarding with an interface on both networks.

The listeners bind the cable adapter specifically, and every inbound connection
— agent socket and HTTP alike — is matched against the configured devices by IP
and refused if unknown.

`/web` and `/video` are a deliberate, mediated loosening: internet *content*
reaches the old machines, but they still open no connection to anyone but the PC,
and nothing executable survives the sanitiser.

## Layout

| path | |
|---|---|
| `host/g3d.py` | the daemon: agent socket, control socket, the whole HTTP site |
| `host/mcp_server.py` | MCP stdio server, standard library only |
| `host/protocol.py` | the wire protocol, and the only place framing lives |
| `host/devices.py` | per-machine state: canvas, framebuffer, link, queue |
| `host/raster.py` | software rasteriser, shared by the mirror and the simulator |
| `host/pages.py` | all HTML, written for a 2008 browser |
| `host/webproxy.py` | the sanitising proxy |
| `host/video.py` | fetch and transcode |
| `host/news.py` | RSS on a background thread |
| `host/isolation.py` | the six network controls |
| `host/xfer.py` | file transfer, line endings, resource-fork limits |
| `g3/g3agent.py` | runs **on the OS 9 Mac**. Python 2.3, no threads, Carbon QuickDraw |
| `g3/PCLink.applescript` | a stay-open OS 9 applet that polls for commands |
| `tools/` | simulators, tests, diagnostics |
| `docs/` | research, triage guides, design |

## Development without the hardware

Both vintage machines are simulated, so the host side can be built and tested
with nothing plugged in:

- `tools/fake_g3.py` — speaks the wire protocol, rasterises to PNG
- `tools/fake_applet.py` — speaks the AppleScript channel, including
  deliberately splitting chunks badly to prove the host copes
- `tools/lint_py23.py` — because **Python 3 cannot syntax-check Python 2.3**:
  3.14 parses `except Exception, e` as a tuple of exception classes and passes
  it silently

## Status

See `STATUS.md` for what works, what is untested, and the known faults —
including the iMac G3's thermal problem, which stops it starting when warm.
