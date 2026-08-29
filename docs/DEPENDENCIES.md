# Dependency Policy

ZigUI owns its implementation and uses no third-party package or runtime
library. `build.zig.zon` must keep an empty dependency table.

The repository audit checks both sides of that contract: the manifest contains
`.dependencies = .{}`, and non-relative Zig imports resolve only to `std`,
compiler-provided modules, or modules created by ZigUI's own build graph. No
prebuilt framework, archive, shared library, DLL, Metal library, or SPIR-V blob
is stored in the source tree.

## Permitted

- Zig standard library.
- Native operating-system APIs and frameworks delivered as part of the target
  operating system.
- Native GPU-driver entry points delivered with the installed graphics driver.
- Protocol and file-format specifications implemented as original Zig source
  in this repository.

Examples include AppKit window/input contracts, Metal, Win32 window/input
contracts, D3D11, UI Automation, native IME contracts, ImageIO's bounded
macOS WebP image provider, and the native Vulkan loader ABI opened through
`std.DynLib` with dynamically resolved driver dispatch. Native APIs are
boundary contracts, not alternate engines: ZigUI still owns layout, Unicode
processing, OpenType shaping, font fallback, glyph rasterization, the in-tree
image decoders, SVG, and scene generation on every target; a documented native
format provider may be used only where the target contract explicitly exposes
that capability.

## Not permitted

- Zig package dependencies.
- Vendored third-party source in any language.
- HarfBuzz, FreeType, Fontconfig, ICU, libpng, libjpeg, resvg, Skia, GLFW,
  SDL, wgpu, Dawn, Yoga, Taffy, libwayland, Xlib, XCB, XKBCommon, libdbus, or
  comparable convenience libraries.
- Runtime subprocesses that delegate framework behavior to external tools.
- Build-time downloads, package-manager resolution, or `pkg-config` probing.

## In-tree responsibilities

ZigUI implements and tests its own:

- flex and grid layout;
- required Unicode segmentation, bidi, normalization, and line breaking;
- OpenType parsing, GSUB/GPOS shaping, fallback selection, TrueType/CFF glyph
  rasterization, and supported color-font formats on Linux;
- Wayland, X11, keyboard, clipboard, drag/drop, D-Bus, and AT-SPI protocols;
- Vulkan loading and dispatch;
- enabled in-tree image and SVG decoders, plus the explicitly documented
  macOS ImageIO WebP provider;
- deterministic headless and testing infrastructure.

Apple and Windows font directories are discovered through narrow native
filesystem contracts, then parsed, shaped, and rasterized by the same in-tree
engine used on Linux and in headless tests. Native IME adapters only exchange
composition, selection, and candidate-window geometry; they do not shape or
render text.

Any future exception requires an explicit architecture decision and a change to
this document; it cannot enter transitively through an optional widget.

Generated standards registry constants and their maintainer-only generators
are catalogued in [Data Provenance](PROVENANCE.md). They introduce no build-time
or runtime dependency.

Native SDK compilers used to turn ZigUI's checked-in shader source into target
objects are build-environment tools, not package dependencies. They do not
download source or supply framework behavior; the generated outputs remain
ordinary build artifacts outside the source closure.
