//! ZVM core struct — the central data structure for the Zig Version Manager.
//! Manages the base directory (~/.zvm), settings, version discovery,
//! symlink-based version switching, and installed version enumeration.

const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("settings.zig");
const platform = @import("platform.zig");

pub const ZVM = struct {
    /// Base directory for all zvm data (default: ~/.zvm).
    base_dir: []const u8,
    /// Loaded settings (version map URLs, color prefs, etc.).
    settings: settings_mod.Settings,
    /// GPA allocator for long-lived allocations.
    allocator: std.mem.Allocator,
    /// Resolved home directory path (owned, freed in deinit).
    home: []const u8,

    /// Initialize the ZVM environment.
    /// Resolves home directory, creates ~/.zvm and ~/.zvm/self directories,
    /// and loads (or creates) settings from JSON.
    pub fn init(allocator: std.mem.Allocator) !ZVM {
        const home = try platform.getHomeDir(allocator);

        var base_buf: [std.fs.max_path_bytes]u8 = undefined;
        const base_dir = try std.fmt.bufPrint(&base_buf, "{s}/.zvm", .{home});
        const owned_base = try allocator.dupe(u8, base_dir);

        // Create base directories
        std.fs.cwd().makePath(owned_base) catch {};
        const self_path = try std.fmt.allocPrint(allocator, "{s}/self", .{owned_base});
        std.fs.cwd().makePath(self_path) catch {};
        allocator.free(self_path);

        // Load settings — settings takes ownership of the path
        const settings_path = try std.fmt.allocPrint(allocator, "{s}/settings.json", .{owned_base});
        const settings = try settings_mod.Settings.load(allocator, settings_path);

        return .{
            .base_dir = owned_base,
            .settings = settings,
            .allocator = allocator,
            .home = home,
        };
    }

    /// Release all owned memory (home, base_dir, settings strings, settings path).
    pub fn deinit(self: *ZVM) void {
        self.allocator.free(self.home);
        self.allocator.free(self.base_dir);
        self.allocator.free(self.settings.version_map_url);
        self.allocator.free(self.settings.zls_vmu);
        self.allocator.free(self.settings.mirror_list_url);
        self.allocator.free(self.settings.preferred_mirror);
        self.allocator.free(self.settings.proxy);
        if (self.settings.path) |p| self.allocator.free(p);
    }

    /// Build the path for a specific version directory (e.g., ~/.zvm/0.13.0).
    pub fn versionPath(self: *ZVM, buf: []u8, version: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.base_dir, version }) catch buf[0..0];
    }

    /// Build the bin symlink path (e.g., ~/.zvm/bin).
    pub fn binPath(self: *ZVM, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/bin", .{self.base_dir}) catch buf[0..0];
    }

    /// Build the path for the cached Zig version map (e.g., ~/.zvm/versions.json).
    pub fn versionsCachePath(self: *ZVM, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/versions.json", .{self.base_dir}) catch buf[0..0];
    }

    /// Build the path for the cached ZLS version map (e.g., ~/.zvm/versions-zls.json).
    pub fn zlsVersionsCachePath(self: *ZVM, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/versions-zls.json", .{self.base_dir}) catch buf[0..0];
    }

    /// List all installed Zig versions by iterating the base directory.
    /// Skips special directories: "bin", "self", and .json files.
    /// Caller owns the returned list and must free each item.
    pub fn getInstalledVersions(self: *ZVM, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var versions: std.ArrayList([]const u8) = .empty;
        errdefer versions.deinit(allocator);

        var dir = try std.fs.cwd().openDir(self.base_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            // Skip special directories
            if (std.mem.eql(u8, entry.name, "bin") or
                std.mem.eql(u8, entry.name, "self"))
                continue;
            // Skip settings/cache files if somehow dirs
            if (std.mem.endsWith(u8, entry.name, ".json")) continue;

            const name = try allocator.dupe(u8, entry.name);
            try versions.append(allocator, name);
        }

        return versions;
    }

    /// Check if a specific Zig version is installed by testing directory existence.
    pub fn isVersionInstalled(self: *ZVM, version: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.versionPath(&buf, version);
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// Set the active Zig version by creating/updating the ~/.zvm/bin symlink
    /// and writing the version name to a .active marker file.
    /// The symlink/junction points to the absolute path of the version directory.
    pub fn setBin(self: *ZVM, version: []const u8) !void {
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = self.versionPath(&target_buf, version);

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_path = self.binPath(&link_buf);

        // base_dir is always absolute (resolved from HOME), so target is already absolute.
        // Remove existing symlink, then create new one pointing to the version directory.
        platform.removeSymlink(link_path);
        try platform.createSymlink(target, link_path);

        // Write active version marker file (used by getActiveVersion, works on all platforms)
        var active_buf: [std.fs.max_path_bytes]u8 = undefined;
        const active_path = std.fmt.bufPrint(&active_buf, "{s}/.active", .{self.base_dir}) catch return;
        const file = std.fs.cwd().createFile(active_path, .{}) catch return;
        defer file.close();
        var w_buf: [256]u8 = undefined;
        var writer = file.writer(&w_buf);
        writer.interface.writeAll(version) catch {};
        writer.interface.flush() catch {};
    }

    /// Get the currently active version by reading the .active marker file.
    /// Returns null if no active version is set.
    /// Caller owns the returned memory.
    pub fn getActiveVersion(self: *ZVM, allocator: std.mem.Allocator) ?[]const u8 {
        var active_buf: [std.fs.max_path_bytes]u8 = undefined;
        const active_path = std.fmt.bufPrint(&active_buf, "{s}/.active", .{self.base_dir}) catch return null;

        const file = std.fs.cwd().openFile(active_path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 256) catch return null;
        defer allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \n\r");
        if (trimmed.len == 0) return null;
        return allocator.dupe(u8, trimmed) catch return null;
    }
};
