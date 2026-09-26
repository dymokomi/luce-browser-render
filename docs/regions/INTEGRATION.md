# Integration of regions r08, r10, r09 and r51a, and of raster-skia

The four region branches were merged into `main` in this order: r08 (gfx geometry), r10 (gfx
paint model), r09 (web_fonts), r51a (display list and CPU player); then the image filter
evaluator (branch `filters`, written during the integration) and port/raster-skia (the raster
module drawing as Skia m144). This note records what the
merges reconciled, what was connected between the regions, what still traps or is gated, and
where the pixels are known to differ from Ladybird's Skia build. The region notes
(`r08.md`, `r10.md`, `r09.md`, `r51a.md`) describe each region; where this note disagrees with
them, this note is current.

## Merges

- **Fragment lists and imports.** `gfx/ORDER` lists r08's fragments, then r10's, then r08's
  tests, then r10's. `web_fonts/ORDER` puts r10's `path` after r09's shaper, before the tests.
  `gfx/module.lucb` has the union of both regions' imports; `web_fonts/module.lucb` lost a
  duplicate `import math32`.
- **namemap.** Merged as a three-way union of rows (rows a branch removed are gone, rows a
  branch added are in), then byte-sorted. No C++ name ended with two rows. No `stub` rows
  remain.
- **Stub files.** Every region deleted its stub fragment, so r51a's fixes to other regions'
  stub signatures landed on the ported functions:
  - `extract_2d_affine_transform` takes `const FloatMatrix4X4*` (r08 took the matrix by value;
    r51a's callers pass a pointer, as the C++ `Matrix4x4 const&`);
  - `calculate_gradient_length(FloatSize, f32)`, `painting_surface_write_from_bitmap(this,
    const Bitmap*)` and `shape_text_f32(…, font: const Font*, …)` already had r51a's
    signatures in r10 and r09.
- **FloatMatrix4X4.** Both r08 and r51a made `m_elements` an `f32[4][4]`; both read it
  row-major (`m_elements[row][column]`, C++ `T m_elements[N][N]`), and one declaration is
  kept.
- **test.sh.** One step per module (see *Tests*).

## Connections between regions

### r10 and r08: Core::AnonymousBuffer

Bitmap's four anonymous-buffer functions are the donor's again, over r08's
`core_anonymous_buffer_*`: `bitmap_create_shareable` (a buffer of the pixels rounded up to
PAGE_SIZE), `bitmap_create_with_anonymous_buffer`, `bitmap_construct_core_anonymous_buffer`
and `bitmap_to_bitmap_backed_by_anonymous_buffer` (answers the bitmap itself when it already
has a buffer). PAGE_SIZE is 4096 (the donor asks `sysconf(_SC_PAGESIZE)` on POSIX; it only
sizes the buffer). Test: `gfx paint: shareable bitmaps and anonymous buffers`.

### r10 and r09: text in paths

web_fonts' `path.lucb` (r10) drew text through two seams that trapped. They are now r09's
font reader, at the scale PathImplSkia uses (`font.skia_font(1)`):

- glyph outlines (SkFont::getPath): `font_glyph_path(font, glyph, 1.0)`, turned into the
  gfx SkPath with SkPath's own move/line/quad/cubic/close;
- advances by glyph id (SkFont::getWidths): `sk_font_glyph_advance` of `font_skia_font(font,
  1.0)`.

`path_glyph_run` follows r09's pointer API (`glyph_run_font` answers `const Font*`).
`tests_path_text.lucb` pins `Path::text` (UTF-8 and UTF-16, TrueType and CFF),
`Path::glyph_run` and `Path::place_text_along` (including the midpoint cut-off) against the
donor's PathImplSkia: the SVG strings (by length and hash) and the bounds match bit for bit.

### r51a and r10, r09: the player's seams

- `to_raster_path` is r10's `path_to_raster_path` with the SkPath's fill type (`winding` or
  `even_odd`; Gfx::WindingRule has no inverse types).
- Glyph runs are drawn from the run's cached text blob, as `drawTextBlob` draws them: each
  glyph's outline from r09's `sk_font_get_path` of the blob's font (already at the blob's
  scale, which resolves r51a's blob-scale FIXME) placed at the blob's position. A run without a
  blob draws nothing, as in the donor.
- `apply_gfx_filter` is gone: layers with image filters, the text-shadow blur and backdrop
  filters go through `cpu_filter.lucb`'s evaluator (see *Image filters*).

### The CPU canvas's layers

`cpu_canvas_layers.lucb` replaces r51a's full-canvas layers with SkCanvas's own rules
(`internalSaveLayer`, `internalDrawDeviceWithFilter`, `internalRestore`):

- A layer covers the prior clip's bounds, or, with an image filter, the part of layer space
  the filter reads to produce them, plus one transparent pixel of padding. A filter that reads
  no source (a flood) is drawn at save time and the layer draws nothing.
- Drawing into a layer is clipped to its bounds only; the prior clip applies once, when the
  layer is drawn back. r51a applied an anti-aliased clip both into and out of the layer, which
  squared the coverage at its edges (new scene: `layer_in_rounded_clip`).
- The layer matrix is skif::Mapping::decomposeCTM's: the CTM when it is a scale and
  translation or every filter node takes any matrix; otherwise its scale, the rest (rotation,
  skew) applied when the filtered layer is drawn back (bilinear, anti-aliased).
- Backdrop layers start as the prior layer's pixels, clamped at their edges
  (SaveLayerRec's default kClamp), through the backdrop filter.

## Image filters

r10 builds a gfx.Filter as the graph of SkImageFilters the donor builds and leaves evaluation to
the player. `cpu_filter*.lucb` evaluate it as Skia m144's raster backend does
(SkImageFilter_Base::filterImage, skif::FilterResult, the filters of
src/effects/imagefilters, SkBlurEngine):

- **FilterResult:** images placed in layer space with layer bounds; deferred color filters
  (consecutive color filters, the restore paint's alpha as `Blend(alpha, kDstIn)` and the luma
  filter are applied in one float pass, as Skia composes them); integer offsets move images,
  fractional transforms resample (bilinear); decal and clamp source tiling; color filters that
  affect transparent black fill the desired output. Parameters map through the layer matrix
  (skif::Mapping::paramToLayer).
- **blur:** SkBlurImageFilter's sigma mapping and clamping, then the raster blur engine: X
  pass, in-place Y pass, GaussianPass below sigma 2, ThreeBoxApproxPass, TentPass, with
  ScaledDividerU32's integer division.
- **color_filter:** matrix (clamped or not), table, sRGB to linear and back, in the raster
  pipeline's float math (its fused multiply-adds, its pow approximation, round-half-to-even
  stores).
- **drop_shadow** as Skia's graph (blur, SrcIn color, translate, merge); **offset** (nearest
  with Skia's round-down at exact integers); **merge** (src-over); **compose** (the inner
  result is the outer's source); **erode / dilate** (per channel, radii rounded, capped at
  256); **shader** (flood; fractal noise and turbulence with stitching, SkPerlinNoiseShader);
  **displacement_map**; **image** (MakeFromImage's rectangle rules); **blend** (every
  CompositingAndBlendingOperator through LibGfx's mapping, in lowp where Skia runs lowp);
  **arithmetic** (Skia's shortcuts, then the arithmetic blender).

The canvas calls it at restore (layers with a filter, the text-shadow blur) and at save
(backdrops, the prior layer clamped). `tests_cpu_filter*.lucb` compare 62 scenes (every node
kind, blur at sigma 1.5 to 300, every blend mode, rotated layer matrices, backdrops) with Skia
m144's pixels for the donor's own Gfx::Filter graphs: all exact but `image_bilinear` (1 level
on 2 pixels: a scaled image with linear sampling goes through Skia's strict, shader-tiled image
path, whose rounding is not reproduced step for step). The player scenes with filters
(`tests_cpu_player_filters.lucb`) match DisplayListPlayerSkia exactly, but the text shadow
(its glyphs, see below).

Deviations: above sigma 135 Skia blurs a downscaled image, the port blurs at full resolution
with the TentPass (unmeasured: the only such scene is transparent in both); fractional image
source rectangles trap (LibWeb never passes them); more than 12 consecutive color filters
resolve to pixels first (one extra rounding, FIXME); the choice between deferring a second
fractional transform and resolving before it is simplified; color-dodge, color-burn and the
non-separable blend modes divide exactly where Skia's arm64 build uses a reciprocal estimate
(every scene still matched); a backdrop under a rotation or skew filters in the new layer's
pixels with the whole CTM instead of resampling into the filter's layer space (FIXME).

## After raster-skia

port/raster-skia (raster now draws as Skia m144: analytic anti-aliasing, lowp rounding,
nearest sampling's round-down, conics) was merged last, and then:

- `path_to_raster_path` passes conics through instead of turning them into quads;
- the player's rounded rectangles are SkPath::RRect's contour (start index 6, clockwise,
  quarter conics of weight sqrt(2)/2), where r51a drew cubics;
- the player's gradients are dithered as `SkPaint::setDither` makes the raster pipeline
  dither them (the 8x8 ordered matrix at 1/255, clamped to alpha);
- `tests_gfx_paint_raster_is_skia_m144` is set, so PainterRaster's cases compare with the
  donor's pixels;
- test.sh checks raster like every module.

## Tests

`./test.sh`:

1. `luce-base fmt --check` on every hand-written `.lucb`;
2. `luce-base check -W` on raster, gfx, web_fonts and display_list, failing on any output;
3. `luce-base test` of gfx (359 tests), web_fonts (123), display_list (104, `--native`) and
   raster (31), and the raster integration suite (`tests/run_raster.py`, 291 scenes).

## Remaining traps, stubs and gates

- **Gates.** Every gate is set: `tests_gfx_paint_r08_is_ported`,
  `tests_r10_four_cc_is_ported`, `gfx_geometry_is_ported`, `gfx_paint_is_ported`,
  `tests_gfx_paint_raster_is_skia_m144`.
- **Traps by design** (`replaced`/`unsupported`, unchanged by the integration): Path::impl,
  PathImpl::create and Path(NonnullOwnPtr<PathImpl>) (the implementation is PathImplRaster);
  PaintingSurface::canvas, sk_surface, sk_image_snapshot and ImmutableBitmap::sk_image (use
  the raster equivalents); Path::intersect (SkPathOps); GPU painting surfaces; YUVData;
  Core::Resource::data (LibCore; `font_data_create_from_file` reads a file for the tests); the
  plus-darker blender in PainterRaster; PathImpl's pure virtuals.
- **Not implemented** (`dbgln` FIXMEs, as the regions left them): PainterRaster's blur mask
  filters, image filters on paints (the canvas 2D painter; the display list's evaluator is in
  display_list, which gfx cannot import), pattern repetition other than repeat; unsupported
  gradient color spaces; ImmutableBitmap exports to RGBA5551.

## Known pixel differences from Skia

The player's 36 scenes against DisplayListPlayerSkia match exactly except:

- **Glyphs.** Skia draws small glyphs from FreeType's hinted glyph masks (outlines snapped to
  the pixel grid, which can move a stem or a baseline by up to a pixel); the player fills the
  unhinted outlines (r09 has no hinting). `glyph_run`: 142 pixels by up to 73 levels;
  `glyph_run_scaled`: 296 by up to 147; `text_shadow` (blurred): 489 by up to 17.
- **Box-shadow blur** (SkMaskFilter::MakeBlur) is r51a's three box blurs of the coverage, not
  Skia's SkMaskBlurFilter: 32 and 29 pixels by 1 level.
- **draw_rect**: Skia strokes an axis-aligned rectangle with SkScan::AntiFrameRect, the player
  fills the frame's even-odd path: 17 pixels by 1 level.
- **Transforms** are 2D (the perspective row of a 4x4 matrix is dropped), as r51a noted.
- The image-filter deviations above.
