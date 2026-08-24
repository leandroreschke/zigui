const std = @import("std");

pub const Platform = enum {
    auto,
    headless,
    macos,
    windows,
    linux_wayland,
    linux_x11,
};

pub const Renderer = enum {
    auto,
    null,
    metal,
    d3d11,
    vulkan,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const requested_platform = b.option(
        Platform,
        "platform",
        "Desktop platform: auto, headless, macos, windows, linux_wayland, linux_x11",
    ) orelse .auto;
    const requested_renderer = b.option(
        Renderer,
        "renderer",
        "GPU renderer: auto, null, metal, d3d11, vulkan",
    ) orelse .auto;
    const metal_toolchain = b.option(
        []const u8,
        "metal-toolchain",
        "Path to an installed Metal.xctoolchain when xcrun cannot select it",
    );

    const platform = resolvePlatform(requested_platform, target.result.os.tag);
    const renderer = resolveRenderer(requested_renderer, platform);
    validateCombination(platform, renderer);

    const enable_text = b.option(bool, "text", "Compile native text shaping and rasterization") orelse true;
    const enable_accessibility = b.option(bool, "a11y", "Compile native accessibility adapters") orelse true;
    const enable_images = b.option(bool, "images", "Compile image resource support") orelse false;
    const enable_svg = b.option(bool, "svg", "Compile the optional SVG provider") orelse false;
    const enable_media = b.option(bool, "media", "Compile external media-surface providers") orelse false;
    const enable_inspector = b.option(bool, "inspector", "Compile the optional UI inspector") orelse false;
    const enable_tracing = b.option(bool, "tracing", "Compile detailed runtime tracing") orelse false;

    const options = b.addOptions();
    options.addOption(Platform, "platform", platform);
    options.addOption(Renderer, "renderer", renderer);
    options.addOption(bool, "enable_text", enable_text);
    options.addOption(bool, "enable_accessibility", enable_accessibility);
    options.addOption(bool, "enable_images", enable_images);
    options.addOption(bool, "enable_svg", enable_svg);
    options.addOption(bool, "enable_media", enable_media);
    options.addOption(bool, "enable_inspector", enable_inspector);
    options.addOption(bool, "enable_tracing", enable_tracing);

    const zigui_core = b.addModule("zigui_core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zigui = b.addModule("zigui", .{
        .root_source_file = b.path("src/zigui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = platform == .macos or platform == .linux_wayland or platform == .linux_x11,
        .imports = &.{.{
            .name = "zigui_options",
            .module = options.createModule(),
        }},
    });
    linkPlatform(zigui, platform);
    if (platform == .macos and renderer == .metal) addMetalLibrary(b, zigui, metal_toolchain);
    if (renderer == .d3d11) zigui.addAnonymousImport("zigui_hlsl_source", .{
        .root_source_file = b.path("shaders/d3d11/zigui.hlsl"),
    });

    // A bare `zig build` must compile a real consumer root rather than only
    // registering lazy modules and succeeding without analyzing ZigUI.
    const compile_check = b.addExecutable(.{
        .name = "zigui-compile-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = zigui }},
        }),
    });
    b.default_step.dependOn(&compile_check.step);

    // Keep the dependency-free engine contract honest. Merely registering a
    // lazy module is insufficient because Zig can otherwise finish a build
    // without analyzing any declaration reachable from that module.
    const core_compile_check = b.addExecutable(.{
        .name = "zigui-core-compile-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/core_compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui_core", .module = zigui_core }},
        }),
    });
    b.default_step.dependOn(&core_compile_check.step);

    const examples_step = b.step("examples", "Compile every ZigUI proof application");
    addExample(b, examples_step, zigui, target, optimize, "hello", "examples/hello.zig");
    addExample(b, examples_step, zigui, target, optimize, "scene_gallery", "examples/scene_gallery.zig");
    addExample(b, examples_step, zigui, target, optimize, "input_lab", "examples/input_lab.zig");
    addExample(b, examples_step, zigui, target, optimize, "text_lab", "examples/text_lab.zig");
    addExample(b, examples_step, zigui, target, optimize, "list_canvas_lab", "examples/list_canvas_lab.zig");
    addExample(b, examples_step, zigui, target, optimize, "window_lab", "examples/window_lab.zig");
    addExample(b, examples_step, zigui, target, optimize, "a11y_lab", "examples/a11y_lab.zig");
    addExample(b, examples_step, zigui, target, optimize, "surface_lab", "examples/surface_lab.zig");
    addExample(b, examples_step, zigui, target, optimize, "stress_lab", "examples/stress_lab.zig");

    const backend_checks = b.step("backend-checks", "Compile every native backend without host linker requirements");
    addBackendCompileCheck(b, backend_checks, optimize, .macos, .metal, .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    addBackendCompileCheck(b, backend_checks, optimize, .windows, .d3d11, .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    });
    addBackendCompileCheck(b, backend_checks, optimize, .linux_wayland, .vulkan, .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    addBackendCompileCheck(b, backend_checks, optimize, .linux_x11, .vulkan, .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });

    const unit_tests = b.addTest(.{ .root_module = zigui });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run the complete ZigUI test suite");
    test_step.dependOn(&run_unit_tests.step);

    // Conformance always uses the deterministic headless/null pair regardless
    // of the host selected above. This keeps shared contracts runnable on CI
    // without silently replacing a requested native renderer at runtime.
    const conformance_options = b.addOptions();
    conformance_options.addOption(Platform, "platform", .headless);
    conformance_options.addOption(Renderer, "renderer", .null);
    conformance_options.addOption(bool, "enable_text", true);
    conformance_options.addOption(bool, "enable_accessibility", true);
    conformance_options.addOption(bool, "enable_images", true);
    conformance_options.addOption(bool, "enable_svg", true);
    conformance_options.addOption(bool, "enable_media", true);
    conformance_options.addOption(bool, "enable_inspector", true);
    conformance_options.addOption(bool, "enable_tracing", true);
    const conformance_zigui = b.addModule("zigui_conformance", .{
        .root_source_file = b.path("src/zigui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "zigui_options",
            .module = conformance_options.createModule(),
        }},
    });
    const conformance = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = conformance_zigui }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(conformance).step);

    // Linux wire formats are target-independent byte contracts. Exercise them
    // on every host even when the selected application backend is not Linux.
    const protocol_conformance = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/protocol_conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = conformance_zigui }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(protocol_conformance).step);

    // Shader conformance is host-runnable. Vulkan modules are generated by
    // the same in-tree writer used by Linux, while the native Metal/HLSL
    // declarations are embedded as data so ABI drift is caught on every host.
    const shader_test_root = b.createModule(.{
        .root_source_file = b.path("tests/shader_conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigui", .module = conformance_zigui }},
    });
    shader_test_root.addAnonymousImport("zigui_metal_source", .{ .root_source_file = b.path("shaders/metal/zigui.metal") });
    shader_test_root.addAnonymousImport("zigui_hlsl_source", .{ .root_source_file = b.path("shaders/d3d11/zigui.hlsl") });
    const shader_conformance = b.addTest(.{ .root_module = shader_test_root });
    test_step.dependOn(&b.addRunArtifact(shader_conformance).step);

    const stress_check = b.addExecutable(.{
        .name = "zigui-stress-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/stress_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = conformance_zigui }},
        }),
    });
    const stress_step = b.step("stress", "Run 10,000 deterministic retained and paint-only frames");
    stress_step.dependOn(&b.addRunArtifact(stress_check).step);
}

