//! Archive extraction for .tar.xz and .zip files.
//! Uses the `tar` CLI for .tar.xz (stdlib xz has compile issues in Zig 0.16.0)
//! and std.zip for .zip archives.

const std = @import("std");
const builtin = @import("builtin");

/// Extract a .tar.xz archive using the system `tar` command.
pub fn extractTarXz(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, output_dir: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "tar", "-xf", archive_path, "-C", output_dir },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.ExtractionFailed;
    }
}

/// Extract a .zip archive using Zig's stdlib zip implementation.
pub fn extractZip(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, output_dir: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);

    var reader_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buf);

    var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();

    var out_dir = try std.Io.Dir.cwd().openDir(io, output_dir, .{});
    defer out_dir.close(io);

    try std.zip.extract(out_dir, &reader, .{
        .diagnostics = &diagnostics,
        .allow_backslashes = true,
    });
}

/// Extract an archive based on its file extension.
/// Supports: .tar.xz, .zip, .tar
pub fn extractArchive(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, output_dir: []const u8) !void {
    if (std.mem.endsWith(u8, archive_path, ".tar.xz")) {
        try extractTarXz(allocator, io, archive_path, output_dir);
    } else if (std.mem.endsWith(u8, archive_path, ".zip")) {
        try extractZip(allocator, io, archive_path, output_dir);
    } else if (std.mem.endsWith(u8, archive_path, ".tar")) {
        // Plain tar using CLI
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xf", archive_path, "-C", output_dir },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            return error.ExtractionFailed;
        }
    } else {
        return error.ExtractionFailed;
    }
}
