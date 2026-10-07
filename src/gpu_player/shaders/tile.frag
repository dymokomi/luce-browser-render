// Every draw of the GPU player (luce-browser-render docs/GPU.md) in one fragment program, so
// the coverage code is embedded once and one shader serves every pipeline (tiles, clip masks,
// composites). The push constants hold a header — the innermost rounded clip (analytic),
// whether the clip mask at binding 2 applies, and the draw's kind — and sixteen floats for
// the kind; instanced draws carry three vec4s per rectangle (locations 1..3, zero under
// `shade`). Colors are stored values premultiplied: the player blends in the encoded space,
// as Skia's legacy raster does.
//
//   kind 0  shapes      rectangles and rounded rectangles with circular corners, instanced:
//                       a the rectangle, b the radius at each corner (top left, top right,
//                       bottom right, bottom left), c the straight color as two 16-bit pairs
//                       (r * 256 + g, b * 256 + a), the stroke width and whether aliased
//   kind 1  rrect       one rounded rectangle with elliptical corners: a the rectangle, b and
//                       c its radii (top-left x/y, top-right x/y; bottom-right, bottom-left);
//                       k0 the premultiplied color, k1.x the stroke, k1.y aliased
//   kind 2  mask        coverage from the atlas at binding 1, instanced: a where the mask
//                       sits (tile pixels) and where in the atlas, b the premultiplied color,
//                       c a nine-patch's center column and row and how far they stretch (zero
//                       for a plain mask; the last negative when the center stays uncovered)
//   kind 3  image       the image at binding 1 scaled onto k0 (x, y, width, height): k1 its
//                       width, height, filter (0 nearest, 1 bilinear clamped to its edges as
//                       Skia's kClamp image shader samples, 2 the sampler's trilinear) and
//                       opacity
//   kind 4  composite   the texture at binding 1 with its top left at k0.xy, texel for pixel,
//                       times k0.w; decoded from sRGB first when k0.z is 1 (the frame texture
//                       onto a linear-light target)
//   kind 5  clip        one clip of a nested clip into an r8 clip mask cleared to 1: an `over`
//                       draw of color 0 with alpha 1 - coverage leaves mask * coverage
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
layout(location = 0) in vec4 vertex_color;
layout(location = 1) flat in vec4 a;
layout(location = 2) flat in vec4 b;
layout(location = 3) flat in vec4 c;
layout(location = 0) out vec4 fragment_color;
layout(push_constant) uniform Params {
    vec4 clip_rect;
    vec4 clip_radii0;
    vec4 clip_radii1;
    vec4 control;    // clip mode (0 none, 1 inside, 2 outside), clip mask, kind
    vec4 k0;
    vec4 k1;
    vec4 k2;
    vec4 k3;
} params;
layout(set = 0, binding = 1) uniform sampler2D source;
layout(set = 0, binding = 2) uniform sampler2D clip_mask;

const int kind_shapes = 0;
const int kind_rrect = 1;
const int kind_mask = 2;
const int kind_image = 3;
const int kind_composite = 4;
const int kind_clip = 5;

// The coverage of a rounded rectangle filled, or stroked `stroke` pixels wide around its
// edge; a pixel is in or out by its center when `aliased`.
float shape_coverage(vec2 p, vec4 rect, vec4 radii0, vec4 radii1, float stroke, float aliased) {
    float coverage;
    if (stroke > 0.0) {
        float h = stroke * 0.5;
        vec4 outer = vec4(rect.xy - h, rect.zw + 2.0 * h);
        vec4 inner = vec4(rect.xy + h, rect.zw - 2.0 * h);
        // Square corners stay square (a mitered frame); rounded ones grow and shrink by h.
        vec4 grow0 = radii0 + h * step(vec4(1e-4), radii0);
        vec4 grow1 = radii1 + h * step(vec4(1e-4), radii1);
        float outer_coverage = rrect_coverage(p, outer, grow0, grow1);
        float inner_coverage = inner.z > 0.0 && inner.w > 0.0 ? rrect_coverage(p, inner, max(radii0 - h, 0.0), max(radii1 - h, 0.0)) : 0.0;
        coverage = clamp(outer_coverage - inner_coverage, 0.0, 1.0);
    } else {
        coverage = rrect_coverage(p, rect, radii0, radii1);
    }
    return aliased > 0.5 ? step(0.5, coverage) : coverage;
}

