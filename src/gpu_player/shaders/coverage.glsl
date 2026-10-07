// Analytic coverage of rounded rectangles at a pixel center, shared by the GPU player's
// shaders (luce-browser-render docs/GPU.md). Rectangles are x, y, width, height in target
// pixels; radii are top-left x/y and top-right x/y, then bottom-right x/y and bottom-left x/y.
// Coverage is 0.5 minus the signed distance to the edge, clamped: exact along straight edges
// (a box filter's area), the distance to an ellipse approximated along its gradient at the
// corners.

// The coverage of the pixel centered at `p` by the rounded rectangle: the exact area of the
// pixel's square inside it away from the rounded corners (a box filter, as an anti-aliased
// rectangle's scan conversion gives), 0.5 minus the distance to the ellipse in a corner (its
// signed distance approximated along its gradient).
float rrect_coverage(vec2 p, vec4 rect, vec4 radii0, vec4 radii1) {
    vec2 lo = rect.xy;
    vec2 hi = rect.xy + rect.zw;
    bvec2 low = lessThan(p, (lo + hi) * 0.5);
    // The corner the point is nearest to, and its radii.
    vec2 r = low.x ? (low.y ? radii0.xy : radii1.zw) : (low.y ? radii0.zw : radii1.xy);
    vec2 q = p - mix(hi - r, lo + r, low);
    if (r.x > 0.0 && r.y > 0.0 && all(equal(lessThan(q, vec2(0.0)), low)) && all(notEqual(q, vec2(0.0)))) {
        float f = length(q / r);
        float g = length(q / (r * r));
        float distance = g > 0.0 ? f * (f - 1.0) / g : -min(r.x, r.y);
        return clamp(0.5 - distance, 0.0, 1.0);
    }
    vec2 covered = clamp(min(p + 0.5, hi) - max(p - 0.5, lo), 0.0, 1.0);
    return covered.x * covered.y;
}

// What the clip mask (nested clips, rendered into an r8 texture of the tile by tile.frag's clip kind)
// lets through at `p`, when `use` is set; 1 otherwise.
float mask_coverage(sampler2D mask, vec2 p, float use) {
    return use > 0.5 ? texelFetch(mask, ivec2(floor(p)), 0).r : 1.0;
}
