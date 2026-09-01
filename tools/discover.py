"""Find a vintage Mac on the cable.

Sweeps the cable subnet, reads the ARP table, and flags anything with an Apple
OUI. Useful when a machine has just been plugged in and you do not yet know
what address, if any, it gave itself.

    C:\\Python310\\python.exe tools\\discover.py
"""
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import config

# Apple OUI prefixes common on PowerPC-era hardware. Not exhaustive -- an
# unmatched MAC is not proof it is not an Apple machine.
APPLE_OUI = set("""
000393 000502 0003ff 000a27 000a95 000d93 0010fa 001124 001451 0016cb
0017f2 0019e3 001b63 001e52 001ec2 0021e9 0023df 0025bc 003065 00306c
0050e4 080007 00a040 0001e3 000a28 001d4f 002332 34159e 002608
""".split())


def ping(ip):
    try:
        r = subprocess.run(["ping", "-n", "1", "-w", "400", ip],
                           capture_output=True, text=True, timeout=8)
        return ip, ("TTL=" in r.stdout or "ttl=" in r.stdout)
    except (OSError, subprocess.TimeoutExpired):
        return ip, False


def arp_table():
    """{ip: mac} across all interfaces."""
    out = {}
    try:
        r = subprocess.run(["arp", "-a"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return out
    for line in r.stdout.splitlines():
        m = re.match(r"\s+(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{17})\s+(\w+)", line)
        if m:
            out[m.group(1)] = m.group(2).lower()
    return out


def is_apple(mac):
    return mac.replace("-", "")[:6] in APPLE_OUI


def main():
    base = config.SUGGESTED_PC_IP.rsplit(".", 1)[0]
    targets = ["%s.%d" % (base, i) for i in range(1, 41)
               if "%s.%d" % (base, i) != config.SUGGESTED_PC_IP]

    print("sweeping %s.1-40 ..." % base)
    with ThreadPoolExecutor(max_workers=40) as ex:
        results = list(ex.map(ping, targets))
    live = [ip for ip, ok in results if ok]

    table = arp_table()
    known = {}
    for name, spec in config.DEVICES.items():
        known[spec["ip"]] = name

    print()
    if live:
        print("ANSWERING on the cable subnet:")
        for ip in live:
            mac = table.get(ip, "?")
            tag = known.get(ip)
            note = ("  <- configured as '%s'" % tag) if tag else ""
            if mac != "?" and is_apple(mac):
                note += "  [Apple hardware]"
            print("  %-15s %s%s" % (ip, mac, note))
    else:
        print("Nothing answered on %s.x" % base)

    # anything Apple-looking anywhere in the ARP table, incl. link-local
    others = []
    for ip, mac in table.items():
        if ip in live or ip.endswith(".255") or ip.startswith(("224.", "239.")):
            continue
        if is_apple(mac):
            others.append((ip, mac))
    if others:
        print()
        print("Apple hardware seen elsewhere in the ARP table:")
        for ip, mac in sorted(others):
            where = "  (LINK-LOCAL: it fell back to self-assigned)" if ip.startswith("169.254.") else ""
            print("  %-15s %s%s" % (ip, mac, where))

    print()
    if not live:
        print("The machine is plugged in and the link is up, but it has no address")
        print("on this subnet. On a direct cable or a bare switch there is no DHCP")
        print("server, so it must be told its address by hand:")
        print()
        print("  Mac OS X:  System Preferences > Network > Built-in Ethernet")
        print("             Configure: Manually")
        print("  Mac OS 9:  Apple menu > Control Panels > TCP/IP")
        print("             Connect via: Ethernet, Configure: Manually")
        print()
        for name, spec in sorted(config.DEVICES.items()):
            print("    %-6s IP %s   mask %s   router/DNS BLANK"
                  % (name, spec["ip"], config.SUGGESTED_MASK))
    return 0


if __name__ == "__main__":
    sys.exit(main())