// The straight 8-bit channels of a pair packed as high * 256 + low.
vec2 unpacked(float pair) {
    float high = floor(pair / 256.0);
    return vec2(high, pair - high * 256.0) / 255.0;
}

// The atlas coverage of a mask draw at pixel `q` of the mask's rectangle: draw_nine's
// stretching for a nine-patch (corners as they are, the center row and column stretched).
float mask_texel(ivec2 q) {
    if (c.z > 0.5) {
        ivec2 center = ivec2(c.xy);
        ivec2 stretch = ivec2(c.z, abs(c.w));
        bvec2 low = lessThan(q, center);
        bvec2 middle = lessThan(q, center + stretch);
        if (!low.x && !low.y && middle.x && middle.y) {
            return c.w > 0.0 ? 1.0 : 0.0;
        }
        q = ivec2(low.x ? q.x : (middle.x ? center.x : q.x - stretch.x + 1), low.y ? q.y : (middle.y ? center.y : q.y - stretch.y + 1));
    }
    return texelFetch(source, q + ivec2(a.zw), 0).r;
}

// A texel of the image, its coordinates clamped to its edges.
vec4 image_texel(ivec2 at) {
    return texelFetch(source, clamp(at, ivec2(0), ivec2(params.k1.xy) - 1), 0);
}

// The image at pixel center `p`: nearest, bilinear or trilinear.
vec4 image_color(vec2 p) {
    vec2 u = (p - params.k0.xy) * (params.k1.xy / params.k0.zw);
    if (params.k1.z > 1.5) {
        // Mipmapped: the sampler picks and blends levels by the scale.
        return texture(source, u / params.k1.xy);
    }
    if (params.k1.z < 0.5) {
        return image_texel(ivec2(floor(u)));
    }
    vec2 v = u - 0.5;
    vec2 base = floor(v);
    vec2 f = v - base;
    ivec2 at = ivec2(base);
    vec4 top = mix(image_texel(at), image_texel(at + ivec2(1, 0)), f.x);
    vec4 bottom = mix(image_texel(at + ivec2(0, 1)), image_texel(at + ivec2(1, 1)), f.x);
    return mix(top, bottom, f.y);
}

vec3 srgb_decode(vec3 v) {
    return mix(v / 12.92, pow((v + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), v));
}

void main() {
    vec2 p = gl_FragCoord.xy;
    int kind = int(params.control.z);
    float clip = clip_coverage(p, params.control.x, params.clip_rect, params.clip_radii0, params.clip_radii1);
    if (kind == kind_clip) {
        fragment_color = vec4(0.0, 0.0, 0.0, 1.0 - clip);
        return;
    }
    vec4 color;
    float coverage = 1.0;
    if (kind == kind_shapes) {
        coverage = shape_coverage(p, a, b.xxyy, b.zzww, c.z, c.w);
        vec4 straight = vec4(unpacked(c.x), unpacked(c.y));
        color = vec4(straight.rgb * straight.a, straight.a);
    } else if (kind == kind_rrect) {
        coverage = shape_coverage(p, a, b, c, params.k1.x, params.k1.y);
        color = params.k0;
    } else if (kind == kind_mask) {
        coverage = mask_texel(ivec2(floor(p - a.xy)));
        color = b;
    } else if (kind == kind_image) {
        color = image_color(p);
        coverage = params.k1.w;
    } else {
        color = texelFetch(source, ivec2(floor(p - params.k0.xy)), 0);
        if (params.k0.z > 0.5) {
            color = color.a > 0.0 ? vec4(srgb_decode(color.rgb / color.a) * color.a, color.a) : vec4(0.0);
        }
        coverage = params.k0.w;
    }
    coverage *= clip * mask_coverage(clip_mask, p, params.control.y);
    fragment_color = color * coverage;
}
