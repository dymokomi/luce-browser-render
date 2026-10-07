#!/bin/sh
# glslangValidator, then spirv-opt for size: the SPIR-V the player embeds carries no debug names
# and is optimized for size (the Metal translation is made from it too).
set -e
glslangValidator "$@"
output=""
previous=""
for argument in "$@"; do
    [ "$previous" = "-o" ] && output="$argument"
    previous="$argument"
done
spirv-opt --strip-debug "$output" -o "$output"
