const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build-time options visible to the code as @import("build_options").
    // `testdata_dir` lets tests find testdata/ no matter the working directory.
    const options = b.addOptions();
    options.addOptionPathDirectory("testdata_dir", b.path("testdata"));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.linkSystemLibrary("opus", .{});

    // libopus headers as a Zig module, @import("c") (@cImport is gone in 0.17).
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("c", c.createModule());
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "goldsrc-hltv-voice",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run goldsrc-hltv-voice (zig build run -- args)");
    run_step.dependOn(&run_cmd.step);

    // One test binary for the whole tree: src/main.zig references every file,
    // so `zig build test` runs every file's tests.
    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
