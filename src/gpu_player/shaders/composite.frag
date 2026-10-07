// A texture of premultiplied, sRGB-encoded values (the player draws in the encoded space)
// copied onto a target: a tile onto the frame texture (`decode` 0, blended in the encoded
// space as the CPU player blends), or the frame texture onto the window's linear-light target
// (`decode` 1: each texel decoded first). `origin` is the texture's top left in the target's
// pixels.
#version 450
layout(location = 0) in vec4 vertex_color;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec2 origin;
    float decode;
} params;
layout(set = 0, binding = 1) uniform sampler2D source;

vec3 srgb_decode(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void main() {
    vec4 t = texelFetch(source, ivec2(floor(gl_FragCoord.xy - params.origin)), 0);
    if (params.decode < 0.5) {
        fragment_color = t;
        return;
    }
    fragment_color = t.a > 0.0 ? vec4(srgb_decode(t.rgb / t.a) * t.a, t.a) : vec4(0.0);
}
