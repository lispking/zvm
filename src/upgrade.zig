//! Upgrade command — self-update zvm from the latest GitHub release.
//! Queries the GitHub Releases API, finds the platform-matching asset,
//! downloads it, extracts, and replaces the current binary.

const std = @import("std");
const builtin = @import("builtin");
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

/// Check for the latest zvm release on GitHub and upgrade if available.
/// Downloads the platform-matching .tar.gz, extracts the new binary,
/// and replaces the current installation.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
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

    // Extract the tag name (e.g., "v0.2.0")
    const release = parsed.value;
    const tag_name = switch (release) {
        .object => |obj| obj.get("tag_name") orelse {
            try terminal.printError(stderr, "Invalid release response");
            return;
        },
        else => {
            try terminal.printError(stderr, "Invalid release response");
            return;
        },
    };
    const latest_version = switch (tag_name) {
        .string => |s| s,
        else => {
            try terminal.printError(stderr, "Invalid version in response");
            return;
        },
    };

    try stdout.print("Latest version: {s}\n", .{latest_version});
    try stdout.flush();

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
    var archive_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&archive_buf, "{s}/zvm-update.tar.gz", .{zvm.base_dir});

    try stdout.print("Downloading {s}...\n", .{latest_version});
    try stdout.flush();

    try http_client.downloadToFile(allocator, url, archive_path);

    // Extract the archive
    try stdout.print("Installing update...\n", .{});
    try stdout.flush();

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xf", archive_path, "-C", zvm.base_dir },
    }) catch {
        try terminal.printError(stderr, "Failed to extract update");
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Find the extracted binary and replace the current installation
    var dir = std.fs.cwd().openDir(zvm.base_dir, .{ .iterate = true }) catch return;
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
                const src = try std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ zvm.base_dir, exe_name });

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
