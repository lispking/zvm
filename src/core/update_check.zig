//! Periodic update check for zvm self-updates.
//! Caches the latest version from GitHub Releases in the cache directory.
//! Only re-checks if the cache is older than 24 hours to avoid unnecessary
//! network requests. Prints a non-intrusive hint when a newer version exists.

const std = @import("std");
const build_options = @import("build_options");
const zvm_mod = @import("zvm.zig");
const http_client = @import("../network/http_client.zig");
const Console = @import("../core/Console.zig");

/// Cache file name for the update check result.
const cache_filename = "_update_check";

/// How often to re-check for updates (24 hours in seconds).
const check_interval_secs: i64 = 86400;

/// Current zvm version, injected at build time.
const VERSION = build_options.version;

/// Compare two semver version strings (without 'v' prefix).
/// Returns true if a > b.
pub fn versionGt(a: []const u8, b: []const u8) bool {
    var a_iter = std.mem.splitScalar(u8, a, '.');
    var b_iter = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_iter.next();
        const b_part = b_iter.next();
        if (a_part == null and b_part == null) return false;
        const a_val: u64 = if (a_part) |p| std.fmt.parseInt(u64, p, 10) catch 0 else 0;
        const b_val: u64 = if (b_part) |p| std.fmt.parseInt(u64, p, 10) catch 0 else 0;
        if (a_val > b_val) return true;
        if (a_val < b_val) return false;
    }
}

/// Strip leading 'v' from a version string if present.
pub fn stripVPrefix(version: []const u8) []const u8 {
    if (version.len > 0 and version[0] == 'v') return version[1..];
    return version;
}

/// Extract the actual version from a GitHub release JSON body.
/// The "latest" release has tag_name="latest", so we extract from body:
/// "Latest stable release (vX.Y.Z)."
pub fn extractVersionFromRelease(json: std.json.Value) ?[]const u8 {
    const obj = switch (json) {
        .object => |o| o,
        else => return null,
    };

    // Try body first: "Latest stable release (vX.Y.Z)."
    if (obj.get("body")) |body_val| {
        if (body_val == .string) {
            const body = body_val.string;
            if (std.mem.indexOf(u8, body, "(")) |open| {
                if (std.mem.indexOf(u8, body[open..], ")")) |close| {
                    return body[open + 1 .. open + close];
                }
            }
        }
    }

    // Fallback to tag_name if it looks like a version
    if (obj.get("tag_name")) |tag| {
        if (tag == .string) {
            const t = tag.string;
            if (t.len > 0 and t[0] == 'v') return t;
        }
    }

    return null;
}

/// Fetch the latest zvm version from GitHub Releases API.
/// Returns an owned string that the caller must free.
pub fn fetchLatestVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    proxy: []const u8,
) ![]const u8 {
    const release_json = try http_client.downloadToMemoryWithProxy(
        allocator,
        io,
        environ_map,
        "https://api.github.com/repos/lispking/zvm/releases/latest",
        proxy,
    );
    defer allocator.free(release_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, release_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const version = extractVersionFromRelease(parsed.value) orelse return error.InvalidResponse;
    return allocator.dupe(u8, version);
}

/// Read the cached latest version and check timestamp.
/// Returns the cached version string (slice into `content_buf`) if valid, null otherwise.
fn readCache(allocator: std.mem.Allocator, io: std.Io, cache_path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, cache_path, .{}) catch return null;
    defer file.close(io);

    var read_buf: [256]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const content = reader.interface.allocRemaining(allocator, .limited(256)) catch return null;

    // Format: "<timestamp>\n<version>"
    const newline = std.mem.indexOfScalar(u8, content, '\n') orelse return null;
    const ts_str = content[0..newline];
    const cached_version = std.mem.trim(u8, content[newline + 1 ..], " \n\r");
    if (cached_version.len == 0) return null;

    const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return null;
    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
    if (now - timestamp > check_interval_secs) return null;

    return cached_version;
}

/// Write the latest version and current timestamp to the cache file.
fn writeCache(io: std.Io, cache_path: []const u8, version: []const u8) void {
    const file = std.Io.Dir.cwd().createFile(io, cache_path, .{}) catch return;
    defer file.close(io);

    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();

    var buf: [512]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.print("{d}\n{s}\n", .{ now, version }) catch {};
    writer.interface.flush() catch {};
}

/// Check if a newer zvm version is available.
/// Uses a 24-hour cache to avoid hammering the GitHub API.
/// Returns an owned string (latest version) if an update is available, null otherwise.
pub fn checkForUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cache_dir: []const u8,
    proxy: []const u8,
) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const cache_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cache_dir, cache_filename }) catch return null;

    // Try reading from cache first
    var content_buf: [256]u8 = undefined;
    _ = &content_buf;
    if (readCache(allocator, io, cache_path)) |cached_version| {
        const current = stripVPrefix(VERSION);
        const latest = stripVPrefix(cached_version);
        if (versionGt(latest, current)) {
            return allocator.dupe(u8, cached_version) catch null;
        }
        return null;
    }

    // Cache miss or stale — fetch from GitHub
    const latest = fetchLatestVersion(allocator, io, environ_map, proxy) catch return null;

    // Update cache
    writeCache(io, cache_path, latest);

    // Compare with current version
    const current = stripVPrefix(VERSION);
    const latest_stripped = stripVPrefix(latest);
    if (versionGt(latest_stripped, current)) {
        return latest;
    }

    allocator.free(latest);
    return null;
}

/// Print a non-intrusive update hint if a newer version is available.
/// Designed to be called after commands that already use the network.
pub fn printUpdateHint(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cache_dir: []const u8,
    proxy: []const u8,
    console: Console,
) void {
    const latest = checkForUpdate(allocator, io, environ_map, cache_dir, proxy) orelse return;
    defer allocator.free(latest);

    console.colorize(.stdout, .yellow, "A new version of zvm is available: {s} (current: v{s})", .{ latest, VERSION });
    console.print(.stdout, "Run `zvm upgrade` to update.\n\n", .{});
    console.flush(.stdout);
}
