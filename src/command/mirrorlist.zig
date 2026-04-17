//! Mirrorlist command — manage the community mirror download server.
//! Mirrors provide alternative download locations for Zig archives,
//! which can be faster than the official servers in some regions.

const std = @import("std");
const zvm_mod = @import("../core/zvm.zig");
const Console = @import("../core/Console.zig");

/// Set or display the mirror list URL.
/// "default" resets to the official community mirrors.
/// With no argument, displays the current mirror list URL.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    url: ?[]const u8,
    console: Console,
) !void {
    if (url) |u| {
        if (std.mem.eql(u8, u, "default")) {
            zvm.settings.resetMirrorList(allocator, zvm.io) catch {};
            console.plain("Reset mirror list to default.", .{});
        } else {
            try zvm.settings.setMirrorListUrl(allocator, zvm.io, u);
            console.plain("Set mirror list to {s}", .{u});
        }
    } else {
        console.plain("Current mirror list: {s}", .{zvm.settings.mirror_list_url});
    }
}
