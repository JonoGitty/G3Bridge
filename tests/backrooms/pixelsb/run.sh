#!/bin/sh
# Runtime tests for the pixels-b unit under haxe --interp (run from the repo root, WSL).
# The flash package is unreachable on eval, so the three classes are copied with
# `flash.Vector` -> `PixVec` (a bounds-checking shim) and compiled LAST so the copies win.
set -e
HAXE=${HAXE:-/mnt/c/AI/tools/haxe/haxe.exe}
mkdir -p run/pixelsb_interp
for c in PixelFont Hud Cards; do
  sed 's/flash\.Vector/PixVec/g' "src/backrooms/$c.hx" > "run/pixelsb_interp/$c.hx"
done
"$HAXE" -cp src/backrooms -cp tests/backrooms/pixelsb -cp run/pixelsb_interp -main TestPixelsB --interp
