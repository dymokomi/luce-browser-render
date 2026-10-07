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
//                       Skia's kClamp image shader samples, 2 + w Skia's linear mipmaps: the
//                       level packed at k2 and the one at k3 bilinearly, lerped by w) and
//                       opacity; k3.w 1 when it repeats unmipmapped (Skia's kRepeat on both
//                       axes: texel coordinates wrap rather than clamp)
//   kind 4  composite   a layer: the texture at binding 1 with its top left at k0.xy, texel for
//                       pixel, times k0.w (its opacity)
//   kind 5  clip        one clip of a nested clip into an r8 clip mask cleared to 1: an `over`
//                       draw of color 0 with alpha 1 - coverage leaves mask * coverage
//   kind 6  blend       a layer (binding 1) at opacity k0.x blended by mode k0.y (blend.glsl)
//                       with the target's pixels copied to binding 3, lerped by the clips'
//                       coverage (Plus scales the layer by it instead), drawn without blending
//   kind 7  stages      a shaded paint (a gradient): the raster pipeline's color stages from
//                       the program at texel k0.x of the float table at binding 1
//                       (stages.glsl), over the draw's rectangle; when k0.y is 1, times the
//                       coverage atlas's texels (binding 3) of a mask whose top left is k1.xy
//                       in the tile and k1.zw in the atlas
#version 450
#extension GL_GOOGLE_include_directive : require
#include "coverage.glsl"
#include "blend.glsl"
#include "stages.glsl"
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
layout(set = 0, binding = 3) uniform sampler2D backdrop;

const int kind_shapes = 0;
const int kind_rrect = 1;
const int kind_mask = 2;
const int kind_image = 3;
const int kind_composite = 4;
const int kind_clip = 5;
const int kind_blend = 6;
const int kind_stages = 7;

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

// A texel of the image, its coordinates clamped to its edges or wrapped.
vec4 image_texel(ivec4 rect, bool repeat, ivec2 at) {
    ivec2 texel = repeat ? (at % rect.zw + rect.zw) % rect.zw : clamp(at, ivec2(0), rect.zw - 1);
    return texelFetch(source, rect.xy + texel, 0);
}

// Bilinear sampling at `u` (texel space) of the image in `rect` of the texture.
vec4 image_bilinear(ivec4 rect, bool repeat, vec2 u) {
    vec2 v = u - 0.5;
    vec2 base = floor(v);
    vec2 f = v - base;
    ivec2 at = ivec2(base);
    vec4 top = mix(image_texel(rect, repeat, at), image_texel(rect, repeat, at + ivec2(1, 0)), f.x);
    vec4 bottom = mix(image_texel(rect, repeat, at + ivec2(0, 1)), image_texel(rect, repeat, at + ivec2(1, 1)), f.x);
    return mix(top, bottom, f.y);
}

// The image at pixel center `p`: nearest, bilinear, or Skia's linear mipmaps (the upper
// level and the lower one sampled bilinearly at the point scaled to each, then lerped).
vec4 image_color(vec2 p) {
    vec2 u = (p - params.k0.xy) * (params.k1.xy / params.k0.zw);
    ivec4 base = ivec4(0, 0, ivec2(params.k1.xy));
    if (params.k1.z > 1.5) {
        vec2 upper = u * (params.k2.zw / params.k1.xy);
        vec4 high = image_bilinear(ivec4(params.k2), false, upper);
        vec4 low = image_bilinear(ivec4(params.k3), false, upper * (params.k3.zw / params.k2.zw));
        return fma(low - high, vec4(params.k1.z - 2.0), high);
    }
    bool repeat = params.k3.w > 0.5;
    if (params.k1.z < 0.5) {
        return image_texel(base, repeat, ivec2(floor(u)));
    }
    return image_bilinear(base, repeat, u);
}

