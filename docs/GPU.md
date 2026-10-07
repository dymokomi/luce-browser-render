# The GPU player

How luce-browser draws pages on the GPU: the design, how it is checked and measured,
its budgets, and the plan. The owner's goal: the best browser there is, very fast,
small, with a small memory footprint, on luce-gpu (Metal on macOS, Vulkan on Windows
and Linux).

## Where it started

Painting records a display list (Ladybird's `DisplayList`: commands, each under a node
of an `AccumulatedVisualContextTree` of clips, transforms, effects and scroll frames).
`DisplayListPlayerCpu`, a port of Skia m144's raster pipeline that matches Ladybird's
Skia output pixel for pixel, replayed the whole list every frame; the view copied the
frame out (`webview_copy_frame`) and luced-browser uploaded it as a texture. A scroll
changes only the scroll state, yet every frame re-rastered everything: 139 ms a frame on
a plain text page, 150 ms to over a second on real ones (tables below). Profiles showed blur masks
and rounded-clip masks rebuilt every frame (a clip mask is the size of the whole surface),
image mipmaps rebuilt, glyph masks rastered per draw, and three full-frame copies.

## What others do, and what we take

| | Skia Ganesh (Ladybird) | Skia Graphite | WebRender (Firefox) | Chrome (cc + Skia) | Vello |
| --- | --- | --- | --- | --- | --- |
| Frame model | replay the list every frame | replay; recordings, fewer state changes | retained display list, picture caching by tile | layers, 256-512 px tiles, raster on GPU | full scene per frame, compute |
| Scrolling | re-raster (Ladybird scrolls in the list) | same | tiles cached per spatial node, moved | tiles moved by the compositor | re-render |
| Text | glyph atlas, instanced quads | atlas | glyph cache atlas, instanced | atlas (Skia) | atlas or paths |
| Paths | tessellation, MSAA, or CPU mask (software path renderer) | tessellation, atlas of coverage masks | CPU-rastered masks into a mask atlas | Skia | GPU compute coverage |
| Blurs, shadows | GPU blur; rrect shadows analytic; CPU blur masks cached (SkMaskCache) | GPU | box shadows: cached blur masks, nine-patch | Skia | not yet |
| Clips | stencil, analytic rrect FP | analytic, depth | clip masks in an atlas, rect clips as scissors | Skia | compute |

Ladybird replays its whole list on the GPU every frame and lets the GPU's speed carry it.
That is the least code, but it spends GPU time and battery on pixels that did not change,
and a CPU fallback for anything the GPU path lacks would then cost every frame. Chrome
and WebRender keep rastered tiles across frames and move them on scroll: the cheapest
scroll there is, and the only design where a CPU fallback per tile stays affordable.
Vello's compute coverage is the long-term answer for complex paths but needs compute in
luce-gpu and is a large body of work; it is a later milestone.

So the player is WebRender-shaped: **retained tiles per scroll plane, rastered once,
composited each frame**, with Skia-style techniques inside a tile (glyph atlas, cached
blur masks, CPU-rastered coverage masks for paths, analytic rounded rectangles and
clips), and the CPU player both as the reference and as the per-tile fallback. No Skia
GPU code is ported: luce-gpu's fragment shaders and the CPU player's own coverage and
mask code do it all.

## Architecture

Module `gpu_player` (luce-browser-render, Base), per view one `GpuCompositor`:

1. **Layers** (`layers.lucb`). Each command's visual-context chain says what its pixels
   depend on: *fixed* (no scroll node), *scrolled* (the chain starts with scroll node S,
   usually the viewport's; inner scroll nodes, such as sticky boxes and scrollers, are
   remembered), or *dynamic* (a non-scroll node above S, a scroll bar, or a command sharing
   an effect group with a dynamic one, since a group cannot be split between planes). A
   layer is a maximal run of commands with the same kind, S and inner frames; layers are
   composited in paint order. A layer's plane is S's content with S's offset at zero.
