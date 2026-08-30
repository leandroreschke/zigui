const std = @import("std");
const builtin = @import("builtin");

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
    const dependency_macos_sdk_path = b.option(
        []const u8,
        "macos_sdk_path",
        "Path to the macOS SDK supplied through a package dependency",
    );
    const macos_sdk_path = dependency_macos_sdk_path orelse b.option(
        []const u8,
        "macos-sdk-path",
        "Path to the macOS SDK used by external consumers",
    ) orelse "";

    const platform = resolvePlatform(requested_platform, target.result.os.tag);
    const renderer = resolveRenderer(requested_renderer, platform);
    validateTarget(platform, target.result.os.tag);
    validateCombination(platform, renderer);
    const compile_only = b.option(bool, "compile-only", "Compile test and stress artifacts without executing them") orelse false;
    // `Query.isNative` includes CPU, OS, ABI, version/dynamic-linker, object
    // format, and feature overrides. OS/architecture equality alone can still
    // describe a binary the build host must not execute.
    const can_run_target = !compile_only and target.query.isNative();

    const enable_text = b.option(bool, "text", "Compile native text shaping and rasterization") orelse true;
    const enable_accessibility = b.option(bool, "a11y", "Compile native accessibility adapters") orelse true;
    const enable_images = b.option(bool, "images", "Compile image resource support") orelse false;
    const enable_svg = b.option(bool, "svg", "Compile the optional SVG provider") orelse false;
    const enable_media = b.option(bool, "media", "Compile media sources and optional native playback adapters") orelse false;
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
    linkPlatform(b, zigui, platform, enable_media, enable_images);
    if (platform == .macos and macos_sdk_path.len != 0) addMacOsSdkPaths(b, zigui, macos_sdk_path);
    const selected_metal_library = if (platform == .macos and renderer == .metal)
        compileMetalLibrary(b, metal_toolchain)
    else
        null;
    if (selected_metal_library) |library| zigui.addAnonymousImport("zigui_metal_library", .{ .root_source_file = library });
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
    dependOnTest(test_step, unit_tests, run_unit_tests, can_run_target);
    if (target.result.os.tag == .macos and platform == .macos and renderer == .metal) {
        const metal_conformance = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/metal_conformance.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigui", .module = zigui }},
            }),
        });
        const run_metal_conformance = b.addRunArtifact(metal_conformance);
        dependOnTest(test_step, metal_conformance, run_metal_conformance, can_run_target);
    }
    if (target.result.os.tag == .windows and platform == .windows and renderer == .d3d11) {
        const windows_native = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/windows_native.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigui", .module = zigui }},
            }),
        });
        const run_windows_native = b.addRunArtifact(windows_native);
        dependOnTest(test_step, windows_native, run_windows_native, can_run_target);
    }

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
    conformance_zigui.addAnonymousImport("zigui_hlsl_source", .{
        .root_source_file = b.path("shaders/d3d11/zigui.hlsl"),
    });
    const conformance = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = conformance_zigui }},
        }),
    });
    const run_conformance = b.addRunArtifact(conformance);
    dependOnTest(test_step, conformance, run_conformance, can_run_target);

    // WebP is a platform capability rather than a hidden application
    // fallback. Keep the cross-target Unsupported contract in the regular
    // headless suite and force the native ImageIO path through a separate
    // macOS test root when image support is enabled.
    if (enable_images) {
        const webp_headless = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/webp_conformance.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigui", .module = conformance_zigui }},
            }),
        });
        const run_webp_headless = b.addRunArtifact(webp_headless);
        dependOnTest(test_step, webp_headless, run_webp_headless, can_run_target);
        if (target.result.os.tag == .macos and platform == .macos and renderer == .metal) {
            const webp_native = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/webp_conformance.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "zigui", .module = zigui }},
                }),
            });
            const run_webp_native = b.addRunArtifact(webp_native);
            dependOnTest(test_step, webp_native, run_webp_native, can_run_target);
        }
    }

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
    const run_protocol_conformance = b.addRunArtifact(protocol_conformance);
    dependOnTest(test_step, protocol_conformance, run_protocol_conformance, can_run_target);

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
    const run_shader_conformance = b.addRunArtifact(shader_conformance);
    dependOnTest(test_step, shader_conformance, run_shader_conformance, can_run_target);

    const shader_sdk_checks = b.step("shader-sdk-checks", "Compile native shaders with the host platform SDK");
    switch (builtin.os.tag) {
        .macos => {
            const library = selected_metal_library orelse compileMetalLibrary(b, metal_toolchain);
            library.addStepDependencies(shader_sdk_checks);
        },
        .windows => if (can_run_target)
            shader_sdk_checks.dependOn(&run_shader_conformance.step)
        else
            shader_sdk_checks.dependOn(&b.addFail(
                "Windows shader SDK checks require a native host target; omit -Dtarget or use the host-native target",
            ).step),
        else => shader_sdk_checks.dependOn(&b.addFail(
            "native shader SDK checks require a macOS Metal host or Windows D3DCompiler host",
        ).step),
    }

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
    if (can_run_target)
        stress_step.dependOn(&b.addRunArtifact(stress_check).step)
    else
        stress_step.dependOn(&stress_check.step);
}

fn dependOnTest(step: *std.Build.Step, artifact: *std.Build.Step.Compile, run: *std.Build.Step.Run, can_run: bool) void {
    step.dependOn(if (can_run) &run.step else &artifact.step);
}

fn addMacOsSdkPaths(b: *std.Build, module: *std.Build.Module, sdk_path: []const u8) void {
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "include" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr", "lib" }) });
    module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System", "Library", "Frameworks" }) });
}

fn compileMetalLibrary(b: *std.Build, toolchain: ?[]const u8) std.Build.LazyPath {
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
    return link.addOutputFileArg("zigui.metallib");
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

fn validateTarget(platform: Platform, os: std.Target.Os.Tag) void {
    const valid = switch (platform) {
        .auto => false,
        .headless => true,
        .macos => os == .macos,
        .windows => os == .windows,
        .linux_wayland, .linux_x11 => os == .linux,
    };
    if (!valid) @panic("ZigUI platform does not match the selected target operating system");
}

fn linkPlatform(
    b: *std.Build,
    module: *std.Build.Module,
    platform: Platform,
    enable_media: bool,
    enable_images: bool,
) void {
    switch (platform) {
        .auto => unreachable,
        .headless => {},
        .macos => {
            module.linkFramework("AppKit", .{});
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("CoreGraphics", .{});
            module.linkFramework("CoreImage", .{});
            module.linkFramework("CoreVideo", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("LinkPresentation", .{});
            // ImageIO is used only by the documented optional macOS WebP and
            // AVIF providers. Other targets report `Unsupported` rather than
            // linking a hidden codec.
            if (enable_images) module.linkFramework("ImageIO", .{});
            module.linkFramework("Metal", .{});
            module.linkFramework("PDFKit", .{});
            module.linkFramework("QuartzCore", .{});
            if (enable_media) {
                module.linkFramework("AVFoundation", .{});
                module.linkFramework("CoreMedia", .{});
            }
            module.linkSystemLibrary("objc", .{});
            module.addCSourceFile(.{ .file = b.path("src/platform/macos/promise_bridge.m"), .flags = &.{"-fblocks"} });
            module.addCSourceFile(.{ .file = b.path("src/platform/macos/page_capture_bridge.m"), .flags = &.{"-fblocks"} });
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
