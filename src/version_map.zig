//! Zig version map fetching and parsing.
//! The version map is a JSON document (from ziglang.org/download/index.json)
//! that lists all available Zig versions with their download URLs and checksums.
//! Uses dynamic JSON parsing (std.json.Value) since version keys are not known at compile time.

const std = @import("std");
const http_client = @import("http_client.zig");

/// The version map is represented as a JSON ObjectMap (dynamic key-value pairs).
pub const VersionMap = std.json.ObjectMap;

/// Fetch the Zig version map from the given URL.
/// Returns a parsed JSON value tree — caller must call parsed.deinit() when done.
pub fn fetchVersionMap(allocator: std.mem.Allocator, url: []const u8, proxy: []const u8) !std.json.Parsed(std.json.Value) {
    const body = try http_client.downloadToMemoryWithProxy(allocator, url, proxy);
    defer allocator.free(body);

    return try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .ignore_unknown_fields = true,
    });
}

/// Load version map from a local cache file.
/// Returns null if the file doesn't exist or can't be read.
pub fn loadCachedVersionMap(allocator: std.mem.Allocator, path: []const u8) !?std.json.Parsed(std.json.Value) {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    return try std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .ignore_unknown_fields = true,
    });
}

/// Save a version map to a local cache file as JSON.
pub fn cacheVersionMap(allocator: std.mem.Allocator, path: []const u8, value: std.json.Value) !void {
    const json_str = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json_str);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.writeAll(json_str);
    try writer.interface.flush();
}

/// Get the tarball download URL for a specific version and platform.
/// Navigates the JSON structure: map[version][platform]["tarball"].
pub fn getTarPath(version: []const u8, platform: []const u8, map: *const VersionMap) ![]const u8 {
    const version_entry = map.get(version) orelse return error.VersionNotInstalled;
    switch (version_entry) {
        .object => |obj| {
            const platform_entry = obj.get(platform) orelse return error.UnsupportedSystem;
            switch (platform_entry) {
                .object => |plat_obj| {
                    const tarball = plat_obj.get("tarball") orelse return error.MissingBundlePath;
                    return tarball.string;
                },
                else => return error.InvalidVersionMap,
            }
        },
        else => return error.InvalidVersionMap,
    }
}

/// Get the SHA256 hash for a specific version and platform.
/// Navigates the JSON structure: map[version][platform]["shasum"].
pub fn getVersionShasum(version: []const u8, platform: []const u8, map: *const VersionMap) ![]const u8 {
    const version_entry = map.get(version) orelse return error.VersionNotInstalled;
    switch (version_entry) {
        .object => |obj| {
            const platform_entry = obj.get(platform) orelse return error.UnsupportedSystem;
            switch (platform_entry) {
                .object => |plat_obj| {
                    const shasum = plat_obj.get("shasum") orelse return error.MissingShasum;
                    return shasum.string;
                },
                else => return error.InvalidVersionMap,
            }
        },
        else => return error.InvalidVersionMap,
    }
}

/// Get the master/dev build version string from the version map.
/// Returns the "version" field from the "master" entry.
pub fn getMasterVersion(map: *const VersionMap) ?[]const u8 {
    const master_entry = map.get("master") orelse return null;
    switch (master_entry) {
        .object => |obj| {
            const version = obj.get("version") orelse return null;
            return version.string;
        },
        else => return null,
    }
}

/// Get all version keys from the map (e.g., "master", "0.13.0", etc.).
/// Caller owns the returned list and must free each item.
pub fn getVersionKeys(allocator: std.mem.Allocator, map: *const VersionMap) !std.ArrayList([]const u8) {
    var keys: std.ArrayList([]const u8) = .empty;
    var iter = map.iterator();
    while (iter.next()) |entry| {
        try keys.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }
    return keys;
}
