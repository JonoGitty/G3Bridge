#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
backrooms_sfx.py -- synthesise the Backrooms Tape sound set.

CONTRACT.md section 5 (asset plan) and DESIGN.md section 6 (audio).

  C:\\Python310\\python.exe tools\\backrooms_sfx.py             make whatever is missing
  C:\\Python310\\python.exe tools\\backrooms_sfx.py --force     remake every generated file
  C:\\Python310\\python.exe tools\\backrooms_sfx.py --only howl1,snarl
  C:\\Python310\\python.exe tools\\backrooms_sfx.py --verify    ffprobe table only (no synthesis)

Standard library only (wave / array / math / random).  Every sound that the
Sfx class embeds and that does not already exist is rendered as 22050 Hz mono
16-bit WAV into run/sfx_wav/, then encoded with ffmpeg
(-ac 1 -ar 22050 -b:a 64k -codec:a libmp3lame) into www/games/backrooms/sfx/.

hum_low.mp3 is not synthesised: it is hum.mp3 resampled by ffmpeg
(asetrate=<source rate>*0.9439,aresample=22050) so it is a true -1 semitone
pitch shift of the same loop, then zero-cross trimmed and faded like every
other loop.

The files that existed before this script (hum, drone, presence, static,
step1-4, tape, thud, screech, flicker) are never written, even with --force.
Every generator is seeded from its name, so a --force re-run reproduces the
same audio bit for bit.
"""

import array
import math
import os
import random
import subprocess
import sys
import time
import wave

SR = 22050
TWO_PI = 2.0 * math.pi

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAV_DIR = os.path.join(ROOT, 'run', 'sfx_wav')
MP3_DIR = os.path.join(ROOT, 'www', 'games', 'backrooms', 'sfx')

FFMPEG = r'C:\Users\jonog\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe'
if not os.path.exists(FFMPEG):
    FFMPEG = 'ffmpeg'
if os.path.dirname(FFMPEG):
    FFPROBE = os.path.join(os.path.dirname(FFMPEG), 'ffprobe.exe')
else:
    FFPROBE = 'ffprobe'

# Pre-existing files (CONTRACT section 5): kept exactly as they are.
KEEP = ('hum', 'drone', 'presence', 'static', 'step1', 'step2', 'step3',
        'step4', 'tape', 'thud', 'screech', 'flicker')

# Every file the Sfx class embeds, in AudioBus id order (0..30).
# distant5 is thud.mp3 (CONTRACT: "distant5 = thud.mp3"), so no distant5.mp3.
SFX_FILES = [
    'hum', 'hum_low', 'hum_dark', 'drone',                       # 0..3
    'presence', 'presence_hi', 'drip_loop',                      # 4..6
    'step1', 'step2', 'step3', 'step4',                          # 7..10
    'splash1', 'splash2',                                        # 11..12
    'distant1', 'distant2', 'distant3', 'distant4', 'thud', 'distant6',  # 13..18
    'clicks1', 'clicks2',                                        # 19..20
    'howl1', 'howl2',                                            # 21..22
    'snarl', 'hound_step', 'screech', 'static', 'tape',          # 23..27
    'vcr_whirr', 'flicker', 'paper',                             # 28..30
]

LOOPS = ('hum', 'hum_low', 'hum_dark', 'drone', 'presence', 'presence_hi', 'drip_loop')


# ----------------------------------------------------------------------------
# DSP toolkit (float lists, 22050 Hz)
# ----------------------------------------------------------------------------

def seconds(s):
    return int(round(s * SR))


def zeros(n):
    return [0.0] * n


def white(n, rng):
    r = rng.random
    return [2.0 * r() - 1.0 for _ in range(n)]


def pink(n, rng):
    """Paul Kellet's economy pink-noise filter on white noise."""
    r = rng.random
    b0 = b1 = b2 = 0.0
    out = [0.0] * n
    for i in range(n):
        w = 2.0 * r() - 1.0
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        out[i] = (b0 + b1 + b2 + w * 0.1848) * 0.25
    return out


def brown(n, rng, leak=0.995):
    r = rng.random
    v = 0.0
    out = [0.0] * n
    for i in range(n):
        v = leak * v + (2.0 * r() - 1.0) * 0.1
        out[i] = v
    return nrm(out)


def _blep(t, dt):
    if t < dt:
        t /= dt
        return t + t - t * t - 1.0
    if t > 1.0 - dt:
        t = (t - 1.0) / dt
        return t * t + t + t + 1.0
    return 0.0


def osc(n, freq, kind='sine', phase=0.0):
    """Oscillator. freq is a float or a per-sample list. saw/square are polyBLEP."""
    out = [0.0] * n
    ph = phase % 1.0
    if isinstance(freq, list):
        fl = freq
    else:
        fl = None
        dt = freq / SR
    sin = math.sin
    if kind == 'sine':
        for i in range(n):
            if fl is not None:
                dt = fl[i] / SR
            out[i] = sin(TWO_PI * ph)
            ph += dt
            if ph >= 1.0:
                ph -= 1.0
    elif kind == 'saw':
        for i in range(n):
            if fl is not None:
                dt = fl[i] / SR
            out[i] = 2.0 * ph - 1.0 - _blep(ph, dt)
            ph += dt
            if ph >= 1.0:
                ph -= 1.0
    elif kind == 'square':
        for i in range(n):
            if fl is not None:
                dt = fl[i] / SR
            v = 1.0 if ph < 0.5 else -1.0
            p2 = ph + 0.5
            if p2 >= 1.0:
                p2 -= 1.0
            out[i] = v + _blep(ph, dt) - _blep(p2, dt)
            ph += dt
            if ph >= 1.0:
                ph -= 1.0
    else:  # tri
        for i in range(n):
            if fl is not None:
                dt = fl[i] / SR
            out[i] = 4.0 * abs(ph - 0.5) - 1.0
            ph += dt
            if ph >= 1.0:
                ph -= 1.0
    return out


def contour(n, pts, log=False):
    """Breakpoint curve: pts = [(t_seconds, value), ...]; linear, or geometric if log."""
    if len(pts) == 1:
        return [float(pts[0][1])] * n
    ts = [seconds(t) for t, _ in pts]
    vs = [float(v) for _, v in pts]
    out = [0.0] * n
    k = 0
    last = len(ts) - 2
    for i in range(n):
        while k < last and i >= ts[k + 1]:
            k += 1
        t0 = ts[k]
        t1 = ts[k + 1]
        if i <= t0:
            out[i] = vs[k]
        elif i >= t1:
            out[i] = vs[k + 1]
        else:
            a = (i - t0) / float(t1 - t0)
            if log:
                out[i] = vs[k] * (vs[k + 1] / vs[k]) ** a
            else:
                out[i] = vs[k] + (vs[k + 1] - vs[k]) * a
    return out


