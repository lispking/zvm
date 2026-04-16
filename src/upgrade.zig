//! Upgrade command — self-update zvm from the latest GitHub release.
//! Queries the GitHub Releases API, finds the platform-matching asset,
//! downloads it, extracts, and replaces the current binary.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zvm_mod = @import("zvm.zig");
const terminal = @import("terminal.zig");
const http_client = @import("http_client.zig");

/// GitHub Release API response structure (used for reference, parsed dynamically).
const GithubRelease = struct {
    tag_name: []const u8,
    assets: []const Asset,

    const Asset = struct {
        name: []const u8,
        browser_download_url: []const u8,
    };
};

/// Compare two semver version strings (without 'v' prefix).
/// Returns true if a > b.
fn versionGt(a: []const u8, b: []const u8) bool {
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
fn stripVPrefix(version: []const u8) []const u8 {
    if (version.len > 0 and version[0] == 'v') return version[1..];
    return version;
}

/// Search for the extracted binary inside self_dir, including subdirectories.
/// The archive may extract into a versioned directory like zvm-v0.1.1-aarch64-macos/.
fn findBinary(allocator: std.mem.Allocator, io: std.Io, self_dir: []const u8, exe_name: []const u8, buf: []u8) ![]const u8 {
    _ = allocator;
    // Direct path: self_dir/zvm
    const direct = try std.fmt.bufPrint(buf, "{s}/{s}", .{ self_dir, exe_name });
    if (std.Io.Dir.cwd().access(io, direct, .{})) {
        return direct;
    } else |_| {}

    // Search subdirectories: self_dir/*/zvm
    var dir = std.Io.Dir.cwd().openDir(io, self_dir, .{ .iterate = true }) catch return error.FileNotFound;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = try std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ self_dir, entry.name, exe_name });
        if (std.Io.Dir.cwd().access(io, candidate, .{})) {
            return candidate;
        } else |_| {}
    }
    return error.FileNotFound;
}

