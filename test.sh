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
# all fails the run, except warnings in another package's code (gpu_player reaches luce-gpu and
# luce-window, whose unused platform helpers warn on other hosts): those are theirs to fix.
check() {
    echo "== luce-base check src/$1 -W"
    status=0
    output=$(luce-base check "src/$1" -W 2>&1) || status=$?
    pattern='^luce-base: luce_[a-z_]+/src/[^ ]*: warning: '
    dependency_warnings=$(printf '%s\n' "$output" | grep -E "$pattern" || true)
    output=$(printf '%s\n' "$output" | grep -v -E "$pattern" || true)
    if [ -n "$output" ]; then
        echo "$output"
        exit 1
    fi
    # Only another package's warnings: the module must check cleanly without -W.
    if [ "$status" -ne 0 ]; then
        [ -n "$dependency_warnings" ] || exit 1
        luce-base check "src/$1"
    fi
}

for module in raster gfx web_fonts display_list gpu_player; do
    check "$module"
done

# gfx: the region tests (geometry, CSSPixels, color, transforms; bitmaps, paths, painter,
# filters).
echo "== luce-base test src/gfx"
luce-base test src/gfx

# web_fonts: its unit tests and the expectations of the reference build (tests_oracle,
# tests_path_text), with the test fonts of tests/web_fonts.
echo "== luce-base test src/web_fonts"
luce-base test src/web_fonts

# display_list and gpu_player: the modules' tests (the CPU player against Skia's pixels, the
# ported LibWeb logic, the GPU player against the CPU player; testing gpu_player runs the tests
# of display_list, which it imports, too). The GPU scenes skip on a machine without a GPU.
echo "== luce-base test src/gpu_player"
luce-base test src/gpu_player --native

# raster: its unit tests.
echo "== luce-base test src/raster"
luce-base test src/raster

# raster: tiny-skia's integration suite against its reference images (tests/raster).
echo "== tests/run_raster.py"
python3 tests/run_raster.py
