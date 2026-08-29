//! Platform-neutral, resolved window appearance.
//!
//! ZigUI exposes the system result, not product theme tokens. Consumers can
//! map this value to their own palette while the framework remains unaware of
//! application-specific colors or typography.

pub const Appearance = enum {
    /// The initial/unresolved value used only by callers constructing a
    /// platform-independent window record. Native platforms should publish a
    /// resolved value before the first frame is composed.
    system,
    light,
    dark,
    high_contrast_light,
    high_contrast_dark,

    pub fn isDark(self: Appearance) bool {
        return self == .dark or self == .high_contrast_dark;
    }

    pub fn isHighContrast(self: Appearance) bool {
        return self == .high_contrast_light or self == .high_contrast_dark;
    }
};
