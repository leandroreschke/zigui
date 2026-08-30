const std = @import("std");
const testing = std.testing;
const ui = @import("zigui");

// A tiny, self-contained lossy WebP (2x2) keeps the conformance test
// independent of a writable fixture directory. The animated sample is a
// two-frame 32x32 alpha WebP with 100 ms frame delays and an infinite loop.
const static_webp = [_]u8{
    0x52, 0x49, 0x46, 0x46, 0x32, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
    0x56, 0x50, 0x38, 0x20, 0x26, 0x00, 0x00, 0x00, 0xb0, 0x01, 0x00, 0x9d,
    0x01, 0x2a, 0x02, 0x00, 0x02, 0x00, 0x02, 0x00, 0x34, 0x25, 0x8c, 0x02,
    0x74, 0x01, 0x0e, 0xfe, 0x02, 0xec, 0x00, 0xfe, 0xfc, 0x2d, 0xeb, 0x50,
    0xcb, 0x2b, 0x65, 0x02, 0x7a, 0xc3, 0xc7, 0x00, 0x00, 0x00,
};

const animated_webp_base64 =
    "UklGRrQDAABXRUJQVlA4WAoAAAASAAAAHwAAHwAAQU5JTQYAAAD/////AABBTk1GyAEAAAAAAAAAAB8AAB8AAGQAAAFBTFBIcQAAAAEPMP8REcJtrW1r8nwH66BNlazAALaWu5VswCQWT8kIuoC7k4QZIvo/AegCukHDWKJbWxqerwizIsyzGVVV8rVkQ3uInrqIHllIA53A9/sfvyCNhB5paJsI+Yukaw+lUMiM9jD0rYWBzxL6baEdgUYEAFZQOCA2AQAAcAYAnQEqIAAgAD6RQpxKJaOioagIALASCWkACBUYgW7F+A8kAMRphpuhigFoZAsoZQPY5dH5edlO32+AAPm3WQ1+Uq4o16coq0sal1WP7YWnUgO8NY3zdLChFCIETQSQPdCePA3k2Ue4vvkk7pJErg5obEeuPZAny7LTT1uf6+ibKzi333Yxf7KnPBUerMZZ3j7ac6rknZg2WUac4Ml2Md/Isdz4C2e3ztFnNl56+z1TtGU115COf+XlWzcua3IArJMv530G6cMyqJa5Jho/qZaMdB04bX4Y837OimJSjzia5OcPPUhF6rk30J9VvRFmqw+a2aIjMO4Z/K8Rn3hWsN6oOSX/S1WmsMCPKxzqNJVrfw1CRYLPqIJ3iHpOkApeV8Py29pWSFdyBSO4gby0aIuxOAAAAEFOTUa4AQAAAAAAAAAAHwAAHwAAZAAAAUFMUEhyAAAAAQ8w/xERwm2tbWvyvidCBy1VsgKlw1ruVrIBk1g8JSPoAu5OZIaI/k8ANAKajqa+gmbu0HQ9JWBeAxa5rKIkC/VoU31Si12pCUs2ocH38wnjJdiMaEJT3QooXJmoP+PFYnZ8AEaeDTH0mMSgQ3QEoCkAVlA4ICYBAABQBgCdASogACAAPpE+mkkloyKhKAqosBIJaQAIGliBbu2ZWHDvXTgY+GFFLQ1l7BKPnGSYO9CO/wzjoADXBLXaDNOLli78KXYuETTIDe3M1k8/MwHLeYWCEwv5PNiySfuUW3nKyHBrnFQvYzbJGif45K1Y/7euZTXrcPfEOLxlFke7OxZa7lxRCI7t0e2PMsHrmWf/73DsP6pp9d2ek225rCj6qSkgCL+h8R7naSGH9z4AA6A2s+GeQpwPd1vw4cu648mVA3se4M4aSZbQnYp+5wSHA88R2IVeiKzPhUgbKOHpvQgV/Xeve3pjY83ZGQwA+bk+D8hzM+zqSSIgc6ZVwxmsCxgEqbMvjztg8N+TkOKcc0xFt+PV63Lnyi9p5zZepDSCgAA=";

