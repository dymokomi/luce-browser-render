#!/bin/sh
# Check that every hand-written fragment is formatted, type-check every module of
# luce-browser-render with warnings as errors, and run each module's tests. Stops at the first
# failing step.
set -e
cd "$(dirname "$0")"

# Every hand-written fragment is laid out as the pinned compiler's formatter lays it out.
# (No fragment of this repository is generated output any more: the skeleton's types_*
# fragments were edited by hand and are formatted too.)
# FIXME: raster (src/luce_browser_render/raster, tests/raster) is left out until the
#        port/raster-skia branch, which rewrites it, is merged and formatted.
echo "== luce-base fmt --check"
for file in $(git ls-files '*.lucb' | grep -v -e '/generated_' -e '_tables\.lucb$' -e '^src/luce_browser_render/raster/' -e '^tests/raster/'); do
    luce-base fmt "$file" --check > /dev/null || { echo "$file is not formatted (luce-base fmt $file --write)"; exit 1; }
done

# raster's own warnings, which every module importing it repeats. FIXME: the five unused
# functions below are the port/raster-skia branch's to remove; drop this list when it is merged.
raster_known_warnings='unused function `f8_round_int`
unused function `i8_to_f8`
unused function `f8_to_i8_bitcast`
unused function `highp_lerp`
unused function `lowp_source_over_k`'

# check MODULE [raster]: `luce-base check -W`, which reports warnings without failing, so any
# output at all fails the run. The raster module's warnings are checked once, by `check raster`
# (against raster_known_warnings); the other modules' checks leave them out.
check() {
    echo "== luce-base check src/luce_browser_render/$1 -W"
    output=$(luce-base check "src/luce_browser_render/$1" -W 2>&1) || { echo "$output"; exit 1; }
    if [ "$1" = raster ]; then
        unknown=$(printf '%s\n' "$output" | grep -v -F "$raster_known_warnings" || true)
    else
        unknown=$(printf '%s\n' "$output" | grep -v '^luce-base: src/luce_browser_render/raster:[0-9]*:[0-9]*: warning: ' || true)
    fi
    if [ -n "$unknown" ]; then
        echo "$unknown"
        exit 1
    fi
}

for module in raster gfx web_fonts display_list; do
    check "$module"
done

# gfx: the region tests (geometry, CSSPixels, color, transforms; bitmaps, paths, painter,
# filters).
echo "== luce-base test src/luce_browser_render/gfx"
luce-base test src/luce_browser_render/gfx

# web_fonts: its unit tests and the expectations of the reference build (tests_oracle,
# tests_path_text), with the test fonts of tests/web_fonts.
echo "== luce-base test src/luce_browser_render/web_fonts"
luce-base test src/luce_browser_render/web_fonts

# display_list: the module's tests (the CPU player against Skia's pixels, the ported LibWeb
# logic).
echo "== luce-base test src/luce_browser_render/display_list"
luce-base test src/luce_browser_render/display_list --native

# raster: its unit tests.
echo "== luce-base test src/luce_browser_render/raster"
luce-base test src/luce_browser_render/raster

# raster: tiny-skia's integration suite against its reference images (tests/raster).
echo "== tests/run_raster.py"
python3 tests/run_raster.py
