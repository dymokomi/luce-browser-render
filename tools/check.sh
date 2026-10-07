#!/bin/sh
# Lint, not a test (`luc test` runs the tests): every fragment is laid out as luce-base fmt
# lays it out, and every module checks with -W without a word.
set -e
cd "$(dirname "$0")/.."
for file in $(git ls-files '*.lucb' | grep -v -e '/generated_' -e '_tables\.lucb$'); do
    luce-base fmt "$file" --check > /dev/null || { echo "$file is not formatted (luce-base fmt $file --write)"; exit 1; }
done
for module in src/raster src/gfx src/web_fonts src/display_list src/gpu_player; do
    # -W reports warnings without failing, so any output at all fails the run, except warnings
    # in another package's code (gpu_player reaches luce-gpu and luce-window, whose platform
    # helpers warn on other hosts): those are shown, and the module must then check without -W.
    status=0
    output=$(luce-base check "$module" -W 2>&1) || status=$?
    pattern='^luce-base: luce_[a-z_]+/src/[^ ]*: warning: '
    dependency_warnings=$(printf '%s\n' "$output" | grep -E "$pattern" || true)
    output=$(printf '%s\n' "$output" | grep -v -E "$pattern" || true)
    [ -z "$output" ] || { echo "$output"; exit 1; }
    if [ "$status" -ne 0 ]; then
        [ -n "$dependency_warnings" ] || exit 1
        printf '%s\n' "$dependency_warnings" | sed 's/^/(another package) /'
        luce-base check "$module"
    fi
done
echo "clean"
