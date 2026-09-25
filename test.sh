#!/bin/sh
# Type-check every module of luce-browser-render (and run its tests once there are any).
# Stops at the first failing step.
set -e
cd "$(dirname "$0")"

for module in gfx web_fonts display_list; do
    echo "== luce-base check src/luce_browser_render/$module"
    luce-base check "src/luce_browser_render/$module"
done

# raster: written by hand (not generated); run its tests once it exists.
if [ -f src/luce_browser_render/raster/ORDER ]; then
    echo "== luce-base test src/luce_browser_render/raster"
    luce-base test src/luce_browser_render/raster
fi
