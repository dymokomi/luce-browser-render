// The raster pipeline's color stages on the GPU: a program written by raster's
// paint_stage_program (luce-browser-render raster/gpu_program.lucb; its header lists the
// layout) and run here stage by stage, each computed as the CPU player's highp stages compute
// it (raster/highp_shaders.lucb, highp_color.lucb, color_math.lucb, color_xform.lucb): fused
// multiply-adds where Skia's NEON code fuses, Skia's polynomial atan and approximate powers.
// The program's texels are in a float texture 1024 texels wide.

// Texel `index` of the program table.
vec4 program_texel(sampler2D table, int index) {
    return texelFetch(table, ivec2(index % 1024, index / 1024), 0);
}

// approx_log2, approx_pow2 and approx_powf of SkRasterPipeline_opts.h, as m144 computes them
// on arm64 (the pow2's rounding is half to even).
float approx_log2(float x) {
    uint bits = floatBitsToUint(x);
    float e = float(bits) * (1.0 / 8388608.0);
    float m = uintBitsToFloat((bits & 0x007fffffu) | 0x3f000000u);
    return fma(-m, 1.498030302, e - 124.225514990) - 1.725879990 / (0.3520887068 + m);
}

float approx_pow2(float x) {
    float f = x - floor(x);
    float approx = fma(-f, 1.490129070, x + 121.274057500);
    approx += 27.728023300 / (4.84252568 - f);
    approx *= 8388608.0;
    approx = min(max(approx, 0.0), 2139095040.0);
    return uintBitsToFloat(uint(roundEven(approx)));
}

float approx_powf(float x, float y) {
    return x == 0.0 || x == 1.0 ? x : approx_pow2(approx_log2(x) * y);
}

// A transfer function stage on one component (1 gamma_, 2 parametric): the curve on |v|, the
// sign kept. `g` holds g, a, b, c and `h` d, e, f.
float transfer(int curve, vec4 g, vec4 h, float v) {
    uint bits = floatBitsToUint(v);
    uint sign = bits & 0x80000000u;
    float x = uintBitsToFloat(bits ^ sign);
    float r = curve == 1 ? approx_powf(x, g.x) : (x <= h.x ? fma(g.w, x, h.z) : approx_powf(fma(g.y, x, g.z), g.x) + h.y);
    return uintBitsToFloat(sign | floatBitsToUint(r));
}

// The color_xform stage (unpremul, curve, gamut matrix, inverse curve, premul) from texel `at`.
vec4 color_xform(sampler2D table, int at, vec4 c) {
    vec4 flags = program_texel(table, at);
    vec4 kinds = program_texel(table, at + 1);
    vec3 rgb = c.rgb;
    if (flags.x > 0.5) {
        float inverse = 1.0 / c.a;
        rgb *= inverse < uintBitsToFloat(0x7f800000u) ? inverse : 0.0;
    }
    if (flags.y > 0.5) {
        vec4 g = program_texel(table, at + 2);
        vec4 h = program_texel(table, at + 3);
        rgb = vec3(transfer(int(kinds.y), g, h, rgb.r), transfer(int(kinds.y), g, h, rgb.g), transfer(int(kinds.y), g, h, rgb.b));
    }
    if (flags.z > 0.5) {
        vec3 m0 = program_texel(table, at + 6).xyz;
        vec3 m1 = program_texel(table, at + 7).xyz;
        vec3 m2 = program_texel(table, at + 8).xyz;
        rgb = vec3(fma(rgb.r, m0.x, fma(rgb.g, m1.x, rgb.b * m2.x)), fma(rgb.r, m0.y, fma(rgb.g, m1.y, rgb.b * m2.y)), fma(rgb.r, m0.z, fma(rgb.g, m1.z, rgb.b * m2.z)));
    }
    if (flags.w > 0.5) {
        vec4 g = program_texel(table, at + 4);
        vec4 h = program_texel(table, at + 5);
        rgb = vec3(transfer(int(kinds.z), g, h, rgb.r), transfer(int(kinds.z), g, h, rgb.g), transfer(int(kinds.z), g, h, rgb.b));
    }
    if (kinds.x > 0.5) {
        rgb *= c.a;
    }
    return vec4(rgb, c.a);
}

