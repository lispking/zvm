//! Uninstall command — remove an installed Zig version.
//! Deletes the version directory from ~/.zvm/ and warns if it's the active version.

const std = @import("std");
const zvm_mod = @import("zvm.zig");

/// Remove an installed Zig version.
/// Checks if the version exists and warns if it's currently active.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = allocator;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = zvm.versionPath(&buf, version);

    // Verify the version is installed
    std.fs.cwd().access(path, .{}) catch {
        try stderr.print("Zig {s} is not installed.\n", .{version});
        try stderr.flush();
        return;
    };

    // Warn if this is the currently active version
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_path = zvm.binPath(&link_buf);
    var target_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    if (std.posix.readlink(bin_path, &target_buf)) |target| {
        if (std.mem.containsAtLeast(u8, target, 1, version)) {
            try stderr.print("Warning: {s} is the active version. Remove the symlink first.\n", .{version});
            try stderr.flush();
        }
    } else |_| {}

    // Delete the version directory tree
    std.fs.cwd().deleteTree(path) catch |err| {
        try stderr.print("Failed to remove {s}: {}\n", .{ version, err });
        try stderr.flush();
        return;
    };

    try stdout.print("Uninstalled Zig {s}\n", .{version});
    try stdout.flush();
}
