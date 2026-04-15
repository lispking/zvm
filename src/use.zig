//! Use command — switch the active Zig version.
//! Updates the bin symlink in the data directory to point to the requested version directory.

const std = @import("std");
const zvm_mod = @import("zvm.zig");

/// Switch to an installed Zig version by updating the bin symlink.
/// Prints an error if the requested version is not installed.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    flags: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = allocator;
    _ = flags;
    _ = stderr;

    if (!zvm.isVersionInstalled(version)) {
        try stdout.print("Zig {s} is not installed. Run 'zvm install {s}' first.\n", .{ version, version });
        try stdout.flush();
        return;
    }

    try zvm.setBin(version);
    try stdout.print("Now using Zig {s}\n", .{version});
    try stdout.flush();
}
