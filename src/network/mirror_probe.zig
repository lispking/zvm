//! Concurrent mirror latency probing.
//! On POSIX: uses raw TCP connect (getaddrinfo + non-blocking socket + poll with timeout)
//! for maximum parallelism — completely bypasses std.http.Client and std.Io.
//! On Windows: uses std.http.Client per probe thread (Winsock API not fully wrapped in Zig 0.16).
//! A background ticker thread provides real-time progress display.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

/// Per-probe timeout in seconds.
const PROBE_TIMEOUT_S: u64 = 2;

/// A candidate URL with its measured latency.
pub const MirrorCandidate = struct {
    url: []const u8,
    latency_ns: u64,
    owned: bool,
};

/// Result of a single latency probe, written by a probe thread.
const ProbeResult = struct {
    url: []const u8,
    latency_ns: u64,
};

/// Context passed to each probe thread.
const ProbeThreadContext = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    result: *?ProbeResult,
    done: *std.atomic.Value(usize),
    // Fields used only by Windows fallback
    io: ?std.Io = null,
    environ_map: ?*std.process.Environ.Map = null,
    proxy: []const u8 = "",
};

/// Shared state for the background progress ticker thread.
const TickerContext = struct {
    total: usize,
    done: *std.atomic.Value(usize),
    start_ns: i96,
    stop: std.atomic.Value(bool),
    current_url: []const u8 = "",
};

/// Background thread that refreshes the progress display at a fixed interval.
fn tickerThread(ctx: *TickerContext) void {
    var latency_buf: [64]u8 = undefined;
    var msg_buf: [256]u8 = undefined;
    const req: std.c.timespec = .{ .sec = 0, .nsec = 100_000_000 }; // 100ms

    while (!ctx.stop.load(.acquire)) {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now_ns: i96 = @as(i96, ts.sec) * 1_000_000_000 + ts.nsec;
        const elapsed_ns: u64 = if (now_ns > ctx.start_ns) @intCast(now_ns - ctx.start_ns) else 0;
        const elapsed_str = formatLatency(&latency_buf, elapsed_ns);
        const done_val = ctx.done.load(.monotonic);
        const pct: u32 = if (ctx.total > 0) @intCast(done_val * 100 / ctx.total) else 0;
        const msg = std.fmt.bufPrint(&msg_buf, "\x1b[2K\r  Probing: {s} ... {d}% ({s})", .{ shortUrl(ctx.current_url), pct, elapsed_str }) catch return;
        _ = std.c.write(2, msg.ptr, msg.len);
        _ = std.c.nanosleep(&req, null);
    }
}

/// ============================================================
/// POSIX implementation — raw TCP connect
/// ============================================================

fn probeThreadMainPosix(ctx: *ProbeThreadContext) void {
    defer _ = ctx.done.fetchAdd(1, .monotonic);

    // Parse URL to extract host and port
    const uri = std.Uri.parse(ctx.url) catch return;
    const host_component = uri.host orelse return;
    const host = host_component.percent_encoded;
    const is_https = std.mem.eql(u8, uri.scheme, "https");
    const port: u16 = uri.port orelse if (is_https) @as(u16, 443) else @as(u16, 80);

    // Null-terminate host for getaddrinfo
    const host_z = ctx.allocator.dupeZ(u8, host) catch return;
    defer ctx.allocator.free(host_z);

    var port_buf: [6:0]u8 = undefined;
    const port_str = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return;

    // Start timing
    var start_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_ts);

    // Resolve hostname
    const hints: std.c.addrinfo = .{
        .flags = .{},
        .family = std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
        .protocol = 0,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };
    var addr_result: ?*std.c.addrinfo = null;
    if (std.c.getaddrinfo(host_z, port_str, &hints, &addr_result) != @as(std.c.EAI, @enumFromInt(0))) return;
    defer std.c.freeaddrinfo(addr_result.?);

    const ai = addr_result.?;

    // Create socket
    const sock = std.c.socket(
        @intCast(ai.family),
        @intCast(ai.socktype),
        @intCast(ai.protocol),
    );
    if (sock < 0) return;
    defer _ = std.c.close(sock);

    // Set non-blocking for timeout control
    const flags = std.c.fcntl(sock, std.c.F.GETFL, @as(c_int, 0));
    if (flags >= 0) {
        const nonblocking: std.c.O = .{ .NONBLOCK = true };
        _ = std.c.fcntl(sock, std.c.F.SETFL, @as(c_int, @bitCast(nonblocking)));
    }

    // Start non-blocking connect
    _ = std.c.connect(sock, ai.addr.?, ai.addrlen);

    // Poll for connect completion with timeout
    var pfd: [1]std.c.pollfd = .{.{
        .fd = sock,
        .events = std.c.POLL.OUT,
        .revents = 0,
    }};
    const timeout_ms: c_int = @intCast(PROBE_TIMEOUT_S * 1000);
    const poll_rc = std.c.poll(&pfd, 1, timeout_ms);
    if (poll_rc <= 0) return; // timeout or error

    // Check for connection error
    var err_code: u32 = 0;
    var err_len: std.c.socklen_t = @sizeOf(u32);
    if (std.c.getsockopt(sock, std.c.SOL.SOCKET, std.c.SO.ERROR, &err_code, &err_len) < 0) return;
    if (err_code != 0) return;

    // Success — calculate elapsed time
    var end_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &end_ts);

    const elapsed_ns: i96 = (end_ts.sec - start_ts.sec) * 1_000_000_000 + (end_ts.nsec - start_ts.nsec);
    if (elapsed_ns <= 0 or elapsed_ns > PROBE_TIMEOUT_S * std.time.ns_per_s) return;

    ctx.result.* = .{
        .url = ctx.url,
        .latency_ns = @intCast(elapsed_ns),
    };
}