fn addMetalLibrary(b: *std.Build, module: *std.Build.Module, toolchain: ?[]const u8) void {
    const compile = if (toolchain) |root|
        b.addSystemCommand(&.{ b.pathJoin(&.{ root, "usr", "bin", "metal" }), "-fmodules-cache-path=.zig-cache/metal-module-cache", "-c" })
    else
        b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metal", "-fmodules-cache-path=.zig-cache/metal-module-cache", "-c" });
    compile.addFileArg(b.path("shaders/metal/zigui.metal"));
    compile.addArg("-o");
    const air = compile.addOutputFileArg("zigui.air");

    const link = if (toolchain) |root|
        b.addSystemCommand(&.{b.pathJoin(&.{ root, "usr", "bin", "metallib" })})
    else
        b.addSystemCommand(&.{ "xcrun", "-sdk", "macosx", "metallib" });
    link.addFileArg(air);
    link.addArg("-o");
    const library = link.addOutputFileArg("zigui.metallib");
    module.addAnonymousImport("zigui_metal_library", .{ .root_source_file = library });
}

fn resolvePlatform(requested: Platform, os: std.Target.Os.Tag) Platform {
    if (requested != .auto) return requested;
    return switch (os) {
        .macos => .macos,
        .windows => .windows,
        .linux => .linux_wayland,
        else => .headless,
    };
}

