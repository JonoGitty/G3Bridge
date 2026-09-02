# Probes that measured the eMac before the game was designed

Compile any of them with (from the repo root, Windows Haxe, relative paths):

    C:\AI\tools\haxe\haxe.exe -cp tools\backrooms_probes -main Bench2 -swf www\games\backrooms\bench2.swf -swf-version 10.1 -D swf-header=1024:768:30:000000

- `Hello.hx` — 320x240 plasma via setVector; proves compile -> serve -> Flash -> /telemetry.
- `Bench.hx` — fill/ray workloads at three resolutions, smoothing, noise overlay, BlurFilter (the 6 fps result).
- `Bench2.hx` — walls, floor casting at full/half rows, billboard sprites.
- `KeyProbe.hx` — keyboard, fullscreen, ExternalInterface `g3`, `/rc` polling, snapshots via Png/Telemetry.

Results are in `docs/backrooms/BRIEF.md` and `run/telemetry.log`.
