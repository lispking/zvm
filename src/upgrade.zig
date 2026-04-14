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
    const release_json = http_client.downloadToMemory(allocator, "https://api.github.com/repos/lispking/zvm/releases/latest") catch {
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
    const self_dir = try std.fmt.bufPrint(&buf1, "{s}/self", .{zvm.base_dir});
    std.fs.cwd().makePath(self_dir) catch {};

    var buf2: [std.fs.max_path_bytes * 2]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&buf2, "{s}/zvm-update.tar.gz", .{self_dir});

    try stdout.print("Downloading {s}...\n", .{latest_version});
    try stdout.flush();

    try http_client.downloadToFile(allocator, url, archive_path);

    // Extract the archive
    try stdout.print("Installing update...\n", .{});
    try stdout.flush();

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xf", archive_path, "-C", self_dir },
    }) catch {
        try terminal.printError(stderr, "Failed to extract update");
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Find the extracted binary and replace the current installation
    var dir = std.fs.cwd().openDir(self_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    // Platform-specific binary name
    const exe_name = comptime switch (builtin.os.tag) {
        .windows => "zvm.exe",
        else => "zvm",
    };

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.name, exe_name)) {
            // Determine where the current zvm is installed (ZVM_INSTALL env var)
            const zvm_install = std.process.getEnvVarOwned(allocator, "ZVM_INSTALL") catch null;
            if (zvm_install) |install_dir| {
                defer allocator.free(install_dir);
                var dst_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
                const dst = try std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ install_dir, exe_name });

                var src_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
                const src = try std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ self_dir, exe_name });

                // Stream-copy the new binary over the old one
                const src_file = std.fs.cwd().openFile(src, .{}) catch continue;
                defer src_file.close();
                const dst_file = std.fs.cwd().createFile(dst, .{}) catch continue;
                defer dst_file.close();

                var src_reader_buf: [8192]u8 = undefined;
                var src_reader = src_file.reader(&src_reader_buf);
                var dst_writer_buf: [8192]u8 = undefined;
                var dst_writer = dst_file.writer(&dst_writer_buf);

                _ = src_reader.interface.streamRemaining(&dst_writer.interface) catch continue;
                try dst_writer.interface.flush();

                // Make the new binary executable (Unix)
                _ = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ "chmod", "+x", dst },
                }) catch {};

                try terminal.printSuccess(stdout, "Updated zvm to latest version!");
            }
            break;
        }
    }

    // Clean up the downloaded archive
    std.fs.cwd().deleteFile(archive_path) catch {};
}
