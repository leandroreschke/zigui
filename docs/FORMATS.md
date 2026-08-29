# Supported Formats

ZigUI owns every parser and decoder listed here. Unsupported variants return a
typed error; they are never delegated to a system codec or external process.
All readers apply byte, dimension, record-count, nesting, and working-memory
limits before allocating attacker-controlled sizes.

## Text and fonts

- Unicode Character Database 17.0.0 data is compiled into the framework.
- UTF-8 decoding, normalization forms NFC/NFD/NFKC/NFKD, extended grapheme,
  word and sentence boundaries, Unicode line breaking, bidirectional ordering,
  mirroring, script extensions, joining, and Indic properties are in-tree.
- OpenType/TrueType single fonts and TTC/OTC collections are parsed directly.
- Character maps 0, 4, 6, 10, 12, 13, and 14 are supported, including Unicode
  variation selectors.
- TrueType `glyf` outlines include simple, composite, phantom, and `gvar`
  variation points. CFF1 Type 2 and CFF2 outlines include local/global
  subroutines, blends, and CFF1 legacy composite accents.
- Horizontal metrics include `hmtx`, HVAR, MVAR, GDEF variation stores, and
  legacy horizontal `kern` format 0.
- GSUB and GPOS cover the lookup families used by the in-tree shaper, including
  extension lookups, contextual/chained rules, mark attachment, cursive
  attachment, device tables, and variation deltas.
- Apple Advanced Typography `morx` version 2 and 3 chains are applied in-tree,
  including rearrangement, contextual, ligature, noncontextual, and insertion
  subtables, feature flags, lookup formats, direction handling, and bounded
  state-machine execution.
- Variable font axes are normalized through `fvar`/`avar`; outline and metric
  deltas are evaluated in-tree.
- Color glyphs support COLR/CPAL v0, supported COLR v1 paint graphs, `sbix`, and
  CBDT/CBLC or EBDT/EBLC bitmap records. OpenType SVG glyph ranges are
  recognized so fallback remains deterministic, but SVG font glyph documents
  are not rasterized and return `error.Unsupported`.

Text layout is horizontal desktop text. Vertical OpenType layout and vertical
writing modes are outside the current public contract and are not emulated by
rotating horizontal output.

## Raster images

- PNG: grayscale, RGB, indexed, grayscale-alpha, and RGBA; every legal 1/2/4/8/16
  bit-depth combination; transparency, palettes, all filters, Adam7, ICC/gamma
  metadata, and APNG frame composition.
- JPEG: 8-bit Huffman baseline, extended-sequential, and progressive scans;
  grayscale, RGB/YCbCr, and four-component CMYK/YCCK; component subsampling,
  restart intervals, EXIF orientation, and ICC assembly. Arithmetic and
  lossless JPEG processes are rejected.
- GIF87a/GIF89a: palettes, transparency, interlacing, LZW, frame delays,
  disposal methods, loop metadata, and incremental animation composition.
- WebP: on macOS builds, bounded ImageIO-backed VP8/VP8L/VP8X still images and
  ANIM/ANMF animations are exposed as owned RGBA8 frames with validated canvas
  dimensions, frame delays, and loop counts. Other targets return
  `error.Unsupported` until a native or in-tree WebP provider is selected.
- BMP: uncompressed 24-bit and uncompressed/bitfield 32-bit DIB images,
  top-down rows, alpha masks, and supported embedded matrix/TRC color profiles.
- QOI: RGB and RGBA streams in sRGB or linear color space.

Decoded output is owned RGBA8 in a declared color space. Orientation is
applied explicitly. Matrix/TRC ICC profiles are converted to linear sRGB;
linked profiles and LUT-processing profiles return `error.Unsupported`.

## SVG

The optional SVG module is a bounded retained parser for UI artwork. It
supports view boxes and aspect-ratio fitting, groups and transforms, paths,
rectangles, rounded rectangles, circles, ellipses, lines, polylines, polygons,
solid fill/stroke, opacity, linear/radial gradients, and local paint-server
references used by those primitives.

The following are rejected rather than partially rendered: scripts, external
resources, CSS stylesheets, animation, filters, masks, clip paths, patterns,
text layout, embedded raster images, foreign objects, linked paint servers,
non-scaling strokes, and unsupported gradient spread modes. Applications can
compose ZigUI text or images beside an SVG when those features are needed.

## Media

The optional built-in media source reads bounded YUV4MPEG2 streams with
progressive or unspecified interlace and mono, 4:2:0, 4:2:2, or 4:4:4 chroma.
It converts frames to uploadable RGBA8 in-tree. The media interfaces also admit
application-owned native GPU surfaces without imposing a decoder dependency.
Other containers and compressed codecs require an application provider; ZigUI
does not launch helper subprocesses or bundle codec libraries. On macOS builds
with media enabled, the optional native-media service can instead hand a local
file or URL to AVFoundation and present it through a window-bound AVPlayerLayer,
including native audio ownership, seek, volume, and mute controls.
