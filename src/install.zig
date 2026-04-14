//! Zig version installation command.
//! Handles the full install flow: fetch version map → resolve version → download
//! (with mirror support) → verify SHA256 → extract → rename → symlink.
//! Optionally installs ZLS (Zig Language Server) alongside Zig.

const std = @import("std");
const zvm_mod = @import("zvm.zig");
const cli = @import("cli.zig");
const platform = @import("platform.zig");
const terminal = @import("terminal.zig");
const version_map = @import("version_map.zig");
const http_client = @import("http_client.zig");
const archive = @import("archive.zig");
const crypto = @import("crypto.zig");

/// Main entry point for the `zvm install` command.
/// Resolves the requested version, checks if already installed,
/// downloads, verifies, extracts, and activates.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    flags: cli.InstallFlags,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Get system info for platform-specific download
    const sys_info = platform.zigStyleSystemInfo();
    var platform_buf: [128]u8 = undefined;
    const target = platform.platformTarget(&platform_buf, sys_info);

    // Fetch version map from configured URL
    try stdout.print("Fetching version map...\n", .{});
    try stdout.flush();

    const parsed_map = version_map.fetchVersionMap(allocator, zvm.settings.version_map_url) catch |err| {
        try terminal.printError(stderr, "Failed to fetch version map");
        return err;
    };
    defer parsed_map.deinit();
    const vmap = &parsed_map.value.object;

    // Check if already installed (skip for --force or master with newer version available)
    if (!flags.force and zvm.isVersionInstalled(version)) {
        if (std.mem.eql(u8, version, "master")) {
            // For master, check if the installed version matches the latest
            if (version_map.getMasterVersion(vmap)) |remote_ver| {
                var ver_buf: [std.fs.max_path_bytes]u8 = undefined;
                const ver_path = zvm.versionPath(&ver_buf, version);
                const zig_path = try std.fmt.allocPrint(allocator, "{s}/zig", .{ver_path});
                defer allocator.free(zig_path);

                const result = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ zig_path, "version" },
                    .max_output_bytes = 1024,
                }) catch {
                    try installVersion(zvm, allocator, version, target, vmap, flags, stdout, stderr);
                    return;
                };
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);

                const installed_ver = std.mem.trim(u8, result.stdout, " \n\r");
                if (std.mem.eql(u8, installed_ver, remote_ver)) {
                    try stdout.print("Master is already up to date ({s}). Use --force to reinstall.\n", .{installed_ver});
                    try stdout.flush();
                    return;
                }
            }
        } else {
            try stdout.print("Zig {s} is already installed. Use --force to reinstall.\n", .{version});
            try stdout.flush();
            return;
        }
    }

    try installVersion(zvm, allocator, version, target, vmap, flags, stdout, stderr);
}

