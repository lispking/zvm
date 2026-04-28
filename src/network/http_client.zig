//! HTTP client for downloading files and fetching remote content.
//! Uses Zig's std.http.Client for all requests, with built-in proxy support
//! (HTTP CONNECT tunneling for HTTPS through HTTP proxies).
//! Supports latency-based mirror selection for fastest downloads.
//! Caches preferred mirror in settings to skip probing on subsequent installs.

const std = @import("std");
const builtin = @import("builtin");

const settings_mod = @import("../core/settings.zig");
const mirror_probe = @import("mirror_probe.zig");
const proxy_tunnel = @import("proxy_tunnel.zig");

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
        proxy_tunnel.setProxyFromUrl(client, allocator, proxy_url) catch {};
    } else {
        client.initDefaultProxies(allocator, environ_map) catch {};
    }
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
    const uri = try std.Uri.parse(url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.DownloadFailed;

    // For HTTPS with proxy, manually establish a CONNECT tunnel.
    if (protocol == .tls and proxy_url.len > 0) {
        const proxy_info = proxy_tunnel.resolveProxy(allocator, environ_map, proxy_url);
        if (proxy_info) |pi| {
            return downloadFileViaProxyTunnel(allocator, io, uri, pi.host, pi.port, dest_path, progress_writer);
        }
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    initClientProxy(&client, allocator, environ_map, proxy_url);

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
        try streamBodyToFile(body_reader, &file_writer.interface, io, total, pw, .limited(64 * 1024));
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

/// Stream response body from a reader to a file writer.
/// Handles both progress display (if progress_writer is non-null) and
/// plain streaming without progress.
fn streamBodyToFile(
    body_reader: *std.Io.Reader,
    file_writer: *std.Io.Writer,
    io: std.Io,
    total: ?u64,
    progress_writer: ?*std.Io.Writer,
    chunk_limit: std.Io.Limit,
) !void {
    if (progress_writer) |pw| {
        var downloaded: u64 = 0;
        const start_ns = std.Io.Timestamp.now(io, .awake);
        var last_update_ns: u64 = 0;

        while (true) {
            const n = body_reader.stream(file_writer, chunk_limit) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) {
                try file_writer.flush();
                continue;
            }
            downloaded += n;

            const now_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
            if (now_ns - last_update_ns > 100_000_000 or (total != null and downloaded >= total.?)) {
                last_update_ns = now_ns;
                printProgress(pw, io, downloaded, total, start_ns) catch {};
            }
        }
        try file_writer.flush();

        const final_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start_ns, std.Io.Timestamp.now(io, .awake)).nanoseconds);
        if (final_ns > 0) {
            printProgress(pw, io, downloaded, total, start_ns) catch {};
            try pw.writeByte('\n');
            try pw.flush();
        }
    } else {
        while (true) {
            const n = body_reader.stream(file_writer, chunk_limit) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) {
                try file_writer.flush();
                continue;
            }
        }
        try file_writer.flush();
    }
}

/// Download content from a URL over HTTPS through a CONNECT proxy tunnel.
/// Reuses a single reader/writer pair throughout to avoid losing buffered data.
fn downloadViaProxyTunnel(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_uri: std.Uri,
    proxy_host: std.Io.net.HostName,
    proxy_port: u16,
) ![]const u8 {
    const tunnel = try proxy_tunnel.ProxyTunnel.create(allocator, io, target_uri, proxy_host, proxy_port);
    defer tunnel.destroy(allocator, io);

    try tunnel.sendHttpGet(target_uri);
    const status = try tunnel.readHttpStatus();
    if (status != 200) return error.DownloadFailed;
    _ = try tunnel.skipHeaders();

    const resp_buf = allocator.alloc(u8, 10 * 1024 * 1024) catch return error.DownloadFailed;
    defer allocator.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);
    _ = tunnel.tls_client.reader.streamRemaining(&resp_writer) catch |err| {
        if (err != error.EndOfStream) return error.DownloadFailed;
    };
    return allocator.dupe(u8, resp_writer.buffered());
}

/// Download a file from a URL over HTTPS through a CONNECT proxy tunnel.
/// Streams the response body directly to the destination file.
fn downloadFileViaProxyTunnel(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_uri: std.Uri,
    proxy_host: std.Io.net.HostName,
    proxy_port: u16,
    dest_path: []const u8,
    progress_writer: ?*std.Io.Writer,
) !void {
    const tunnel = try proxy_tunnel.ProxyTunnel.create(allocator, io, target_uri, proxy_host, proxy_port);
    defer tunnel.destroy(allocator, io);

    try tunnel.sendHttpGet(target_uri);
    const status = try tunnel.readHttpStatus();
    if (status != 200) return error.DownloadFailed;
    const content_length = try tunnel.skipHeaders();

    const file = try std.Io.Dir.cwd().createFile(io, dest_path, .{});
    defer file.close(io);
    var file_buf: [16384]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);

    try streamBodyToFile(&tunnel.tls_client.reader, &file_writer.interface, io, content_length, progress_writer, .unlimited);
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

    const uri = try std.Uri.parse(url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.DownloadFailed;

    // For HTTPS with proxy, manually establish a CONNECT tunnel.
    // Workaround for Zig's std.http.Client.connectProxied() returning 400.
    if (protocol == .tls and proxy_url.len > 0) {
        const proxy_info = proxy_tunnel.resolveProxy(allocator, environ_map, proxy_url);
        if (proxy_info) |pi| {
            return downloadViaProxyTunnel(allocator, io, uri, pi.host, pi.port);
        }
    }

    // No proxy — use client's built-in proxy support
    initClientProxy(&client, allocator, environ_map, proxy_url);

    var body_buf: [10 * 1024 * 1024]u8 = undefined;
    var body_writer: std.Io.Writer = .fixed(&body_buf);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body_writer,
    });
    if (result.status != .ok) return error.DownloadFailed;
    const body = body_writer.buffered();
    return allocator.dupe(u8, body);
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
    force_probe: bool,
) ![]const u8 {
    // Extract filename once (used for constructing mirror URLs and extracting base URL)
    const filename = if (std.mem.lastIndexOfScalar(u8, original_url, '/')) |idx| original_url[idx + 1 ..] else original_url;

    // --- Cache-fast path: try cached mirror if fresh ---
    if (!force_probe and settings.preferred_mirror.len > 0 and settings.mirror_updated_at > 0) {
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

    // Probe all candidates sequentially
    try mirror_probe.probeAll(allocator, io, environ_map, original_url, &mirrors, filename, proxy, &candidates, progress_writer);

    // If no candidates responded, fall back to the original URL
    if (candidates.items.len == 0) {
        try downloadToFileWithProxy(allocator, io, environ_map, original_url, dest_path, proxy, progress_writer);
        return allocator.dupe(u8, original_url);
    }

    // Sort candidates by bandwidth (fastest first)
    std.mem.sort(mirror_probe.MirrorCandidate, candidates.items, {}, mirror_probe.greaterThanByBandwidth);

    // Show which mirror was selected
    if (verbose_writer) |vw| {
        const best = candidates.items[0];
        var speed_buf: [64]u8 = undefined;
        var lat_buf: [64]u8 = undefined;
        const spd_str = mirror_probe.formatThroughput(&speed_buf, best.bandwidth_bps);
        const lat_str = mirror_probe.formatLatency(&lat_buf, best.latency_ns);
        try vw.print("  Selected: {s} ({s}/s, latency: {s})\n\n", .{ mirror_probe.shortUrl(best.url), spd_str, lat_str });
        try vw.flush();
    }

    // Try downloading from candidates in bandwidth order
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
