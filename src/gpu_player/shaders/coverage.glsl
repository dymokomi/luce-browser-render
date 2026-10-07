// Analytic coverage of rounded rectangles at a pixel center, shared by the GPU player's
// shaders (luce-browser-render docs/GPU.md). Rectangles are x, y, width, height in target
// pixels; radii are top-left x/y and top-right x/y, then bottom-right x/y and bottom-left x/y.
// Coverage is 0.5 minus the signed distance to the edge, clamped: exact along straight edges
// (a box filter's area), the distance to an ellipse approximated along its gradient at the
// corners.

// The signed distance from `p` to the rounded rectangle (negative inside).
float rrect_distance(vec2 p, vec4 rect, vec4 radii0, vec4 radii1) {
    vec2 lo = rect.xy;
    vec2 hi = rect.xy + rect.zw;
    vec2 center = (lo + hi) * 0.5;
    // The corner the point is nearest to, and its radii.
    vec2 r = p.x < center.x ? (p.y < center.y ? radii0.xy : radii1.zw) : (p.y < center.y ? radii0.zw : radii1.xy);
    vec2 corner = vec2(p.x < center.x ? lo.x + r.x : hi.x - r.x, p.y < center.y ? lo.y + r.y : hi.y - r.y);
    vec2 q = p - corner;
    bool in_corner = r.x > 0.0 && r.y > 0.0 && (p.x < center.x ? q.x < 0.0 : q.x > 0.0) && (p.y < center.y ? q.y < 0.0 : q.y > 0.0);
    if (in_corner) {
        vec2 scaled = q / r;
        float f = length(scaled);
        float g = length(q / (r * r));
        return g > 0.0 ? f * (f - 1.0) / g : -min(r.x, r.y);
    }
    vec2 d = max(lo - p, p - hi);
    return max(d.x, d.y);
}

// The coverage of the pixel centered at `p` by the rounded rectangle: the exact area of the
// pixel's square inside it away from the rounded corners (a box filter, as an anti-aliased
// rectangle's scan conversion gives), 0.5 minus the distance to the ellipse in a corner.
float rrect_coverage(vec2 p, vec4 rect, vec4 radii0, vec4 radii1) {
    vec2 lo = rect.xy;
    vec2 hi = rect.xy + rect.zw;
    vec2 center = (lo + hi) * 0.5;
    vec2 r = p.x < center.x ? (p.y < center.y ? radii0.xy : radii1.zw) : (p.y < center.y ? radii0.zw : radii1.xy);
    vec2 corner = vec2(p.x < center.x ? lo.x + r.x : hi.x - r.x, p.y < center.y ? lo.y + r.y : hi.y - r.y);
    vec2 q = p - corner;
    bool in_corner = r.x > 0.0 && r.y > 0.0 && (p.x < center.x ? q.x < 0.0 : q.x > 0.0) && (p.y < center.y ? q.y < 0.0 : q.y > 0.0);
    if (in_corner) {
        return clamp(0.5 - rrect_distance(p, rect, radii0, radii1), 0.0, 1.0);
    }
    vec2 covered = clamp(min(p + 0.5, hi) - max(p - 0.5, lo), 0.0, 1.0);
    return covered.x * covered.y;
}

// What a rounded clip lets through at `p`: mode 0 no clip, 1 the inside, 2 the outside.
float clip_coverage(vec2 p, float mode, vec4 rect, vec4 radii0, vec4 radii1) {
    if (mode < 0.5) {
        return 1.0;
    }
    float inside = rrect_coverage(p, rect, radii0, radii1);
    return mode < 1.5 ? inside : 1.0 - inside;
}

// What the clip mask (nested clips, rendered into an r8 texture of the tile by tile.frag's clip kind)
// lets through at `p`, when `use` is set; 1 otherwise.
float mask_coverage(sampler2D mask, vec2 p, float use) {
    return use > 0.5 ? texelFetch(mask, ivec2(floor(p)), 0).r : 1.0;
}
