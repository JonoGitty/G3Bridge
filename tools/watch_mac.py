"""Watch the cable for signs of life from the Mac.

Samples two independent signals and logs only CHANGES, so the log stays
readable across a long diagnostic session:

  link   the PC's ethernet adapter link state and negotiated speed.
         Up at 100 Mbps means the iMac's ethernet chip is powered and has
         auto-negotiated with us. It does NOT by itself prove the machine has
         booted -- some hardware links on standby power alone.

  arp    whether the Mac answers at its static address. This DOES prove the
         OS has come up far enough to run its TCP/IP stack.

    C:\\Python310\\python.exe tools\\watch_mac.py
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "host"))
import config

PS = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                  "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "run", "mac_watch.log")


def link_state():
    try:
        r = subprocess.run(
            [PS, "-NoProfile", "-NonInteractive", "-Command",
             "$a = Get-NetAdapter -Name 'Ethernet'; "
             "'{0}|{1}' -f $a.MediaConnectionState, $a.LinkSpeed"],
            capture_output=True, text=True, timeout=30)
        out = (r.stdout or "").strip().splitlines()
        return out[-1].strip() if out else "?"
    except (OSError, subprocess.TimeoutExpired):
        return "?"


def responds():
    try:
        r = subprocess.run(["ping", "-n", "1", "-w", "900", config.SUGGESTED_G3_IP],
                           capture_output=True, text=True, timeout=15)
        return "TTL=" in r.stdout or "ttl=" in r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False


def main():
    last = None
    print("watching the cable for the Mac. Ctrl-C to stop.")
    print("logging changes to run/mac_watch.log\n")
    while True:
        state = (link_state(), responds())
        if state != last:
            line = "%s  link=%-18s  answers_ping=%s" % (
                time.strftime("%H:%M:%S"), state[0], "YES" if state[1] else "no")
            print(line)
            try:
                with open(LOG, "a") as f:
                    f.write(line + "\n")
            except OSError:
                pass
            last = state
        time.sleep(10)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nstopped")