void main() {
    vec2 p = gl_FragCoord.xy;
    int kind = int(params.control.z);
    bool shape = kind == kind_shapes || kind == kind_rrect;
    // The shape of a shapes or rrect draw: its rectangle, radii, stroke width and aliasing.
    vec4 radii0 = kind == kind_shapes ? b.xxyy : b;
    vec4 radii1 = kind == kind_shapes ? b.zzww : c;
    float stroke = kind == kind_shapes ? c.z : params.k1.x;
    float aliased = kind == kind_shapes ? c.w : params.k1.y;
    // The rounded rectangles the pixel's coverage needs, evaluated at one call site (the
    // program stays small): the clip (0), and a shape's outer (1) and inner (2) edges. A
    // stroke's edges are the rectangle grown and shrunk by half its width; square corners stay
    // square (a mitered frame), rounded ones grow and shrink with it.
    float h = stroke * 0.5;
    vec4 rects[3] = vec4[3](params.clip_rect, a, vec4(0.0));
    vec4 corners0[3] = vec4[3](params.clip_radii0, radii0, vec4(0.0));
    vec4 corners1[3] = vec4[3](params.clip_radii1, radii1, vec4(0.0));
    if (stroke > 0.0) {
        rects[1] = vec4(a.xy - h, a.zw + 2.0 * h);
        corners0[1] = radii0 + h * step(vec4(1e-4), radii0);
        corners1[1] = radii1 + h * step(vec4(1e-4), radii1);
        rects[2] = max(vec4(a.xy + h, a.zw - 2.0 * h), vec4(-1e9, -1e9, 0.0, 0.0));
        corners0[2] = max(radii0 - h, 0.0);
        corners1[2] = max(radii1 - h, 0.0);
    }
    float covered[3] = float[3](1.0, 0.0, 0.0);
    int last = shape ? (stroke > 0.0 ? 3 : 2) : 1;
    for (int i = params.control.x > 0.5 ? 0 : 1; i < last; i++) {
        covered[i] = rrect_coverage(p, rects[i], corners0[i], corners1[i]);
    }
    // What the rounded clip lets through: mode 0 no clip, 1 the inside, 2 the outside.
    float clip = params.control.x < 0.5 ? 1.0 : (params.control.x < 1.5 ? covered[0] : 1.0 - covered[0]);
    if (kind == kind_clip) {
        fragment_color = vec4(0.0, 0.0, 0.0, 1.0 - clip);
        return;
    }
    if (kind == kind_blend) {
        ivec2 at = ivec2(floor(p));
        vec4 layer = texelFetch(source, at, 0) * params.k0.x;
        vec4 below = texelFetch(backdrop, at, 0);
        float cover = clip * mask_coverage(clip_mask, p, params.control.y);
        int mode = int(params.k0.y);
        fragment_color = mode == 12 ? blend(mode, layer * cover, below) : mix(below, blend(mode, layer, below), cover);
        return;
    }
    vec4 color;
    float coverage = 1.0;
    if (shape) {
        coverage = clamp(covered[1] - covered[2], 0.0, 1.0);
        if (aliased > 0.5) {
            coverage = step(0.5, coverage);
        }
        if (kind == kind_shapes) {
            vec4 straight = vec4(unpacked(c.x), unpacked(c.y));
            color = vec4(straight.rgb * straight.a, straight.a);
        } else {
            color = params.k0;
        }
    } else if (kind == kind_mask) {
        coverage = mask_texel(ivec2(floor(p - a.xy)));
        color = b;
    } else if (kind == kind_image) {
        color = image_color(p);
        coverage = params.k1.w;
    } else if (kind == kind_stages) {
        color = run_program(source, int(params.k0.x), p);
        if (params.k0.y > 0.5) {
            coverage = texelFetch(backdrop, ivec2(floor(p - params.k1.xy)) + ivec2(params.k1.zw), 0).r;
        }
    } else {
        color = texelFetch(source, ivec2(floor(p - params.k0.xy)), 0);
        coverage = params.k0.w;
    }
    coverage *= clip * mask_coverage(clip_mask, p, params.control.y);
    fragment_color = color * coverage;
}