def env_perc(n, attack, tau, start=0.0):
    """Silent until start; linear attack (s); then exponential decay with time constant tau (s)."""
    out = [0.0] * n
    s = seconds(start)
    a = max(1, seconds(attack))
    k = 1.0 / (tau * SR)
    exp = math.exp
    for i in range(s, n):
        j = i - s
        if j < a:
            out[i] = j / float(a)
        else:
            out[i] = exp(-(j - a) * k)
    return out


def env_exp(n, tau):
    k = 1.0 / (tau * SR)
    exp = math.exp
    return [exp(-i * k) for i in range(n)]


def env_follow(x, tau):
    """Rectified one-pole envelope follower."""
    k = math.exp(-1.0 / (tau * SR))
    v = 0.0
    out = [0.0] * len(x)
    for i, s in enumerate(x):
        s = abs(s)
        v = s if s > v else s + (v - s) * k
        out[i] = v
    return out


def gain(x, g):
    return [v * g for v in x]


def mul(a, b):
    return [u * v for u, v in zip(a, b)]


def rms_db(x):
    return 10.0 * math.log10(sum(v * v for v in x) / max(1, len(x)) + 1e-20)


def nrm_rms(x, target_db, max_peak=0.9):
    """Scale to an RMS level in dBFS (for dense beds, where peak says little about loudness); peak-guarded."""
    g = 10.0 ** ((target_db - rms_db(x)) / 20.0)
    m = max(abs(v) for v in x) * g
    if m > max_peak:
        g *= max_peak / m
    return [v * g for v in x]


def nrm(x, peak=1.0):
    m = max(abs(v) for v in x) if x else 0.0
    if m < 1e-9:
        return list(x)
    g = peak / m
    return [v * g for v in x]


def add_into(buf, x, at=0.0, g=1.0):
    s = seconds(at)
    need = s + len(x)
    if need > len(buf):
        buf.extend([0.0] * (need - len(buf)))
    for i, v in enumerate(x):
        buf[s + i] += v * g
    return buf


def mixn(parts):
    """parts: list of (x, gain) or (x, gain, at_seconds). Result is as long as the longest part."""
    buf = []
    for p in parts:
        at = p[2] if len(p) > 2 else 0.0
        add_into(buf, p[0], at, p[1])
    return buf


def add(a, b, g=1.0):
    return mixn([(a, 1.0), (b, g)])


def clip(x, drive=1.0):
    t = math.tanh
    k = 1.0 / t(drive)
    return [t(v * drive) * k for v in x]


def lp1(x, f):
    k = 1.0 - math.exp(-TWO_PI * f / SR)
    v = 0.0
    out = [0.0] * len(x)
    for i, s in enumerate(x):
        v += (s - v) * k
        out[i] = v
    return out


def hp1(x, f):
    lo = lp1(x, f)
    return [a - b for a, b in zip(x, lo)]


def fade(x, in_s, out_s):
    x = list(x)
    n = len(x)
    a = min(n, seconds(in_s))
    for i in range(a):
        x[i] *= i / float(a)
    b = min(n, seconds(out_s))
    for i in range(b):
        x[n - 1 - i] *= i / float(b)
    return x


def loop_finish(x, fade_s=0.05):
    """Trim to a rising zero crossing at both ends, then 50 ms fades (CONTRACT section 5)."""
    n = len(x)
    a = 0
    for i in range(1, n):
        if x[i - 1] <= 0.0 < x[i]:
            a = i
            break
    b = n
    for i in range(n - 1, a + 1, -1):
        if x[i - 1] <= 0.0 < x[i]:
            b = i
            break
    return fade(x[a:b], fade_s, fade_s)


class Biquad(object):
    """RBJ cookbook biquad, transposed direct form II."""
    __slots__ = ('b0', 'b1', 'b2', 'a1', 'a2', 'z1', 'z2')

    def __init__(self, kind, f, q=0.707, gain_db=0.0):
        self.z1 = 0.0
        self.z2 = 0.0
        self.set(kind, f, q, gain_db)

    def set(self, kind, f, q=0.707, gain_db=0.0):
        f = max(10.0, min(f, SR * 0.45))
        q = max(0.05, q)
        w0 = TWO_PI * f / SR
        c = math.cos(w0)
        alpha = math.sin(w0) / (2.0 * q)
        if kind == 'lowpass':
            b0 = (1.0 - c) * 0.5; b1 = 1.0 - c; b2 = b0
            a0 = 1.0 + alpha; a1 = -2.0 * c; a2 = 1.0 - alpha
        elif kind == 'highpass':
            b0 = (1.0 + c) * 0.5; b1 = -(1.0 + c); b2 = b0
            a0 = 1.0 + alpha; a1 = -2.0 * c; a2 = 1.0 - alpha
        elif kind == 'bandpass':          # constant 0 dB peak gain
            b0 = alpha; b1 = 0.0; b2 = -alpha
            a0 = 1.0 + alpha; a1 = -2.0 * c; a2 = 1.0 - alpha
        elif kind == 'notch':
            b0 = 1.0; b1 = -2.0 * c; b2 = 1.0
            a0 = 1.0 + alpha; a1 = -2.0 * c; a2 = 1.0 - alpha
        elif kind == 'peaking':
            A = 10.0 ** (gain_db / 40.0)
            b0 = 1.0 + alpha * A; b1 = -2.0 * c; b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A; a1 = -2.0 * c; a2 = 1.0 - alpha / A
        else:
            raise ValueError(kind)
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0

    def run(self, x, out=None, start=0, end=None):
        b0, b1, b2, a1, a2 = self.b0, self.b1, self.b2, self.a1, self.a2
        z1, z2 = self.z1, self.z2
        if out is None:
            out = [0.0] * len(x)
        if end is None:
            end = len(x)
        for i in range(start, end):
            s = x[i]
            y = b0 * s + z1
            z1 = b1 * s - a1 * y + z2
            z2 = b2 * s - a2 * y
            out[i] = y
        self.z1, self.z2 = z1, z2
        return out


def biquad(x, kind, f, q=0.707, gain_db=0.0):
    return Biquad(kind, f, q, gain_db).run(x)


def biquad_sweep(x, kind, fc, q=0.707, block=32):
    """Biquad whose centre frequency follows the per-sample list fc (recomputed every `block` samples)."""
    n = len(x)
    out = [0.0] * n
    bq = Biquad(kind, fc[0], q)
    i = 0
    while i < n:
        e = min(n, i + block)
        bq.set(kind, fc[i], q)
        bq.run(x, out, i, e)
        i = e
    return out


