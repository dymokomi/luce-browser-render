#!/bin/sh
# Type-check every module of luce-browser-render (and run its tests once there are any).
# Stops at the first failing step.
set -e
cd "$(dirname "$0")"

for module in gfx web_fonts display_list; do
    echo "== luce-base check src/luce_browser_render/$module"
    luce-base check "src/luce_browser_render/$module"
done

# display_list: the module's tests (the CPU player against Skia's pixels, the ported LibWeb logic).
echo "== luce-base test src/luce_browser_render/display_list"
luce-base test src/luce_browser_render/display_list --native

# raster: written by hand (not generated); run its tests once it exists.
if [ -f src/luce_browser_render/raster/ORDER ]; then
    echo "== luce-base test src/luce_browser_render/raster"
    luce-base test src/luce_browser_render/raster
fi

# raster: tiny-skia's integration suite against its reference images (tests/raster).
if [ -f tests/raster/run.lucb ]; then
    echo "== tests/run_raster.py"
    python3 tests/run_raster.py
fi