2. **Tiles** (`compositor.lucb`). 512-pixel tiles of each layer's plane, found by
   `hash(layer index, offsets of its inner frames, tile position)`, kept in `rgba8_linear`
   textures while the display list stays the same. A tile where nothing draws keeps no
   texture. A scroll moves tiles by S's offset (rounded as the CPU player rounds it).
   Least-recently-used tiles go past a budget (96 tiles; the current frame's are never
   dropped); textures are pooled.
   **Schedule** (`schedule.lucb`; see Scheduling below): which missing tiles are drawn when:
   required ones at once, uncovered visible ones within a raster budget per frame, tiles ahead
   of the scroll in spare budget and in idle time.
   **Bins** (`bins.lucb`): once per display list and layer key, each command's bounding
   rectangle, mapped through its visual context to the layer's plane, is sorted into the
   tiles it meets; a tile plays only its bin's commands
   (`display_list_player_execute_tile_commands`) and a tile whose bin is empty is not recorded.
3. **Raster** (`recorder*.lucb`, `replay.lucb`). `DisplayListPlayerGpu` (class id 2) is
   driven by Ladybird's own loop (`display_list_player_execute_tile`: a command range,
   moved by the tile's origin), so visual contexts, culling and scroll offsets are the
   CPU player's. It records draws, then replays them as luce-gpu texture frames: runs of
   glyph, path and shadow masks and of rounded rectangles with circular corners become one
   instanced draw each (`shade_instances`), and a tile with more than a frame's 4,000 draws
   goes on in a frame that keeps what the first drew (`Texture.frame(keep)`). Every draw
   is one fragment program, `shaders/tile.frag` (a header of the analytic clip, the clip
   mask flag and the draw's kind, then the kind's values), so the coverage code is
   embedded once; only the composite, which covers the screen every frame, has its own
   small program (`composite.frag`). Layers (`save_layer`, opacity, blend modes) are
   textures of their own, one per depth, composited when their save is restored. If the
   recording meets a command or state it does not support, it gives the tile up and the
   CPU player draws that tile's commands (one CPU player and surface per frame, with the
   engine's allocator) and it is uploaded.
4. **Composite.** On a target that blends on encoded values (luced-browser's window, an
   encoded luce-gpu surface; or an `rgba8_linear` texture) tiles composite straight onto it.
   On any other they composite into a frame texture of the viewport, which is then drawn
   onto the target with an sRGB decode.

