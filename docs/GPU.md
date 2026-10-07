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
   texture. A scroll moves tiles by S's offset (rounded as the CPU player rounds it) and
   draws only the uncovered ones. Least-recently-used tiles go past a budget (96 tiles;
   the current frame's are never dropped); textures are pooled.
3. **Raster** (`recorder*.lucb`, `replay.lucb`). `DisplayListPlayerGpu` (class id 2) is
   driven by Ladybird's own loop (`display_list_player_execute_tile`: a command range,
   moved by the tile's origin), so visual contexts, culling and scroll offsets are the
   CPU player's. It records draws, then replays them as luce-gpu texture frames: runs of
   glyph and path masks and of rounded rectangles with circular corners become one
   instanced draw each (`shade_instances`; `glyphs.frag`, `shapes.frag`), and a tile with
   more than a frame's 4,000 draws goes on in a frame that keeps what the first drew
   (`Texture.frame(keep)`). If it meets a command or state it does not support, it gives
   the tile up and the CPU player draws that tile (with the engine's allocator) and it is
   uploaded.
4. **Composite.** On a target that blends on encoded values (luced-browser's window, an
   encoded luce-gpu surface; or an `rgba8_linear` texture) tiles composite straight onto it.
   On any other they composite into a frame texture of the viewport, which is then drawn
   onto the target with an sRGB decode.

**Color.** Web content blends in the encoded space (Skia's legacy raster does, and so
does the reference). Tiles are `rgba8_linear` holding encoded premultiplied bytes.
luced-browser opens its window with `Blending.encoded` (luce-ui's `Application(blending)`),
so the compositor asks the target (`RenderTarget.blending()`, `pixel_format()`) and draws
tiles onto it directly: no frame texture (16 MiB at 2560x1600) and no decode pass. A linear
target still gets both (`shaders/composite.frag`).

**Caches.** The coverage atlas (one r8 2048² texture, shelf-packed) holds glyph masks
keyed by strike and quarter-pixel phase (rastered once per process with the CPU player's
`sk_strike_glyph_mask`, so text is the reference's coverage), path and line coverage
(small shapes once per shape, large ones per tile), and blurred shadow masks keyed by size,
radii and blur (`cpu_blurred_rrect_mask`, Skia's SkMaskCache idea). When a mask does not
fit, the tile being recorded draws what it has into its texture first, then the atlas grows
once to 4096 texels a side by a GPU copy (`copy_texture`, every entry kept), and after that
starts again; no tile goes to the CPU for it. Images are uploaded once per bitmap as
premultiplied textures (64 MiB budget, LRU); an image drawn smaller with mipmapped sampling
gets a mipmapped texture (`generate_mipmaps`), sampled trilinearly.

**Clips.** Rectangle clips are scissors. The innermost rounded clip is analytic in every
shader; the rounded clips around it go into a clip mask, an r8 texture of the tile rendered
before the tile's frame (`clip.frag` multiplies each clip in: an `over` draw of color 0 and
alpha 1 - coverage), which the shaders sample at binding 2. A tile holds up to 32 masks of
up to 8 clips each; identical clip stacks share one.

**Commands.**

| Command | GPU technique |
| --- | --- |
| `fill_rect` | one triangle batch per run under one scissor (exact: integer rectangles) |
| `fill_rect_with_rounded_corners`, `draw_rect`, scroll bars | `fill.frag`: exact box coverage on straight edges, distance to the ellipse at corners; strokes as outer minus inner |
| `add_clip_rect`, rect clip nodes | scissor (integer, exact) |
| `add_rounded_rect_clip`, rounded clip nodes | the innermost analytic in every shader (inside or outside), the ones around it in an r8 clip mask |
| `draw_glyph_run` | glyph atlas, a run's glyphs one instanced `glyphs.frag` draw |
| `fill_path` (color) | CPU coverage (the reference's own scan converter) in the atlas, `mask.frag` |
| `draw_line` | the reference's stroke (`cpu_line_of`) rastered to coverage, `mask.frag` |
| `paint_outer_box_shadow` | the reference's blur mask, cached in the atlas, under the content's outside clip |
| `draw_scaled_immutable_bitmap` | `image.frag`, nearest or bilinear in the shader on premultiplied texels, trilinear from mipmaps when drawn smaller |
| whole-pixel `translate`, translation-only transforms, effects that change nothing, `save_layer` | state only |
| everything else | the tile goes to the CPU player |

What falls back today: non-translation transforms, opacity/blend/filter effects, clip
paths, gradients, inner and text shadows, ellipses, stroked and painted paths, repeated
images, color-managed images, nested display lists (iframes), external content, vertical
text and text over 256 px. Nested rounded clips, minified images, full atlases and tiles of
more than 4,000 draws no longer fall back.

## Correctness

The CPU player is the reference: it matches Ladybird's Skia, and the GPU player must match
it within a fuzzy bound, as Ladybird's ref tests compare (a channel may be off by a little;
a few pixels may be off by more).

- `gpu_player/tests_gpu_player.lucb`: scenes drawn both ways and compared (rectangles,
  clips and translations, at two scroll offsets: off by at most 2 per channel; paths, lines
  and images: at most 2; rounded rectangles and clips: corner pixels within 40; outer
  shadows: within 40 on at most 300 pixels; a scroll that must move kept tiles and send
  only a gradient's tile to the CPU).
- `webview/tests_webview_gpu.lucb`: a real page through the engine, before and after a
  wheel scroll, against the CPU player's frame of the same display list.
- `tools/scroll_bench --player both`: real pages compared every 16th frame.
- Next: run web_test's Ref and Screenshot corpus with the GPU player (a `--player gpu`
  mode for web_test drawing into an offscreen texture), with per-test fuzzy metadata.

Where the GPU differs: anti-aliased corners of rounded rectangles (analytic coverage vs
Skia's scan conversion), large paths rastered per tile (an edge clipped at a tile seam is
set up differently), blend rounding (float vs Skia's 8-bit lowp), and minified images (the
GPU's box-filtered mip chain and trilinear sampling vs Skia's mipmaps: gnu.org's large
illustration, drawn smaller, differs in its fine lines by up to 93 in a channel, so two of
its checked frames exceed the bench's strict bound). On the saved Verge
and the shadows page under 1.2% of pixels differ by more than 2, all on such edges.

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

### Binary size (luced-browser, release, arm64)

| | Bytes |
| --- | ---: |
| main (CPU player only) | 27,083,016 (21,927,336 stripped) |
| gpu/player | 27,360,840 (22,179,784 stripped): +271 KiB |
| of which `gpu_player` code | 172,576 |

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
- **Process memory**: today 1.35 GiB resident before a page loads. That is not drawing:
  `PathFontProvider` reads every system font file into memory (and copies it once more),
  where Ladybird maps them. Mapping them is the largest single memory win available
  (target: under 150 MiB resident for an empty view). In GPU mode the view still keeps
  two full-frame back stores it no longer draws into (32 MiB at 2560x1600), and display
  lists are never freed.
- **Binary**: the GPU player under 250 KiB of code; the shaders under 40 KiB.

## Plan

| Milestone | What | Measured by |
| --- | --- | --- |
| M1 (done) | tiles kept across scrolls; rects, rounded rects, borders (paths), lines, text atlas, images, rect and one rounded clip, outer shadows on the GPU; CPU per tile otherwise | GPU average 3-42 ms on the seven pages vs 139-1,027 ms CPU (table above) |
| M1b (done) | luce-gpu's additions: instanced glyphs and shapes, encoded window, keep frames, atlas growth by GPU copy, mipmapped images, r8 clip masks for nested rounded clips | no CPU tiles for nested clips, minified images, full atlases or draw counts (table above) |
| M2 | gradients (linear, radial, conic in a shader with the CPU's stop math), opacity groups (an offscreen tile layer), translation+scale transforms, inner and text shadows (cached masks), mipmapped images (request 5) | no CPU tiles on the six saved pages; web_test Ref with `--player gpu` within fuzzy bounds |
| M3 | raster budget per frame with prefetch ahead of the scroll; spatial binning of a layer's commands per tile (one pass records bounds) | p95 under 8 ms on every saved page |
| M4 | memory: mapped fonts, no back stores in GPU mode, freed display lists, tile reuse across display-list changes (diff by command ranges) | empty view under 150 MiB; Wikipedia under 400 MiB |
| M5 | clip paths (coverage into the r8 clip mask), filters and backdrop filters (luce-gpu compute), 3D transforms; Vello-style compute coverage for big paths | all of web_test's Ref and Screenshot through the GPU player |

The requests to luce-gpu are in [GPU-LUCE-GPU-REQUESTS.md](GPU-LUCE-GPU-REQUESTS.md).
