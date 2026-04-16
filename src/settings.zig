//! Settings persistence for zvm.
//! Manages the JSON configuration file ($XDG_CONFIG_HOME/zvm/settings.json) with
//! eager persistence — every mutation immediately writes to disk.

const std = @import("std");

/// Application settings, persisted as JSON.
pub const Settings = struct {
    /// URL for the Zig version map (default: ziglang.org).
    version_map_url: []const u8,
    /// URL for the ZLS version map (default: zigtools.org).
    zls_vmu: []const u8,
    /// URL for the community mirror list.
    mirror_list_url: []const u8,
    /// Whether to use ANSI colors in terminal output.
    use_color: bool,
    /// Whether to always force reinstall without prompting.
    always_force_install: bool,
    /// Cached preferred mirror base URL (empty = no cache).
    preferred_mirror: []const u8,
    /// Unix timestamp (seconds) when the preferred mirror was last validated.
    mirror_updated_at: i64,
    /// HTTP/HTTPS proxy URL (empty = auto-detect from environment variables).
    proxy: []const u8,

    /// Internal path to the settings JSON file (not serialized).
    path: ?[]const u8,

    /// Default settings matching the official Zig infrastructure.
    pub const default: Settings = .{
        .version_map_url = "https://ziglang.org/download/index.json",
        .zls_vmu = "https://releases.zigtools.org/",
        .mirror_list_url = "https://ziglang.org/download/community-mirrors.txt",
        .use_color = true,
        .always_force_install = false,
        .preferred_mirror = "",
        .mirror_updated_at = 0,
        .proxy = "",
        .path = null,
    };

    /// Serializable subset of settings (excludes internal fields like path).
    const JsonSettings = struct {
        version_map_url: []const u8,
        zls_vmu: []const u8,
        mirror_list_url: []const u8,
        use_color: bool,
        always_force_install: bool,
        preferred_mirror: []const u8 = "",
        mirror_updated_at: i64 = 0,
        proxy: []const u8 = "",
    };

    /// Return a copy of this Settings with all string fields heap-allocated.
    /// The caller owns the returned value and must free all string fields.
    fn toOwned(self: Settings, allocator: std.mem.Allocator) !Settings {
        return Settings{
            .version_map_url = try allocator.dupe(u8, self.version_map_url),
            .zls_vmu = try allocator.dupe(u8, self.zls_vmu),
            .mirror_list_url = try allocator.dupe(u8, self.mirror_list_url),
            .use_color = self.use_color,
            .always_force_install = self.always_force_install,
            .preferred_mirror = try allocator.dupe(u8, self.preferred_mirror),
            .mirror_updated_at = self.mirror_updated_at,
            .proxy = try allocator.dupe(u8, self.proxy),
            .path = self.path,
        };
    }

    /// Load settings from a JSON file, or create with defaults if not found.
    /// Takes ownership of the `path` parameter.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Settings {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // Create new settings file with defaults; all strings must be heap-owned.
                var settings = try default.toOwned(allocator);
                settings.path = path;
                try settings.save(allocator, io);
                return settings;
            },
            else => return err,
        };
        defer file.close(io);

        var read_buf: [1024 * 1024]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const content = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(
            JsonSettings,
            allocator,
            content,
            .{ .ignore_unknown_fields = true },
        ) catch {
            // If parsing fails, return defaults; all strings must be heap-owned.
            var settings = try default.toOwned(allocator);
            settings.path = path;
            return settings;
        };
        defer parsed.deinit();

        const val = parsed.value;
        var settings = Settings{
            .version_map_url = try allocator.dupe(u8, val.version_map_url),
            .zls_vmu = try allocator.dupe(u8, val.zls_vmu),
            .mirror_list_url = try allocator.dupe(u8, val.mirror_list_url),
            .use_color = val.use_color,
            .always_force_install = val.always_force_install,
            .preferred_mirror = try allocator.dupe(u8, val.preferred_mirror),
            .mirror_updated_at = val.mirror_updated_at,
            .proxy = try allocator.dupe(u8, val.proxy),
            .path = path,
        };

        // Fill any empty fields with defaults
        try settings.resetEmpty(allocator);
        return settings;
    }

    /// Persist current settings to the JSON file.
    pub fn save(self: Settings, allocator: std.mem.Allocator, io: std.Io) !void {
        _ = allocator;
        const path = self.path orelse return;

        const jsonable = JsonSettings{
            .version_map_url = self.version_map_url,
            .zls_vmu = self.zls_vmu,
            .mirror_list_url = self.mirror_list_url,
            .use_color = self.use_color,
            .always_force_install = self.always_force_install,
            .preferred_mirror = self.preferred_mirror,
            .mirror_updated_at = self.mirror_updated_at,
            .proxy = self.proxy,
        };

        // Ensure parent directory exists
        if (std.Io.Dir.path.dirname(path)) |dir_path| {
            std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
        }

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try std.json.Stringify.value(jsonable, .{
            .whitespace = .indent_4,
        }, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    /// Fill in any empty/missing fields with their default values.
    pub fn resetEmpty(self: *Settings, allocator: std.mem.Allocator) !void {
        if (self.version_map_url.len == 0) {
            self.version_map_url = try allocator.dupe(u8, default.version_map_url);
        }
        if (self.zls_vmu.len == 0) {
            self.zls_vmu = try allocator.dupe(u8, default.zls_vmu);
        }
        if (self.mirror_list_url.len == 0) {
            self.mirror_list_url = try allocator.dupe(u8, default.mirror_list_url);
        }
    }

    /// Set the Zig version map URL and persist immediately.
    pub fn setVersionMapUrl(self: *Settings, allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
        const old = self.version_map_url;
        self.version_map_url = try allocator.dupe(u8, url);
        self.save(allocator, io) catch {};
        allocator.free(old);
    }

    /// Set the ZLS version map URL and persist immediately.
    pub fn setZlsVMU(self: *Settings, allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
        const old = self.zls_vmu;
        self.zls_vmu = try allocator.dupe(u8, url);
        self.save(allocator, io) catch {};
        allocator.free(old);
    }

    /// Set the mirror list URL and persist immediately.
    pub fn setMirrorListUrl(self: *Settings, allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
        const old = self.mirror_list_url;
        self.mirror_list_url = try allocator.dupe(u8, url);
        self.save(allocator, io) catch {};
        allocator.free(old);
    }

    /// Reset the Zig version map URL to the official default.
    pub fn resetVersionMap(self: *Settings, allocator: std.mem.Allocator, io: std.Io) !void {
        const old = self.version_map_url;
        self.version_map_url = try allocator.dupe(u8, default.version_map_url);
        self.save(allocator, io) catch {};
        allocator.free(old);
    }

    /// Reset the ZLS version map URL to the official default.
    pub fn resetZlsVMU(self: *Settings, allocator: std.mem.Allocator, io: std.Io) !void {
        const old = self.zls_vmu;
        self.zls_vmu = try allocator.dupe(u8, default.zls_vmu);
        self.save(allocator, io) catch {};
        allocator.free(old);
    }

    /// Reset the mirror list URL to the official default.
    pub fn resetMirrorList(self: *Settings, allocator: std.mem.Allocator, io: std.Io) !void {
        const old = self.mirror_list_url;
        self.mirror_list_url = try allocator.dupe(u8, default.mirror_list_url);
        self.save(allocator, io) catch {};
        allocator.free(old);
    }

    /// Toggle colored output on/off and persist.
    pub fn toggleColor(self: *Settings, allocator: std.mem.Allocator, io: std.Io) !void {
        self.use_color = !self.use_color;
        try self.save(allocator, io);
    }

    /// Set the proxy URL and persist immediately.
    pub fn setProxy(self: *Settings, allocator: std.mem.Allocator, io: std.Io, url: []const u8) !void {
        const old = self.proxy;
        self.proxy = try allocator.dupe(u8, url);
        self.save(allocator, io) catch {};
        allocator.free(old);
    }

    /// Update the cached preferred mirror and persist immediately.
    pub fn setPreferredMirror(self: *Settings, allocator: std.mem.Allocator, io: std.Io, base_url: []const u8) void {
        const old = self.preferred_mirror;
        self.preferred_mirror = allocator.dupe(u8, base_url) catch return;
        self.mirror_updated_at = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
        self.save(allocator, io) catch {};
        if (old.len > 0) allocator.free(old);
    }

    /// Clear the cached preferred mirror (e.g., when it fails).
    pub fn clearPreferredMirror(self: *Settings, allocator: std.mem.Allocator, io: std.Io) void {
        const old = self.preferred_mirror;
        self.preferred_mirror = "";
        self.mirror_updated_at = 0;
        self.save(allocator, io) catch {};
        if (old.len > 0) allocator.free(old);
    }
};
