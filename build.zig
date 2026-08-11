//
// Copyright (c) 2026 Bitdancer (github.com/RealBitdancer).
// SPDX-License-Identifier: MIT
//

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseSafe: safety checks stay on for untrusted music files.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default ReleaseSafe)",
    ) orelse .ReleaseSafe;

    const strip = b.option(bool, "strip", "Strip debug information (default false)") orelse false;

    const opal_dep = b.dependency("opal", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const zaudio_dep = b.dependency("zaudio", .{
        .target = target,
        .optimize = optimize,
    });

    const app_name = @tagName(@import("build.zig.zon").name);
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    options.addOption([]const u8, "name", app_name);
    options.addOption([]const u8, "brand", @import("build.zig.zon").brand);

    const deps: Deps = .{
        .options = options,
        .vaxis = vaxis_dep,
        .opal = opal_dep,
        .zaudio = zaudio_dep,
    };

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    addModuleImports(exe_mod, deps);

    addMacosSdkPaths(b, exe_mod, target);

    const exe = b.addExecutable(.{
        .name = app_name,
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addModuleImports(test_mod, deps);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}

// zaudio propagates its framework links to consumers but not the search path,
// so the executable needs its own. An explicit -Dtarget makes Zig treat even a
// macOS host build as cross-compilation and skip the xcrun SDK probe, so this
// is required on macOS too.
fn addMacosSdkPaths(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos) return;
    const sdk = b.lazyDependency("system_sdk", .{}) orelse return;
    mod.addFrameworkPath(sdk.path("macos12/System/Library/Frameworks"));
    mod.addSystemIncludePath(sdk.path("macos12/usr/include"));
    mod.addLibraryPath(sdk.path("macos12/usr/lib"));
}

const Deps = struct {
    options: *std.Build.Step.Options,
    vaxis: *std.Build.Dependency,
    opal: *std.Build.Dependency,
    zaudio: *std.Build.Dependency,
};

fn addModuleImports(mod: *std.Build.Module, deps: Deps) void {
    mod.addOptions("build_options", deps.options);
    mod.addImport("vaxis", deps.vaxis.module("vaxis"));
    mod.addImport("opal", deps.opal.module("opal"));
    mod.addImport("zaudio", deps.zaudio.module("root"));
    mod.linkLibrary(deps.zaudio.artifact("miniaudio"));
    mod.link_libc = true;
}
