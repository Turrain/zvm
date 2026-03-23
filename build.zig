const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main zvm binary
    const exe = b.addExecutable(.{
        .name = "zvm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Proxy launcher binary (installed as ~/.zvm/bin/zig)
    const proxy = b.addExecutable(.{
        .name = "zvm-proxy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proxy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(proxy);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zvm");
    run_step.dependOn(&run_cmd.step);

    // Tests for the main module
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Tests for the proxy module
    const proxy_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proxy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
    test_step.dependOn(&b.addRunArtifact(proxy_tests).step);
}
