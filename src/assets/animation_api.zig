pub const Looping = union(enum) {
    once,
    infinite,
    /// Number of additional repetitions after the first presentation.
    repetitions: u32,
};

/// Borrowed view of the decoder's current composited RGBA8 canvas. The pixels
/// remain valid until the decoder is advanced, reset, or destroyed.
pub const Frame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    duration_ns: u64,
    index: usize,
};
