//! Uninstall command — remove an installed Zig version.
//! Deletes the version directory from the data directory and warns if it's the active version.

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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = zvm.versionPath(&buf, version);

    // Verify the version is installed
    std.Io.Dir.cwd().access(zvm.io, path, .{}) catch {
        try stderr.print("Zig {s} is not installed.\n", .{version});
        try stderr.flush();
        return;
    };

    // Warn if this is the currently active version
    if (zvm.getActiveVersion(allocator)) |active| {
        defer allocator.free(active);
        if (std.mem.eql(u8, active, version)) {
            try stderr.print("Warning: {s} is the active version. Remove the symlink first.\n", .{version});
            try stderr.flush();
        }
    }

    // Delete the version directory tree
    std.Io.Dir.cwd().deleteTree(zvm.io, path) catch |err| {
        try stderr.print("Failed to remove {s}: {}\n", .{ version, err });
        try stderr.flush();
        return;
    };

    try stdout.print("Uninstalled Zig {s}\n", .{version});
    try stdout.flush();
}
