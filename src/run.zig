//! Run command — execute a specific Zig version without switching the default.
//! Spawns the zig binary from the requested version directory as a child process.

const std = @import("std");
const zvm_mod = @import("zvm.zig");

/// Run a Zig command using a specific installed version.
/// All arguments after the version are passed through to the zig binary.
/// The child process inherits stdin/stdout/stderr from the current process.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stdout;
    _ = stderr;

    if (!zvm.isVersionInstalled(version)) {
        var buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(zvm.io, &buf);
        try stderr_writer.interface.print("Zig {s} is not installed. Run 'zvm install {s}' first.\n", .{ version, version });
        try stderr_writer.interface.flush();
        std.process.exit(1);
    }

    // Build the zig binary path: data_dir/<version>/zig
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const version_dir = zvm.versionPath(&path_buf, version);
    const zig_path = try std.fmt.allocPrint(allocator, "{s}/zig", .{version_dir});
    defer allocator.free(zig_path);

    // Build argv: [zig_path, arg1, arg2, ...]
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, zig_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    // Spawn child process with inherited stdio (default behavior)
    var child = std.process.spawn(zvm.io, .{
        .argv = argv.items,
    }) catch {
        var buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(zvm.io, &buf);
        try stderr_writer.interface.print("Failed to spawn zig {s}\n", .{version});
        try stderr_writer.interface.flush();
        std.process.exit(1);
    };
    const term = child.wait(zvm.io) catch {
        std.process.exit(1);
    };

    // Propagate exit code
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => {
            std.debug.print("Process killed by signal\n", .{});
            std.process.exit(1);
        },
        else => std.process.exit(1),
    }
}