**Color.** Web content blends in the encoded space (Skia's legacy raster does, and so
does the reference). Tiles are `rgba8_linear` holding encoded premultiplied bytes.
luced-browser opens its window with `Blending.encoded` (luce-ui's `Application(blending)`),
so the compositor asks the target (`RenderTarget.blending()`, `pixel_format()`) and draws
tiles onto it directly: no frame texture (16 MiB at 2560x1600) and no decode pass. A linear
target still gets both (`shaders/composite.frag`). `tools/shaders.sh` embeds the shaders
(SPIR-V without debug names, its locals made SSA values, nothing inlined, and its Metal
translation).

**Caches.** The coverage atlas (one r8 2048² texture, shelf-packed) holds glyph masks
keyed by strike and quarter-pixel phase (rastered once per process with the CPU player's
`sk_strike_glyph_mask`, so text is the reference's coverage), path and line coverage
(small shapes once per shape, large ones per tile, rastered 16 pixels past the tile so the
scan converter's edge clipping does not change the visible pixels), and blurred shadows as
the small nine-patch Skia blurs (`cpu_blurred_rrect_nine`, filterRectsToNine and
filterRRectToNine; the shader stretches it as draw_nine does), keyed by size, radii and
blur (Skia's SkMaskCache idea). When a mask does not
fit, the tile being recorded draws what it has into its texture first, then the atlas grows
once to 4096 texels a side by a GPU copy (`copy_texture`, every entry kept), and after that
starts again; no tile goes to the CPU for it. Images are uploaded once per bitmap as
premultiplied textures (64 MiB budget, LRU); an image drawn smaller with mipmapped sampling
gets Skia's own mip levels (raster's downsampler) packed beside it, and the shader blends
the two levels SkMipmapAccessor picks (`raster.mipmap_choice`). Gradients' stage programs
go into a float table per recording (1 MiB), uploaded before the tile's frames.

**Clips.** Rectangle clips are scissors. The innermost rounded clip is analytic in every
shader; the rounded clips around it go into a clip mask, an r8 texture of the tile rendered
before the tile's frame (tile.frag's clip kind multiplies each clip in: an `over` draw of
color 0 and alpha 1 - coverage), which the shaders sample at binding 2. A rounded
rectangle's coverage takes the corner whose ellipse's box holds the pixel (a corner may
reach past the middle). A tile holds up to 32 masks of
up to 8 clips each; identical clip stacks share one.

**Commands.**

| Command | GPU technique |
| --- | --- |
| `fill_rect` | one triangle batch per run under one scissor (exact: integer rectangles) |
| `fill_rect_with_rounded_corners`, `draw_rect`, scroll bars | box coverage on straight edges, distance to the ellipse at corners; strokes as outer minus inner |
| `add_clip_rect`, `add_rounded_rect_clip`, clip nodes | scissors; the innermost rounded clip analytic, the ones around it in an r8 clip mask |
| `draw_glyph_run` | glyph atlas (strikes made with the matrix's 2x2), a run's glyphs one instanced draw |
| `fill_path`, `stroke_path`, `draw_line`, ellipses | the CPU rasterizer's coverage (fill, stroke with caps, joins and dashes) in the atlas, under any matrix |
| `paint_outer_box_shadow`, `paint_inner_box_shadow` | Skia's blurred nine-patch (or whole mask) from the CPU player's code, cached in the atlas |
| `paint_*_gradient`, paths painted by gradient paint servers | the raster pipeline's own color stages for the paint (`raster.paint_stage_program`), run per pixel by tile.frag (`stages.glsl`): shapes, tiling, stops, CSS interpolation spaces and hue methods, dither |
| `draw_scaled_immutable_bitmap`, `draw_repeated_immutable_bitmap` | nearest or bilinear on premultiplied texels, clamped or wrapping; Skia's mip levels when drawn smaller |
| `save_layer`, opacity, blend modes (`apply_effects`) | a layer texture, composited `over` at its opacity or by the blend mode (`blend.glsl`, reading a copy of the target), under the clips it was saved under |
| `apply_transform` | 2D matrices: whole-pixel translations as state, anything else drawn under the matrix as above; clips it keeps axis-aligned |
| `paint_nested_display_list` | played by the same player, translated |
| text shadows, filters, backdrop filters, luminance masks, clip paths, perspective and 3D matrices, pattern paint servers, color-managed and external images, vertical text, text over 256 px, images and shadows under a rotation | the tile goes to the CPU player |

## Scheduling: raster budget, drawing ahead, binning (M3)

What others do. Chrome's compositor rasters on worker threads and never lets raster hold a
frame: the tile manager gives each tile a priority bin (NOW for the viewport, SOON for the
"skewport", the viewport extrapolated by the scroll velocity, EVENTUALLY for an interest rect
around it), rasters by bin and distance within a memory budget, and a visible tile that is
not ready at draw time is drawn as the layer's background color (checkerboarding). A pending
tree activates only once its visible tiles are ready. Firefox's APZ paints a display port
larger than the viewport, skewed toward the scroll. WebRender rasters only the dirty tiles of
its picture cache each frame and finds each primitive's tiles once. Chrome's raster source
keeps an R-tree of display items so a tile plays only what it meets; Skia's
SkPicture playback culls by bounds.

What the player does, on the main thread:

- **Required tiles** are drawn at once, whatever they cost: every visible tile of a new display
  list (as Chrome activates a tree), of fixed and dynamic layers, and of a layer whose key
  changed (a sticky header moved). `complete` draws (comparisons, screenshots) mark every
  visible tile required.
- **Uncovered visible tiles** are drawn within `GpuSchedule.budget` (4 ms of main-thread raster a
  frame): largest visible area first, each only when the time so far plus its layer's running
  cost per tile (a moving average of measured tiles) fits, but at least one a frame. A tile left
  shows the page's background (the list's first `fill_rect`, in the bottom layer) and counts as
  not ready; `gpu_compositor_incomplete` asks the embedder to draw again.
- **Ahead of the scroll**: each scrolled layer's interest area is the viewport grown in the
  scroll's direction by its velocity (device pixels a frame, smoothed, per scroll frame) over
  16 frames, at least a tile and at most a viewport; after a pause of 100 ms, a tile on every
  side. Tiles nearest the viewport first, never past the layer's content (its bins), and only
  while the tiles used this frame stay within the 96-tile budget. A frame draws, within its
  budget, only those the scroll reaches within 6 frames (Chrome's SOON); the rest wait for
  idle time.
- **CPU tiles become previews while the page scrolls.** A tile whose bin holds a drawing command
  under a filter or a clip path (a node's, a stream `apply_effects` until its restore, or one
  inside a nested display list such as an SVG's) is one the GPU player gives to the CPU player,
  at tens of milliseconds. While scroll offsets change it is drawn on the GPU as a preview,
  without what the filter or clip path applies to (`DisplayListPlayerGpu.preview`), as Chrome
  shows low-resolution tiles rather than hold a frame. Once the scroll stops (no offset change
  for 100 ms) the visible previews are drawn in full, one per idle period or frame whatever it
  costs; a complete frame draws them in full at once.
- **Filters are given up lazily.** A filter whose graph makes no pixels from nothing (no shader,
  image, arithmetic k4 or color filter that lifts transparent black) gives the tile up only when
  something is drawn under it: Ladybird's loop applies an element's effects for any command of
  it that reaches the tile, a clip included, and an empty group filters to nothing for the CPU
  player too.
- **Idle time** (`gpu_compositor_idle`, `webview_gpu_idle`, `webview_api.gpu_idle`): the embedder
  calls it when its loop has nothing due, with a deadline; it draws the visible tiles a frame
  left, then the interest area, then (once the scroll stops) previews in full, commits the work
  to the GPU (`Device.done` on the last tile frame's submission), and answers when to call
  again: at once, after the scroll's pause (only previews left), or never. luced-browser calls
  it each turn while the engine's next deadline is more than 2 ms away, 3 ms at a time (input
  waits no longer), and wakes when it answers; its page draws again while the last frame was
  incomplete or idle time drew a visible tile (`gpu_compositor_incomplete`).
- **Bins** (`bins.lucb`): per layer and layer key, a node table maps each visual context node to
  the plane (scroll offsets as the player applies them, 2D transforms about their origin, clip
  rectangles narrowing), each command's Ladybird bounding rectangle is mapped, clipped, grown by
  2 pixels and put in every tile it meets (counts, prefix sums, indices: one pass). Commands
  without bounds, clips, scroll bars and commands under perspective go in an `always` list
  every tile plays, merged in list order. A command left out is one the player's own culling
  would skip for that tile, so the pixels are the same; a layer with a stream `translate`, or a
  grid over 65,536 tiles, is played whole.

## Correctness

The CPU player is the reference: it matches Ladybird's Skia, and the GPU player must match
it within a fuzzy bound, as Ladybird's ref tests compare (a channel may be off by a little;
a few pixels may be off by more).

- `gpu_player/tests_gpu_player*.lucb`: scenes drawn both ways and compared (rectangles,
  clips and translations at two scroll offsets, paths, lines, images, mipmaps and
  gradients in every interpolation space: off by at most 2 per channel; rounded rectangles
  and clips: corner pixels within 40; shadows: within 40 on at most 300 pixels; layers,
  transforms, strokes, ellipses and patterns: within 3 but for a few hundred corner and
  edge pixels; a scroll that must move kept tiles and send only a perspective tile to the
  CPU).
- `webview/tests_webview_gpu.lucb`: a real page through the engine, before and after a
  wheel scroll, against the CPU player's frame of the same display list.
- `tools/scroll_bench --player both`: real pages compared every 16th frame.
- `web_test ref screenshot --player gpu` (engine): Ladybird's Ref and Screenshot tests with
  the GPU player's screenshots. Ref: 780 of 820 pass, as with the CPU player; Screenshot:
  44 of 67 (CPU player 65; the GPU player before M2 44). Most Screenshot misses are within
  a level or a few pixels of Ladybird's tight bounds (analytic corners, float blending,
  gradients within 1 on 12 pixels where 6 are allowed); clip paths and filters still go to
  CPU tiles, whose plane is drawn alone (see below).

Where the GPU differs: anti-aliased corners of rounded rectangles (analytic coverage vs
Skia's scan conversion), blend rounding (float vs Skia's 8-bit lowp), and shapes rastered
at another whole-pixel offset than the CPU player's frame (the raster port's anti-aliased
oval is not quite translation-invariant: its last row differs by up to 30 levels at some
offsets). Mipmapped images are now Skia's levels: gnu.org's checked frames all match. A
blend mode reads only what its compositor layer drew: a page background in another plane
(fixed while the content scrolls) is not under it, for GPU and CPU tiles alike; blends
across planes need the planes flattened (to do).

Platform coverage: the player and luce-gpu's encoded surfaces are tested on macOS (Metal,
on screen) and on Linux (Vulkan on RADV with validation, an Xwayland window). On Windows
(Vulkan on NVIDIA) the tests run headless only: encoded window presentation has not been seen
on screen there, because ssh runs in session 0 and has no desktop.

