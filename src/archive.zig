//! Archive extraction for .tar.xz and .zip files.
//! Uses the `tar` CLI for .tar.xz (stdlib xz has compile issues in Zig 0.15.2)
//! and std.zip for .zip archives.

const std = @import("std");
const builtin = @import("builtin");

/// Extract a .tar.xz archive using the system `tar` command.
/// This is the primary extraction method on Unix platforms.
pub fn extractTarXz(allocator: std.mem.Allocator, archive_path: []const u8, output_dir: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xf", archive_path, "-C", output_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ExtractionFailed;
    }
}

/// Extract a .zip archive using Zig's stdlib zip implementation.
pub fn extractZip(allocator: std.mem.Allocator, archive_path: []const u8, output_dir: []const u8) !void {
    _ = output_dir;
    const file = try std.fs.cwd().openFile(archive_path, .{});
    defer file.close();

    var reader_buf: [8192]u8 = undefined;
    var reader = file.reader(&reader_buf);

    var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();

    try std.zip.extract(std.fs.cwd(), &reader, .{
        .diagnostics = &diagnostics,
    });
}

/// Extract an archive based on its file extension.
/// Supports: .tar.xz, .zip, .tar
pub fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, output_dir: []const u8) !void {
    if (std.mem.endsWith(u8, archive_path, ".tar.xz")) {
        try extractTarXz(allocator, archive_path, output_dir);
    } else if (std.mem.endsWith(u8, archive_path, ".zip")) {
        try extractZip(allocator, archive_path, output_dir);
    } else if (std.mem.endsWith(u8, archive_path, ".tar")) {
        // Plain tar using CLI
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "tar", "-xf", archive_path, "-C", output_dir },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.ExtractionFailed;
        }
    } else {
        return error.ExtractionFailed;
    }
}
