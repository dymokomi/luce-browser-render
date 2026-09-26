# luce-browser-render

Geometry, color, fonts, the CPU rasterizer and the display list of the luce-browser port of Ladybird, in luce-base.

Part of the luce-browser family, a faithful port of Ladybird's LibWeb to luce-base; the design every
porter follows is [DESIGN.md](../luce-browser-engine/docs/DESIGN.md).

| Module | Contents |
| --- | --- |
| `gfx` | LibGfx geometry, color, paths; CSS pixels |
| `web_fonts` | fonts and text layout |
| `raster` | the CPU rasterizer |
| `display_list` | the display list |

Depends on: luce-std, luce-browser-foundation, luce-browser-css.

## Status

Skeleton: every type of the phase-1 closure is declared and every function has its generated
signature and a `trap("unported: ...")` body, grouped by region (`docs/regions.tsv`). Regions
replace their stub fragments with ported code (DESIGN.md §4.5). `docs/namemap.tsv` maps every C++
name to its Luce name; `docs/gc_fields.tsv` lists the GC pointer fields each cell must visit.

The skeleton is generated from Ladybird at `47c82b38d0` (see `PIN`) by a local tool that is not part
of this repository.

## Testing

`./test.sh` checks the formatting, type-checks every module with warnings as errors and runs the `display_list` and `raster` tests (the CPU
display-list player is compared with Skia's pixels; the rasterizer with tiny-skia's reference
images).

## License

BSD-2-Clause, as Ladybird; see `LICENSE`.
