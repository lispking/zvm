//! Sequential mirror probing.
//! Tests each mirror one by one, measuring both latency (HTTP HEAD round-trip)
//! and throughput (5-second download to NUL). Results are displayed immediately
//! as each mirror is tested, giving the user real-time visibility.

const std = @import("std");
const builtin = @import("builtin");

const proxy_tunnel = @import("proxy_tunnel.zig");

/// A candidate URL with its measured latency and throughput.
pub const MirrorCandidate = struct {
    url: []const u8,
    /// HTTP HEAD round-trip time
    latency_ns: u64,
    /// Bytes per second (0 = bandwidth measurement failed)
    bandwidth_bps: u64,
    owned: bool,
};

/// ============================================================
/// Internal helpers
/// ============================================================
fn setupClient(client: *std.http.Client, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map, proxy: []const u8) void {
    if (proxy.len > 0) {
        proxy_tunnel.setProxyFromUrl(client, allocator, proxy) catch {};
    } else {
        client.initDefaultProxies(allocator, environ_map) catch {};
    }
}

/// Measure latency via HTTP HEAD (DNS + TCP + TLS + response).
fn measureLatency(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, url: []const u8, proxy: []const u8) ?u64 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    setupClient(&client, allocator, environ_map, proxy);

    const uri = std.Uri.parse(url) catch return null;
    const start = std.Io.Timestamp.now(io, .awake);

    var req = client.request(.HEAD, uri, .{ .redirect_behavior = .init(3) }) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;

    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch return null;

    const end = std.Io.Timestamp.now(io, .awake);
    if (response.head.status.class() != .success) return null;

    const elapsed: u64 = @intCast(std.Io.Timestamp.durationTo(start, end).nanoseconds);
    return if (elapsed > 0) elapsed else null;
}

/// Measure throughput by downloading data for up to 5 seconds.
/// Uses the same I/O path as the real download (stream to a file writer),
/// but writes to NUL (/dev/null) so no data is stored on disk.
/// Returns bytes per second, or null on failure.
fn measureBandwidth(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, url: []const u8, proxy: []const u8) ?u64 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    setupClient(&client, allocator, environ_map, proxy);

    const uri = std.Uri.parse(url) catch return null;

    // Open null device — discards all written data, no disk I/O
    const null_path: []const u8 = if (builtin.os.tag == .windows) "NUL" else "/dev/null";
    const null_file = std.Io.Dir.cwd().createFile(io, null_path, .{}) catch return null;
    defer null_file.close(io);

    const start = std.Io.Timestamp.now(io, .awake);

    // Send GET request
    var req = client.request(.GET, uri, .{ .redirect_behavior = .init(3) }) catch return null;
    defer req.deinit();
    req.sendBodiless() catch return null;

    // Receive response head
    var head_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&head_buf) catch return null;
    if (response.head.status.class() != .success) return null;

    // Stream body to null device — same pattern as the real download (streamBodyToFile).
    // 64KB chunk limit matches the real download. Writer buffer is flushed to NUL
    // when full, so we can keep reading indefinitely.
    var reader_buf: [16384]u8 = undefined;
    const body_reader = response.reader(&reader_buf);
    var file_buf: [16384]u8 = undefined;
    var file_writer = null_file.writer(io, &file_buf);

    const max_ns: u64 = 5 * std.time.ns_per_s;
    var total_read: u64 = 0;
    while (true) {
        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start, now).nanoseconds);
        if (elapsed_ns >= max_ns) break;

        const n = body_reader.stream(&file_writer.interface, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => break,
        };
        if (n == 0) {
            file_writer.interface.flush() catch break;
            continue;
        }
        total_read += n;
    }
    file_writer.interface.flush() catch {};

    if (total_read == 0) return null;

    const end = std.Io.Timestamp.now(io, .awake);
    const final_ns: u64 = @intCast(std.Io.Timestamp.durationTo(start, end).nanoseconds);
    if (final_ns == 0) return null;

    return @intFromFloat(@as(f64, @floatFromInt(total_read)) / (@as(f64, @floatFromInt(final_ns)) / 1_000_000_000.0));
}