## Measuring

Without a window, from the engine's root:

```sh
luce-base build tools/scroll_bench -o build/scroll_bench --release
build/scroll_bench tests/scroll_bench/*.html SCRATCH/pages/*/index.html --frames 60 --player cpu|gpu|both [--layers]
python3 -I tools/scroll_bench/save_page.py https://news.ycombinator.com/ SCRATCH/pages/hn
python3 ../luced-browser/tools/binary_size.py ../luced-browser/build/luced-browser
```

A frame is a 40 CSS-pixel wheel scroll at 1280x800 points, device pixel ratio 2, and its
time is the main thread's work until the frame reaches the GPU (CPU: rastered and copied
out; GPU: drawn into an offscreen texture and waited for). Real pages are saved to scratch,
not committed (licenses). Measured on an Apple M-series Mac, release builds, luce-base
164f3d76.

### Frame time

| Page | CPU avg | CPU p95 | GPU avg | GPU p95 | GPU tiles / CPU tiles over 60 frames |
| --- | ---: | ---: | ---: | ---: | --- |
| text.html (local) | 139 | 154 | 3.3 | 8.1 | 120 / 0 |
| shadows.html (local) | 374 | 473 | 9.4 | 60 | 107 / 39 |
| boxes.html (local) | over 60,000 | | 15.5 | 95 | 81 / 65 |
| gnu.org | 926 | 1,030 | 41.7 | 284 | 179 / 91 |
| Hacker News | 498 | 800 | 4.1 | 16.5 | 220 / 5 |
| Wikipedia (Web browser) | 148 | 235 | 7.9 | 25.7 | 81 / 65 |
| The Verge | 1,027 | 1,151 | 13.2 | 73.6 | 234 / 101 |