def formants(x, bands):
    """Parallel band-passes: bands = [(f_or_contour, q, gain), ...]."""
    out = [0.0] * len(x)
    for f, q, g in bands:
        y = biquad_sweep(x, 'bandpass', f, q) if isinstance(f, list) else biquad(x, 'bandpass', f, q)
        for i, v in enumerate(y):
            out[i] += v * g
    return out


def reverb(x, rt60=2.0, wet=0.4, dry=1.0, damp=0.3, predelay=0.02, tail=None):
    """Schroeder/freeverb-style: 4 damped combs in parallel into 2 allpasses. Output = dry + wet tail."""
    n_in = len(x)
    extra = seconds(rt60 * 0.9) if tail is None else seconds(tail)
    n = n_in + extra
    comb_d = [556, 594, 641, 683]      # 25-31 ms
    ap_d = [278, 112]
    pre = seconds(predelay)
    combs = [[0.0] * d for d in comb_d]
    fb = [10.0 ** (-3.0 * d / SR / rt60) for d in comb_d]
    store = [0.0] * 4
    idx = [0] * 4
    aps = [[0.0] * d for d in ap_d]
    apidx = [0, 0]
    out = [0.0] * n
    d1 = damp
    d2 = 1.0 - damp
    inv = 0.25
    for i in range(n):
        j = i - pre
        inp = x[j] if 0 <= j < n_in else 0.0
        acc = 0.0
        for c in range(4):
            buf = combs[c]
            k = idx[c]
            y = buf[k]
            st = y * d2 + store[c] * d1
            store[c] = st
            buf[k] = inp + st * fb[c]
            k += 1
            idx[c] = 0 if k >= comb_d[c] else k
            acc += y
        v = acc * inv
        for a in range(2):
            buf = aps[a]
            k = apidx[a]
            b = buf[k]
            buf[k] = v + b * 0.5
            v = b - v
            k += 1
            apidx[a] = 0 if k >= ap_d[a] else k
        out[i] = (x[i] * dry if i < n_in else 0.0) + v * wet
    return out


def loop_reverb(x, **kw):
    """Reverb whose tail wraps round to the start, so the loop stays seamless."""
    n = len(x)
    y = reverb(x, **kw)
    for i in range(n, len(y)):
        y[i - n] += y[i]
    return y[:n]


def distant(x, cutoff=1200.0, rt60=2.4, wet=0.5, predelay=0.04, damp=0.4):
    """Far away down the corridors: muffled, then a long hall behind it."""
    y = biquad(biquad(x, 'lowpass', cutoff, 0.8), 'lowpass', cutoff * 1.4, 0.7)
    return reverb(y, rt60=rt60, wet=wet, dry=0.9, damp=damp, predelay=predelay)


def gate_bursts(n, rng, on=(0.03, 0.2), off=(0.05, 0.4), ramp=0.003):
    """Random on/off gate (seconds ranges) with short ramps."""
    out = [0.0] * n
    i = 0
    state = rng.random() < 0.5
    while i < n:
        d = seconds(rng.uniform(*(on if state else off)))
        e = min(n, i + d)
        if state:
            for j in range(i, e):
                out[j] = 1.0
        i = e
        state = not state
    return lp1(out, 1.0 / max(ramp, 0.0005))


def flutter(n, rng, fmin, fmax, floor=0.3):
    """Sine LFO whose rate random-walks between fmin and fmax; output in floor..1."""
    out = [0.0] * n
    ph = rng.random()
    f = rng.uniform(fmin, fmax)
    a = 0.5 * (1.0 - floor)
    m = floor + a
    for i in range(n):
        if i % 512 == 0:
            f = min(fmax, max(fmin, f + rng.uniform(-2.0, 2.0)))
        out[i] = m + a * math.sin(TWO_PI * ph)
        ph += f / SR
    return out


def sparse_impulses(n, rng, per_second):
    out = [0.0] * n
    p = per_second / SR
    r = rng.random
    for i in range(n):
        if r() < p:
            out[i] = rng.uniform(0.3, 1.0) * (1.0 if r() < 0.5 else -1.0)
    return out


def stick_slip(n, rng, rmin, rmax):
    """Friction chatter: each slip is a sharp attack then a decay; slip rate wanders rmin..rmax Hz."""
    out = [0.0] * n
    ph = 0.0
    rate = rng.uniform(rmin, rmax)
    for i in range(n):
        if i % 256 == 0:
            rate = min(rmax, max(rmin, rate + rng.uniform(-3.0, 3.0)))
        v = 1.0 - ph
        out[i] = 0.2 + 0.8 * v * v
        ph += rate / SR
        if ph >= 1.0:
            ph -= 1.0
            rate = min(rmax, max(rmin, rate * rng.uniform(0.8, 1.25)))
    return out


def pulse_train(n, rng, rate, jitter=0.2, width=0.35):
    """Vocal-fry pulses: 1 for `width` of each (jittered) period, else 0; edges softened."""
    out = [0.0] * n
    ph = 0.0
    per = rate
    for i in range(n):
        if ph < width:
            out[i] = 1.0
        ph += per / SR
        if ph >= 1.0:
            ph -= 1.0
            per = rate * rng.uniform(1.0 - jitter, 1.0 + jitter)
    return lp1(out, 1500.0)


def wander(n, rng, base, depth, rate):
    """Random-walk value around base (fraction depth), updated `rate` times a second, interpolated."""
    step = max(1, seconds(1.0 / rate))
    pts = []
    v = 0.0
    t = 0
    while t <= n + step:
        v = max(-1.0, min(1.0, v + rng.uniform(-0.5, 0.5)))
        pts.append((t / float(SR), base * (1.0 + depth * v)))
        t += step
    return contour(n, pts)


def grain_gate(n, rng, gmin, gmax):
    """Random amplitude per grain (exponential-ish distribution): crackle."""
    out = [0.0] * n
    i = 0
    while i < n:
        e = min(n, i + seconds(rng.uniform(gmin, gmax)))
        a = min(1.0, -math.log(1.0 - rng.random() * 0.98) * 0.5)
        for j in range(i, e):
            out[j] = a
        i = e
    return lp1(out, 800.0)


# ----------------------------------------------------------------------------
# Recipes (DESIGN section 6)
# ----------------------------------------------------------------------------

