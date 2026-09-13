const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pubgrub", .{
        .root_source_file = b.path("src/pubgrub.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pubgrub", .module = mod }},
        }),
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const fmt_step = b.step("fmt-check", "Check source formatting");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon", "examples", "test" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);

    const example = b.addExecutable(.{
        .name = "resolve-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/resolve_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pubgrub", .module = mod }},
        }),
    });
    const example_step = b.step("example", "Run the resolve demo example");
    example_step.dependOn(&b.addRunArtifact(example).step);
}