CPU: 12 frames (40 for text and shadows gave the same), GPU: 60 frames; times in ms.
boxes.html's CPU frames did not finish 3 frames in 27 minutes: 160 cards each clip with
a rounded rectangle, and the CPU player builds a clip mask the size of the whole surface
for each. Before the float intrinsics landed (luce-base 2903eb9), the CPU player measured
116 / 138 ms on text.html, 310 / 383 on shadows.html and 480 / 507 on Hacker News.

Where the GPU frames still cost: a frame that uncovers a row of tiles the CPU must draw
(gnu.org's shadows and gradients, the Verge's transforms and inner shadows) takes 50 to
300 ms; frames that only move tiles take 1 to 3 ms. The CPU tiles column is the whole
reason for the p95 column. Why tiles fell back, over 60 frames: gnu.org shadow 65
(inner and text shadows), gradient 20, image 6 (minified); the Verge shadow 52,
transform 43, effects 2, nested rounded clip 2, atlas full 2; Wikipedia effects 51,
ellipse 13, nested display list 1; boxes.html nested rounded clip 60, atlas full 5;
Hacker News gradient 5.

### After the luce-gpu additions (2026-10-07)

Instanced glyphs and shapes, tiles straight onto an encoded target, keep frames, atlas
growth by GPU copy, mipmapped images and r8 clip masks (luce-gpu `e1cce0d`..`c226290`).
The old player (main before this change) and the new one, rebuilt against the same
luce-gpu and run interleaved (`--player gpu`, 60 frames, second of two rounds; the Mac was
indexing, so absolute numbers run higher than the table above). GPU time is the sum of a
frame's submissions' GPU times (luce-gpu's `gpu_time`; tiles, uploads, masks and composite).

| Page | Old avg / p95 ms | New avg / p95 ms | New GPU avg / p95 ms | GPU / CPU tiles, old → new |
| --- | ---: | ---: | ---: | --- |
| text.html | 4.15 / 9.66 | 4.05 / 7.79 | 0.15 / 0.22 | 120 / 0 → 120 / 0 |
| shadows.html | 9.56 / 57.88 | 5.42 / 30.46 | 0.21 / 0.61 | 107 / 39 → 133 / 13 |
| boxes.html | 16.24 / 103.45 | 4.91 / 14.31 | 0.26 / 0.92 | 81 / 65 → 146 / 0 |
| gnu.org | 41.02 / 279.20 | 39.99 / 273.25 | 0.37 / 1.57 | 179 / 91 → 185 / 85 |
| Hacker News | 4.47 / 19.71 | 4.17 / 20.18 | 0.23 / 0.23 | 220 / 5 → 220 / 5 |
| Wikipedia | 8.01 / 25.60 | 7.81 / 26.32 | 0.17 / 0.24 | 81 / 65 → 81 / 65 |
| The Verge | 13.38 / 75.34 | 13.27 / 70.76 | 0.34 / 1.01 | 234 / 101 → 238 / 97 |

The frame's GPU work is now well under a millisecond on every page; what remains of the
frame time is the engine's turns, the bench's one-texel wait for the GPU, and the CPU
tiles (shadows, gradients, effects, transforms). Compositing straight onto an encoded
target halves the composite's GPU time (text.html: 0.30 ms through the frame texture,
0.15 ms direct).