def s_hum_dark(rng):
    """Dark-zone bed: the 60 Hz mains family an octave lower, heavier, with a loose diffuser rattling."""
    L = 12.0                      # 720 mains cycles: the loop wraps on a stationary part
    n = seconds(L)
    sub = osc(n, 30.0)
    f60 = osc(n, 60.0)
    f120 = osc(n, 120.0)
    f180 = osc(n, 180.0)
    f240 = osc(n, 240.0)
    # slow swells with periods that divide 12 s, so the loop ends where it started
    sw1 = [0.86 + 0.14 * math.sin(TWO_PI * i / SR / 6.0) for i in range(n)]
    sw2 = [0.90 + 0.10 * math.sin(TWO_PI * i / SR / 4.0 + 1.3) for i in range(n)]
    tone = [(0.30 * sub[i] + 0.34 * f60[i] + 0.22 * f120[i] + 0.09 * f180[i] + 0.05 * f240[i]) * sw1[i]
            for i in range(n)]
    # the ballast buzz, band-limited into the rattle region
    buzz = biquad(biquad(osc(n, 120.0, 'square'), 'bandpass', 1400.0, 1.2), 'highpass', 500.0, 0.7)
    buzz = nrm(biquad(buzz, 'peaking', 2400.0, 2.0, 6.0))
    # a loose diffuser panel chattering in irregular bursts, fluttering inside each burst
    gate = gate_bursts(n, rng, on=(0.04, 0.35), off=(0.08, 0.6), ramp=0.004)
    flut = flutter(n, rng, 8.0, 20.0, floor=0.3)
    rattle = [buzz[i] * gate[i] * flut[i] * sw2[i] for i in range(n)]
    # thin ballast whine, beating (2400 and 2400.5 Hz both complete whole cycles in 12 s)
    whine = [0.5 * math.sin(TWO_PI * 2400.0 * i / SR) + 0.5 * math.sin(TWO_PI * 2400.5 * i / SR) for i in range(n)]
    # dark air
    air = nrm(lp1(lp1(pink(n, rng), 220.0), 220.0))
    # electrical crackle: sparse ticks
    crack = nrm(biquad(sparse_impulses(n, rng, 1.5), 'bandpass', 3200.0, 3.0))
    x = [tone[i] + 0.16 * rattle[i] + 0.012 * whine[i] + 0.10 * air[i] + 0.08 * crack[i] for i in range(n)]
    return clip(x, 1.4)


def s_presence_hi(rng):
    """Thin 6 kHz whine: beating sines plus a narrow tinnitus hiss, trembling slightly."""
    L = 8.0
    n = seconds(L)
    sin = math.sin
    # every partial completes a whole number of cycles in 8 s (f = k/8)
    tone = [0.5 * sin(TWO_PI * 6000.0 * i / SR) + 0.3 * sin(TWO_PI * 6000.5 * i / SR)
            + 0.2 * sin(TWO_PI * 5999.25 * i / SR) + 0.06 * sin(TWO_PI * 3000.125 * i / SR)
            + 0.08 * sin(TWO_PI * 8400.125 * i / SR) for i in range(n)]
    trem = [0.85 + 0.15 * sin(TWO_PI * 7.0 * i / SR) for i in range(n)]          # 56 cycles
    wob = [0.85 + 0.15 * sin(TWO_PI * 0.5 * i / SR + 0.7) for i in range(n)]      # 4 cycles
    drift = [0.9 + 0.1 * sin(TWO_PI * i / SR / 8.0 + 2.0) for i in range(n)]      # 1 cycle
    w = white(n, rng)
    hiss = nrm(biquad(w, 'bandpass', 6000.0, 30.0))
    bed = nrm(biquad(w, 'bandpass', 6000.0, 8.0))
    air = nrm(biquad(white(n, rng), 'highpass', 5000.0, 0.7))
    x = [(tone[i] * trem[i] + (0.45 * hiss[i] + 0.15 * bed[i]) * wob[i] + 0.04 * air[i]) * drift[i]
         for i in range(n)]
    return x


def _plink(rng, f0, amp):
    d = seconds(0.1)
    f = contour(d, [(0, f0), (0.035, f0 * 0.55), (0.1, f0 * 0.5)], log=True)
    x = mul(osc(d, f), env_perc(d, 0.0008, 0.018))
    fb = contour(d, [(0, 320.0), (0.05, 110.0)], log=True)
    x = add(x, mul(osc(d, fb), env_perc(d, 0.002, 0.02)), 0.35)
    click = mul(biquad(white(d, rng), 'bandpass', 4500.0, 2.0), env_perc(d, 0.0003, 0.0015))
    x = add(x, nrm(click), 0.5)
    return gain(x, amp)


def s_drip_loop(rng):
    """Water dripping into a pit: irregular plinks in a hollow, reverberant space; tail wraps the loop."""
    L = 6.0
    n = seconds(L)
    x = zeros(n)
    times = []
    tries = 0
    while len(times) < 7 and tries < 500:
        tries += 1
        t = rng.uniform(0.2, L - 0.25)
        if all(abs(t - u) > 0.35 for u in times):
            times.append(t)
    for t in times:
        add_into(x, _plink(rng, rng.uniform(1200.0, 2600.0), rng.uniform(0.5, 1.0)), t)
    x = x[:n]
    # the pit: dark moving air and a low hollow resonance, very quiet
    air = mul(nrm(lp1(brown(n, rng), 150.0)), [0.7 + 0.3 * math.sin(TWO_PI * i / SR / 3.0) for i in range(n)])
    res = nrm(biquad(pink(n, rng), 'bandpass', 90.0, 8.0))
    x = mixn([(x, 1.0), (air, 0.05), (res, 0.04)])
    return loop_reverb(x, rt60=2.2, wet=0.5, dry=1.0, damp=0.45, predelay=0.02)


def s_splash(rng, variant):
    """Wet footstep: carpet step under a splat, a squelch and a few flung droplets."""
    n = seconds(0.42)
    thump = mul(osc(n, contour(n, [(0, 120.0), (0.08, 55.0)], log=True)), env_perc(n, 0.002, 0.045))
    splat = biquad_sweep(white(n, rng), 'bandpass', contour(n, [(0, 3200.0), (0.13, 650.0)], log=True), 1.1)
    splat = mul(splat, env_perc(n, 0.003, 0.05))
    sq0 = 1900.0 if variant == 1 else 2400.0
    squelch = biquad_sweep(pink(n, rng), 'bandpass', contour(n, [(0.02, sq0), (0.2, 380.0)], log=True), 4.0)
    squelch = mul(squelch, env_perc(n, 0.015, 0.09 if variant == 1 else 0.12, start=0.02))
    carpet = mul(biquad(white(n, rng), 'bandpass', 420.0, 1.0), env_perc(n, 0.004, 0.03))
    drops = zeros(n)
    for _ in range(rng.randint(5, 9)):
        t = rng.uniform(0.04, 0.27)
        f = rng.uniform(2000.0, 5200.0) * (1.15 if variant == 2 else 1.0)
        d = seconds(rng.uniform(0.008, 0.016))
        blip = mul(osc(d, contour(d, [(0, f), (0.012, f * 0.7)], log=True)), env_perc(d, 0.0005, 0.004))
        add_into(drops, blip, t, rng.uniform(0.15, 0.4))
    x = mixn([(thump, 0.55), (nrm(splat), 0.9), (nrm(squelch), 0.5), (nrm(carpet), 0.4), (drops[:n], 1.0)])
    x = biquad(x, 'highpass', 60.0, 0.7)
    return fade(x, 0.001, 0.03)


