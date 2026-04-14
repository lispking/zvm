//! HTTP client for downloading files and fetching remote content.
//! Uses Zig's std.http.Client for direct downloads, and curl subprocess when
//! a proxy is configured (Zig's HTTP client cannot handle HTTPS through HTTP
//! proxies due to missing TLS-over-CONNECT tunnel support).
//! Supports latency-based mirror selection for fastest downloads.
//! Caches preferred mirror in settings to skip probing on subsequent installs.

const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");

/// Cache TTL: 24 hours in seconds.
const MIRROR_CACHE_TTL: i64 = 86400;

/// Download a file from a URL to the given file path.
/// Uses streaming to handle large files without loading everything into memory.
pub fn downloadToFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
) !void {
    return downloadToFileWithProxy(allocator, url, dest_path, "");
}

pub fn downloadToFileWithProxy(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
    proxy_url: []const u8,
) !void {
    // When a proxy is configured, use curl which correctly handles
    // HTTPS through HTTP proxies via CONNECT tunneling + TLS.
    // Zig's std.http.Client has a known bug where it establishes the CONNECT
    // tunnel but does not upgrade to TLS, causing the connection to be closed.
    if (proxy_url.len > 0) {
        return downloadFileViaCurl(allocator, url, dest_path, proxy_url);
    }
    return downloadFileDirect(allocator, url, dest_path);
}

/// Download a file using curl subprocess (used when proxy is configured).
fn downloadFileViaCurl(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
    proxy_url: []const u8,
) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sL", "-x", proxy_url, "-o", dest_path, url },
    }) catch {
        return error.DownloadFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.DownloadFailed,
        else => return error.DownloadFailed,
    }
}

/// Download a file using Zig's built-in HTTP client (direct connection).
fn downloadFileDirect(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
) !void {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Auto-detect proxy from environment variables
    client.initDefaultProxies(allocator) catch {};

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .init(5),
    });
    defer req.deinit();

    try req.sendBodiless();

    var head_buf: [16384]u8 = undefined;
    var response = try req.receiveHead(&head_buf);

    if (response.head.status != .ok) {
        return error.DownloadFailed;
    }

    const file = try std.fs.cwd().createFile(dest_path, .{});
    defer file.close();

    var file_buf: [16384]u8 = undefined;
    var file_writer = file.writer(&file_buf);

    var reader_buf: [16384]u8 = undefined;
    const body_reader = response.reader(&reader_buf);

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
    return downloadToMemoryWithProxy(allocator, url, "");
}

pub fn downloadToMemoryWithProxy(
    allocator: std.mem.Allocator,
    url: []const u8,
    proxy_url: []const u8,
) ![]const u8 {
    if (proxy_url.len > 0) {
        return downloadMemoryViaCurl(allocator, url, proxy_url);
    }
    return downloadMemoryDirect(allocator, url);
}

/// Download content into memory using curl subprocess (used when proxy is configured).
fn downloadMemoryViaCurl(
    allocator: std.mem.Allocator,
    url: []const u8,
    proxy_url: []const u8,
) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sL", "-x", proxy_url, url },
    }) catch {
        return error.DownloadFailed;
    };
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(result.stdout);
            return error.DownloadFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.DownloadFailed;
        },
    }
    return result.stdout;
}

