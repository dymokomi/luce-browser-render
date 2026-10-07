// Skia's blend modes on premultiplied colors, as the CPU player's raster pipeline computes
// them (luce-browser-render raster/highp_blend.lucb, Skia m144's BLEND_MODE stages): the
// Porter-Duff modes, the separable blend modes, the non-separable ones, and the Skia player's
// plus-darker blender. `mode` is raster.BlendMode's value; 29 is plus-darker.

// The separable modes on the color channels: source s and destination d (premultiplied) with
// their alphas.
vec3 blend_separable(int mode, vec3 s, vec3 d, float sa, float da) {
    vec3 rest = s * (1.0 - da) + d * (1.0 - sa);
    if (mode == 15 || mode == 20) {
        // overlay, hard-light: one formula, the destination's and the source's roles swapped.
        bvec3 low = mode == 15 ? lessThanEqual(2.0 * d, vec3(da)) : lessThanEqual(2.0 * s, vec3(sa));
        return rest + mix(sa * da - 2.0 * (da - d) * (sa - s), 2.0 * s * d, low);
    }
    if (mode == 16) {
        return s + d - max(s * da, d * sa);
    }
    if (mode == 17) {
        return s + d - min(s * da, d * sa);
    }
    if (mode == 18) {
        // color-dodge
        vec3 general = sa * min(vec3(da), (d * sa) / (sa - s)) + rest;
        return mix(mix(general, s + d * (1.0 - sa), equal(s, vec3(sa))), s * (1.0 - da), equal(d, vec3(0.0)));
    }
    if (mode == 19) {
        // color-burn
        vec3 general = sa * (da - min(vec3(da), (da - d) * sa / s)) + rest;
        return mix(mix(general, d * (1.0 - sa), equal(s, vec3(0.0))), d + s * (1.0 - da), equal(d, vec3(da)));
    }
    if (mode == 21) {
        // soft-light
        vec3 m = da > 0.0 ? d / da : vec3(0.0);
        vec3 s2 = 2.0 * s;
        vec3 m4 = 4.0 * m;
        vec3 dark_src = d * (sa + (s2 - sa) * (1.0 - m));
        vec3 dark_dst = (m4 * m4 + m4) * (m - 1.0) + 7.0 * m;
        vec3 lite_dst = sqrt(m) - m;
        vec3 lite_src = d * sa + da * (s2 - sa) * mix(lite_dst, dark_dst, lessThanEqual(4.0 * d, vec3(da)));
        return rest + mix(lite_src, dark_src, lessThanEqual(s2, vec3(sa)));
    }
    if (mode == 22) {
        return s + d - 2.0 * min(s * da, d * sa);
    }
    if (mode == 23) {
        return s + d - 2.0 * s * d;
    }
    if (mode == 24) {
        return s * d + rest;
    }
    // screen
    return s + d - s * d;
}

float blend_lum(vec3 c) {
    return dot(c, vec3(0.30, 0.59, 0.11));
}

float blend_sat(vec3 c) {
    return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
}

vec3 blend_set_sat(vec3 c, float s) {
    float mn = min(c.r, min(c.g, c.b));
    float range = max(c.r, max(c.g, c.b)) - mn;
    return range == 0.0 ? vec3(0.0) : (c - mn) * (s / range);
}

vec3 blend_set_lum(vec3 c, float l) {
    return c + (l - blend_lum(c));
}

vec3 blend_clip_color(vec3 c, float a) {
    float mn = min(c.r, min(c.g, c.b));
    float mx = max(c.r, max(c.g, c.b));
    float l = blend_lum(c);
    if (mn < 0.0 && l != mn) {
        c = l + (c - l) * (l / (l - mn));
    }
    if (mx > a && l != mx) {
        c = l + (c - l) * ((a - l) / (mx - l));
    }
    return max(c, vec3(0.0));
}

// `source` blended onto `destination` (both premultiplied) by `mode`.
vec4 blend(int mode, vec4 source, vec4 destination) {
    vec4 s = source;
    vec4 d = destination;
    float sa = s.a;
    float da = d.a;
    switch (mode) {
    case 0: return vec4(0.0);
    case 1: return s;
    case 2: return d;
    case 3: return s + d * (1.0 - sa);
    case 4: return d + s * (1.0 - da);
    case 5: return s * da;
    case 6: return d * sa;
    case 7: return s * (1.0 - da);
    case 8: return d * (1.0 - sa);
    case 9: return s * da + d * (1.0 - sa);
    case 10: return d * sa + s * (1.0 - da);
    case 11: return s * (1.0 - da) + d * (1.0 - sa);
    case 12: return min(s + d, vec4(1.0));
    case 13: return s * d;
    case 29: return clamp(clamp(da + sa, 0.0, 1.0) - clamp(da - d, 0.0, 1.0) - clamp(sa - s, 0.0, 1.0), 0.0, 1.0);
    }
    float alpha = sa + da - sa * da;
    if (mode < 25) {
        return vec4(blend_separable(mode, s.rgb, d.rgb, sa, da), alpha);
    }
    // The non-separable modes, with premultiplied inputs (W3C compositing, simplified as
    // OpenGL ES 3.2 writes them).
    vec3 c;
    if (mode == 25) {
        c = blend_set_lum(blend_set_sat(s.rgb * sa, blend_sat(d.rgb) * sa), blend_lum(d.rgb) * sa);
    } else if (mode == 26) {
        c = blend_set_lum(blend_set_sat(d.rgb * sa, blend_sat(s.rgb) * da), blend_lum(d.rgb) * sa);
    } else if (mode == 27) {
        c = blend_set_lum(s.rgb * da, blend_lum(d.rgb) * sa);
    } else {
        c = blend_set_lum(d.rgb * sa, blend_lum(s.rgb) * da);
    }
    c = blend_clip_color(c, sa * da);
    return vec4(s.rgb * (1.0 - da) + d.rgb * (1.0 - sa) + c, alpha);
}
