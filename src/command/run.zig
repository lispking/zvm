//! Run command — execute a specific Zig version without switching the default.
//! Spawns the zig binary from the requested version directory as a child process.

const std = @import("std");
const zvm_mod = @import("../core/zvm.zig");
const Console = @import("../core/Console.zig");

/// Run a Zig command using a specific installed version.
/// All arguments after the version are passed through to the zig binary.
/// The child process inherits stdin/stdout/stderr from the current process.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    args: []const []const u8,
    console: Console,
) !void {
    if (!zvm.isVersionInstalled(version)) {
        console.err("Zig {s} is not installed. Run 'zvm install {s}' first.", .{ version, version });
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
        console.fatal("Failed to spawn zig {s}", .{version});
    };
    const term = child.wait(zvm.io) catch {
        std.process.exit(1);
    };

    // Propagate exit code
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => {
            console.println(.stderr, "Process killed by signal", .{});
            console.flush(.stderr);
            std.process.exit(1);
        },
        else => std.process.exit(1),
    }
}
