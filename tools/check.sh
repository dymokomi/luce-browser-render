#!/bin/sh
# Lint, not a test (`luc test` runs the tests): every fragment is laid out as luce-base fmt
# lays it out, and every module checks with -W without a word.
set -e
cd "$(dirname "$0")/.."
for file in $(git ls-files '*.lucb' | grep -v -e '/generated_' -e '_tables\.lucb$'); do
    luce-base fmt "$file" --check > /dev/null || { echo "$file is not formatted (luce-base fmt $file --write)"; exit 1; }
done
for module in src/raster src/gfx src/web_fonts src/display_list; do
    # -W reports warnings without failing, so any output at all fails the run.
    output=$(luce-base check "$module" -W 2>&1) || { echo "$output"; exit 1; }
    [ -z "$output" ] || { echo "$output"; exit 1; }
done
echo "clean"