// mod_: x - y * floor(x / y), with the multiply by 1 / y.
float pipeline_mod(float x, float y) {
    return fma(-y, floor(x * (1.0 / y)), x);
}

// css_hsl_to_srgb_ for hue, saturation and lightness.
vec3 hsl_to_srgb(float h0, float s0, float l0) {
    float h = pipeline_mod(h0, 360.0);
    float s = s0 * 0.01;
    float l = l0 * 0.01;
    vec3 k = vec3(pipeline_mod(0.0 + h * (1.0 / 30.0), 12.0), pipeline_mod(8.0 + h * (1.0 / 30.0), 12.0), pipeline_mod(4.0 + h * (1.0 / 30.0), 12.0));
    float a = s * min(l, 1.0 - l);
    return l - a * max(vec3(-1.0), min(min(k - 3.0, 9.0 - k), vec3(1.0)));
}

// sin5q_: sin(x * 2 pi) for x in [-1/4, 1/4].
float sin5q(float x) {
    float x2 = x * x;
    return x * fma(fma(x2, 74.4388885, -41.1693687), x2, 6.28230858);
}

// The CSS stages: Lab, OKLab, LCH (as hue, chroma, lightness), HSL and HWB back to their
// intermediate spaces.
vec4 css_stage(int stage, vec4 c) {
    if (stage == 86) {
        // css_lab_to_xyz
        const float k = 24389.0 / 27.0;
        const float e = 216.0 / 24389.0;
        float f1 = (c.x + 16.0) * (1.0 / 116.0);
        float f0 = (c.y * (1.0 / 500.0)) + f1;
        float f2 = f1 - (c.z * (1.0 / 200.0));
        vec3 cubed = vec3(f0 * f0 * f0, f1 * f1 * f1, f2 * f2 * f2);
        float x = cubed.x > e ? cubed.x : (116.0 * f0 - 16.0) * (1.0 / k);
        float y = c.x > k * e ? cubed.y : c.x * (1.0 / k);
        float z = cubed.z > e ? cubed.z : (116.0 * f2 - 16.0) * (1.0 / k);
        return vec4(x * (0.3457 / 0.3585), y, z * ((1.0 - 0.3457 - 0.3585) / 0.3585), c.w);
    }
    if (stage == 87) {
        // css_oklab_to_linear_srgb
        float l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z;
        float m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z;
        float s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z;
        l = l * l * l;
        m = m * m * m;
        s = s * s * s;
        return vec4(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s, c.w);
    }
    if (stage == 88) {
        // css_hcl_to_lab, with sin_ and cos_
        float radians = c.x * (3.14159265 / 180.0);
        float one_over_pi2 = 1.0 / (2.0 * 3.14159265);
        float s = fma(radians, -one_over_pi2, 0.25);
        s = 0.25 - abs(s - floor(s + 0.5));
        float k = radians * one_over_pi2;
        k = 0.25 - abs(k - floor(k + 0.5));
        return vec4(c.z, c.y * sin5q(k), c.y * sin5q(s), c.w);
    }
    if (stage == 89) {
        return vec4(hsl_to_srgb(c.x, c.y, c.z), c.w);
    }
    // css_hwb_to_srgb
    float white = c.y * 0.01;
    float black = c.z * 0.01;
    if (white + black >= 1.0) {
        return vec4(vec3(white / (white + black)), c.w);
    }
    return vec4(hsl_to_srgb(c.x, 100.0, 50.0) * (1.0 - white - black) + white, c.w);
}

// The factor and bias at entry `index` (clamped to the last) of a gradient table at `at`, in
// the gradient stages' mad(t, factor, bias).
vec4 gradient_lookup(sampler2D table, int at, int index, int entries, float t) {
    int i = min(index, entries - 1);
    return fma(vec4(t), program_texel(table, at + 1 + 3 * i), program_texel(table, at + 2 + 3 * i));
}

