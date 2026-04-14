const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Embed version and git commit hash at build time
    // Default "0.0.1" ensures local builds always have a lower version than
    // any released version, so `zvm upgrade` can detect and perform the update.
    const version = b.option(
        []const u8,
        "version",
        "Semantic version (e.g. 0.2.0). In CI, pass the git tag. Locally defaults to git describe or \"0.0.1\".",
    ) orelse blk: {
        const tag = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "git", "describe", "--tags", "--abbrev=0" },
        }) catch break :blk "0.0.1";
        switch (tag.term) {
            .Exited => |code| if (code != 0) break :blk "0.0.1",
            else => break :blk "0.0.1",
        }
        const trimmed = std.mem.trim(u8, tag.stdout, " \n\r");
        if (trimmed.len == 0) break :blk "0.0.1";
        break :blk if (trimmed[0] == 'v') trimmed[1..] else trimmed;
    };

    const git_commit = blk: {
        const result = std.process.Child.run(.{
            .allocator = b.allocator,
            .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        }) catch break :blk "unknown";
        break :blk std.mem.trim(u8, result.stdout, " \n\r");
    };

    const exe = b.addExecutable(.{
        .name = "zvm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "git_commit", git_commit);
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
