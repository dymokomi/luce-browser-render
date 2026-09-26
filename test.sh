#!/bin/sh
# Check that every hand-written fragment is formatted, type-check every module of
# luce-browser-render with warnings as errors, and run each module's tests. Stops at the first
# failing step.
set -e
cd "$(dirname "$0")"

# Every hand-written fragment is laid out as the pinned compiler's formatter lays it out.
# (No fragment of this repository is generated output any more: the skeleton's types_*
# fragments were edited by hand and are formatted too.)
echo "== luce-base fmt --check"
for file in $(git ls-files '*.lucb' | grep -v -e '/generated_' -e '_tables\.lucb$'); do
    luce-base fmt "$file" --check > /dev/null || { echo "$file is not formatted (luce-base fmt $file --write)"; exit 1; }
done

# check MODULE: `luce-base check -W`, which reports warnings without failing, so any output at
# all fails the run.
check() {
    echo "== luce-base check src/luce_browser_render/$1 -W"
    output=$(luce-base check "src/luce_browser_render/$1" -W 2>&1) || { echo "$output"; exit 1; }
    if [ -n "$output" ]; then
        echo "$output"
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