/// Check for the latest zvm release on GitHub and upgrade if available.
/// Compares versions and only downloads if a newer version is available.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    current_version: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    try stdout.print("Current version: v{s} ({s})\n", .{ current_version, build_options.git_commit });
    try stdout.print("Checking for zvm updates...\n", .{});
    try stdout.flush();

    // Fetch latest release info from GitHub API
    const proxy = zvm.settings.proxy;
    const release_json = http_client.downloadToMemoryWithProxy(allocator, zvm.io, zvm.environ_map, "https://api.github.com/repos/lispking/zvm/releases/latest", proxy) catch {
        try terminal.printError(stderr, "Failed to check for updates");
        return;
    };
    defer allocator.free(release_json);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, release_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        try terminal.printError(stderr, "Failed to parse release info");
        return;
    };
    defer parsed.deinit();

    // Extract version info from release.
    // The "latest" release has tag_name="latest" (not a real version),
    // so we extract the actual version from the body: "Latest stable release (vX.Y.Z)."
    const release = parsed.value;
    const release_obj = switch (release) {
        .object => |obj| obj,
        else => {
            try terminal.printError(stderr, "Invalid release response");
            return;
        },
    };

    var latest_version: []const u8 = "unknown";
    // Try to extract version from body: "Latest stable release (vX.Y.Z)."
    if (release_obj.get("body")) |body_val| {
        if (body_val == .string) {
            const body = body_val.string;
            if (std.mem.indexOf(u8, body, "(")) |open| {
                if (std.mem.indexOf(u8, body[open..], ")")) |close| {
                    latest_version = body[open + 1 .. open + close];
                }
            }
        }
    }
    // Fallback to tag_name if body parsing failed and tag_name looks like a version
    if (std.mem.eql(u8, latest_version, "unknown")) {
        if (release_obj.get("tag_name")) |tag| {
            if (tag == .string) {
                const t = tag.string;
                if (t.len > 0 and t[0] == 'v') {
                    latest_version = t;
                }
            }
        }
    }

    try stdout.print("Latest version: {s}\n", .{latest_version});
    try stdout.flush();

    // Compare versions and skip download if already up-to-date
    const current_stripped = stripVPrefix(current_version);
    const latest_stripped = stripVPrefix(latest_version);
    if (!versionGt(latest_stripped, current_stripped)) {
        try terminal.printSuccess(stdout, "Already up-to-date!");
        try stdout.flush();
        return;
    }

    // Detect current platform for asset matching
    const os_name = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "unknown",
    };
    const arch_name = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "unknown",
    };

    // Find the matching release asset for this platform
    const assets = switch (release) {
        .object => |obj| obj.get("assets") orelse {
            try terminal.printError(stderr, "No assets found");
            return;
        },
        else => return,
    };

    var download_url: ?[]const u8 = null;
    switch (assets) {
        .array => |arr| {
            for (arr.items) |asset| {
                switch (asset) {
                    .object => |obj| {
                        const name = switch (obj.get("name") orelse continue) {
                            .string => |s| s,
                            else => continue,
                        };
                        // Match asset filename containing both OS and arch
                        if (std.mem.containsAtLeast(u8, name, 1, os_name) and
                            std.mem.containsAtLeast(u8, name, 1, arch_name))
                        {
                            const url = switch (obj.get("browser_download_url") orelse continue) {
                                .string => |s| s,
                                else => continue,
                            };
                            download_url = url;
                            break;
                        }
                    },
                    else => continue,
                }
            }
        },
        else => {},
    }

    const url = download_url orelse {
        try terminal.printError(stderr, "No matching binary found for your platform");
        return;
    };

    // Download the release archive
    var buf1: [std.fs.max_path_bytes * 2]u8 = undefined;
    const self_dir = try std.fmt.bufPrint(&buf1, "{s}/self", .{zvm.data_dir});
    std.Io.Dir.cwd().createDirPath(zvm.io, self_dir) catch {};

    var buf2: [std.fs.max_path_bytes * 2]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&buf2, "{s}/zvm-update.tar.gz", .{self_dir});

    try stdout.print("Downloading {s}...\n", .{latest_version});
    try stdout.flush();

    http_client.downloadToFileWithProxy(allocator, zvm.io, zvm.environ_map, url, archive_path, proxy, stdout) catch {
        try terminal.printError(stderr, "Failed to download update");
        std.Io.Dir.cwd().deleteFile(zvm.io, archive_path) catch {};
        return;
    };

    // Extract the archive
    try stdout.print("Installing update...\n", .{});
    try stdout.flush();

    const result = std.process.run(allocator, zvm.io, .{
        .argv = &.{ "tar", "-xf", archive_path, "-C", self_dir },
    }) catch {
        try terminal.printError(stderr, "Failed to extract update");
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Find the extracted binary and replace the current installation.
    // The archive may extract into a subdirectory (e.g. zvm-v0.1.1-aarch64-macos/zvm),
    // so search recursively.
    const exe_name = comptime switch (builtin.os.tag) {
        .windows => "zvm.exe",
        else => "zvm",
    };

    // Resolve the current zvm install directory
    const install_dir = blk: {
        if (zvm.environ_map.get("ZVM_INSTALL")) |env_dir_raw| {
            const env_dir = try allocator.dupe(u8, env_dir_raw);
            break :blk env_dir;
        } else {
            var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_path_len = std.process.executablePath(zvm.io, &exe_buf) catch {
                try terminal.printError(stderr, "Could not determine running binary path");
                return;
            };
            const exe_path = exe_buf[0..exe_path_len];
            if (std.Io.Dir.path.dirname(exe_path)) |dir_path| {
                break :blk allocator.dupe(u8, dir_path) catch {
                    try terminal.printError(stderr, "Out of memory");
                    return;
                };
            }
            try terminal.printError(stderr, "Could not determine install directory");
            return;
        }
    };
    defer allocator.free(install_dir);

    // Find the extracted zvm binary (may be nested in a versioned subdirectory)
    var src_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const src_path = findBinary(allocator, zvm.io, self_dir, exe_name, &src_buf) catch {
        try terminal.printError(stderr, "Could not find extracted zvm binary");
        return;
    };

    var dst_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const dst_path = try std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ install_dir, exe_name });

    // On Unix, rename the old binary aside first — macOS refuses to write
    // to a running executable. Rename is allowed; then write to the original path.
    var old_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&old_buf, "{s}/{s}.old", .{ install_dir, exe_name });
    _ = std.process.run(allocator, zvm.io, .{
        .argv = &.{ "mv", dst_path, old_path },
    }) catch {};

    // Stream-copy the new binary
    const src_file = std.Io.Dir.cwd().openFile(zvm.io, src_path, .{}) catch {
        try terminal.printError(stderr, "Failed to read extracted binary");
        return;
    };
    defer src_file.close(zvm.io);
    const dst_file = std.Io.Dir.cwd().createFile(zvm.io, dst_path, .{}) catch {
        try terminal.printError(stderr, "Failed to write to install directory");
        return;
    };
    defer dst_file.close(zvm.io);

    var src_reader_buf: [8192]u8 = undefined;
    var src_reader = src_file.reader(zvm.io, &src_reader_buf);
    var dst_writer_buf: [8192]u8 = undefined;
    var dst_writer = dst_file.writer(zvm.io, &dst_writer_buf);

    _ = src_reader.interface.streamRemaining(&dst_writer.interface) catch {
        try terminal.printError(stderr, "Failed to copy binary");
        return;
    };
    try dst_writer.interface.flush();

    // Make the new binary executable
    if (builtin.os.tag != .windows) {
        _ = std.process.run(allocator, zvm.io, .{
            .argv = &.{ "chmod", "+x", dst_path },
        }) catch {};
    }

    // Clean up old binary
    std.Io.Dir.cwd().deleteFile(zvm.io, old_path) catch {};

    try terminal.printSuccess(stdout, "Updated zvm to latest version!");
    try stdout.print("Now running zvm {s}\n", .{latest_version});
    try stdout.flush();

    // Show the active Zig version
    if (zvm.getActiveVersion(allocator)) |active| {
        defer allocator.free(active);
        var ver_buf: [std.fs.max_path_bytes]u8 = undefined;
        const ver_path = zvm.versionPath(&ver_buf, active);
        const zig_path = std.fmt.allocPrint(allocator, "{s}/zig", .{ver_path}) catch return;
        defer allocator.free(zig_path);

        const ver_result = std.process.run(allocator, zvm.io, .{
            .argv = &.{ zig_path, "version" },
            .stdout_limit = .limited(1024),
        }) catch return;
        defer allocator.free(ver_result.stdout);
        defer allocator.free(ver_result.stderr);

        if (ver_result.stdout.len > 0) {
            const ver = std.mem.trim(u8, ver_result.stdout, " \n\r");
            try stdout.print("Active Zig: {s} ({s})\n", .{ active, ver });
            try stdout.flush();
        }
    }

    // Clean up the downloaded archive
    std.Io.Dir.cwd().deleteFile(zvm.io, archive_path) catch {};
}
