// One clip of a nested clip, into the tile's clip mask (an r8 texture cleared to 1): an
// `over` draw of color 0 with alpha 1 - coverage leaves mask * coverage, so each clip
// multiplies what the clips before it let through.
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
layout(location = 0) in vec4 vertex_color;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec4 clip_rect;
    vec4 clip_radii0;
    vec4 clip_radii1;
    float clip_mode;
} params;

void main() {
    float coverage = clip_coverage(gl_FragCoord.xy, params.clip_mode, params.clip_rect, params.clip_radii0, params.clip_radii1);
    fragment_color = vec4(0.0, 0.0, 0.0, 1.0 - coverage);
}
