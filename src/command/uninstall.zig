//! Uninstall command — remove an installed Zig version.
//! Deletes the version directory from the data directory.
//! Blocks removal of the currently active version and suggests switching first.

const std = @import("std");
const zvm_mod = @import("../core/zvm.zig");
const Console = @import("../core/Console.zig");

/// Remove an installed Zig version.
/// Checks if the version exists and blocks removal if it's currently active.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    version: []const u8,
    console: Console,
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = zvm.versionPath(&buf, version);

    // Verify the version is installed
    std.Io.Dir.cwd().access(zvm.io, path, .{}) catch {
        console.println(.stderr, "Zig {s} is not installed.", .{version});
        console.flush(.stderr);
        return;
    };

    // Block removal if this is the currently active version
    if (zvm.getActiveVersion(allocator)) |active| {
        defer allocator.free(active);
        if (std.mem.eql(u8, active, version)) {
            console.err("Cannot remove the active version.", .{});

            // List other installed versions so user can pick one to switch to
            var versions = zvm.getInstalledVersions(allocator) catch return;
            defer {
                for (versions.items) |v| allocator.free(v);
                versions.deinit(allocator);
            }

            // Collect non-active versions
            var others: std.ArrayList([]const u8) = .empty;
            defer others.deinit(allocator);
            for (versions.items) |ver| {
                if (!std.mem.eql(u8, ver, version)) {
                    try others.append(allocator, ver);
                }
            }

            if (others.items.len > 0) {
                console.println(.stderr, "Switch to another version first:", .{});
                console.flush(.stderr);
                for (others.items) |ver| {
                    console.println(.stdout, "  {s}", .{ver});
                }
            } else {
                console.println(.stderr, "No other versions available. Install one first:", .{});
                console.println(.stderr, "  zvm install <version>", .{});
            }
            console.flush(.stderr);
            console.flush(.stdout);
            return;
        }
    }

    // Delete the version directory tree
    std.Io.Dir.cwd().deleteTree(zvm.io, path) catch |err| {
        console.println(.stderr, "Failed to remove {s}: {}", .{ version, err });
        console.flush(.stderr);
        return;
    };

    console.plain("Uninstalled Zig {s}", .{version});
}
