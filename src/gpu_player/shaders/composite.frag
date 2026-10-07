// A tile (or the frame texture) onto the compositor's target, texel for pixel: the texture at
// binding 1 with its top left at `origin` of the target, premultiplied and sRGB-encoded as the
// player draws (blended in the encoded space, as the CPU player blends); decoded first when
// `decode` is 1 (the frame texture onto a linear-light target). Its own small program, since
// it covers the screen every frame.
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
