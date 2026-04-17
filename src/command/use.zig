//! Use command — switch the active Zig version.
//! Updates the bin symlink in the data directory to point to the requested version directory.

const std = @import("std");
const zvm_mod = @import("../core/zvm.zig");
const Console = @import("../core/Console.zig");

/// Switch to an installed Zig version by updating the bin symlink.
/// Prints an error if the requested version is not installed.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    flags: anytype,
    console: Console,
) !void {
    _ = allocator;
    _ = flags;

    if (!zvm.isVersionInstalled(version)) {
        console.plain("Zig {s} is not installed. Run 'zvm install {s}' first.", .{ version, version });
        return;
    }

    try zvm.setBin(version);
    console.plain("Now using Zig {s}", .{version});
}