def s_distant1(rng):
    """A door slammed somewhere far off: impact, wooden body, frame rattling, long hall."""
    n = seconds(0.9)
    burst = mul(biquad(biquad(white(n, rng), 'highpass', 220.0, 0.7), 'lowpass', 1600.0, 0.9),
                env_perc(n, 0.001, 0.035))
    body = mul(osc(n, contour(n, [(0, 58.0), (0.25, 36.0)], log=True)), env_perc(n, 0.002, 0.12))
    wood = mul(biquad(white(n, rng), 'bandpass', 95.0, 12.0), env_perc(n, 0.001, 0.2))
    wood2 = mul(biquad(white(n, rng), 'bandpass', 340.0, 9.0), env_perc(n, 0.001, 0.09))
    rattle = zeros(n)
    t = 0.03
    for _ in range(4):
        d = seconds(0.03)
        tick = mul(biquad(white(d, rng), 'bandpass', rng.uniform(1500.0, 2600.0), 4.0), env_perc(d, 0.0005, 0.006))
        add_into(rattle, nrm(tick), t, rng.uniform(0.15, 0.35))
        t += rng.uniform(0.02, 0.045)
    x = mixn([(nrm(burst), 1.0), (body, 0.85), (nrm(wood), 0.55), (nrm(wood2), 0.3), (rattle[:n], 1.0)])
    return distant(clip(x, 1.6), cutoff=1100.0, rt60=2.4, wet=0.55, predelay=0.045)


def s_distant2(rng):
    """A fluorescent tube pinging: inharmonic metallic tink, then the ballast stuttering."""
    n = seconds(0.9)

    def tink(scale, amp):
        y = zeros(n)
        for f, a, tau in ((2380.0, 1.0, 0.35), (3810.0, 0.5, 0.22), (6100.0, 0.3, 0.14), (8500.0, 0.15, 0.08)):
            f = f * scale * rng.uniform(0.995, 1.005)
            y = add(y, mul(osc(n, f, 'sine', rng.random()), env_perc(n, 0.0005, tau)), a)
        click = mul(biquad(white(n, rng), 'bandpass', 4200.0, 2.0), env_perc(n, 0.0002, 0.0012))
        y = add(y, nrm(click), 0.6)
        return gain(nrm(y), amp)

    x = mixn([(tink(1.0, 1.0), 1.0), (tink(0.79, 0.35), 1.0, 0.42)])[:n]
    buzz = nrm(biquad(osc(n, 120.0, 'square'), 'bandpass', 900.0, 2.0))
    g = zeros(n)
    for t, d in ((0.0, 0.025), (0.06, 0.04), (0.13, 0.015), (0.55, 0.02)):
        for i in range(seconds(t), min(n, seconds(t + d))):
            g[i] = 1.0
    g = lp1(g, 400.0)
    x = add(x, mul(buzz, g), 0.35)
    return distant(x, cutoff=4200.0, rt60=1.9, wet=0.45, predelay=0.03, damp=0.5)


def s_distant3(rng):
    """Something heavy being dragged: stick-slip friction over a wandering resonance, with two bumps."""
    n = seconds(2.6)
    src = pink(n, rng)
    fc = contour(n, [(0, 380.0), (0.9, 820.0), (1.6, 520.0), (2.2, 900.0), (2.6, 400.0)], log=True)
    fr = add(biquad_sweep(src, 'bandpass', fc, 2.5), biquad_sweep(src, 'lowpass', fc, 4.0), 0.5)
    am = stick_slip(n, rng, 16.0, 45.0)
    env = contour(n, [(0, 0.0), (0.35, 1.0), (0.9, 0.7), (1.15, 1.0), (1.7, 0.6), (1.95, 1.0), (2.25, 0.9), (2.6, 0.0)])
    fric = [fr[i] * am[i] * env[i] for i in range(n)]
    tone = biquad(osc(n, contour(n, [(0, 130.0), (1.3, 160.0), (2.6, 120.0)], log=True), 'saw'), 'bandpass', 620.0, 2.0)
    tone = [tone[i] * am[i] * env[i] for i in range(n)]
    bumps = zeros(n)
    for t in (0.85, 2.2):
        d = seconds(0.35)
        add_into(bumps, mul(osc(d, contour(d, [(0, 72.0), (0.2, 44.0)], log=True)), env_perc(d, 0.003, 0.09)), t, 0.9)
        k = mul(biquad(white(d, rng), 'lowpass', 900.0, 0.8), env_perc(d, 0.001, 0.02))
        add_into(bumps, nrm(k), t, 0.5)
    x = mixn([(nrm(fric), 1.0), (nrm(tone), 0.3), (bumps[:n], 1.0)])
    return distant(clip(x, 1.3), cutoff=900.0, rt60=2.6, wet=0.5, predelay=0.05)


def s_distant4(rng):
    """A cough down the corridor: three voiced, formant-shaped bursts and an intake of breath."""
    n = seconds(1.0)
    x = zeros(n)
    for t, dur, amp, f0 in ((0.0, 0.17, 1.0, 165.0), (0.27, 0.13, 0.85, 140.0), (0.49, 0.10, 0.6, 125.0)):
        d = seconds(dur + 0.12)
        F1 = contour(d, [(0, 620.0), (dur, 420.0)])
        bands = [(F1, 4.0, 1.0), (1450.0, 6.0, 0.55), (2600.0, 8.0, 0.3)]
        noise = nrm(formants(white(d, rng), bands))
        voice = nrm(formants(osc(d, contour(d, [(0, f0), (dur, f0 * 0.6)], log=True), 'saw'), bands))
        e_n = env_perc(d, 0.006, dur * 0.35)
        e_v = env_perc(d, 0.01, dur * 0.3, start=0.008)
        chest = mul(osc(d, 80.0), env_perc(d, 0.003, 0.04))
        b = [noise[i] * e_n[i] + 0.7 * voice[i] * e_v[i] + 0.4 * chest[i] for i in range(d)]
        add_into(x, b, t, amp)
    breath = mul(nrm(biquad(white(n, rng), 'highpass', 1500.0, 0.7)),
                 contour(n, [(0.66, 0.0), (0.74, 1.0), (0.86, 0.0)]))
    x = add(x[:n], breath, 0.12)
    return distant(clip(x, 1.5), cutoff=1800.0, rt60=2.2, wet=0.5, predelay=0.03)