/// ============================================================
/// Windows fallback — std.http.Client per thread
/// ============================================================

fn configureClientProxy(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    proxy_url: []const u8,
) void {
    if (proxy_url.len > 0) {
        const uri = std.Uri.parse(proxy_url) catch
            std.Uri.parseAfterScheme("http", proxy_url) catch return;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
        const raw_host = uri.getHostAlloc(allocator) catch return;
        const authorization: ?[]const u8 = if (uri.user != null or uri.password != null) a: {
            const auth_buf = allocator.alloc(u8, std.http.Client.basic_authorization.valueLengthFromUri(uri)) catch return;
            std.debug.assert(std.http.Client.basic_authorization.value(uri, auth_buf).len == auth_buf.len);
            break :a auth_buf;
        } else null;
        const proxy = allocator.create(std.http.Client.Proxy) catch return;
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
        client.http_proxy = proxy;
        client.https_proxy = proxy;
    } else {
        client.initDefaultProxies(allocator, environ_map) catch {};
    }
}

fn probeThreadMainWindows(ctx: *ProbeThreadContext) void {
    defer _ = ctx.done.fetchAdd(1, .monotonic);

    const io = ctx.io orelse return;
    const environ_map = ctx.environ_map orelse return;

    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = io };
    defer client.deinit();
    configureClientProxy(&client, ctx.allocator, environ_map, ctx.proxy);

    const uri = std.Uri.parse(ctx.url) catch return;
    var req = client.request(.HEAD, uri, .{
        .redirect_behavior = .init(3),
    }) catch return;
    defer req.deinit();

    const start = std.Io.Timestamp.now(io, .awake);
    req.sendBodiless() catch return;

    var buf: [4096]u8 = undefined;
    const response = req.receiveHead(&buf) catch return;
    const end = std.Io.Timestamp.now(io, .awake);

    const elapsed_ns = std.Io.Timestamp.durationTo(start, end).nanoseconds;
    if (elapsed_ns > PROBE_TIMEOUT_S * std.time.ns_per_s) return;
    if (response.head.status.class() != .success) return;

    ctx.result.* = .{
        .url = ctx.url,
        .latency_ns = @intCast(elapsed_ns),
    };
}

/// ============================================================
/// Platform-dispatched probe thread entry point
/// ============================================================

fn probeThreadMain(ctx: *ProbeThreadContext) void {
    switch (native_os) {
        .windows => probeThreadMainWindows(ctx),
        else => probeThreadMainPosix(ctx),
    }
}

/// ============================================================
/// Public API
/// ============================================================

/// Probe all candidate URLs concurrently using real OS threads.
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
    var done = std.atomic.Value(usize).init(0);
    var time_buf: [64]u8 = undefined;

    // Capture start time
    var start_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_ts);
    const start_ns: i96 = @as(i96, start_ts.sec) * 1_000_000_000 + start_ts.nsec;

    // Spawn background ticker thread for dynamic progress display
    var ticker_ctx: TickerContext = .{
        .total = total,
        .done = &done,
        .start_ns = start_ns,
        .stop = std.atomic.Value(bool).init(false),
    };
    const ticker = if (progress_writer != null)
        std.Thread.spawn(.{}, tickerThread, .{&ticker_ctx}) catch null
    else
        null;
    defer {
        ticker_ctx.stop.store(true, .release);
        if (ticker) |t| t.join();
    }

    // Allocate results and thread contexts
    var results = try allocator.alloc(?ProbeResult, total);
    defer allocator.free(results);
    @memset(results, null);

    var contexts = try allocator.alloc(ProbeThreadContext, total);
    defer allocator.free(contexts);

    ticker_ctx.current_url = all_urls.items[0];

    for (0..total) |i| {
        contexts[i] = .{
            .allocator = allocator,
            .url = all_urls.items[i],
            .result = &results[i],
            .done = &done,
            // Windows fallback fields
            .io = io,
            .environ_map = environ_map,
            .proxy = proxy,
        };
    }

    // Spawn one OS thread per probe — guaranteed true parallelism
    var threads = try allocator.alloc(?std.Thread, total);
    defer allocator.free(threads);
    @memset(threads, null);

    for (0..total) |i| {
        threads[i] = std.Thread.spawn(.{}, probeThreadMain, .{&contexts[i]}) catch null;
    }

    // Wait for all probe threads to complete
    for (0..total) |i| {
        if (threads[i]) |t| t.join();
    }

    // Collect successful results
    for (results) |res| {
        if (res) |r| {
            try candidates.append(allocator, .{
                .url = r.url,
                .latency_ns = r.latency_ns,
                .owned = true,
            });
            for (all_urls.items) |*u| {
                if (u.*.ptr == r.url.ptr) {
                    u.* = "";
                    break;
                }
            }
        }
    }

    if (progress_writer) |pw| {
        var end_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &end_ts);
        const end_ns: i96 = @as(i96, end_ts.sec) * 1_000_000_000 + end_ts.nsec;
        const elapsed_ns: u64 = if (end_ns > start_ns) @intCast(end_ns - start_ns) else 0;
        const elapsed_str = formatLatency(&time_buf, elapsed_ns);
        try pw.print("\x1b[2K\r  Probing: done ({d} sources, {s})\n", .{ total, elapsed_str });
        try pw.flush();
    }
}

/// Compare two MirrorCandidates by latency (for sorting).
pub fn lessThanByLatency(_: void, a: MirrorCandidate, b: MirrorCandidate) bool {
    return a.latency_ns < b.latency_ns;
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
