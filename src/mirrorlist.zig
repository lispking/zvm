//! Mirrorlist command — manage the community mirror download server.
//! Mirrors provide alternative download locations for Zig archives,
//! which can be faster than the official servers in some regions.

const std = @import("std");
const zvm_mod = @import("zvm.zig");

/// Set or display the mirror list URL.
/// "default" resets to the official community mirrors.
/// With no argument, displays the current mirror list URL.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    url: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stderr;

    if (url) |u| {
        if (std.mem.eql(u8, u, "default")) {
            zvm.settings.resetMirrorList(allocator) catch {};
            try stdout.print("Reset mirror list to default.\n", .{});
        } else {
            try zvm.settings.setMirrorListUrl(allocator, u);
            try stdout.print("Set mirror list to {s}\n", .{u});
        }
    } else {
        try stdout.print("Current mirror list: {s}\n", .{zvm.settings.mirror_list_url});
    }
    try stdout.flush();
}