def s_distant6(rng):
    """A two-note chime (lift or PA) from far away: detuned tubular partials, muffled."""
    n = seconds(2.4)

    def bell(f0, amp, at):
        y = zeros(n)
        for r, a, tau in ((1.0, 1.0, 1.3), (2.0, 0.4, 0.9), (2.76, 0.35, 0.7), (4.07, 0.15, 0.4), (5.4, 0.08, 0.25)):
            for det in (0.9985, 1.0015):
                y = add(y, mul(osc(n, f0 * r * det, 'sine', rng.random()), env_perc(n, 0.002, tau)), a * 0.5)
        strike = mul(biquad(white(n, rng), 'bandpass', f0 * 3.0, 1.5), env_perc(n, 0.0003, 0.004))
        y = add(y, nrm(strike), 0.5)
        return (nrm(y), amp, at)

    x = mixn([bell(659.3, 1.0, 0.0), bell(523.3, 0.9, 0.5)])[:n]
    return distant(x, cutoff=3000.0, rt60=2.6, wet=0.5, predelay=0.04, damp=0.35)


def s_clicks(rng, variant):
    """The Watcher relocating: a burst of bony clicks, fast in the middle, with a chitinous rasp under it."""
    N = 11 if variant == 1 else 7
    base = 0.042 if variant == 1 else 0.075
    lo, hi = (2700.0, 3700.0) if variant == 1 else (1900.0, 2700.0)
    x = zeros(seconds(0.3))
    t = 0.02
    for k in range(N):
        d = seconds(0.06)
        imp = zeros(d)
        imp[0] = 1.0
        imp[1] = -0.6
        for i in range(2, seconds(0.002)):
            imp[i] = (rng.random() * 2.0 - 1.0) * 0.5
        ring = nrm(biquad(imp, 'bandpass', rng.uniform(lo, hi), 14.0))
        knock = nrm(biquad(imp, 'bandpass', rng.uniform(600.0, 850.0), 9.0))
        c = mul(add(ring, knock, 0.5), env_exp(d, 0.007))
        add_into(x, c, t, rng.uniform(0.6, 1.0))
        t += base * (1.0 + 0.9 * math.cos(math.pi * (k + 0.5) / N) ** 2)
    n = len(x) + seconds(0.05)
    x.extend([0.0] * (n - len(x)))
    rasp = mul(nrm(biquad(pink(n, rng), 'highpass', 4000.0, 0.7)), env_follow(x, 0.02))
    x = add(x, rasp, 0.15)
    return reverb(x, rt60=0.5 if variant == 1 else 0.9, wet=0.25, dry=1.0, damp=0.5, predelay=0.008)


def s_howl(rng, variant):
    """The Hound's howl: a gliding, vibrato'd voice through morphing vowel formants, growl at both ends."""
    if variant == 1:
        dur = 2.3
        pitch = [(0, 170.0), (0.45, 330.0), (1.5, 345.0), (1.75, 300.0), (2.3, 200.0)]
    else:
        dur = 2.6
        pitch = [(0, 140.0), (0.6, 265.0), (1.15, 270.0), (1.22, 400.0), (1.32, 250.0), (1.9, 240.0), (2.6, 160.0)]
    n = seconds(dur)
    f = contour(n, pitch, log=True)
    vib = [f[i] * (1.0 + 0.03 * math.sin(TWO_PI * 5.5 * i / SR) * min(1.0, i / (SR * 0.6))) for i in range(n)]
    src = osc(n, vib, 'saw')
    sub = osc(n, [v * 0.5 for v in vib], 'square')
    growl = contour(n, [(0, 1.0), (0.5, 0.0), (dur - 0.7, 0.0), (dur - 0.25, 1.0), (dur, 1.0)])
    am = [1.0 - 0.5 * growl[i] * (0.5 + 0.5 * math.sin(TWO_PI * 30.0 * i / SR)) for i in range(n)]
    voice = [(src[i] + 0.35 * sub[i] * growl[i]) * am[i] for i in range(n)]
    F1 = contour(n, [(0, 340.0), (0.6, 720.0), (1.6, 700.0), (dur, 380.0)])
    F2 = contour(n, [(0, 780.0), (0.6, 1180.0), (1.6, 1150.0), (dur, 850.0)])
    bands = [(F1, 6.0, 1.0), (F2, 7.0, 0.55), (2500.0, 8.0, 0.18)]
    v = nrm(add(formants(voice, bands), voice, 0.15))
    breath = nrm(formants(pink(n, rng), bands))
    env = contour(n, [(0, 0.0), (0.12, 1.0), (dur - 0.45, 1.0), (dur, 0.0)])
    x = [(v[i] + 0.25 * breath[i]) * env[i] for i in range(n)]
    return distant(clip(x, 1.8), cutoff=2200.0, rt60=2.8, wet=0.55, predelay=0.05, damp=0.4)


def s_snarl(rng):
    """The Hound, lost: a guttural snarl in two pulses, vocal fry, breath and rasp, saturated."""
    dur = 1.25
    n = seconds(dur)
    f0 = wander(n, rng, 85.0, 0.08, 6.0)
    src = add(osc(n, f0, 'saw'), osc(n, f0, 'square'), 0.5)
    fry = pulse_train(n, rng, 32.0, jitter=0.25, width=0.35)
    src = [src[i] * (0.3 + 0.7 * fry[i]) for i in range(n)]
    breath = biquad(pink(n, rng), 'bandpass', 900.0, 1.0)
    rasp = nrm([breath[i] * fry[i] for i in range(n)])
    bands = [(450.0, 5.0, 1.0), (1300.0, 6.0, 0.55), (2300.0, 6.0, 0.3)]
    v = add(formants(src, bands), formants(breath, bands), 0.35)
    v = add(v, rasp, 0.2)
    env = contour(n, [(0, 0.0), (0.08, 0.8), (0.5, 1.0), (0.58, 0.25), (0.66, 1.0), (1.05, 0.9), (1.25, 0.0)])
    x = clip(mul(nrm(v), env), 2.5)
    return reverb(x, rt60=0.7, wet=0.2, dry=1.0, damp=0.5, predelay=0.012)


