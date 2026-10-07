// Many masks from the player's atlas in one instanced draw (glyphs of a run, path and
// shadow coverage), each tinted with its own color, under at most one rounded clip and
// the clip mask shared by the draw. Per instance (luce-gpu's locations 1..2): where the
// mask sits in the tile and in the atlas, and its premultiplied color.
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
layout(location = 0) in vec4 vertex_color;
layout(location = 1) flat in vec4 placement;   // dst.xy (tile pixels), src.xy (atlas texels)
layout(location = 2) flat in vec4 color;       // premultiplied
layout(location = 3) flat in vec4 unused;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec4 clip_rect;
    vec4 clip_radii0;
    vec4 clip_radii1;
    float clip_mode;
    float mask;      // 1: multiply by the clip mask at binding 2
} params;
layout(set = 0, binding = 1) uniform sampler2D atlas;
layout(set = 0, binding = 2) uniform sampler2D clip_mask;

void main() {
    vec2 p = gl_FragCoord.xy;
    ivec2 at = ivec2(floor(p - placement.xy)) + ivec2(placement.zw);
    float coverage = texelFetch(atlas, at, 0).r;
    coverage *= clip_coverage(p, params.clip_mode, params.clip_rect, params.clip_radii0, params.clip_radii1);
    coverage *= mask_coverage(clip_mask, p, params.mask);
    fragment_color = color * coverage;
}
