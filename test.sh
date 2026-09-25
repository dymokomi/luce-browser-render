#!/bin/sh
# Type-check every module of luce-browser-render (and run its tests once there are any).
# Stops at the first failing step.
set -e
cd "$(dirname "$0")"

for module in gfx web_fonts raster display_list; do
    echo "== luce-base check src/luce_browser_render/$module"
    luce-base check "src/luce_browser_render/$module"
done