/// ============================================================
/// Public API
/// ============================================================
/// Probe all candidate URLs sequentially.
/// For each mirror, measures latency (HEAD) and throughput (5-second download),
/// displaying results immediately to the terminal.
pub fn probeAll(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    original_url: []const u8,
    mirrors: *std.ArrayList([]const u8),
    filename: []const u8,
    proxy: []const u8,
    candidates: *std.ArrayList(MirrorCandidate),
    progress_writer: ?*std.Io.Writer,
) !void {
    // Build full URL list with owned URLs
    var all_urls: std.ArrayList([]const u8) = .empty;
    defer {
        for (all_urls.items) |u| {
            if (u.len > 0) allocator.free(u);
        }
        all_urls.deinit(allocator);
    }

    const owned_original = allocator.dupe(u8, original_url) catch unreachable;
    try all_urls.append(allocator, owned_original);

    for (mirrors.items) |mirror_base| {
        const mirror_url = std.fmt.allocPrint(allocator, "{s}/{s}", .{ mirror_base, filename }) catch continue;
        try all_urls.append(allocator, mirror_url);
    }

    const total = all_urls.items.len;
    var latency_buf: [64]u8 = undefined;
    var speed_buf: [64]u8 = undefined;

    if (progress_writer) |pw| {
        try pw.print("  Probing {d} source(s):\n", .{total});
        try pw.flush();
    }

    for (all_urls.items, 0..) |url, idx| {
        // Display: "  Testing: mirror_name ..."
        if (progress_writer) |pw| {
            try pw.print("  Testing: {s} ...", .{shortUrl(url)});
            try pw.flush();
        }

        // Phase 1: Measure latency (HTTP HEAD)
        const latency = measureLatency(allocator, io, environ_map, url, proxy);

        // Phase 2: Measure bandwidth (HTTP GET, 5-second download)
        const bandwidth = measureBandwidth(allocator, io, environ_map, url, proxy);

        // Display result and add to candidates
        if (progress_writer) |pw| {
            const lat_str = if (latency) |lat| formatLatency(&latency_buf, lat) else "timeout";
            if (bandwidth) |bw| {
                const spd_str = formatThroughput(&speed_buf, bw);
                try pw.print("\r  {d:>3}. {s:<32} latency: {s:<10} speed: {s}/s\n", .{
                    idx + 1, shortUrl(url), lat_str, spd_str,
                });
            } else {
                try pw.print("\r  {d:>3}. {s:<32} latency: {s:<10} speed: timeout\n", .{
                    idx + 1, shortUrl(url), lat_str,
                });
            }
            try pw.flush();
        }

        if (bandwidth) |bw| {
            try candidates.append(allocator, .{
                .url = url,
                .latency_ns = latency orelse 0,
                .bandwidth_bps = bw,
                .owned = true,
            });
            // Mark URL as transferred to candidates
            for (all_urls.items) |*u| {
                if (u.*.ptr == url.ptr) {
                    u.* = "";
                    break;
                }
            }
        }
    }
}

/// Compare two MirrorCandidates by bandwidth (for sorting).
/// Higher bandwidth_bps = faster mirror. Failed probes (bandwidth_bps == 0) sort last.
/// When bandwidth difference is <10%, lower latency wins as tiebreaker.
pub fn greaterThanByBandwidth(_: void, a: MirrorCandidate, b: MirrorCandidate) bool {
    // Failed bandwidth probes sort last
    if (a.bandwidth_bps == 0) return false;
    if (b.bandwidth_bps == 0) return true;

    // If bandwidth difference < 10%, use latency as tiebreaker
    const max_bps = @max(a.bandwidth_bps, b.bandwidth_bps);
    const diff = if (a.bandwidth_bps > b.bandwidth_bps)
        a.bandwidth_bps - b.bandwidth_bps
    else
        b.bandwidth_bps - a.bandwidth_bps;

    if (diff * 10 < max_bps) {
        // Both failed latency → order doesn't matter
        if (a.latency_ns == 0 and b.latency_ns == 0) return false;
        // One failed latency → sort last
        if (a.latency_ns == 0) return false;
        if (b.latency_ns == 0) return true;
        // Lower latency = better
        return a.latency_ns < b.latency_ns;
    }

    // Higher bandwidth = better
    return a.bandwidth_bps > b.bandwidth_bps;
}

/// Format nanoseconds as a human-readable string (e.g., "123ms", "1.2s").
pub fn formatLatency(buf: []u8, ns: u64) []const u8 {
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

/// Format throughput from bytes per second as "X.YMB" etc.
pub fn formatThroughput(buf: []u8, bps: u64) []const u8 {
    if (bps == 0) return "?B";
    return formatBytes(buf, bps);
}

/// Format bytes as a human-readable string (e.g., "427.0KB", "1.2MB").
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

/// Extract the host part of a URL for concise display.
pub fn shortUrl(url: []const u8) []const u8 {
    const start: usize = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        0;
    const rest = url[start..];
    for (rest, 0..) |ch, i| {
        if (ch == '/') return rest[0..i];
    }
    return rest;
}