fn resolveRenderer(requested: Renderer, platform: Platform) Renderer {
    if (requested != .auto) return requested;
    return switch (platform) {
        .auto => unreachable,
        .headless => .null,
        .macos => .metal,
        .windows => .d3d11,
        .linux_wayland, .linux_x11 => .vulkan,
    };
}

fn validateCombination(platform: Platform, renderer: Renderer) void {
    const valid = switch (platform) {
        .auto => false,
        .headless => renderer == .null,
        .macos => renderer == .metal,
        .windows => renderer == .d3d11,
        .linux_wayland, .linux_x11 => renderer == .vulkan,
    };
    if (!valid) @panic("invalid ZigUI platform and renderer combination");
}

fn linkPlatform(module: *std.Build.Module, platform: Platform) void {
    switch (platform) {
        .auto => unreachable,
        .headless => {},
        .macos => {
            module.linkFramework("AppKit", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("CoreGraphics", .{});
            module.linkFramework("CoreVideo", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("Metal", .{});
            module.linkFramework("QuartzCore", .{});
            module.linkSystemLibrary("objc", .{});
        },
        .windows => {
            inline for (&.{
                "comdlg32",
                "d3d11",
                "dcomp",
                "dxgi",
                "gdi32",
                "imm32",
                "ole32",
                "oleaut32",
                "shell32",
                "shcore",
                "uiautomationcore",
                "user32",
            }) |library| module.linkSystemLibrary(library, .{});
        },
        .linux_wayland => {
            // Protocol clients, text, keyboard input, accessibility transport,
            // and Vulkan dispatch are implemented in-tree. The native Vulkan
            // loader is opened at runtime through Zig's standard library.
        },
        .linux_x11 => {
            // Protocol clients, text, keyboard input, accessibility transport,
            // and Vulkan dispatch are implemented in-tree. The native Vulkan
            // loader is opened at runtime through Zig's standard library.
        },
    }
}

fn addExample(
    b: *std.Build,
    examples_step: *std.Build.Step,
    zigui: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
) void {
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = zigui }},
        }),
    });
    if (target.result.os.tag == .windows) executable.subsystem = .windows;
    examples_step.dependOn(&executable.step);

    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name}));
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    run_step.dependOn(&run.step);
}

fn addBackendCompileCheck(
    b: *std.Build,
    checks: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    platform: Platform,
    renderer: Renderer,
    query: std.Target.Query,
) void {
    const target = b.resolveTargetQuery(query);
    const options = b.addOptions();
    options.addOption(Platform, "platform", platform);
    options.addOption(Renderer, "renderer", renderer);
    options.addOption(bool, "enable_text", true);
    options.addOption(bool, "enable_accessibility", true);
    options.addOption(bool, "enable_images", true);
    options.addOption(bool, "enable_svg", true);
    options.addOption(bool, "enable_media", true);
    options.addOption(bool, "enable_inspector", true);
    options.addOption(bool, "enable_tracing", true);

    const framework = b.createModule(.{
        .root_source_file = b.path("src/zigui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = platform == .macos or platform == .linux_wayland or platform == .linux_x11,
        .imports = &.{.{ .name = "zigui_options", .module = options.createModule() }},
    });
    if (renderer == .metal) framework.addAnonymousImport("zigui_metal_library", .{
        .root_source_file = b.path("shaders/metal/zigui.metal"),
    });
    if (renderer == .d3d11) framework.addAnonymousImport("zigui_hlsl_source", .{
        .root_source_file = b.path("shaders/d3d11/zigui.hlsl"),
    });

    const object = b.addObject(.{
        .name = b.fmt("zigui-{s}-{s}-check", .{ @tagName(platform), @tagName(renderer) }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = framework }},
        }),
    });
    checks.dependOn(&object.step);
}
