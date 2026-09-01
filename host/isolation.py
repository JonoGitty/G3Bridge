"""Verify that the iMac cannot reach the internet through this PC.

The Mac is a 1999 machine with no security patches and a TLS stack that no
modern site would accept anyway. The requirement is that its only network peer
is this PC.

Two independent halves:

  Mac side      Its TCP/IP control panel has no Router and no Name Server, so
                Open Transport has no default route and cannot address anything
                off 192.168.11.0/24. This is the primary control and it is
                enforced ON the Mac -- nothing here can check it remotely.

  Windows side  Even with the Mac trying, this PC must not carry its packets to
                the internet. That means: no IPv4 forwarding, no Internet
                Connection Sharing, no network bridge, no RRAS. Those are what
                this module checks.

Everything here is READ-ONLY. It reports and tells you the fix; it changes
nothing.
"""

import os
import subprocess

PS = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                  "System32", "WindowsPowerShell", "v1.0", "powershell.exe")


def _ps(script):
    """Run a PowerShell snippet, return stripped stdout, or None if it failed."""
    try:
        r = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command", script],
                           capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0 and not r.stdout.strip():
        return None
    return r.stdout.strip()


def check_forwarding():
    out = _ps("(Get-NetIPInterface -AddressFamily IPv4 | "
              "Where-Object {$_.Forwarding -ne 'Disabled'} | "
              "Measure-Object).Count")
    if out is None:
        return (None, "could not query IPv4 forwarding", "")
    n = out.strip().splitlines()[-1].strip()
    if n == "0":
        return (True, "no interface is forwarding IPv4", "")
    return (False, "%s interface(s) are forwarding IPv4" % n,
            "Set-NetIPInterface -InterfaceAlias 'Ethernet' -Forwarding Disabled   (admin)")


def check_ipenablerouter():
    out = _ps("$v = Get-ItemProperty -Path "
              "'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters' "
              "-Name IPEnableRouter -ErrorAction SilentlyContinue; "
              "if ($null -eq $v) { 'absent' } else { $v.IPEnableRouter }")
    if out is None:
        return (None, "could not read IPEnableRouter", "")
    v = out.strip().splitlines()[-1].strip()
    if v in ("absent", "0"):
        return (True, "IPEnableRouter is %s" % v, "")
    return (False, "IPEnableRouter = %s (this PC is set up to route)" % v,
            r"reg add HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters "
            r"/v IPEnableRouter /t REG_DWORD /d 0 /f   (admin, then reboot)")


def check_ics():
    """The service being Running proves nothing -- it also backs Mobile Hotspot.
    Ask the ICS COM object which connections are actually shared."""
    out = _ps("""
try {
  $n = New-Object -ComObject HNetCfg.HNetShare
  $shared = @()
  foreach ($c in $n.EnumEveryConnection) {
    $cfg = $n.INetSharingConfigurationForINetConnection($c)
    if ($cfg.SharingEnabled) { $shared += $n.NetConnectionProps($c).Name }
  }
  if ($shared.Count -eq 0) { 'none' } else { $shared -join ', ' }
} catch { 'ERROR' }
""")
    if out is None:
        return (None, "could not query Internet Connection Sharing", "")
    v = out.strip().splitlines()[-1].strip()
    if v == "none":
        return (True, "Internet Connection Sharing is not enabled on any adapter", "")
    if v == "ERROR":
        return (None, "the ICS interface could not be queried", "")
    return (False, "ICS is SHARING: %s" % v,
            "Network Connections > right-click that adapter > Properties > "
            "Sharing tab > untick 'Allow other network users to connect'")


def check_bridge():
    out = _ps("(Get-NetAdapter -IncludeHidden | Where-Object "
              "{ $_.InterfaceDescription -match 'Bridge' -or $_.Name -match 'Bridge' } | "
              "Measure-Object).Count")
    if out is None:
        return (None, "could not check for a network bridge", "")
    n = out.strip().splitlines()[-1].strip()
    if n == "0":
        return (True, "no network bridge adapter", "")
    return (False, "%s bridge adapter(s) present" % n,
            "Network Connections > right-click the bridge > Delete")


def check_rras():
    out = _ps("(Get-Service RemoteAccess -ErrorAction SilentlyContinue).Status")
    if out is None:
        return (None, "could not query the RemoteAccess service", "")
    v = out.strip().splitlines()[-1].strip() if out.strip() else "Absent"
    if v in ("Stopped", "Absent", ""):
        return (True, "Routing and Remote Access is not running", "")
    return (False, "Routing and Remote Access is %s" % v,
            "Stop-Service RemoteAccess; Set-Service RemoteAccess -StartupType Disabled   (admin)")


def check_wsl_forwarding():
    """The Windows checks above are BLIND to this.

    WSL2 in mirrored networking mode runs its own Linux TCP/IP stack with an
    interface on the cable subnet AND an interface on the internet with a
    default route. If that kernel has ip_forward=1 it is a router straddling
    both networks, and no Windows-side query will ever show it.
    """
    try:
        r = subprocess.run(["wsl.exe", "-e", "sh", "-c",
                            "cat /proc/sys/net/ipv4/ip_forward 2>/dev/null; "
                            "ip -4 -o addr show 2>/dev/null | awk '{print $2\"=\"$4}'"],
                           capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired):
        return (None, "could not query WSL (not installed, or not running)", "")
    out = (r.stdout or "").replace("\x00", "").strip()
    if not out:
        return (None, "WSL did not answer; treat as unchecked", "")
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    fwd = lines[0] if lines else "?"
    addrs = " ".join(lines[1:])
    cable = "192.168.11." in addrs
    if fwd != "1":
        return (True, "WSL kernel is not forwarding (ip_forward=%s)" % fwd, "")
    if not cable:
        return (True, "WSL forwards, but has no interface on the cable subnet", "")
    return (False,
            "WSL has ip_forward=1 AND an interface on the cable subnet -- it is a "
            "second router the Windows checks cannot see",
            "In WSL:  sudo iptables -I FORWARD -s 192.168.11.0/24 -j DROP\n"
            "            sudo iptables -I FORWARD -d 192.168.11.0/24 -j DROP\n"
            "       (surgical: leaves Docker working. Turning ip_forward off "
            "entirely would break Docker networking.)")


CHECKS = (
    ("IPv4 forwarding", check_forwarding),
    ("IPEnableRouter", check_ipenablerouter),
    ("Internet Connection Sharing", check_ics),
    ("Network bridge", check_bridge),
    ("Routing and Remote Access", check_rras),
    ("WSL2 second IP stack", check_wsl_forwarding),
)


def report():
    """Print the isolation report. Returns (passed, failed, unknown)."""
    print("  These decide whether this PC would carry the Mac's traffic to the")
    print("  internet. All are read-only queries.\n")
    passed = failed = unknown = 0
    for label, fn in CHECKS:
        ok, detail, fix = fn()
        if ok is True:
            mark, passed = "ok", passed + 1
        elif ok is False:
            mark, failed = "!!", failed + 1
        else:
            mark, unknown = "??", unknown + 1
        print("  [%s] %-28s %s" % (mark, label, detail))
        if ok is False and fix:
            print("       fix: %s" % fix)
    return passed, failed, unknown
