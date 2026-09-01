# G3Bridge setup

## On the PC

1. `start.cmd` — runs the daemon on Windows Python 3.10.
2. `C:\Python310\python.exe tools\netcheck.py` — checks every link in the chain
   and prints the exact fix for whatever is broken.
3. Restart Claude Code so it picks up the MCP server.

The daemon must run on **Windows** Python, not WSL. Two reasons, both verified:
the Windows Defender rules on this machine already permit
`C:\python310\python.exe` inbound on any TCP port on the *Public* profile
(which is the active profile), whereas the WSL VM's Hyper-V firewall defaults
to `DefaultInboundAction = Block` and would need an elevated
`New-NetFirewallHyperVRule` that does not exist here. Windows Python also
already has Pillow 11.2.1; WSL's Python 3.14 has no pip at all
(PEP 668 externally-managed).

## Addressing

The PC is already on `192.168.1.0/24` over WiFi, so **do not put the cable on
`192.168.1.x`** — the routing table will misbehave. Use `192.168.11.0/24`:

| | address |
|---|---|
| PC (Ethernet adapter) | `192.168.11.10` |
| iMac G3 | `192.168.11.2` |
| mask | `255.255.255.0` |
| router / DNS | blank |

There is no DHCP on a direct cable, so both ends are set by hand.

## Cabling

The iMac G3 almost certainly has no auto-MDI-X, so a direct PC-to-Mac run may
need a **crossover** cable. A modern gigabit PC NIC will usually flip the pairs
itself and make a straight cable work — but don't gamble first bring-up on it.
Putting any cheap switch or the house router between the two removes the
question entirely.

## On the Mac

See `g3/README-G3.txt`, which the daemon also serves in Mac-readable form at
`http://192.168.11.10:9980/boot/README-G3.txt`.