def s_hound_step(rng):
    """One fast, wet, slapping footfall: slap + flap, pad thump, squelch, claw tick, droplets."""
    n = seconds(0.2)
    slap = mul(biquad(white(n, rng), 'bandpass', 1500.0, 0.8), env_perc(n, 0.0005, 0.018))
    flap = mul(biquad(white(n, rng), 'bandpass', 1100.0, 1.0), env_perc(n, 0.0005, 0.012, start=0.014))
    pad = mul(osc(n, contour(n, [(0, 130.0), (0.05, 70.0)], log=True)), env_perc(n, 0.002, 0.03))
    squelch = mul(biquad_sweep(pink(n, rng), 'bandpass', contour(n, [(0, 1500.0), (0.1, 500.0)], log=True), 4.0),
                  env_perc(n, 0.004, 0.04, start=0.006))
    claw = mul(biquad(white(n, rng), 'bandpass', 5200.0, 3.0), env_perc(n, 0.0002, 0.0015))
    drops = zeros(n)
    for _ in range(3):
        d = seconds(0.012)
        fq = rng.uniform(2500.0, 4200.0)
        b = mul(osc(d, contour(d, [(0, fq), (0.012, fq * 0.7)], log=True)), env_perc(d, 0.0005, 0.004))
        add_into(drops, b, rng.uniform(0.02, 0.12), 0.3)
    x = mixn([(nrm(slap), 1.0), (nrm(flap), 0.6), (pad, 0.7), (nrm(squelch), 0.35), (nrm(claw), 0.4), (drops[:n], 1.0)])
    x = biquad(x, 'highpass', 50.0, 0.7)
    return fade(x, 0.0005, 0.02)


def s_vcr_whirr(rng):
    """A VCR loading: clunk, motor spinning up with the head drum whining, servo ticks, hiss, clunk."""
    dur = 2.2
    n = seconds(dur)
    speed = contour(n, [(0, 0.0), (0.05, 0.0), (0.4, 1.0), (1.85, 1.0), (1.9, 0.3), (2.2, 0.0)])
    mf = [50.0 * max(0.05, s) for s in speed]
    motor = biquad(osc(n, mf, 'saw'), 'lowpass', 420.0, 1.2)
    motor = add(motor, osc(n, [v * 2.0 for v in mf]), 0.3)
    motor = add(motor, osc(n, [v * 3.0 for v in mf]), 0.15)
    comm = [1.0 - 0.2 * (0.5 + 0.5 * math.sin(TWO_PI * 24.0 * i / SR)) for i in range(n)]
    motor = nrm([motor[i] * comm[i] * speed[i] for i in range(n)])
    drum_f = [1500.0 * s * (1.0 + 0.006 * math.sin(TWO_PI * 8.0 * i / SR)) for i, s in enumerate(speed)]
    drum = add(osc(n, drum_f), osc(n, [v * 2.0 for v in drum_f]), 0.3)
    drum = nrm([drum[i] * speed[i] ** 2 for i in range(n)])
    hiss = nrm(mul(biquad(white(n, rng), 'highpass', 3000.0, 0.7), speed))
    ticks = zeros(n)
    t = 0.45
    while t < 1.75:
        d = seconds(0.02)
        tk = mul(biquad(white(d, rng), 'bandpass', 3000.0, 4.0), env_perc(d, 0.0002, 0.002))
        add_into(ticks, nrm(tk), t, rng.uniform(0.08, 0.15))
        t += 0.09

    def clunk(at, g):
        d = seconds(0.3)
        thud = mul(osc(d, contour(d, [(0, 90.0), (0.1, 50.0)], log=True)), env_perc(d, 0.002, 0.06))
        clk = mul(biquad(white(d, rng), 'bandpass', 1800.0, 3.0), env_perc(d, 0.0003, 0.008))
        plastic = mul(biquad(white(d, rng), 'bandpass', 420.0, 10.0), env_perc(d, 0.001, 0.07))
        return (mixn([(thud, 0.7), (nrm(clk), 0.6), (nrm(plastic), 0.4)]), g, at)

    x = mixn([(motor, 0.35), (drum, 0.12), (hiss, 0.06), (ticks[:n], 1.0), clunk(0.0, 1.0), clunk(1.85, 0.9)])[:n]
    return reverb(x, rt60=0.4, wet=0.15, dry=1.0, damp=0.6, predelay=0.006)


def s_paper(rng):
    """The map unfolding / folding: crackling grain, discrete crinkles, two flaps and a final snap."""
    dur = 0.55
    n = seconds(dur)
    bed = biquad(white(n, rng), 'highpass', 1800.0, 0.7)
    shape = contour(n, [(0, 0.0), (0.06, 0.5), (0.2, 1.0), (0.32, 0.6), (0.42, 0.9), (0.5, 0.2), (0.55, 0.0)])
    grain = grain_gate(n, rng, 0.004, 0.012)
    bed = nrm([bed[i] * shape[i] * grain[i] for i in range(n)])
    crinkles = zeros(n)
    for _ in range(28):
        t = min(0.5, max(0.01, rng.gauss(0.25, 0.12)))
        d = seconds(rng.uniform(0.003, 0.009))
        c = mul(biquad(white(d, rng), 'bandpass', rng.uniform(2000.0, 7000.0), 3.0), env_perc(d, 0.0003, 0.002))
        add_into(crinkles, nrm(c), t, rng.uniform(0.2, 0.7))
    flaps = zeros(n)
    for t, g in ((0.05, 0.5), (0.4, 0.45)):
        d = seconds(0.06)
        fl = mul(biquad(white(d, rng), 'lowpass', 600.0, 0.8), env_perc(d, 0.002, 0.02))
        add_into(flaps, nrm(fl), t, g)
    snap = mul(white(n, rng), env_perc(n, 0.0002, 0.0025, start=0.455))
    x = mixn([(bed, 0.8), (crinkles[:n], 1.0), (flaps[:n], 1.0), (snap, 0.7)])
    return fade(x, 0.001, 0.02)


# name -> (generator, peak[, rms_dB]).  Loops (in LOOPS) get loop_finish.  A third value normalises
# by RMS instead of peak: the dense tonal beds must sit with hum (-18 dB) and presence (-20 dB),
# since AudioBus crossfades HUM <-> HUM_DARK at equal volume.
RECIPES = {
    'hum_dark':    (lambda r: s_hum_dark(r), 0.59, -16.0),
    'presence_hi': (lambda r: s_presence_hi(r), 0.59, -20.0),
    'drip_loop':   (lambda r: s_drip_loop(r), 0.70),
    'splash1':     (lambda r: s_splash(r, 1), 0.84),
    'splash2':     (lambda r: s_splash(r, 2), 0.84),
    'distant1':    (lambda r: s_distant1(r), 0.80),
    'distant2':    (lambda r: s_distant2(r), 0.75),
    'distant3':    (lambda r: s_distant3(r), 0.80),
    'distant4':    (lambda r: s_distant4(r), 0.80),
    'distant6':    (lambda r: s_distant6(r), 0.75),
    'clicks1':     (lambda r: s_clicks(r, 1), 0.84),
    'clicks2':     (lambda r: s_clicks(r, 2), 0.84),
    'howl1':       (lambda r: s_howl(r, 1), 0.84),
    'howl2':       (lambda r: s_howl(r, 2), 0.84),
    'snarl':       (lambda r: s_snarl(r), 0.84),
    'hound_step':  (lambda r: s_hound_step(r), 0.84),
    'vcr_whirr':   (lambda r: s_vcr_whirr(r), 0.80),
    'paper':       (lambda r: s_paper(r), 0.84),
}

