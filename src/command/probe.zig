//! Probe command — test mirror download speeds without installing.
//! Fetches the version map and mirror list, probes all mirrors for
//! latency and throughput, and displays sorted results.

const std = @import("std");

const Console = @import("../core/Console.zig");
const platform = @import("../core/platform.zig");
const zvm_mod = @import("../core/zvm.zig");
const http_client = @import("../network/http_client.zig");
const mirror_probe = @import("../network/mirror_probe.zig");
const version_map = @import("../network/version_map.zig");

pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    console: Console,
) !void {
    const stdout = console.stdout.writer;
    const proxy = zvm.settings.proxy;

    // 1. Fetch version map to get a real tar URL for probing
    console.plain("Fetching version map...", .{});
    const parsed_map = version_map.fetchVersionMap(allocator, zvm.io, zvm.environ_map, zvm.settings.version_map_url, proxy) catch {
        console.err("Failed to fetch version map", .{});
        return;
    };
    defer parsed_map.deinit();
    const vmap = &parsed_map.value.object;

    // 2. Get master tar URL for the current platform
    const sys_info = platform.zigStyleSystemInfo();
    var plat_buf: [128]u8 = undefined;
    const target = platform.platformTarget(&plat_buf, sys_info);

    const tar_url = version_map.getTarPath("master", target, vmap) catch {
        console.err("Failed to find download for your platform", .{});
        return;
    };

    const filename = if (std.mem.lastIndexOfScalar(u8, tar_url, '/')) |idx| tar_url[idx + 1 ..] else tar_url;

    // 3. Fetch mirror list
    if (zvm.settings.mirror_list_url.len == 0) {
        console.err("No mirror list configured. Use 'zvm mirrorlist <url>' to set one.", .{});
        return;
    }

    const mirror_list_content = http_client.downloadToMemoryWithProxy(allocator, zvm.io, zvm.environ_map, zvm.settings.mirror_list_url, proxy) catch {
        console.err("Failed to fetch mirror list", .{});
        return;
    };
    defer allocator.free(mirror_list_content);

    // 4. Parse mirrors (one URL per line)
    var mirrors: std.ArrayList([]const u8) = .empty;
    defer mirrors.deinit(allocator);

    var lines = std.mem.splitSequence(u8, mirror_list_content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        try mirrors.append(allocator, trimmed);
    }

    if (mirrors.items.len == 0) {
        console.err("No mirrors found in mirror list", .{});
        return;
    }

    // 5. Probe all mirrors
    var candidates: std.ArrayList(mirror_probe.MirrorCandidate) = .empty;
    defer {
        for (candidates.items) |c| {
            if (c.owned) allocator.free(c.url);
        }
        candidates.deinit(allocator);
    }

    try mirror_probe.probeAll(allocator, zvm.io, zvm.environ_map, tar_url, &mirrors, filename, proxy, &candidates, stdout);

    // 6. Sort by bandwidth (with latency tiebreaker)
    std.mem.sort(mirror_probe.MirrorCandidate, candidates.items, {}, mirror_probe.greaterThanByBandwidth);

    // 7. Display sorted summary
    if (candidates.items.len == 0) {
        console.plain("  No mirrors responded.", .{});
        return;
    }

    try stdout.print("\n  Summary (sorted by speed):\n", .{});
    for (candidates.items, 1..) |candidate, rank| {
        var latency_buf: [64]u8 = undefined;
        var speed_buf: [64]u8 = undefined;
        const lat_str = if (candidate.latency_ns > 0)
            mirror_probe.formatLatency(&latency_buf, candidate.latency_ns)
        else
            "?";
        const spd_str = mirror_probe.formatThroughput(&speed_buf, candidate.bandwidth_bps);
        const marker = if (rank == 1) " <-- fastest" else "";
        try stdout.print("    {d:>3}. {s:<32} latency: {s:<10} speed: {s}/s{s}\n", .{
            rank, mirror_probe.shortUrl(candidate.url), lat_str, spd_str, marker,
        });
    }
    try stdout.flush();
}
