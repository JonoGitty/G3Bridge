"""Per-machine state, so the bridge can drive more than one vintage Mac.

Everything that is "about a machine" lives on a Device: its canvas, its mirror
framebuffer, its socket to an agent, its AppleScript queue, its frame counter.
Everything that is "about the bridge" (the listeners, the transfer folders)
stays global.

Devices are identified by their IP on the cable, because that is what every
inbound connection carries and it needs no cooperation from the machine.
"""

import os
import threading
import time

import config
import raster


class Device:
    def __init__(self, name, spec):
        self.name = name
        self.ip = spec["ip"]
        self.label = spec.get("label", name)
        self.canvas = tuple(spec.get("canvas", (config.CANVAS_W, config.CANVAS_H)))
        self.os = spec.get("os", "unknown")

        self.mirror = raster.Screen(self.canvas[0], self.canvas[1])
        self.mirror_lock = threading.Lock()
        self.frame_seq = 0
        self.link = None            # set by g3d to a Link()
        self.queue = None           # set by g3d to a CommandQueue()
        self.first_seen = None
        self.last_seen = None
        self.http_hits = 0
        self.enrolled = {}      # what the machine reported about itself
        self._load_enrolment()

    def _load_enrolment(self):
        """Survive a daemon restart -- otherwise the setup page tells someone
        to redo a step they have already done."""
        path = os.path.join(config.RUN_DIR_ABS, "enrol_%s.txt" % self.name)
        try:
            fh = open(path)
        except OSError:
            return
        try:
            for line in fh:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    self.enrolled[k] = v
        finally:
            fh.close()

    # -- frames ---------------------------------------------------------
    def frame_path(self, ext):
        return os.path.join(config.RUN_DIR_ABS, "frame_%s.%s" % (self.name, ext))

    def present(self):
        if not os.path.isdir(config.RUN_DIR_ABS):
            os.makedirs(config.RUN_DIR_ABS)
        with self.mirror_lock:
            self.frame_seq += 1
            self.mirror.save(self.frame_path("png"))
            if raster.HAVE_PIL:
                self.mirror.save(self.frame_path("gif"))

    def touch(self):
        now = time.time()
        if self.first_seen is None:
            self.first_seen = now
        self.last_seen = now
        self.http_hits += 1

    def describe(self):
        out = ["device=%s" % self.name, "ip=%s" % self.ip,
               "canvas=%dx%d" % self.canvas, "os=%s" % self.os]
        if self.last_seen:
            out.append("last_seen=%ds_ago" % int(time.time() - self.last_seen))
            out.append("http_hits=%d" % self.http_hits)
        else:
            out.append("last_seen=never")
        # Prefixed, because the machine reports its own "os" (10.5.6) and the
        # config carries a coarser one (macosx). Two os= keys in one line means
        # whichever parses last silently wins.
        for k in sorted(self.enrolled):
            out.append("reported_%s=%s" % (k, self.enrolled[k]))
        return out


class Registry:
    def __init__(self):
        self._by_name = {}
        self._by_ip = {}
        for name, spec in config.DEVICES.items():
            d = Device(name, spec)
            self._by_name[name] = d
            self._by_ip[d.ip] = d

    def __iter__(self):
        # sorted so listings are stable; no sorted(key=) tricks needed
        names = list(self._by_name.keys())
        names.sort()
        return iter([self._by_name[n] for n in names])

    def by_name(self, name):
        return self._by_name.get(name)

    def by_ip(self, ip):
        return self._by_ip.get(ip)

    def resolve(self, name_or_none):
        """A tool call with no device named gets the sensible one.

        If exactly one device has ever been seen, that is the answer -- the
        common case is a single machine plugged in, and making the caller name
        it every time is noise. Otherwise fall back to the configured default.
        """
        if name_or_none:
            return self._by_name.get(name_or_none)
        seen = [d for d in self if d.last_seen is not None]
        if len(seen) == 1:
            return seen[0]
        return self._by_name.get(config.DEFAULT_DEVICE)

    def for_peer(self, ip):
        """Which device is this inbound connection? Loopback is the default,
        so the test harness and local tools keep working."""
        d = self._by_ip.get(ip)
        if d is not None:
            return d
        if ip == "127.0.0.1":
            return self._by_name.get(config.DEFAULT_DEVICE)
        return None

    def names(self):
        n = list(self._by_name.keys())
        n.sort()
        return n
