const std = @import("std");
const config = @import("../config.zig");
const Error = @import("../core/error.zig").Error;
const api = @import("api.zig");

pub fn createBundle(allocator: std.mem.Allocator, app_config: config.AppConfig) Error!api.Bundle {
    return switch (config.compiled_platform) {
        .auto => unreachable,
        .headless => blk: {
            const text_backend: ?@import("../text/api.zig").Backend = if (config.text_enabled) blk_backend: {
                const instance = try @import("../text/in_tree_backend.zig").Backend.createInstance(
                    allocator,
                    app_config.memory.loaded_font_bytes,
                    app_config.memory.mapped_font_bytes,
                    app_config.memory.font_instance_count,
                    app_config.memory.font_catalog_count,
                    app_config.memory.font_catalog_bytes,
                );
                break :blk_backend instance.interface();
            } else null;
            errdefer {
                if (text_backend) |backend| backend.deinit();
            }
            const harness = try @import("headless.zig").createWithMemory(allocator, text_backend, app_config.memory);
            break :blk harness.bundle;
        },
        .macos => @import("macos/platform.zig").create(allocator, app_config),
        .windows => @import("windows/platform.zig").create(allocator, app_config),
        .linux_wayland => @import("linux/wayland/platform.zig").create(allocator, app_config),
        .linux_x11 => @import("linux/x11/platform.zig").create(allocator, app_config),
    };
}
