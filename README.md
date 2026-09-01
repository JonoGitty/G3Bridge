# G3Bridge

Turn this PC into a **host computer for a Mac OS 9 iMac G3**, driven by Claude Code.

Claude issues a tool call on the modern machine; the G3 executes it and draws on its own
CRT with native QuickDraw. The G3 becomes an output device Claude can program.

```
Claude Code  ──MCP(stdio)──►  g3d daemon  ──Ethernet/TCP──►  iMac G3 (Mac OS 9)
                                  │                              │
                                  └── HTTP :9080 ────────────────┘  (bootstrap + no-install mode)
```

## Status
Scaffold. See `STATUS.md` for the live build board.

## Layout
| Path | What |
|---|---|
| `host/`  | Everything that runs on the modern PC (daemon + MCP server) |
| `g3/`    | Everything that gets copied onto the Mac OS 9 machine |
| `tools/` | Test harness, incl. a simulated G3 so the host can be developed without the hardware |
| `docs/`  | Design notes and research findings |
