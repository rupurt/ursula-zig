const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ursula = b.addModule("ursula", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "ursula",
        .linkage = .static,
        .root_module = ursula,
    });
    b.installArtifact(library);

    const unit_tests = b.addTest(.{
        .root_module = ursula,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_tests.step);
}