### After M2 (2026-10-07)

Box shadows as nine-patches, inner shadows, layers (opacity, blend modes, isolation),
2D transforms, gradients, ellipses, repeated images, strokes, painted paths and nested
display lists on the GPU. Main thread avg / p95 ms, GPU avg / p95 ms (luce-gpu 0d70913,
before its one command buffer per frame, after which the bench's per-submission GPU time
counts the whole buffer), tiles over 60 frames; before is main at the start of M2:

| Page | Before avg / p95 | After avg / p95 | GPU after | GPU / CPU tiles, before → after |
| --- | ---: | ---: | ---: | --- |
| text.html | 3.78 / 7.60 | 3.81 / 7.34 | 0.16 / 0.27 | 120 / 0 → 120 / 0 |
| shadows.html | 5.59 / 33.36 | 3.99 / 7.55 | 0.28 / 1.12 | 133 / 13 → 146 / 0 |
| boxes.html | 4.23 / 14.49 | 4.78 / 15.96 | 0.36 / 1.38 | 146 / 0 → 146 / 0 |
| gnu.org | 43.50 / 296.26 | 4.00 / 14.30 | 0.73 / 4.67 | 178 / 85 → 263 / 0 |
| Hacker News | 3.89 / 21.56 | 4.43 / 18.51 | 0.23 / 0.25 | 220 / 5 → 225 / 0 |
| Wikipedia | 8.17 / 26.17 | 5.47 / 10.45 | 0.16 / 0.18 | 81 / 65 → 146 / 0 |
| The Verge | 10.81 / 57.62 | 5.02 / 11.00 | 0.59 / 3.03 | 238 / 97 → 290 / 4 |

