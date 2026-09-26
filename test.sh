#!/bin/sh
# Type-check every module of luce-browser-render (and run its tests once there are any).
# Stops at the first failing step.
set -e
cd "$(dirname "$0")"

for module in gfx web_fonts display_list; do
    echo "== luce-base check src/luce_browser_render/$module"
    luce-base check "src/luce_browser_render/$module"
done

# web_fonts: its unit tests and the expectations of the reference build (tests_oracle), with
# the test fonts of tests/web_fonts.
echo "== luce-base test src/luce_browser_render/web_fonts"
luce-base test src/luce_browser_render/web_fonts

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
