//! Clean command — remove build artifacts from the cache directory.
//! Deletes downloaded .zip, .xz, .tar, and .tar.xz files from the XDG cache dir.

const std = @import("std");
const zvm_mod = @import("zvm.zig");

/// Remove archive files (.zip, .xz, .tar, .tar.xz) from the cache directory.
/// These are leftover files from downloads that are no longer needed after extraction.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = allocator;
    _ = stderr;

    const extensions = [_][]const u8{ ".zip", ".xz", ".tar", ".tar.xz" };

    var dir = try std.Io.Dir.cwd().openDir(zvm.io, zvm.cache_dir, .{ .iterate = true });
    defer dir.close(zvm.io);

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(zvm.io)) |entry| {
        if (entry.kind != .file) continue;
        for (extensions) |ext| {
            if (std.mem.endsWith(u8, entry.name, ext)) {
                dir.deleteFile(zvm.io, entry.name) catch continue;
                count += 1;
                break;
            }
        }
    }

    try stdout.print("Cleaned {d} artifact(s)\n", .{count});
    try stdout.flush();
}
