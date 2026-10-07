# luce-gpu: what the browser's GPU player asks for

A proposal to LUCE_LANG, who owns luce-gpu. The GPU player (`gpu_player` in
luce-browser-render; design in [GPU.md](GPU.md)) runs today on luce-gpu 0.5.1 as it
is. Nothing below has a local stand-in yet: each item names what the player does
without it and what it costs. They are ordered by what they buy.

Signatures follow luce-gpu's style: Base functions next to `shade`, manual resources,
errors from the existing set.

## 1. Encoded-space presentation surfaces

```luce
pub enum Blending as u8:
    linear = 0      # today: sRGB attachment, blending in linear light
    encoded = 1     # a UNORM attachment tagged sRGB: blending on encoded values

pub func Surface.open(device: Device, window: window.Window, blending: Blending = Blending.linear) -> Surface!
```

**Why.** Web content blends in the encoded (gamma) space: Skia's legacy raster does,
Chrome does, and the CPU player, our reference, does. luce-gpu's surfaces are sRGB
attachments, so the player cannot composite layers onto the window directly: it
composites them into an `rgba8_linear` frame texture of the viewport (16 MiB at
2560x1600) and draws that onto the window with a decoding shader. With an encoded
surface the frame texture and the extra full-screen pass go away.

**Metal.** `CAMetalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm` with
`colorspace = kCGColorSpaceSRGB` (the compositor then treats values as encoded sRGB);
pipelines built for `none` use the UNORM format. **Vulkan.** Choose a
`VK_FORMAT_B8G8R8A8_UNORM` swapchain format with `VK_COLOR_SPACE_SRGB_NONLINEAR_KHR`
(every desktop driver lists it).

## 2. Instanced client-shader rectangles

```luce
## One rectangle of an instanced draw: where it goes (points) and 12 floats its
## fragment reads at locations 1..3 (vec4 each), flat-interpolated.
pub struct ShadeInstance:
    pub var rect: f32[4]
    pub var data: f32[12]

pub func shade_instances(target: const RenderTarget*, pipeline: Pipeline, instances: const ShadeInstance[],
                         uniforms: const u8[]? = none, images: const Texture[]? = none, filter: Filter = Filter.linear) -> !
```

**Why.** Every glyph, path mask and rounded rectangle is one `shade` draw today:
encoding cost per draw, and luce-gpu's 4,096-draw canvas limit caps a tile (the
player sends a tile over 4,000 draws to the CPU). Text-heavy tiles hold 500 to 1,500
glyphs. Instancing makes a glyph run one draw (WebRender, Skia's Ganesh atlas text
and Graphite all draw glyphs as instanced quads).

**Metal.** One vertex buffer of instances, `drawPrimitives(.triangleStrip, 0, 4,
instanceCount)`; the vertex function reads `[[instance_id]]` and passes `data` as flat
varyings. **Vulkan.** An instance-rate vertex binding (or a storage buffer indexed by
`gl_InstanceIndex`) and `vkCmdDraw(4, count, 0, 0)`. The vertex stage is luce-gpu's,
so client shaders stay fragment-only.

## 3. Keep a texture's contents when a frame begins

```luce
pub func Texture.frame(keep: bool = false) -> interop.Reference[Frame]!
## present() clears only when the frame was not begun with `keep`.
```

**Why.** A texture frame always clears. The player cannot add to a tile (an
invalidated rectangle of a page that changed, a tile split over the draw limit, a
dirty-rect update of the viewport's frame texture): it redraws the whole tile.

**Metal.** `MTLLoadActionLoad` on the color attachment. **Vulkan.**
`VK_ATTACHMENT_LOAD_OP_LOAD` with the image in `COLOR_ATTACHMENT_OPTIMAL` (one more
render pass per format).

## 4. Texture-to-texture copies

```luce
pub func copy_texture(source: Texture, region: Region, target: Texture, x: u32, y: u32) -> !
```

**Why.** Scrolling by a few pixels could move the previous frame texture and draw
only the uncovered strip (what Chrome's and Firefox's compositors avoid needing only
because they own the window's layers). Also atlas defragmentation without CPU
round trips.

**Metal.** `MTLBlitCommandEncoder.copyFromTexture`. **Vulkan.** `vkCmdCopyImage` with
layout transitions, ordered on the queue like `upload`.

## 5. Mipmapped textures

```luce
pub func Texture.create(device: Device, width: u32, height: u32, pixel_format: Format, mipmaps: bool = false) -> Texture!
pub func Texture.generate_mipmaps() -> !
## Filter gains `trilinear` (linear between levels).
```

**Why.** Images drawn smaller than their size with `bilinear_mipmap` (photos, avatars,
thumbnails) go to the CPU player today. **Metal.** `mipmapLevelCount`,
`generateMipmapsForTexture` on a blit encoder, `mipFilter = .linear`. **Vulkan.**
`mipLevels`, a `vkCmdBlitImage` chain, `mipmapMode = LINEAR`.

## 6. A clip stencil for texture frames

```luce
pub func Texture.frame(keep: bool = false, stencil: bool = false) -> interop.Reference[Frame]!
pub func clip_mask(target: const RenderTarget*, pipeline: Pipeline, rectangle: Rect, uniforms: const u8[]?, images: const Texture[]?, value: u8) -> !   # writes stencil where coverage > 0
pub func RenderTarget.stencil_test(value: u8) -> interop.View[RenderTarget]!
```

**Why.** Nested rounded clips and `clip-path` send tiles to the CPU (one rounded
clip is analytic in every shader; a second is not). A stencil (or an r8 clip-mask
render target the shaders sample, if luce-gpu prefers to allow `r8` render targets)
covers both. **Metal.** `MTLPixelFormatStencil8` attachment, depth-stencil state per
draw. **Vulkan.** `VK_FORMAT_S8_UINT` (or D24S8) attachment, stencil ops in the
pipeline's dynamic state.

## 7. Small ones

- `RenderTarget.pixel_format() -> Format?`: the target's format (none: a surface), so
  `gpu_compositor_draw` need not be told which pipeline to pick.
- `Canvas` draw limit: `RenderTarget.allow_draws(count)` as `allow_vertices` does, since
  the page's composite shares the window frame's 4,096 draws with luce-ui.
- `Frame.present` returning a completion token and `Device.wait(token)`, plus GPU
  timestamps (`MTLCounterSampleBuffer`, `vkCmdWriteTimestamp`): the scroll benchmark
  now waits with a one-texel read and cannot separate GPU time from CPU time.
- Compute (luce-gpu's GPU.md lists it as a later increment): Gaussian blurs for
  `filter: blur()` and backdrop filters, and a Vello-style coverage pass for large
  paths, once the player moves those off the CPU.
