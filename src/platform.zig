//! Platform detection and OS abstraction layer.
//! Provides system info detection (OS, arch), symlink management,
//! and home directory resolution for cross-platform support.

const std = @import("std");
const builtin = @import("builtin");

/// System information containing OS and architecture as Zig-style strings.
pub const SystemInfo = struct {
    os: []const u8,
    arch: []const u8,

    /// Returns the Zig-style target triple (e.g., "x86_64-macos").
    /// Note: the returned slice references a stack-local buffer — use immediately.
    pub fn zigTarget(self: SystemInfo) []const u8 {
        var buf: [128]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "{s}-{s}", .{ self.arch, self.os }) catch unreachable;
        return result;
    }
};

/// Detect the current OS and architecture at comptime.
/// Returns Zig-style names: os = "macos"|"linux"|"windows"|..., arch = "x86_64"|"aarch64"|...
pub fn zigStyleSystemInfo() SystemInfo {
    const os_tag = builtin.os.tag;
    const arch = builtin.cpu.arch;

    const os_name: []const u8 = switch (os_tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .dragonfly => "dragonfly",
        else => @tagName(os_tag),
    };

    const arch_name: []const u8 = switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7a",
        .riscv64 => "riscv64",
        .powerpc64, .powerpc64le => "powerpc64le",
        .x86 => "x86",
        else => @tagName(arch),
    };

    return .{
        .os = os_name,
        .arch = arch_name,
    };
}

/// Returns the archive file extension for the current platform.
/// Windows uses .zip, all other platforms use .tar.xz.
pub fn getArchiveExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".zip",
        else => ".tar.xz",
    };
}

/// Create a symbolic link at `link_path` pointing to `target`.
/// Removes any existing file/link at `link_path` before creation.
/// On Windows, creates a directory junction (no admin privileges required).
pub fn createSymlink(target: []const u8, link_path: []const u8, io: std.Io) !void {
    // Remove existing link/dir first
    std.Io.Dir.cwd().deleteFile(io, link_path) catch {};

    if (builtin.os.tag == .windows) {
        // On Windows, use directory junction via mklink /J.
        // Junctions work without administrator privileges and behave like
        // directory symlinks — the linked path resolves transparently.
        std.Io.Dir.cwd().deleteDir(io, link_path) catch {};
        const result = std.process.run(std.heap.page_allocator, io, .{
            .argv = &.{ "cmd", "/c", "mklink", "/J", link_path, target },
        }) catch return error.SymlinkFailed;
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0)
            return error.SymlinkFailed;
        return;
    }

    std.Io.Dir.symLinkAbsolute(io, target, link_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Try harder to remove
            std.Io.Dir.cwd().deleteTree(io, link_path) catch {};
            try std.Io.Dir.symLinkAbsolute(io, target, link_path, .{});
        },
        else => return err,
    };
}

/// Remove a symbolic link at the given path (best-effort, ignores errors).
/// On Windows, junctions are removed as directories.
pub fn removeSymlink(io: std.Io, path: []const u8) void {
    if (builtin.os.tag == .windows) {
        std.Io.Dir.cwd().deleteDir(io, path) catch {};
        return;
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Resolve the home directory (used as fallback for XDG defaults).
/// Caller owns the returned memory.
fn getHomeDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (environ_map.get("USERPROFILE")) |path| {
            return allocator.dupe(u8, path);
        }
    }

    if (environ_map.get("HOME")) |path| {
        return allocator.dupe(u8, path);
    }
    return error.FileNotFound;
}

/// Resolve the XDG config directory.
/// Checks XDG_CONFIG_HOME, falls back to $HOME/.config.
/// On Windows, falls back to %APPDATA% or %USERPROFILE%/.config.
/// Caller owns the returned memory.
pub fn getConfigDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("XDG_CONFIG_HOME")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    if (builtin.os.tag == .windows) {
        if (environ_map.get("APPDATA")) |path| {
            if (path.len > 0) return allocator.dupe(u8, path);
        }
    }

    const home = try getHomeDir(allocator, environ_map);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config", .{home});
}

/// Resolve the XDG data directory.
/// Checks ZVM_PATH (legacy override) first, then XDG_DATA_HOME,
/// falls back to $HOME/.local/share.
/// On Windows, falls back to %USERPROFILE%/.local/share.
/// Caller owns the returned memory.
pub fn getDataDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    // Legacy ZVM_PATH override — use as-is (user already specifies full path)
    if (environ_map.get("ZVM_PATH")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    if (environ_map.get("XDG_DATA_HOME")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    const home = try getHomeDir(allocator, environ_map);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
}

/// Resolve the XDG cache directory.
/// Checks XDG_CACHE_HOME, falls back to $HOME/.cache.
/// On Windows, falls back to %LOCALAPPDATA% or %USERPROFILE%/.cache.
/// Caller owns the returned memory.
pub fn getCacheDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("XDG_CACHE_HOME")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path);
    }

    if (builtin.os.tag == .windows) {
        if (environ_map.get("LOCALAPPDATA")) |path| {
            if (path.len > 0) return allocator.dupe(u8, path);
        }
    }

    const home = try getHomeDir(allocator, environ_map);
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.cache", .{home});
}

/// Build the target-specific platform string used in Zig download URLs.
/// E.g., "x86_64-macos", "aarch64-linux"
pub fn platformTarget(buf: []u8, info: SystemInfo) []const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ info.arch, info.os }) catch buf[0..0];
}