/// Core installation logic: download, verify, extract, rename, symlink.
fn installVersion(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    target: []const u8,
    vmap: *const version_map.VersionMap,
    flags: cli.InstallFlags,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Resolve the tarball download URL from the version map
    const tar_url = version_map.getTarPath(version, target, vmap) catch {
        try terminal.printError(stderr, "Failed to find download for this version/platform");
        return error.UnsupportedVersion;
    };

    // Get expected SHA256 checksum (optional — warns if missing)
    const shasum = version_map.getVersionShasum(version, target, vmap) catch blk: {
        try stdout.print("Warning: No shasum found, skipping verification.\n", .{});
        try stdout.flush();
        break :blk null;
    };

    // Determine local archive filename from the download URL
    const archive_name = if (std.mem.lastIndexOfScalar(u8, tar_url, '/')) |idx| tar_url[idx + 1 ..] else "zig-archive";

    var archive_path_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const archive_path = try std.fmt.bufPrint(&archive_path_buf, "{s}/{s}", .{ zvm.base_dir, archive_name });

    // Download archive (with optional mirror support)
    try stdout.print("Downloading Zig {s}...\n", .{version});
    try stdout.flush();

    const actual_url = if (flags.nomirror) blk: {
        try http_client.downloadToFile(allocator, tar_url, archive_path);
        break :blk tar_url;
    } else blk: {
        const mirror_url = http_client.attemptMirrorDownload(allocator, zvm.settings.mirror_list_url, tar_url, archive_path, stdout, &zvm.settings) catch {
            try http_client.downloadToFile(allocator, tar_url, archive_path);
            break :blk tar_url;
        };
        break :blk mirror_url;
    };

    // Show the actual download source
    if (actual_url.ptr != tar_url.ptr) {
        try stdout.print("  from: {s}\n", .{actual_url});
        try stdout.flush();
        allocator.free(actual_url);
    }

    // Verify SHA256 checksum
    if (shasum) |expected| {
        try stdout.print("Verifying checksum...\n", .{});
        try stdout.flush();

        const matches = crypto.verifyFileSha256(archive_path, expected) catch {
            try terminal.printError(stderr, "Failed to verify checksum");
            return error.ShasumMismatch;
        };

        if (!matches) {
            try terminal.printError(stderr, "SHA256 checksum mismatch!");
            std.fs.cwd().deleteFile(archive_path) catch {};
            return error.ShasumMismatch;
        }
        try terminal.printSuccess(stdout, "Checksum verified.");
    }

    // Extract the archive
    try stdout.print("Extracting...\n", .{});
    try stdout.flush();

    archive.extractArchive(allocator, archive_path, zvm.base_dir) catch {
        try terminal.printError(stderr, "Failed to extract archive");
        return error.ExtractionFailed;
    };

    // Rename the extracted directory (e.g., zig-macos-x86_64-0.13.0 → 0.13.0)
    try renameExtractedDir(zvm, allocator, version, target, stderr);

    // Create symlink so this version becomes the active one
    try zvm.setBin(version);

    // Clean up the downloaded archive
    std.fs.cwd().deleteFile(archive_path) catch {};

    // Clean up any leftover extracted zig-* directories
    cleanupExtractedDirs(zvm);

    try terminal.printSuccess(stdout, "Installed Zig");

    // Verify the installed binary can actually compile (detect platform compatibility issues)
    try stdout.print("Verifying installation...\n", .{});
    try stdout.flush();

    if (!try verifyInstall(zvm, allocator, version)) {
        try terminal.printWarning(stdout, "This Zig version has linking issues on your platform.");
        try stdout.print(
            \\This is a known issue with official Zig releases on macOS 26+.
            \\The binary can run basic commands but cannot compile programs.
            \\
            \\Suggested fixes:
            \\  1. Install the latest nightly:  zvm install master
            \\  2. Use Mach engine builds:     zvm vmu zig mach && zvm install <version>
            \\
        , .{});
        try stdout.flush();
        return;
    }

    try stdout.print("Now using Zig {s}\n", .{version});
    try stdout.flush();

    // Optionally install ZLS alongside Zig
    if (flags.zls) {
        try installZls(zvm, allocator, version, flags.full, stdout, stderr);
    }
}

/// Rename the extracted archive directory to match the version name.
/// Zig archives extract to directories like "zig-macos-x86_64-0.13.0".
/// We rename them to just "0.13.0" for cleaner path management.
/// If the version directory already exists (--force), it is removed first.
fn renameExtractedDir(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    target: []const u8,
    stderr: *std.Io.Writer,
) !void {
    _ = allocator;

    // Find the extracted directory (starts with "zig-" and matches both arch and os).
    // The target string is "arch-os" (e.g., "aarch64-macos"), but archive directories
    // use "os-arch" order (e.g., "zig-macos-aarch64-0.13.0"), so we match components separately.
    const dash_idx = std.mem.indexOfScalar(u8, target, '-') orelse return;
    const arch_part = target[0..dash_idx];
    const os_part = target[dash_idx + 1 ..];

    var dir = std.fs.cwd().openDir(zvm.base_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var found: ?[]const u8 = null;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, "zig-") and
            std.mem.containsAtLeast(u8, entry.name, 1, arch_part) and
            std.mem.containsAtLeast(u8, entry.name, 1, os_part))
        {
            found = entry.name;
            break;
        }
    }

    // No extracted directory found — version dir may already exist
    if (found == null) return;

    // Remove existing version directory if it exists (for --force reinstalls)
    var version_buf: [std.fs.max_path_bytes]u8 = undefined;
    const version_path = zvm.versionPath(&version_buf, version);
    std.fs.cwd().deleteTree(version_path) catch {};

    // Rename the extracted directory to the version name
    dir.rename(found.?, version) catch {
        try terminal.printError(stderr, "Failed to rename extracted directory");
        return;
    };
}

