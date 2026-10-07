#!/bin/sh
# glslangValidator, then spirv-opt for size: the SPIR-V the player embeds carries no debug
# names, its locals become SSA values and dead code goes, but nothing is inlined (inlining
# grows the program, and the Metal translation made from it, several times over).
set -e
glslangValidator "$@"
output=""
previous=""
for argument in "$@"; do
    [ "$previous" = "-o" ] && output="$argument"
    previous="$argument"
done
spirv-opt --strip-debug --eliminate-local-single-block --eliminate-local-single-store --eliminate-local-multi-store --ccp --simplify-instructions --redundancy-elimination --eliminate-dead-branches --merge-blocks --eliminate-dead-code-aggressive --compact-ids "$output" -o "$output"
