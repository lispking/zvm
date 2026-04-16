//! HTTP client for downloading files and fetching remote content.
//! Uses Zig's std.http.Client for all requests, with built-in proxy support
//! (HTTP CONNECT tunneling for HTTPS through HTTP proxies).
//! Supports latency-based mirror selection for fastest downloads.
//! Caches preferred mirror in settings to skip probing on subsequent installs.

const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("../core/settings.zig");
const mirror_probe = @import("mirror_probe.zig");

/// Cache TTL: 24 hours in seconds.
const MIRROR_CACHE_TTL: i64 = 86400;

/// Initialize an std.http.Client with proxy configuration.
/// If `proxy_url` is non-empty, parses it and sets both http_proxy and https_proxy.
/// Otherwise, auto-detects proxy from environment variables.
fn initClientProxy(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    proxy_url: []const u8,
) void {
    if (proxy_url.len > 0) {
        setProxyFromUrl(client, allocator, proxy_url) catch {};
    } else {
        client.initDefaultProxies(allocator, environ_map) catch {};
    }
}

/// Parse a proxy URL string and configure the client's http_proxy/https_proxy fields.
fn setProxyFromUrl(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    proxy_url: []const u8,
) !void {
    const uri = std.Uri.parse(proxy_url) catch
        std.Uri.parseAfterScheme("http", proxy_url) catch return;

    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
    const raw_host = uri.getHostAlloc(allocator) catch return;

    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) a: {
        const auth_buf = try allocator.alloc(u8, std.http.Client.basic_authorization.valueLengthFromUri(uri));
        errdefer allocator.free(auth_buf);
        std.debug.assert(std.http.Client.basic_authorization.value(uri, auth_buf).len == auth_buf.len);
        break :a auth_buf;
    } else null;

    const proxy = try allocator.create(std.http.Client.Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = raw_host,
        .authorization = authorization,
        .port = uri.port orelse switch (protocol) {
            .plain => @as(u16, 80),
            .tls => @as(u16, 443),
        },
        .supports_connect = true,
    };

    // Set both proxy fields so HTTP and HTTPS traffic go through the proxy
    client.http_proxy = proxy;
    client.https_proxy = proxy;
}

/// Download a file from a URL to the given file path.
/// Uses streaming to handle large files without loading everything into memory.
pub fn downloadToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    dest_path: []const u8,
) !void {
    return downloadToFileWithProxy(allocator, io, environ_map, url, dest_path, "", null);
}

pub fn downloadToFileWithProxy(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    dest_path: []const u8,
    proxy_url: []const u8,
    progress_writer: ?*std.Io.Writer,
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    initClientProxy(&client, allocator, environ_map, proxy_url);

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

    const total: ?u64 = response.head.content_length;
    const file = try std.Io.Dir.cwd().createFile(io, dest_path, .{});
    defer file.close(io);

    var file_buf: [16384]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);

    var reader_buf: [16384]u8 = undefined;
    const body_reader = response.reader(&reader_buf);

    if (progress_writer) |pw| {
        // Download with progress display
        const chunk_limit: std.Io.Limit = .limited(64 * 1024);
        var downloaded: u64 = 0;
        const start_ns = std.Io.Timestamp.now(io, .awake);
        var last_update_ns: u64 = 0;

        while (true) {
            const n = body_reader.stream(&file_writer.interface, chunk_limit) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| {
                    if (err == error.ReadFailed) {
                        if (response.bodyErr()) |be| return be;
                    }
                    return e;
                },
            };
            downloaded += n;

            // Update progress at most ~10 times per second
            const now_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
            if (now_ns - last_update_ns > 100_000_000 or (total != null and downloaded >= total.?)) {
                last_update_ns = now_ns;
                printProgress(pw, io, downloaded, total, start_ns) catch {};
            }
        }
        try file_writer.interface.flush();

        // Final progress update and newline
        const final_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
        if (final_ns > 0) {
            printProgress(pw, io, downloaded, total, start_ns) catch {};
            try pw.writeByte('\n');
            try pw.flush();
        }
    } else {
        // Download without progress (original behavior)
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
}

/// Print a single-line progress update (overwrites current line with \r).
fn printProgress(
    writer: *std.Io.Writer,
    io: std.Io,
    downloaded: u64,
    total: ?u64,
    start_ns: std.Io.Timestamp,
) !void {
    var dl_buf: [32]u8 = undefined;
    const dl_str = formatBytes(&dl_buf, downloaded);

    const elapsed_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    var speed_buf: [32]u8 = undefined;
    const speed_str: []const u8 = if (elapsed_s > 0.0) blk: {
        const speed = @as(f64, @floatFromInt(downloaded)) / elapsed_s;
        break :blk formatBytes(&speed_buf, @intFromFloat(speed));
    } else "?B";

    if (total) |t| {
        var total_buf: [32]u8 = undefined;
        const total_str = formatBytes(&total_buf, t);
        const pct = @min(@divFloor(downloaded * 100, t), 100);
        try writer.print("\x1b[2K\r  {d:>3}% [{s} / {s}] {s}/s", .{ pct, dl_str, total_str, speed_str });
    } else {
        try writer.print("\x1b[2K\r  {s}  {s}/s", .{ dl_str, speed_str });
    }
    try writer.flush();
}

/// Download content from a URL into memory.
/// Caller owns returned memory.
pub fn downloadToMemory(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
) ![]const u8 {
    return downloadToMemoryWithProxy(allocator, io, environ_map, url, "");
}