/// Remove any leftover zig-* directories from failed or interrupted extractions.
fn cleanupExtractedDirs(zvm: *zvm_mod.ZVM) void {
    var dir = std.fs.cwd().openDir(zvm.base_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, "zig-")) {
            var buf: [std.fs.max_path_bytes * 2]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ zvm.base_dir, entry.name }) catch continue;
            std.fs.cwd().deleteTree(path) catch {};
        }
    }
}

/// Verify the installed Zig binary can actually compile programs.
/// Creates a minimal Zig source file, compiles it, and checks for linking errors.
/// Returns true if the binary works correctly, false if it has platform compatibility issues.
fn verifyInstall(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
) !bool {
    var ver_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ver_path = zvm.versionPath(&ver_buf, version);
    const zig_path = try std.fmt.allocPrint(allocator, "{s}/zig", .{ver_path});
    defer allocator.free(zig_path);

    // Create a temporary test file in the zvm base directory
    var test_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const test_path = try std.fmt.bufPrint(&test_buf, "{s}/_zvm_smoke_test.zig", .{zvm.base_dir});
    defer std.fs.cwd().deleteFile(test_path) catch {};

    const test_file = try std.fs.cwd().createFile(test_path, .{});
    defer test_file.close();
    var test_writer_buf: [256]u8 = undefined;
    var test_writer = test_file.writer(&test_writer_buf);
    try test_writer.interface.writeAll("pub fn main() void {}\n");
    try test_writer.interface.flush();

    // Try to compile the test file
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ zig_path, "build-exe", test_path, "-fno-emit-bin" },
        .max_output_bytes = 4096,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check for linking errors (undefined symbol errors indicate platform incompatibility)
    if (result.term == .Exited and result.term.Exited == 0) {
        return true;
    }

    // Check stderr for "undefined symbol" — indicates macOS 26+ linking issue
    if (std.mem.containsAtLeast(u8, result.stderr, 1, "undefined symbol")) {
        return false;
    }

    // Other errors — might be a real issue, but not a platform compat problem
    return true;
}