gnu.org is the saved page with its ten remote images pointed at a local one (gnu.org was
unreachable and its load event waited for them). The Verge's last four CPU tiles are a
`drop-shadow` filter with a 70 px blur. Hacker News's p95 has no CPU tile in it: the
frames that raster a new row of tiles (M3's raster budget and prefetch).

### Memory

| | Peak resident |
| --- | ---: |
| engine initialized, no page | 1,350-1,430 MiB |
| text.html, CPU / GPU | 1,757 / 1,549 MiB |
| shadows.html, CPU / GPU | 1,704 / 1,540 MiB |
| gnu.org, CPU / GPU | 1,802 / 1,726 MiB |
| Hacker News, CPU / GPU | 1,648 / 1,636 MiB |
| Wikipedia, CPU / GPU | 1,975 / 1,968 MiB |
| The Verge, CPU / GPU | 2,681 / 2,630 MiB |
| GPU player's own textures (tiles, pool, atlas, images, frame) | 118-127 MiB |

Each page in its own process; peak resident set (on Apple silicon the GPU's textures are
in the same memory, but Metal's private textures are not counted in the process's
resident set).

After the memory work of 2026-10-07 (mapped fonts loaded by family, no back stores in GPU
mode, finer blob size classes, one-entry cascaded-property vectors; GPU player on from the
view's first frame, 60 frames; `scroll_bench --census` prints the breakdown and
`tests/memory` holds the budgets):

| | Peak resident | Footprint (Activity Monitor) | GPU device allocated |
| --- | ---: | ---: | ---: |
| engine initialized, no page | 11 MiB | | |
| blank page | 58 MiB | 141 MiB | 86 MiB |
| text.html | 79 MiB | 672 MiB | 147 MiB |
| shadows.html | 68 MiB | 724 MiB | 164 MiB |
| boxes.html | 119 MiB | 771 MiB | 177 MiB |
| Hacker News | 103 MiB | 685 MiB | |
| Wikipedia | 372 MiB | 858 MiB | |
| The Verge | 548 MiB | 919 MiB | 192 MiB |

The footprint's excess over the resident set is GPU memory: the device's allocations
(tiles, frame, atlas, images) and, while frames render, about 400 MiB of Metal driver
memory in 8 MiB chunks (39-48 of them) that turns reclaimable once rendering stops; it
is there on a blank page too, idle and reclaimable. The Verge's peak is the live heap
(about 155 MiB: style 78, parse 26, layout 11, images 12, cells 21), heap blocks' free
cells (56 MiB), blocks cached for reuse (126 MiB, released to the system as reusable),
and the CPU tiles' garbage between collections (about 100 MiB: each CPU tile makes a
fresh 1 MiB surface and a CPU player).

### Binary size (luced-browser, release, arm64)

| | Bytes |
| --- | ---: |
| main (CPU player only) | 27,083,016 (21,927,336 stripped) |
| gpu/player | 27,360,840 (22,179,784 stripped): +271 KiB |
| of which `gpu_player` code | 172,576 |

