"""Video for a 2004 Macintosh.

The eMac cannot fetch, and could not decode a modern stream if it could. So the
PC does both: yt-dlp pulls the video, ffmpeg re-encodes it to something a
1.25 GHz PowerPC G4 can actually play, and the result is served down the cable.

CODEC CHOICE MATTERS HERE. H.264 is decodable on a G4 but expensive; MPEG-4
Part 2 is what that generation of QuickTime was built for and costs a fraction
of the CPU. At 480x360 a G4 plays Part 2 comfortably and H.264 marginally, so
Part 2 is the default and H.264 is offered for quality on short clips.

Jobs run one at a time on a worker thread. Transcoding is slow and doing two at
once on a shared machine just makes both slow.
"""

import os
import re
import subprocess
import threading
import time

FFMPEG = None
YTDLP = None
for cand in (r"C:\Users\jonog\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe",
             r"C:\Panda3D-1.10.15-x64\bin\ffmpeg.exe", "ffmpeg"):
    if cand == "ffmpeg" or os.path.isfile(cand):
        FFMPEG = cand
        break
for cand in (r"C:\Python310\Scripts\yt-dlp.exe", "yt-dlp"):
    if cand == "yt-dlp" or os.path.isfile(cand):
        YTDLP = cand
        break

# name -> (width, height, video bitrate, codec, human description)
PROFILES = {
    "small":  (320, 240, "350k",  "mpeg4", "320x240 - safest, plays on anything"),
    "normal": (480, 360, "700k",  "mpeg4", "480x360 - the sweet spot for a G4"),
    "large":  (640, 480, "1100k", "mpeg4", "640x480 - fills more of the screen, may stutter"),
    "sharp":  (480, 360, "800k",  "h264",  "480x360 H.264 - better picture, heavier to decode"),
}
DEFAULT_PROFILE = "normal"
MAX_SECONDS = 60 * 25          # refuse very long videos; a G4 has a small disk

_lock = threading.Lock()
_jobs = []                     # newest first
_queue = []
_worker = None


def available():
    return bool(FFMPEG and YTDLP)


def safe_stem(text):
    text = re.sub(r"[^A-Za-z0-9 _-]", "", text or "").strip()
    text = re.sub(r"\s+", "_", text)
    return (text or "video")[:60]


class Job(object):
    def __init__(self, url, profile):
        self.url = url
        self.profile = profile if profile in PROFILES else DEFAULT_PROFILE
        self.state = "queued"      # queued|fetching|encoding|ready|failed
        self.title = url
        self.message = ""
        self.filename = None
        self.size = 0
        self.started = time.time()
        self.finished = None
        self.duration = 0


def submit(url, profile, outdir):
    url = (url or "").strip()
    if not url.lower().startswith(("http://", "https://")):
        raise ValueError("that does not look like a web address")
    job = Job(url, profile)
    with _lock:
        _jobs.insert(0, job)
        _queue.append((job, outdir))
    _start_worker()
    return job


def jobs():
    with _lock:
        return list(_jobs)


def _start_worker():
    global _worker
    if _worker is not None and _worker.is_alive():
        return
    _worker = threading.Thread(target=_run, name="video", daemon=True)
    _worker.start()


def _probe_title_and_length(url):
    try:
        r = subprocess.run([YTDLP, "--no-warnings", "--print", "%(title)s|%(duration)s",
                            "--skip-download", url],
                           capture_output=True, text=True, timeout=90)
        line = (r.stdout or "").strip().splitlines()
        if line:
            parts = line[-1].split("|")
            title = parts[0].strip()
            dur = 0
            if len(parts) > 1:
                try:
                    dur = int(float(parts[1]))
                except ValueError:
                    dur = 0
            return title, dur
    except (OSError, subprocess.TimeoutExpired):
        pass
    return url, 0


def _run():
    while True:
        with _lock:
            if not _queue:
                return
            job, outdir = _queue.pop(0)
        try:
            _process(job, outdir)
        except Exception as e:
            job.state = "failed"
            job.message = "%s: %s" % (type(e).__name__, str(e)[:200])
            job.finished = time.time()


def _process(job, outdir):
    if not os.path.isdir(outdir):
        os.makedirs(outdir)

    job.state = "fetching"
    title, dur = _probe_title_and_length(job.url)
    job.title = title or job.url
    job.duration = dur
    if dur and dur > MAX_SECONDS:
        job.state = "failed"
        job.message = ("that is %d minutes long; the limit is %d so the eMac's disk "
                       "and your patience survive" % (dur // 60, MAX_SECONDS // 60))
        job.finished = time.time()
        return

    stem = safe_stem(job.title)
    tmp = os.path.join(outdir, stem + ".src")
    for old in (tmp, tmp + ".part"):
        if os.path.exists(old):
            try:
                os.remove(old)
            except OSError:
                pass

    r = subprocess.run(
        [YTDLP, "--no-warnings", "--no-playlist",
         "-f", "bv*[height<=720]+ba/b[height<=720]/b",
         "--merge-output-format", "mp4", "-o", tmp, job.url],
        capture_output=True, text=True, timeout=1800)
    src = tmp
    if not os.path.exists(src):
        for ext in (".mp4", ".mkv", ".webm"):
            if os.path.exists(tmp + ext):
                src = tmp + ext
                break
    if not os.path.exists(src):
        job.state = "failed"
        job.message = "could not download: " + (r.stderr or "")[-220:]
        job.finished = time.time()
        return

    job.state = "encoding"
    w, h, vb, codec, _desc = PROFILES[job.profile]
    out = os.path.join(outdir, stem + ".mp4")
    if codec == "h264":
        vargs = ["-c:v", "libx264", "-profile:v", "baseline", "-level", "3.0",
                 "-preset", "medium", "-b:v", vb]
    else:
        # MPEG-4 Part 2: what QuickTime 7 on PowerPC was designed around.
        vargs = ["-c:v", "mpeg4", "-vtag", "mp4v", "-b:v", vb]

    cmd = ([FFMPEG, "-y", "-i", src,
            "-vf", "scale=%d:%d:force_original_aspect_ratio=decrease,"
                   "pad=%d:%d:(ow-iw)/2:(oh-ih)/2,fps=24" % (w, h, w, h)]
           + vargs
           + ["-c:a", "aac", "-b:a", "96k", "-ac", "2", "-ar", "44100",
              "-movflags", "+faststart", out])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    try:
        os.remove(src)
    except OSError:
        pass

    if not os.path.exists(out) or os.path.getsize(out) < 1000:
        job.state = "failed"
        job.message = "encode failed: " + (r.stderr or "")[-220:]
        job.finished = time.time()
        return

    job.filename = os.path.basename(out)
    job.size = os.path.getsize(out)
    job.state = "ready"
    job.finished = time.time()


def library(outdir):
    """[(filename, size, mtime)] newest first."""
    out = []
    try:
        names = os.listdir(outdir)
    except OSError:
        return out
    for n in names:
        if not n.endswith(".mp4"):
            continue
        fn = os.path.join(outdir, n)
        try:
            st = os.stat(fn)
        except OSError:
            continue
        out.append((n, st.st_size, st.st_mtime))
    out.sort(key=lambda r: r[2], reverse=True)
    return out
