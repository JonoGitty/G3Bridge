"""Diagnose the link between this PC and the iMac G3.

    C:\\Python310\\python.exe tools\\netcheck.py

Enumerates this machine's addresses rather than assuming one, because the PC
already has a WiFi LAN address and picking a colliding subnet for the cable is
the easiest way to break this silently.
"""
import os
import socket
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import config


def out(ok, label, detail=""):
    print("  [%s] %s%s" % ("ok" if ok else "!!", label, ("  " + detail) if detail else ""))
    return ok


def listening(port, host="127.0.0.1"):
    try:
        socket.create_connection((host, port), timeout=1).close()
        return True
    except OSError:
        return False


def local_ipv4():
    found = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            found.add(info[4][0])
    except socket.gaierror:
        pass
    # the address used to reach the outside world, which getaddrinfo can miss
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        found.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(found)


def main():
    print("G3Bridge network check\n")

    addrs = local_ipv4()
    print("  this PC's IPv4 addresses:")
    for a in addrs:
        print("      %s" % a)
    if not addrs:
        print("      (none found)")

    print()
    same_subnet = [a for a in addrs
                   if a.rsplit(".", 1)[0] == config.SUGGESTED_PC_IP.rsplit(".", 1)[0]]
    ready = out(bool(same_subnet),
                "PC has an address on the cable subnet %s.x"
                % config.SUGGESTED_PC_IP.rsplit(".", 1)[0],
                ", ".join(same_subnet))
    if not ready:
        print("      The cable needs its own subnet, separate from your WiFi LAN.")
        print("      In an ADMIN Command Prompt (list adapters: netsh interface show interface):")
        print('        netsh interface ip set address name="Ethernet" static %s %s'
              % (config.SUGGESTED_PC_IP, config.SUGGESTED_MASK))

    print()
    out(listening(config.AGENT_PORT), "daemon agent port %d listening" % config.AGENT_PORT)
    out(listening(config.CONTROL_PORT), "daemon control port %d listening" % config.CONTROL_PORT)
    ok_http = out(listening(config.HTTP_PORT), "display HTTP port %d listening" % config.HTTP_PORT)
    if not ok_http:
        print("      Fix: run start.cmd")

    print()
    print("  pinging the iMac at %s ..." % config.SUGGESTED_G3_IP)
    reachable = False
    try:
        r = subprocess.run(["ping", "-n", "2", "-w", "1000", config.SUGGESTED_G3_IP],
                           capture_output=True, text=True, timeout=20)
        reachable = "TTL=" in r.stdout or "ttl=" in r.stdout
    except (OSError, subprocess.TimeoutExpired):
        pass
    out(reachable, "iMac answers at %s" % config.SUGGESTED_G3_IP)
    if not reachable:
        print()
        print("      ON THE MAC: Apple menu > Control Panels > TCP/IP")
        print("        Connect via:  Ethernet")
        print("        Configure:    Manually")
        print("        IP Address:   %s" % config.SUGGESTED_G3_IP)
        print("        Subnet mask:  %s" % config.SUGGESTED_MASK)
        print("        Router / Name server: leave BLANK")
        print("        Close the window, click Save.")
        print()
        print("      If it still will not answer, the cable is the next suspect.")
        print("      The iMac G3's Ethernet port probably has no auto-MDI-X, so a")
        print("      direct PC-to-Mac link may need a CROSSOVER cable. Putting any")
        print("      cheap switch or your router between the two removes the doubt.")

    if reachable and ready:
        print("\n  Link looks good. Next: run the agent on the Mac.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