GEN_ORDER = ['hum_low'] + [n for n in SFX_FILES if n in RECIPES]


# ----------------------------------------------------------------------------
# Files
# ----------------------------------------------------------------------------

def write_wav(path, x):
    a = array.array('h')
    for v in x:
        if v > 1.0:
            v = 1.0
        elif v < -1.0:
            v = -1.0
        a.append(int(round(v * 32767.0)))
    w = wave.open(path, 'wb')
    try:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(a.tobytes())
    finally:
        w.close()


def read_wav(path):
    w = wave.open(path, 'rb')
    try:
        if w.getnchannels() != 1 or w.getsampwidth() != 2 or w.getframerate() != SR:
            raise RuntimeError('%s is not %d Hz mono 16-bit' % (path, SR))
        a = array.array('h')
        a.frombytes(w.readframes(w.getnframes()))
    finally:
        w.close()
    return [v / 32768.0 for v in a]


def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.stderr.write(p.stderr.decode('utf-8', 'replace'))
        raise RuntimeError('command failed: %s' % ' '.join(cmd))
    return p.stdout.decode('utf-8', 'replace')


def encode_mp3(wav, mp3):
    """CONTRACT section 5: ffmpeg -y -i in.wav -ac 1 -ar 22050 -b:a 64k -codec:a libmp3lame out.mp3"""
    run([FFMPEG, '-y', '-hide_banner', '-loglevel', 'error', '-i', wav,
         '-ac', '1', '-ar', '22050', '-b:a', '64k', '-codec:a', 'libmp3lame', mp3])


def probe(path):
    """(duration_s, sample_rate, channels, codec, bytes) via ffprobe; None if the file is missing."""
    if not os.path.exists(path):
        return None
    out = run([FFPROBE, '-v', 'error', '-show_entries',
               'stream=codec_name,sample_rate,channels:format=duration',
               '-of', 'csv=p=0', path])
    codec = sr = ch = None
    dur = 0.0
    for line in out.splitlines():
        parts = line.strip().split(',')
        if len(parts) >= 3 and parts[0] and not parts[0].replace('.', '').isdigit():
            codec, sr, ch = parts[0], int(parts[1]), int(parts[2])
        elif len(parts) >= 1 and parts[0]:
            try:
                dur = float(parts[0])
            except ValueError:
                pass
    return (dur, sr, ch, codec, os.path.getsize(path))


def make_hum_low(wav, force):
    """hum.mp3 pitched down one semitone by ffmpeg (asetrate=<src>*0.9439,aresample=22050), then loop-finished."""
    src = os.path.join(MP3_DIR, 'hum.mp3')
    if not os.path.exists(src):
        raise RuntimeError('hum.mp3 is missing; hum_low is derived from it')
    info = probe(src)
    src_rate = info[1] if info and info[1] else 22050
    if src_rate != 22050:
        print('  note: hum.mp3 is %d Hz, so asetrate=%d*0.9439 (the contract wrote 22050*0.9439 assuming a 22050 Hz source)'
              % (src_rate, src_rate))
    raw = wav + '.raw.wav'
    run([FFMPEG, '-y', '-hide_banner', '-loglevel', 'error', '-i', src,
         '-af', 'asetrate=%d*0.9439,aresample=22050' % src_rate,
         '-ac', '1', '-ar', '22050', '-acodec', 'pcm_s16le', raw])
    x = loop_finish(read_wav(raw))
    os.remove(raw)
    write_wav(wav, x)
    return len(x)


def build(name, force):
    wav = os.path.join(WAV_DIR, name + '.wav')
    mp3 = os.path.join(MP3_DIR, name + '.mp3')
    if name in KEEP:
        raise RuntimeError('%s is a kept file and is never generated' % name)
    if os.path.exists(mp3) and not force:
        print('  %-12s exists, skipped' % name)
        return
    if not os.path.exists(wav) or force:
        t0 = time.time()
        if name == 'hum_low':
            n = make_hum_low(wav, force)
        else:
            spec = RECIPES[name]
            gen, peak = spec[0], spec[1]
            rng = random.Random('backrooms:' + name)
            x = gen(rng)
            x = nrm_rms(x, spec[2]) if len(spec) > 2 else nrm(x, peak)
            if name in LOOPS:
                x = loop_finish(x)
            else:
                x = fade(x, 0.0, 0.01)      # reverb tails end below -30 dB; this removes the last tick
            write_wav(wav, x)
            n = len(x)
        print('  %-12s wav  %6.2f s  (%.1f s to render)' % (name, n / float(SR), time.time() - t0))
    else:
        print('  %-12s wav exists' % name)
    encode_mp3(wav, mp3)
    print('  %-12s mp3  %d bytes' % (name, os.path.getsize(mp3)))


def verify():
    """Every file the Sfx class embeds: present, mono. Returns True if all good."""
    ok = True
    print('')
    print('%-3s %-12s %-6s %8s %6s %3s %8s  %s' % ('id', 'name', 'kind', 'dur s', 'rate', 'ch', 'bytes', 'file'))
    for i, name in enumerate(SFX_FILES):
        path = os.path.join(MP3_DIR, name + '.mp3')
        info = probe(path)
        kind = 'loop' if name in LOOPS else 'shot'
        if info is None:
            print('%-3d %-12s %-6s %8s %6s %3s %8s  MISSING' % (i, name, kind, '-', '-', '-', '-'))
            ok = False
            continue
        dur, sr, ch, codec, size = info
        flag = ''
        if ch != 1:
            flag = '  NOT MONO'
            ok = False
        if codec != 'mp3':
            flag += '  codec=%s' % codec
            ok = False
        print('%-3d %-12s %-6s %8.3f %6d %3d %8d  %s%s' % (i, name, kind, dur, sr, ch, size, name + '.mp3', flag))
    print('')
    print('ALL PRESENT AND MONO' if ok else 'PROBLEMS FOUND')
    return ok


def main(argv):
    force = '--force' in argv
    only = None
    for a in argv:
        if a.startswith('--only'):
            v = a.split('=', 1)[1] if '=' in a else argv[argv.index(a) + 1]
            only = [s.strip() for s in v.split(',') if s.strip()]
    if '--verify' not in argv:
        os.makedirs(WAV_DIR, exist_ok=True)
        os.makedirs(MP3_DIR, exist_ok=True)
        names = GEN_ORDER if only is None else only
        for name in names:
            if name not in GEN_ORDER:
                raise SystemExit('unknown sound %r (generated set: %s)' % (name, ', '.join(GEN_ORDER)))
        print('backrooms_sfx: %d generated sounds -> %s' % (len(names), MP3_DIR))
        for name in names:
            build(name, force)
    return 0 if verify() else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