/// Download content into memory using Zig's built-in HTTP client (direct connection).
fn downloadMemoryDirect(
    allocator: std.mem.Allocator,
    url: []const u8,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    client.initDefaultProxies(allocator) catch {};

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

/// A candidate URL with its measured latency.
const MirrorCandidate = struct {
    url: []const u8,
    latency_ns: u64,
    owned: bool,
};

/// Measure the latency of a URL by sending a HEAD request.
/// Returns the round-trip time in nanoseconds, or null if the request failed.
fn measureLatency(allocator: std.mem.Allocator, url: []const u8, proxy_url: []const u8) ?u64 {
    if (proxy_url.len > 0) {
        return measureLatencyViaCurl(allocator, url, proxy_url);
    }
    return measureLatencyDirect(allocator, url);
}

/// Measure latency using curl subprocess (when proxy is configured).
fn measureLatencyViaCurl(allocator: std.mem.Allocator, url: []const u8, proxy_url: []const u8) ?u64 {
    const start = std.time.Instant.now() catch return null;
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sI", "-x", proxy_url, "-o", "/dev/null", "-w", "%{http_code}", url },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const end = std.time.Instant.now() catch return null;
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    // Check HTTP status code starts with '2' (2xx)
    const status = std.mem.trim(u8, result.stdout, " \n\r");
    if (status.len < 1 or status[0] != '2') return null;
    return end.since(start);
}

/// Measure latency using Zig's built-in HTTP client (direct connection).
fn measureLatencyDirect(allocator: std.mem.Allocator, url: []const u8) ?u64 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return null;
    var req = client.request(.HEAD, uri, .{
        .redirect_behavior = .init(3),
    }) catch return null;
    defer req.deinit();

    req.sendBodiless() catch return null;

    var buf: [4096]u8 = undefined;
    const start = std.time.Instant.now() catch return null;
    const response = req.receiveHead(&buf) catch return null;
    const end = std.time.Instant.now() catch return null;

    // Accept 2xx status codes
    if (response.head.status.class() != .success) return null;

    return end.since(start);
}

/// Compare two MirrorCandidates by latency (for sorting).
fn lessThanByLatency(_: void, a: MirrorCandidate, b: MirrorCandidate) bool {
    return a.latency_ns < b.latency_ns;
}

/// Format nanoseconds as a human-readable string (e.g., "123ms", "1.2s").
fn formatLatency(buf: []u8, ns: u64) []const u8 {
    if (ns < 1000) {
        return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "?";
    } else if (ns < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.0}us", .{@as(f64, @floatFromInt(ns)) / 1000.0}) catch "?";
    } else if (ns < 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d:.0}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch "?";
    }
}

/// Select the fastest mirror by measuring latency to all candidates,
/// then download the file from the fastest responsive source.
/// If a cached preferred mirror is fresh (< 24h), try it directly first
/// to skip the probing overhead entirely.
/// Returns the actual URL that was successfully downloaded from (caller owns the memory).
pub fn attemptMirrorDownload(
    allocator: std.mem.Allocator,
    mirror_list_url: []const u8,
    original_url: []const u8,
    dest_path: []const u8,
    verbose_writer: ?*std.Io.Writer,
    settings: *settings_mod.Settings,
) ![]const u8 {
    // Extract filename once (used for constructing mirror URLs and extracting base URL)
    const filename = if (std.mem.lastIndexOfScalar(u8, original_url, '/')) |idx| original_url[idx + 1 ..] else original_url;

    // --- Cache-fast path: try cached mirror if fresh ---
    if (settings.preferred_mirror.len > 0 and settings.mirror_updated_at > 0) {
        const now = std.time.timestamp();
        const age = now - settings.mirror_updated_at;
        if (age >= 0 and age < MIRROR_CACHE_TTL) {
            const cached_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ settings.preferred_mirror, filename }) catch
                return try probeAndDownload(allocator, mirror_list_url, original_url, filename, dest_path, verbose_writer, settings);
            defer allocator.free(cached_url);

            downloadToFileWithProxy(allocator, cached_url, dest_path, settings.proxy) catch {
                // Cached mirror failed — clear cache and fall through to full probe
                settings.clearPreferredMirror(allocator);
                if (verbose_writer) |vw| {
                    try vw.print("  Cached mirror unavailable, re-probing...\n", .{});
                    try vw.flush();
                }
                return try probeAndDownload(allocator, mirror_list_url, original_url, filename, dest_path, verbose_writer, settings);
            };

            if (verbose_writer) |vw| {
                try vw.print("  from: {s} (cached)\n", .{shortUrl(settings.preferred_mirror)});
                try vw.flush();
            }
            return allocator.dupe(u8, cached_url);
        }
    }

    // No cache or stale — full probe
    return try probeAndDownload(allocator, mirror_list_url, original_url, filename, dest_path, verbose_writer, settings);
}

