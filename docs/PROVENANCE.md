# Data Provenance

ZigUI has no package or source-code dependencies. Two generated source files
contain standards registry data so applications do not load databases or run
generators at build time.

| Generated source | Upstream data | Version | In-tree generator |
| --- | --- | --- | --- |
| `src/text/unicode_data.zig` | Unicode Character Database, UAX property files, emoji property data | 17.0.0 | `tools/generate_unicode.zig` |
| `src/text/opentype_language.zig` | Microsoft OpenType language-system registry and ISO 639 aliases | OpenType 1.9.1 registry snapshot | `tools/generate_opentype_languages.zig` |

The checked-in generated files are ordinary Zig constants. The framework
build performs no network access and does not require the upstream registry
files. Regeneration is a maintainer operation: inputs are supplied explicitly
to the generators, outputs are reviewed as source changes, and the published
version markers are updated together.

Standards tables and registry facts are data, not executable third-party
libraries. Their applicable upstream notices must accompany a distributed
source release even though they do not change ZigUI's zero-dependency runtime
or build closure.
