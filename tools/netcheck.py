"""Report whether this machine is set up to talk to the G3 over the cable.

    python tools/netcheck.py

Checks the host IP, whether the daemon ports are listening, and whether the
Mac answers a ping. Prints the exact fix for whatever is wrong.
"""
import socket
import subprocess
import sys

PC_IP = "192.168.77.1"
G3_IP = "192.168.77.2"
MASK = "255.255.255.0"


def out(ok, label, detail=""):
    print("  [%s] %s%s" % ("ok" if ok else "!!", label, ("  " + detail) if detail else ""))
    return ok


def listening(port, host="127.0.0.1"):
    try:
        socket.create_connection((host, port), timeout=1).close()
        return True
    except OSError:
        return False


def main():
    print("G3Bridge network check\n")

    addrs = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except socket.gaierror:
        pass
    print("  this machine's IPv4 addresses: %s" % (", ".join(sorted(addrs)) or "none found"))
    has_static = out(PC_IP in addrs, "PC has the static IP %s" % PC_IP)
    if not has_static:
        print("      Fix, in an ADMIN Command Prompt (change \"Ethernet\" to your adapter name):")
        print('      netsh interface ip set address name="Ethernet" static %s %s'
              % (PC_IP, MASK))
        print("      Adapter names: netsh interface show interface")

    out(listening(9990, "0.0.0.0") or listening(9990), "daemon agent port 9990 is listening")
    out(listening(9991), "daemon control port 9991 is listening")
    if not listening(9991):
        print("      Fix: run start.cmd")

    print("\n  pinging the iMac at %s ..." % G3_IP)
    try:
        r = subprocess.run(["ping", "-n", "2", "-w", "1000", G3_IP],
                           capture_output=True, text=True, timeout=15)
        reachable = "TTL=" in r.stdout or "ttl=" in r.stdout
    except (OSError, subprocess.TimeoutExpired):
        reachable = False
    out(reachable, "iMac G3 answers at %s" % G3_IP)
    if not reachable:
        print("      On the Mac: Apple menu > Control Panels > TCP/IP")
        print("        Connect via: Ethernet    Configure: Manually")
        print("        IP Address:  %s" % G3_IP)
        print("        Subnet Mask: %s" % MASK)
        print("        Router:      (leave blank)")
        print("      Then close the window and click Save.")
        print("      Also check Windows Firewall is not blocking python.exe:")
        print('        netsh advfirewall firewall add rule name="G3Bridge" '
              'dir=in action=allow protocol=TCP localport=9990')
    return 0


if __name__ == "__main__":
    sys.exit(main())
