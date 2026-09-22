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
    if (b.option(bool, "verbose-tests", "Use the terminal test runner for individual test output") orelse false) {
        run_tests.test_runner_mode = false;
        run_tests.stdio = .inherit;
        run_tests.disable_zig_progress = true;
    }
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_tests.step);

    const examples = .{
        .{ "read", "example", "Read an existing stream: -- BASE_URL BUCKET STREAM" },
        .{ "tail", "tail", "Tail an existing stream: -- BASE_URL BUCKET STREAM" },
    };
    inline for (examples) |entry| {
        const example = b.addExecutable(.{
            .name = "ursula-" ++ entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ entry[0] ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ursula", .module = ursula }},
            }),
        });
        // Compile public API examples without contacting a server during tests.
        test_step.dependOn(&example.step);
        const run_example = b.addRunArtifact(example);
        run_example.addPassthruArgs();
        b.step(entry[1], entry[2]).dependOn(&run_example.step);
    }
}