// The program at texel `start` for the pixel centered at `p`: its premultiplied color.
vec4 run_program(sampler2D table, int start, vec2 p) {
    int count = int(program_texel(table, start).x);
    vec4 c = vec4(0.0);
    for (int i = 0; i < count; i++) {
        vec4 op = program_texel(table, start + 1 + i);
        int stage = int(op.x);
        int at = start + int(op.y);
        if (stage == 6) {
            // seed_shader: the pixel center.
            c = vec4(p, 1.0, 0.0);
        } else if (stage == 47) {
            vec4 m0 = program_texel(table, at);
            vec4 m1 = program_texel(table, at + 1);
            c.xy = vec2(fma(c.x, m0.x, fma(c.y, m0.y, m0.z)), fma(c.x, m1.x, fma(c.y, m1.y, m1.z)));
        } else if (stage == 62) {
            c.x = sqrt(c.x * c.x + c.y * c.y);
        } else if (stage == 61) {
            // xy_to_unit_angle: Skia's degree-7 polynomial for atan.
            vec2 v = abs(c.xy);
            float slope = min(v.x, v.y) / max(v.x, v.y);
            float s = slope * slope;
            float phi = slope * (0.15912117063999176025390625 + s * (-5.185396969318389892578125e-2 + s * (2.476101927459239959716796875e-2 + s * -7.0547382347285747528076171875e-3)));
            phi = v.x < v.y ? 0.25 - phi : phi;
            phi = c.x < 0.0 ? 0.5 - phi : phi;
            phi = c.y < 0.0 ? 1.0 - phi : phi;
            c.x = isnan(phi) ? 0.0 : phi;
        } else if (stage == 55) {
            c.x = clamp(c.x, 0.0, 1.0);
        } else if (stage == 56) {
            float x = c.x - 1.0;
            float twice = floor(x * 0.5);
            c.x = clamp(abs((x - (twice + twice)) - 1.0), 0.0, 1.0);
        } else if (stage == 57) {
            c.x = clamp(c.x - floor(c.x), 0.0, 1.0);
        } else if (stage == 58 || stage == 59) {
            int entries = int(program_texel(table, at).x);
            float t = c.x;
            int index = 0;
            if (stage == 59) {
                index = int(t * float(entries - 1));
            } else {
                for (int e = 1; e < entries; e++) {
                    index += t >= program_texel(table, at + 3 + 3 * e).x ? 1 : 0;
                }
            }
            c = gradient_lookup(table, at, index, entries, t);
        } else if (stage == 60) {
            c = fma(vec4(c.x), program_texel(table, at), program_texel(table, at + 1));
        } else if (stage == 5) {
            c = program_texel(table, at);
        } else if (stage == 4) {
            c.rgb *= c.a;
        } else if (stage == 84 || stage == 85) {
            // unpremul (the polar form keeps the hue)
            float inverse = 1.0 / c.a;
            float scale = inverse < uintBitsToFloat(0x7f800000u) ? inverse : 0.0;
            c.rgb *= stage == 84 ? vec3(scale) : vec3(1.0, scale, scale);
        } else if (stage >= 86 && stage <= 90) {
            c = css_stage(stage, c);
        } else if (stage == 92 || stage == 93) {
            c = color_xform(table, at, c);
        } else if (stage == 18) {
            c *= op.z;
        } else if (stage == 19) {
            // dither: an 8x8 ordered pattern from the pixel's coordinates' low bits.
            uint x = uint(p.x);
            uint y = uint(p.y) ^ x;
            uint m = (y & 1u) << 5 | (x & 1u) << 4 | (y & 2u) << 2 | (x & 2u) << 1 | (y & 4u) >> 1 | (x & 4u) >> 2;
            float d = fma(float(m), 2.0 / 128.0, -63.0 / 128.0);
            c.rgb = max(vec3(0.0), min(fma(vec3(d), vec3(op.z), c.rgb), vec3(c.a)));
        } else if (stage == 2) {
            c = clamp(c, 0.0, 1.0);
        }
    }
    return c;
}
