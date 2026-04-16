//! Uninstall command — remove an installed Zig version.
//! Deletes the version directory from the data directory.
//! Blocks removal of the currently active version and suggests switching first.

const std = @import("std");
const zvm_mod = @import("../core/zvm.zig");
const terminal = @import("../core/terminal.zig");

/// Remove an installed Zig version.
/// Checks if the version exists and blocks removal if it's currently active.
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

    // Block removal if this is the currently active version
    if (zvm.getActiveVersion(allocator)) |active| {
        defer allocator.free(active);
        if (std.mem.eql(u8, active, version)) {
            try terminal.printError(stderr, "Cannot remove the active version.");

            // List other installed versions so user can pick one to switch to
            var versions = zvm.getInstalledVersions(allocator) catch return;
            defer {
                for (versions.items) |v| allocator.free(v);
                versions.deinit(allocator);
            }

            // Collect non-active versions
            var others: std.ArrayList([]const u8) = .empty;
            defer others.deinit(allocator);
            for (versions.items) |ver| {
                if (!std.mem.eql(u8, ver, version)) {
                    try others.append(allocator, ver);
                }
            }

            if (others.items.len > 0) {
                try stderr.print("Switch to another version first:\n", .{});
                try stderr.flush();
                for (others.items) |ver| {
                    try stdout.print("  {s}\n", .{ver});
                }
            } else {
                try stderr.print("No other versions available. Install one first:\n", .{});
                try stderr.print("  zvm install <version>\n", .{});
            }
            try stderr.flush();
            try stdout.flush();
            return;
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