/// Install ZLS (Zig Language Server) for a specific Zig version.
/// Queries the ZLS select-version API, downloads the platform-specific binary,
/// and places it alongside the Zig installation.
fn installZls(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    full_compat: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    try stdout.print("Installing ZLS for Zig {s}...\n", .{version});
    try stdout.flush();

    // Get the installed Zig version string
    var ver_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ver_path = zvm.versionPath(&ver_buf, version);
    const zig_path = try std.fmt.allocPrint(allocator, "{s}/zig", .{ver_path});
    defer allocator.free(zig_path);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ zig_path, "version" },
        .max_output_bytes = 1024,
    }) catch {
        try terminal.printError(stderr, "Failed to get Zig version for ZLS lookup");
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const zig_version = std.mem.trim(u8, result.stdout, " \n\r");

    // Query ZLS select-version API with the Zig version and compatibility mode
    const compat_mode = if (full_compat) "full" else "only-runtime";
    const zls_url = try std.fmt.allocPrint(
        allocator,
        "{s}v1/zls/select-version?zig_version={s}&compatibility={s}",
        .{ zvm.settings.zls_vmu, zig_version, compat_mode },
    );
    defer allocator.free(zls_url);

    const zls_response = http_client.downloadToMemory(allocator, zls_url) catch {
        try terminal.printError(stderr, "Failed to query ZLS version");
        return;
    };
    defer allocator.free(zls_response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, zls_response, .{}) catch {
        try terminal.printError(stderr, "Failed to parse ZLS response");
        return;
    };
    defer parsed.deinit();

    const zls_data = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            try terminal.printError(stderr, "Invalid ZLS response");
            return;
        },
    };

    // Find platform-specific download URL in the ZLS response
    const sys_info = platform.zigStyleSystemInfo();
    var plat_buf: [128]u8 = undefined;
    const target = platform.platformTarget(&plat_buf, sys_info);

    var tarball_url: ?[]const u8 = null;
    var outer_iter = zls_data.iterator();
    while (outer_iter.next()) |entry| {
        switch (entry.value_ptr.*) {
            .object => |obj| {
                const plat_entry = obj.get(target) orelse continue;
                switch (plat_entry) {
                    .object => |plat_obj| {
                        if (plat_obj.get("tarball")) |tb| {
                            tarball_url = tb.string;
                            break;
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    const zls_tarball = tarball_url orelse {
        try terminal.printError(stderr, "No ZLS build found for your platform");
        return;
    };

    // Download ZLS archive
    const zls_archive_name = if (std.mem.lastIndexOfScalar(u8, zls_tarball, '/')) |idx| zls_tarball[idx + 1 ..] else "zls-archive";

    var archive_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const zls_archive_path = try std.fmt.bufPrint(&archive_buf, "{s}/{s}", .{ zvm.base_dir, zls_archive_name });

    try http_client.downloadToFile(allocator, zls_tarball, zls_archive_path);

    // Extract to a temporary directory
    var temp_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const temp_dir = try std.fmt.bufPrint(&temp_buf, "{s}/zls-temp", .{zvm.base_dir});
    std.fs.cwd().makePath(temp_dir) catch {};

    archive.extractArchive(allocator, zls_archive_path, temp_dir) catch {
        try terminal.printError(stderr, "Failed to extract ZLS archive");
        return;
    };

    // Find the zls binary in the extracted directory and copy it to the version dir
    var temp_handle = std.fs.cwd().openDir(temp_dir, .{ .iterate = true }) catch return;
    defer temp_handle.close();

    var iter = temp_handle.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            var inner_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
            const inner_path = try std.fmt.bufPrint(&inner_buf, "{s}/{s}", .{ temp_dir, entry.name });

            var inner_dir = std.fs.cwd().openDir(inner_path, .{ .iterate = true }) catch continue;
            defer inner_dir.close();

            var inner_iter = inner_dir.iterate();
            while (try inner_iter.next()) |inner_entry| {
                if (std.mem.eql(u8, inner_entry.name, "zls") or std.mem.eql(u8, inner_entry.name, "zls.exe")) {
                    // Copy the zls binary to ~/.zvm/<version>/zls
                    var src_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
                    const src = try std.fmt.bufPrint(&src_buf, "{s}/{s}/{s}", .{ temp_dir, entry.name, inner_entry.name });

                    var dst_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
                    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/{s}/zls", .{ zvm.base_dir, version });

                    const src_file = std.fs.cwd().openFile(src, .{}) catch continue;
                    defer src_file.close();
                    const dst_file = std.fs.cwd().createFile(dst, .{}) catch continue;
                    defer dst_file.close();

                    // Stream-copy the binary file
                    var src_reader_buf: [8192]u8 = undefined;
                    var src_reader = src_file.reader(&src_reader_buf);
                    var dst_writer_buf: [8192]u8 = undefined;
                    var dst_writer = dst_file.writer(&dst_writer_buf);

                    _ = src_reader.interface.streamRemaining(&dst_writer.interface) catch continue;
                    try dst_writer.interface.flush();

                    // Make the binary executable (Unix only, best-effort)
                    _ = std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &.{ "chmod", "+x", dst },
                    }) catch {};
                    try terminal.printSuccess(stdout, "Installed ZLS");
                    try stdout.flush();
                }
            }
        }
    }

    // Cleanup temporary files
    std.fs.cwd().deleteFile(zls_archive_path) catch {};
    std.fs.cwd().deleteTree(temp_dir) catch {};
}
