//! Upgrade command — self-update zvm from the latest GitHub release.
//! Queries the GitHub Releases API, finds the platform-matching asset,
//! downloads it, extracts, and replaces the current binary.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zvm_mod = @import("../core/zvm.zig");
const Console = @import("../core/Console.zig");
const platform = @import("../core/platform.zig");
const http_client = @import("../network/http_client.zig");
const update_check = @import("../core/update_check.zig");

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
    console: Console,
) !void {
    console.plain("Current version: v{s} ({s})", .{ current_version, build_options.git_commit });
    console.plain("Checking for zvm updates...", .{});

    // Fetch latest release info from GitHub API (single request)
    const proxy = zvm.settings.proxy;
    const release_json = http_client.downloadToMemoryWithProxy(allocator, zvm.io, zvm.environ_map, "https://api.github.com/repos/lispking/zvm/releases/latest", proxy) catch {
        console.err("Failed to check for updates", .{});
        return;
    };
    defer allocator.free(release_json);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, release_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        console.err("Failed to parse release info", .{});
        return;
    };
    defer parsed.deinit();

    const release = parsed.value;

    // Extract version from release JSON (reuses shared logic)
    const latest_version = update_check.extractVersionFromRelease(release) orelse {
        console.err("Invalid release response", .{});
        return;
    };

    console.plain("Latest version: {s}", .{latest_version});

    // Compare versions and skip download if already up-to-date
    const current_stripped = update_check.stripVPrefix(current_version);
    const latest_stripped = update_check.stripVPrefix(latest_version);
    if (!update_check.versionGt(latest_stripped, current_stripped)) {
        console.success("Already up-to-date!", .{});
        return;
    }

    // Detect current platform for asset matching
    const sys_info = platform.zigStyleSystemInfo();
    const os_name = sys_info.os;
    const arch_name = sys_info.arch;

    // Find the matching release asset for this platform
    const assets = switch (release) {
        .object => |obj| obj.get("assets") orelse {
            console.err("No assets found", .{});
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
        console.err("No matching binary found for your platform", .{});
        return;
    };

    // Download the release archive
    var buf1: [std.fs.max_path_bytes * 2]u8 = undefined;
    const self_dir = try std.fmt.bufPrint(&buf1, "{s}/self", .{zvm.data_dir});
    std.Io.Dir.cwd().createDirPath(zvm.io, self_dir) catch {};

    var buf2: [std.fs.max_path_bytes * 2]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&buf2, "{s}/zvm-update.tar.gz", .{self_dir});

    console.plain("Downloading {s}...", .{latest_version});

    http_client.downloadToFileWithProxy(allocator, zvm.io, zvm.environ_map, url, archive_path, proxy, console.stdout.writer) catch {
        console.err("Failed to download update", .{});
        std.Io.Dir.cwd().deleteFile(zvm.io, archive_path) catch {};
        return;
    };

    console.plain("Installing update...", .{});

    // Extract the archive
    const result = std.process.run(allocator, zvm.io, .{
        .argv = &.{ "tar", "-xf", archive_path, "-C", self_dir },
    }) catch {
        console.err("Failed to extract update", .{});
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
                console.err("Could not determine running binary path", .{});
                return;
            };
            const exe_path = exe_buf[0..exe_path_len];
            if (std.Io.Dir.path.dirname(exe_path)) |dir_path| {
                break :blk allocator.dupe(u8, dir_path) catch {
                    console.err("Out of memory", .{});
                    return;
                };
            }
            console.err("Could not determine install directory", .{});
            return;
        }
    };
    defer allocator.free(install_dir);

    // Find the extracted zvm binary (may be nested in a versioned subdirectory)
    var src_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const src_path = findBinary(allocator, zvm.io, self_dir, exe_name, &src_buf) catch {
        console.err("Could not find extracted zvm binary", .{});
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
    platform.copyFile(zvm.io, src_path, dst_path) catch {
        console.err("Failed to copy binary", .{});
        return;
    };

    // Make the new binary executable
    if (builtin.os.tag != .windows) {
        _ = std.process.run(allocator, zvm.io, .{
            .argv = &.{ "chmod", "+x", dst_path },
        }) catch {};
    }

    // Clean up old binary
    std.Io.Dir.cwd().deleteFile(zvm.io, old_path) catch {};

    console.success("Updated zvm to latest version!", .{});
    console.plain("Now running zvm {s}", .{latest_version});

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
            console.plain("Active Zig: {s} ({s})", .{ active, ver });
        }
    }

    // Clean up the downloaded archive
    std.Io.Dir.cwd().deleteFile(zvm.io, archive_path) catch {};
}