// AOMediaCodec/libavif's BSD-licensed 1x1 white conformance fixture, embedded
// so the native ImageIO test has no network or writable-directory dependency.
const white_avif_base64 =
    "AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUEAAADybWV0YQAAAAAAAAAoaGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAGxpYmF2aWYAAAAADnBpdG0AAAAAAAEAAAAeaWxvYwAAAABEAAABAAEAAAABAAABGgAAABcAAAAoaWluZgAAAAAAAQAAABppbmZlAgAAAAABAABhdjAxQ29sb3IAAAAAamlwcnAAAABLaXBjbwAAABRpc3BlAAAAAAAAAAEAAAABAAAAEHBpeGkAAAAAAwgICAAAAAxhdjFDgSAAAAAAABNjb2xybmNseAABAA0ABoAAAAAXaXBtYQAAAAAAAAABAAEEAQKDBAAAAB9tZGF0EgAKBzgABhAQ0GkyCh/wP///xAAAr3A=";

fn decodeAnimatedFixture(allocator: std.mem.Allocator) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(animated_webp_base64);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    try decoder.decode(bytes, animated_webp_base64);
    return bytes;
}

fn decodeAvifFixture(allocator: std.mem.Allocator) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(white_avif_base64);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    try decoder.decode(bytes, white_avif_base64);
    return bytes;
}

test "AVIF still image is native or explicitly unsupported" {
    const bytes = try decodeAvifFixture(testing.allocator);
    defer testing.allocator.free(bytes);
    if (ui.config.compiled_platform != .macos) {
        try testing.expectError(error.Unsupported, ui.image.decode(testing.allocator, bytes, .{}));
        return;
    }
    var still = try ui.image.decode(testing.allocator, bytes, .{});
    defer still.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), still.width);
    try testing.expectEqual(@as(u32, 1), still.height);
    try testing.expectEqual(@as(usize, 4), still.pixels.len);
    try testing.expectEqual(@as(u8, 255), still.pixels[3]);
}

test "WebP image and animation contracts are native or explicitly unsupported" {
    if (ui.config.compiled_platform != .macos) {
        try testing.expectError(error.Unsupported, ui.image.decode(testing.allocator, &static_webp, .{}));
        try testing.expectError(error.Unsupported, ui.animation.Decoder.init(testing.allocator, &static_webp, .{}));
        return;
    }

    var still = try ui.image.decode(testing.allocator, &static_webp, .{});
    defer still.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), still.width);
    try testing.expectEqual(@as(u32, 2), still.height);
    try testing.expectEqual(@as(usize, 16), still.pixels.len);
    try testing.expectEqual(@as(usize, 8), still.stride);

    const animated_bytes = try decodeAnimatedFixture(testing.allocator);
    defer testing.allocator.free(animated_bytes);
    try testing.expect(ui.image.isWebp(animated_bytes));

    var decoder = try ui.animation.Decoder.init(testing.allocator, animated_bytes, .{});
    defer decoder.deinit();
    try testing.expect(decoder.looping() == .infinite);
    var frame_count: usize = 0;
    while (try decoder.next()) |frame| {
        try testing.expectEqual(@as(u32, 32), frame.width);
        try testing.expectEqual(@as(u32, 32), frame.height);
        try testing.expectEqual(@as(usize, 32 * 4), frame.stride);
        try testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), frame.duration_ns);
        frame_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), frame_count);

    var player = try ui.animation.Player.init(testing.allocator, animated_bytes, .{}, 0);
    defer player.deinit();
    try testing.expectEqual(@as(usize, 0), player.frame().?.index);
    try testing.expect(try player.advance(100 * std.time.ns_per_ms));
    try testing.expectEqual(@as(usize, 1), player.frame().?.index);
    try testing.expect(try player.advance(200 * std.time.ns_per_ms));
    try testing.expectEqual(@as(usize, 0), player.frame().?.index);
    try testing.expect(player.isPlaying());

    var finite = try testing.allocator.dupe(u8, animated_bytes);
    defer testing.allocator.free(finite);
    // ANIM starts at offset 30: four bytes of background then loop count.
    finite[42] = 3;
    finite[43] = 0;
    var finite_decoder = try ui.animation.Decoder.init(testing.allocator, finite, .{});
    defer finite_decoder.deinit();
    switch (finite_decoder.looping()) {
        .repetitions => |count| try testing.expectEqual(@as(u32, 2), count),
        else => return error.TestUnexpectedResult,
    }

    var malformed = try testing.allocator.dupe(u8, &static_webp);
    defer testing.allocator.free(malformed);
    malformed[4] = 0x31;
    try testing.expectError(error.InvalidImage, ui.image.decode(testing.allocator, malformed, .{}));
    try testing.expectError(error.BudgetExceeded, ui.image.decode(testing.allocator, &static_webp, .{ .maximum_compressed_bytes = static_webp.len - 1 }));
    try testing.expectError(error.BudgetExceeded, ui.animation.Decoder.init(testing.allocator, animated_bytes, .{ .maximum_animation_frames = 1 }));
}