After M2 (2026-10-07, against main of the same day's other packages): 27,684,920 bytes
(22,468,328 stripped), from 27,577,752 (22,380,456) with M1b's player; the `gpu_player`
module, with its shaders, 287,708 → 321,524 bytes. The embedded SPIR-V is 52.9 KiB (from
85.2 KiB for seven programs) and its Metal source 45.2 KiB (from 43.3 KiB), with layers,
every blend mode, the gradient stages and mipmaps added; but Luce Base compiles a `let`
array of u32 literals to initializer code, about 13.6 bytes a word: the SPIR-V costs
189 KB of code (200 KB before). Emitting such arrays as data would make it 53 KB.

Largest code by module: `luce_browser_engine_web` 6.8 MB (39%),
`luce_browser_foundation_ak` 1.8 MB (generic instantiations), `text_codec` 1.3 MB
(encoding tables in code), `luce_tls_roots` 0.76 MB, `raster` 0.71 MB, brotli 0.49 MB.
Read-only data (`__const`) is 3.3 MB; the symbol table 5.2 MB (strip it in releases).

## Budgets

- **Scroll**: a frame that only moves tiles under 2 ms on the main thread at 2560x1600;
  p95 under 8 ms (a frame rastering one new row of GPU tiles); no CPU tile on the pages of
  `tests/scroll_bench` and on gnu.org, Hacker News, Wikipedia.
- **GPU memory**: tiles at most twice the viewport per layer, 96 tiles (96 MiB) in all;
  atlas 4 MiB; images 64 MiB; frame texture 4 bytes a pixel until request 1 removes it.
- **Process memory**: 11 MiB resident before a page loads, 58 MiB peak for a blank page,
  under 125 MiB for the local test pages (tests/memory's budgets: 75-150 MiB). Fonts are
  mapped and loaded by family, GPU mode keeps one-pixel back stores, and a replaced display
  list is garbage at once (tests/memory and webview's tests check these).
- **Binary**: the GPU player under 250 KiB of code; the shaders under 40 KiB (52.9 KiB of
  SPIR-V now; see Binary size).

## Plan

| Milestone | What | Measured by |
| --- | --- | --- |
| M1 (done) | tiles kept across scrolls; rects, rounded rects, borders (paths), lines, text atlas, images, rect and one rounded clip, outer shadows on the GPU; CPU per tile otherwise | GPU average 3-42 ms on the seven pages vs 139-1,027 ms CPU (table above) |
| M1b (done) | luce-gpu's additions: instanced glyphs and shapes, encoded window, keep frames, atlas growth by GPU copy, mipmapped images, r8 clip masks for nested rounded clips | no CPU tiles for nested clips, minified images, full atlases or draw counts (table above) |
| M2 (done but filters) | gradients (the raster pipeline's stages on the GPU), layers for opacity, blend modes and isolation, 2D transforms, inner shadows and nine-patch shadows, ellipses, strokes, painted paths, repeated images, Skia's mipmaps, nested display lists, one shader | CPU tiles only for The Verge's drop-shadow filter (4); p95 under 16 ms but Hacker News (18.5); web_test Ref with `--player gpu` 780/820, as the CPU player |
| M3 | raster budget per frame with prefetch ahead of the scroll; spatial binning of a layer's commands per tile (one pass records bounds) | p95 under 8 ms on every saved page |
| M4 | memory: mapped fonts, no back stores in GPU mode, freed display lists (done 2026-10-07: blank page 58 MiB, Wikipedia 372 MiB peak); still to do: one reused CPU-tile surface and player, tile reuse across display-list changes (diff by command ranges) | empty view under 150 MiB; Wikipedia under 400 MiB |
| M5 | filters and backdrop filters (layers larger than a tile by the filter's reach; blur through luce-gpu compute or a separable pass matching SkBlurImageFilter; color matrix, drop shadow), clip paths (coverage into the r8 clip mask), luminance masks, pattern paint servers, color-managed images (the color_xform stage exists in stages.glsl), blends across compositor planes, 3D transforms; Vello-style compute coverage for big paths | all of web_test's Ref and Screenshot through the GPU player |

The requests to luce-gpu are in [GPU-LUCE-GPU-REQUESTS.md](GPU-LUCE-GPU-REQUESTS.md).