pub fn downloadToMemoryWithProxy(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    url: []const u8,
    proxy_url: []const u8,
) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    initClientProxy(&client, allocator, environ_map, proxy_url);

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

/// Format a byte count as a human-readable string (e.g., "1.5MB", "234KB").
fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;
    if (bytes < KB) {
        return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
    } else if (bytes < MB) {
        return std.fmt.bufPrint(buf, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(KB))}) catch "?";
    } else if (bytes < GB) {
        return std.fmt.bufPrint(buf, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(MB))}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2}GB", .{@as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(GB))}) catch "?";
    }
}

/// Select the fastest mirror by measuring latency to all candidates,
/// then download the file from the fastest responsive source.
/// Returns the actual URL that was successfully downloaded from (caller owns the memory).
pub fn attemptMirrorDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    mirror_list_url: []const u8,
    original_url: []const u8,
    dest_path: []const u8,
    verbose_writer: ?*std.Io.Writer,
    progress_writer: ?*std.Io.Writer,
    settings: *settings_mod.Settings,
) ![]const u8 {
    // Extract filename once (used for constructing mirror URLs and extracting base URL)
    const filename = if (std.mem.lastIndexOfScalar(u8, original_url, '/')) |idx| original_url[idx + 1 ..] else original_url;

    // --- Cache-fast path: try cached mirror if fresh ---
    if (settings.preferred_mirror.len > 0 and settings.mirror_updated_at > 0) {
        const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
        const age = now - settings.mirror_updated_at;
        if (age >= 0 and age < MIRROR_CACHE_TTL) {
            const cached_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ settings.preferred_mirror, filename }) catch
                return try probeAndDownload(allocator, io, environ_map, mirror_list_url, original_url, filename, dest_path, verbose_writer, progress_writer, settings);
            defer allocator.free(cached_url);

            downloadToFileWithProxy(allocator, io, environ_map, cached_url, dest_path, settings.proxy, progress_writer) catch {
                // Cached mirror failed — clear cache and fall through to full probe
                settings.clearPreferredMirror(allocator, io);
                if (verbose_writer) |vw| {
                    try vw.print("  Cached mirror unavailable, re-probing...\n", .{});
                    try vw.flush();
                }
                return try probeAndDownload(allocator, io, environ_map, mirror_list_url, original_url, filename, dest_path, verbose_writer, progress_writer, settings);
            };

            if (verbose_writer) |vw| {
                try vw.print("  from: {s} (cached)\n", .{mirror_probe.shortUrl(settings.preferred_mirror)});
                try vw.flush();
            }
            return allocator.dupe(u8, cached_url);
        }
    }

    // No cache or stale — full probe
    return try probeAndDownload(allocator, io, environ_map, mirror_list_url, original_url, filename, dest_path, verbose_writer, progress_writer, settings);
}

/// Full probe: fetch mirror list, measure latency for all candidates, download from fastest.
fn probeAndDownload(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    mirror_list_url: []const u8,
    original_url: []const u8,
    filename: []const u8,
    dest_path: []const u8,
    verbose_writer: ?*std.Io.Writer,
    progress_writer: ?*std.Io.Writer,
    settings: *settings_mod.Settings,
) ![]const u8 {
    const proxy = settings.proxy;

    // No mirror list — download directly from the original URL
    if (mirror_list_url.len == 0) {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    }

    // Fetch the mirror list
    const mirror_list_content = downloadToMemoryWithProxy(allocator, io, environ_map, mirror_list_url, proxy) catch {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
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
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    }

    // Build candidate list with owned URLs
    var candidates: std.ArrayList(mirror_probe.MirrorCandidate) = .empty;
    defer candidates.deinit(allocator);

    // Probe all candidates concurrently
    try mirror_probe.probeAll(allocator, io, environ_map, original_url, &mirrors, filename, proxy, &candidates, progress_writer);

    // If no candidates responded, fall back to the original URL
    if (candidates.items.len == 0) {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    }

    // Sort candidates by latency (fastest first)
    std.mem.sort(mirror_probe.MirrorCandidate, candidates.items, {}, mirror_probe.lessThanByLatency);

    // Print latency results if verbose output is requested
    if (verbose_writer) |vw| {
        var time_buf: [64]u8 = undefined;
        try vw.print("  Probed {d} source(s):\n", .{candidates.items.len});
        for (candidates.items, 1..) |candidate, rank| {
            const time_str = mirror_probe.formatLatency(&time_buf, candidate.latency_ns);
            const marker = if (rank == 1) " <-- fastest" else "";
            const short_url = mirror_probe.shortUrl(candidate.url);
            try vw.print("    {d}. {s}  ({s}{s})\n", .{ rank, short_url, time_str, marker });
        }
        try vw.flush();
    }

    // Try downloading from candidates in latency order
    for (candidates.items, 0..) |candidate, idx| {
        downloadToFileWithProxy(allocator, io, environ_map, candidate.url, dest_path, proxy, progress_writer) catch {
            continue;
        };
        // Success — cache the winning mirror base URL for next time
        const base_url = extractBaseUrl(candidate.url);
        if (base_url.len > 0) {
            settings.setPreferredMirror(allocator, io, base_url);
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

    try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
    return allocator.dupe(u8, original_url);
}

/// Extract the base URL (scheme + host + path up to last '/') from a full URL.
fn extractBaseUrl(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '/')) |idx| {
        return url[0..idx];
    }
    return url;
}
