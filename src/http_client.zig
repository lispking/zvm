//! HTTP client for downloading files and fetching remote content.
//! Uses Zig's std.http.Client for all network operations.
//! Supports mirror-based downloads for faster distribution.

const std = @import("std");
const builtin = @import("builtin");

/// Download a file from a URL to the given file path.
/// Uses streaming to handle large files without loading everything into memory.
pub fn downloadToFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .init(5),
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) return error.DownloadFailed;

    const file = try std.fs.cwd().createFile(dest_path, .{});
    defer file.close();

    var file_buf: [8192]u8 = undefined;
    var file_writer = file.writer(&file_buf);

    var reader_buf: [8192]u8 = undefined;
    const body_reader = response.reader(&reader_buf);

    // Use streamRemaining to ensure ALL bytes are written, including the last partial chunk.
    // Note: Reader.take(n) drops the final partial chunk in Zig 0.15.x, so streamRemaining
    // is required for correctness (e.g., SHA256 verification depends on every byte).
    _ = body_reader.streamRemaining(&file_writer.interface) catch |err| switch (err) {
        error.ReadFailed => {
            const body_err = response.bodyErr();
            if (body_err) |be| return be;
            return error.DownloadFailed;
        },
        else => return err,
    };
    try file_writer.interface.flush();
}

/// Download content from a URL into memory.
/// Uses a fixed 1MB buffer for the response body.
/// Caller owns returned memory.
pub fn downloadToMemory(
    allocator: std.mem.Allocator,
    url: []const u8,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Use a fixed buffer approach for efficiency
    var body_buf: [1024 * 1024]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body_writer,
    });

    if (result.status != .ok) return error.DownloadFailed;

    const body = body_writer.buffered();
    return allocator.dupe(u8, body);
}

/// Attempt to download a file using community mirrors before falling back to the original URL.
/// Mirrors are fetched from a URL that returns one mirror base URL per line.
/// The filename is extracted from the original URL and appended to each mirror base.
pub fn attemptMirrorDownload(
    allocator: std.mem.Allocator,
    mirror_list_url: []const u8,
    original_url: []const u8,
    dest_path: []const u8,
) !void {
    // Try original URL first if mirror list is empty
    if (mirror_list_url.len == 0) {
        return downloadToFile(allocator, original_url, dest_path);
    }

    // Fetch the mirror list
    const mirror_list_content = downloadToMemory(allocator, mirror_list_url) catch {
        return downloadToFile(allocator, original_url, dest_path);
    };
    defer allocator.free(mirror_list_content);

    // Parse mirrors (one URL per line)
    var mirrors: std.ArrayList([]const u8) = .empty;
    defer mirrors.deinit(allocator);

    var lines = std.mem.splitSequence(u8, mirror_list_content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        try mirrors.append(allocator, trimmed);
    }

    if (mirrors.items.len == 0) {
        return downloadToFile(allocator, original_url, dest_path);
    }

    // Extract the filename from the original URL (e.g., "zig-linux-x86_64-0.13.0.tar.xz")
    const filename = if (std.mem.lastIndexOfScalar(u8, original_url, '/'))
        |idx| original_url[idx + 1 ..]
    else
        original_url;

    // Try each mirror in order
    for (mirrors.items) |mirror_base| {
        const mirror_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ mirror_base, filename }) catch continue;
        defer allocator.free(mirror_url);

        downloadToFile(allocator, mirror_url, dest_path) catch {
            continue;
        };
        return;
    }

    // All mirrors failed, fall back to original URL
    return downloadToFile(allocator, original_url, dest_path);
}
