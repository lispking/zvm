//! List command — displays installed or remote Zig versions.
//! Three modes:
//!   - Default: list locally installed versions (mark active with color)
//!   - --all / available / remote: list all versions from the remote version map
//!   - --vmu: show configured version map URLs

const std = @import("std");
const zvm_mod = @import("zvm.zig");
const terminal = @import("terminal.zig");
const version_map = @import("version_map.zig");

pub const ListFlags = @import("cli.zig").ListFlags;

/// Main entry point for the `zvm list` command.
/// Dispatches to the appropriate listing mode based on flags.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    flags: ListFlags,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Show configured version map URLs
    if (flags.vmu) {
        try stdout.print("Zig Version Map: {s}\n", .{zvm.settings.version_map_url});
        try stdout.print("ZLS VMU:         {s}\n", .{zvm.settings.zls_vmu});
        try stdout.print("Mirror List:     {s}\n", .{zvm.settings.mirror_list_url});
        try stdout.flush();
        return;
    }

    // List remote versions from the version map
    if (flags.all) {
        try listRemote(zvm, allocator, stdout, stderr);
        return;
    }

    // Default: list locally installed versions
    var versions = try zvm.getInstalledVersions(allocator);
    defer {
        for (versions.items) |v| allocator.free(v);
        versions.deinit(allocator);
    }

    const active = zvm.getActiveVersion(allocator);
    defer if (active) |a| allocator.free(a);

    if (versions.items.len == 0) {
        try stdout.print("No Zig versions installed.\n", .{});
        try stdout.print("Use 'zvm install <version>' to install one.\n", .{});
        try stdout.flush();
        return;
    }

    for (versions.items) |ver| {
        const is_active = if (active) |a| std.mem.eql(u8, a, ver) else false;
        if (is_active) {
            try terminal.println(stdout, .green, "{s} (active)", .{ver});
        } else {
            try stdout.print("{s}\n", .{ver});
        }
    }
    try stdout.flush();
}

/// Fetch and display all remote versions from the version map.
/// Shows version name and installation status (installed/active).
fn listRemote(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    try stdout.print("Fetching available versions...\n", .{});
    try stdout.flush();

    const parsed = version_map.fetchVersionMap(allocator, zvm.settings.version_map_url, zvm.settings.proxy) catch {
        try terminal.printError(stderr, "Failed to fetch version map");
        return;
    };
    defer parsed.deinit();

    const vmap = &parsed.value.object;

    // Get installed versions for marking status
    var installed = try zvm.getInstalledVersions(allocator);
    defer {
        for (installed.items) |v| allocator.free(v);
        installed.deinit(allocator);
    }

    const active = zvm.getActiveVersion(allocator);
    defer if (active) |a| allocator.free(a);

    // Collect and sort version keys
    var keys = try version_map.getVersionKeys(allocator, vmap);
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    // Print table header
    try stdout.print("{s:<30} {s:<12}\n", .{ "Version", "Installed" });
    try stdout.print("{s:<30} {s:<12}\n", .{ "-------", "---------" });

    // Print master version first (with its dev build version number)
    if (vmap.get("master")) |master| {
        const master_ver = switch (master) {
            .object => |obj| if (obj.get("version")) |v| v.string else "?",
            else => "?",
        };
        const is_installed = isInstalled(installed.items, "master");
        const is_active = if (active) |a| std.mem.eql(u8, a, "master") else false;
        const status = if (is_active) "active" else if (is_installed) "yes" else "";
        try stdout.print("master ({s})", .{master_ver});
        if (status.len > 0) {
            if (is_active) {
                try terminal.println(stdout, .green, "  {s}", .{status});
            } else {
                try stdout.print("  {s}\n", .{status});
            }
        } else {
            try stdout.print("\n", .{});
        }
    }

    // Print all tagged release versions
    for (keys.items) |key| {
        if (std.mem.eql(u8, key, "master")) continue;
        const is_installed = isInstalled(installed.items, key);
        const is_active_flag = if (active) |a| std.mem.eql(u8, a, key) else false;
        const status = if (is_active_flag) "active" else if (is_installed) "yes" else "";
        try stdout.print("{s}", .{key});
        if (status.len > 0) {
            if (is_active_flag) {
                try terminal.println(stdout, .green, "  {s}", .{status});
            } else {
                try stdout.print("  {s}\n", .{status});
            }
        } else {
            try stdout.print("\n", .{});
        }
    }
    try stdout.flush();
}

/// Check if a version exists in the installed versions list.
fn isInstalled(installed: []const []const u8, version: []const u8) bool {
    for (installed) |inst| {
        if (std.mem.eql(u8, inst, version)) return true;
    }
    return false;
}
