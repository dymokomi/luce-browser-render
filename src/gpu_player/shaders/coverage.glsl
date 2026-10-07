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
    // The corner whose ellipse's box holds the point (fitted radii never overlap, but one
    // corner may reach past the middle), and that ellipse's center.
    vec2 r = vec2(0.0);
    vec2 center = vec2(0.0);
    if (p.x < lo.x + radii0.x && p.y < lo.y + radii0.y) {
        r = radii0.xy;
        center = lo + r;
    } else if (p.x > hi.x - radii0.z && p.y < lo.y + radii0.w) {
        r = radii0.zw;
        center = vec2(hi.x - r.x, lo.y + r.y);
    } else if (p.x > hi.x - radii1.x && p.y > hi.y - radii1.y) {
        r = radii1.xy;
        center = hi - r;
    } else if (p.x < lo.x + radii1.z && p.y > hi.y - radii1.w) {
        r = radii1.zw;
        center = vec2(lo.x + r.x, hi.y - r.y);
    }
    if (r.x > 0.0 && r.y > 0.0) {
        vec2 q = p - center;
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
