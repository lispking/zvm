//! ZVM core struct — the central data structure for the Zig Version Manager.
//! Manages XDG-compliant directories (config, data, cache), settings,
//! version discovery, symlink-based version switching, and installed version enumeration.

const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");
const platform = @import("platform.zig");

pub const ZVM = struct {
    /// Config directory (default: ~/.config/zvm).
    config_dir: []const u8,
    /// Data directory (default: ~/.local/share/zvm).
    data_dir: []const u8,
    /// Cache directory (default: ~/.cache/zvm).
    cache_dir: []const u8,
    /// Loaded settings (version map URLs, color prefs, etc.).
    settings: settings_mod.Settings,
    /// GPA allocator for long-lived allocations.
    allocator: std.mem.Allocator,
    /// I/O context from std.process.Init — needed for subprocess and HTTP operations.
    io: std.Io,
    /// Environment map from std.process.Init — needed for HTTP proxy auto-detection.
    environ_map: *std.process.Environ.Map,

    /// Initialize the ZVM environment.
    /// Resolves XDG directories, creates them, and loads (or creates) settings from JSON.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map) !ZVM {
        const xdg_config = try platform.getConfigDir(allocator, environ_map);
        const xdg_data = try platform.getDataDir(allocator, environ_map);
        const xdg_cache = try platform.getCacheDir(allocator, environ_map);

        // Build zvm-specific paths under XDG directories
        var config_buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_dir = try std.fmt.bufPrint(&config_buf, "{s}/zvm", .{xdg_config});
        const owned_config = try allocator.dupe(u8, config_dir);
        allocator.free(xdg_config);

        var data_buf: [std.fs.max_path_bytes]u8 = undefined;
        const data_dir = try std.fmt.bufPrint(&data_buf, "{s}/zvm", .{xdg_data});
        const owned_data = try allocator.dupe(u8, data_dir);
        allocator.free(xdg_data);

        var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cache_dir = try std.fmt.bufPrint(&cache_buf, "{s}/zvm", .{xdg_cache});
        const owned_cache = try allocator.dupe(u8, cache_dir);
        allocator.free(xdg_cache);

        // Create directory trees
        std.Io.Dir.cwd().createDirPath(io, owned_config) catch {};
        std.Io.Dir.cwd().createDirPath(io, owned_data) catch {};
        std.Io.Dir.cwd().createDirPath(io, owned_cache) catch {};

        const self_path = try std.fmt.allocPrint(allocator, "{s}/self", .{owned_data});
        std.Io.Dir.cwd().createDirPath(io, self_path) catch {};
        allocator.free(self_path);

        // Load settings from config directory
        const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{owned_config});
        const settings = try settings_mod.Settings.load(allocator, io, settings_path);

        return .{
            .config_dir = owned_config,
            .data_dir = owned_data,
            .cache_dir = owned_cache,
            .settings = settings,
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
        };
    }

    /// Release all owned memory (directories, settings strings, settings path).
    pub fn deinit(self: *ZVM) void {
        self.allocator.free(self.config_dir);
        self.allocator.free(self.data_dir);
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.settings.version_map_url);
        self.allocator.free(self.settings.zls_vmu);
        self.allocator.free(self.settings.mirror_list_url);
        self.allocator.free(self.settings.preferred_mirror);
        self.allocator.free(self.settings.proxy);
        if (self.settings.path) |p| self.allocator.free(p);
    }

    /// Build the path for a specific version directory (e.g., ~/.local/share/zvm/0.13.0).
    pub fn versionPath(self: *ZVM, buf: []u8, version: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.data_dir, version }) catch buf[0..0];
    }

    /// Build the bin symlink path (e.g., ~/.local/share/zvm/bin).
    pub fn binPath(self: *ZVM, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/bin", .{self.data_dir}) catch buf[0..0];
    }

    /// Build the path for the cached Zig version map (e.g., ~/.cache/zvm/versions.json).
    pub fn versionsCachePath(self: *ZVM, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/versions.json", .{self.cache_dir}) catch buf[0..0];
    }

    /// Build the path for the cached ZLS version map (e.g., ~/.cache/zvm/versions-zls.json).
    pub fn zlsVersionsCachePath(self: *ZVM, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/versions-zls.json", .{self.cache_dir}) catch buf[0..0];
    }

    /// List all installed Zig versions by iterating the data directory.
    /// Skips special directories: "bin", "self".
    /// Caller owns the returned list and must free each item.
    pub fn getInstalledVersions(self: *ZVM, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var versions: std.ArrayList([]const u8) = .empty;
        errdefer versions.deinit(allocator);

        var dir = try std.Io.Dir.cwd().openDir(self.io, self.data_dir, .{ .iterate = true });
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            // Skip special directories
            if (std.mem.eql(u8, entry.name, "bin") or
                std.mem.eql(u8, entry.name, "self"))
                continue;

            const name = try allocator.dupe(u8, entry.name);
            try versions.append(allocator, name);
        }

        return versions;
    }

    /// Check if a specific Zig version is installed by testing directory existence.
    pub fn isVersionInstalled(self: *ZVM, version: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.versionPath(&buf, version);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Set the active Zig version by creating/updating the bin symlink
    /// and writing the version name to a .active marker file.
    /// The symlink/junction points to the absolute path of the version directory.
    pub fn setBin(self: *ZVM, version: []const u8) !void {
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = self.versionPath(&target_buf, version);

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_path = self.binPath(&link_buf);

        // data_dir is always absolute (resolved from XDG/HOME), so target is already absolute.
        // Remove existing symlink, then create new one pointing to the version directory.
        platform.removeSymlink(self.io, link_path);
        try platform.createSymlink(target, link_path, self.io);

        // Write active version marker file (used by getActiveVersion, works on all platforms)
        var active_buf: [std.fs.max_path_bytes]u8 = undefined;
        const active_path = std.fmt.bufPrint(&active_buf, "{s}/.active", .{self.data_dir}) catch return;
        const file = std.Io.Dir.cwd().createFile(self.io, active_path, .{}) catch return;
        defer file.close(self.io);
        var w_buf: [256]u8 = undefined;
        var writer = file.writer(self.io, &w_buf);
        writer.interface.writeAll(version) catch {};
        writer.interface.flush() catch {};
    }

    /// Get the currently active version by reading the .active marker file.
    /// Returns null if no active version is set.
    /// Caller owns the returned memory.
    pub fn getActiveVersion(self: *ZVM, allocator: std.mem.Allocator) ?[]const u8 {
        var active_buf: [std.fs.max_path_bytes]u8 = undefined;
        const active_path = std.fmt.bufPrint(&active_buf, "{s}/.active", .{self.data_dir}) catch return null;

        const file = std.Io.Dir.cwd().openFile(self.io, active_path, .{}) catch return null;
        defer file.close(self.io);

        var read_buf: [256]u8 = undefined;
        var reader = file.reader(self.io, &read_buf);
        const content = reader.interface.allocRemaining(allocator, .limited(256)) catch return null;
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \n\r");
        if (trimmed.len == 0) return null;
        return allocator.dupe(u8, trimmed) catch return null;
    }
};
