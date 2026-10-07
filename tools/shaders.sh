#!/bin/sh
# Embeds the GPU player's shaders (src/gpu_player/shaders) into generated_shaders.lucb with
# luce-gpu's tools/embed_shaders.py. Needs glslangValidator, spirv-opt and spirv-cross; builds
# use the checked-in module, so run this only when a shader changes.
set -e
cd "$(dirname "$0")/.."
shaders=src/gpu_player/shaders
python3 ../luce-gpu/tools/embed_shaders.py src/gpu_player/generated_shaders.lucb --shared \
    --glslang "$PWD/tools/glslang_small.sh" \
    $shaders/tile.frag