/// Full probe: fetch mirror list, measure latency for all candidates, download from fastest.
/// Caches the winning mirror base URL in settings on success.
fn probeAndDownload(
    allocator: std.mem.Allocator,
    mirror_list_url: []const u8,
    original_url: []const u8,
    filename: []const u8,
    dest_path: []const u8,
    verbose_writer: ?*std.Io.Writer,
    settings: *settings_mod.Settings,
) ![]const u8 {
    const proxy = settings.proxy;

    // No mirror list — download directly from the original URL
    if (mirror_list_url.len == 0) {
        try downloadToFileWithProxy(allocator, original_url, dest_path, proxy);
        return allocator.dupe(u8, original_url);
    }

    // Fetch the mirror list
    const mirror_list_content = downloadToMemoryWithProxy(allocator, mirror_list_url, proxy) catch {
        try downloadToFileWithProxy(allocator, original_url, dest_path, proxy);
        return allocator.dupe(u8, original_url);
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
        try downloadToFileWithProxy(allocator, original_url, dest_path, proxy);
        return allocator.dupe(u8, original_url);
    }

    // Build candidate list with owned URLs
    var candidates: std.ArrayList(MirrorCandidate) = .empty;
    defer candidates.deinit(allocator);

    // Measure latency for the original URL
    if (measureLatency(allocator, original_url, proxy)) |latency| {
        const owned = allocator.dupe(u8, original_url) catch unreachable;
        try candidates.append(allocator, .{ .url = owned, .latency_ns = latency, .owned = true });
    }

    // Measure latency for each mirror
    for (mirrors.items) |mirror_base| {
        const mirror_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ mirror_base, filename }) catch continue;
        defer allocator.free(mirror_url);

        if (measureLatency(allocator, mirror_url, proxy)) |latency| {
            const owned_url = allocator.dupe(u8, mirror_url) catch continue;
            try candidates.append(allocator, .{ .url = owned_url, .latency_ns = latency, .owned = true });
        }
    }

    // If no candidates responded, fall back to the original URL
    if (candidates.items.len == 0) {
        try downloadToFileWithProxy(allocator, original_url, dest_path, proxy);
        return allocator.dupe(u8, original_url);
    }

    // Sort candidates by latency (fastest first)
    std.mem.sort(MirrorCandidate, candidates.items, {}, lessThanByLatency);

    // Print latency results if verbose output is requested
    if (verbose_writer) |vw| {
        var time_buf: [64]u8 = undefined;
        try vw.print("  Probed {d} source(s):\n", .{candidates.items.len});
        for (candidates.items, 1..) |candidate, rank| {
            const time_str = formatLatency(&time_buf, candidate.latency_ns);
            const marker = if (rank == 1) " <-- fastest" else "";
            // Shorten URL for display: show only the host
            const short_url = shortUrl(candidate.url);
            try vw.print("    {d}. {s}  ({s}{s})\n", .{ rank, short_url, time_str, marker });
        }
        try vw.flush();
    }

    // Try downloading from candidates in latency order
    for (candidates.items, 0..) |candidate, idx| {
        downloadToFileWithProxy(allocator, candidate.url, dest_path, proxy) catch {
            continue;
        };
        // Success — cache the winning mirror base URL for next time
        const base_url = extractBaseUrl(candidate.url);
        if (base_url.len > 0) {
            settings.setPreferredMirror(allocator, base_url);
        }
        // Return the winning URL (caller owns it)
        const result = candidate.url;
        // Free all other candidate URLs
        for (candidates.items, 0..) |c, i| {
            if (i != idx) allocator.free(c.url);
        }
        // Prevent defer from freeing the returned URL
        candidates.items.len = 0;
        return result;
    }

    // All candidates failed during actual download — last resort
    for (candidates.items) |c| {
        allocator.free(c.url);
    }
    candidates.items.len = 0;

    try downloadToFileWithProxy(allocator, original_url, dest_path, proxy);
    return allocator.dupe(u8, original_url);
}

/// Extract the base URL (scheme + host + path up to last '/') from a full URL.
/// e.g. "https://mirror.example.com/path/file.tar.gz" → "https://mirror.example.com/path"
fn extractBaseUrl(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |idx| {
        return url[0..idx];
    }
    return url;
}

/// Extract the host part of a URL for concise display.
fn shortUrl(url: []const u8) []const u8 {
    // Skip "https://"
    const start: usize = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        0;
    // Find end of host (first '/' after scheme)
    const rest = url[start..];
    for (rest, 0..) |ch, i| {
        if (ch == '/') return rest[0..i];
    }
    return rest;
}
