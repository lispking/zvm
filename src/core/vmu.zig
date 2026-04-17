//! VMU (Version Map URL) command — manage version map sources.
//! Allows switching between official, Mach engine, or custom version maps
//! for both Zig and ZLS releases.

const std = @import("std");
const zvm_mod = @import("zvm.zig");
const cli = @import("../cli.zig");
const Console = @import("Console.zig");

/// Set the version map source for Zig or ZLS.
/// Special values: "default" resets to official, "mach" (Zig only) uses Mach engine builds.
/// Any other value is treated as a custom URL.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    target: cli.VmuTarget,
    value: []const u8,
    console: Console,
) !void {
    switch (target) {
        .zig => {
            if (std.mem.eql(u8, value, "default")) {
                zvm.settings.resetVersionMap(allocator, zvm.io) catch {};
                console.println(.stdout, "Reset Zig version map to default.", .{});
            } else if (std.mem.eql(u8, value, "mach")) {
                try zvm.settings.setVersionMapUrl(allocator, zvm.io, "https://machengine.org/zig/index.json");
                console.println(.stdout, "Set Zig version map to Mach engine.", .{});
            } else {
                try zvm.settings.setVersionMapUrl(allocator, zvm.io, value);
                console.println(.stdout, "Set Zig version map to {s}", .{value});
            }
        },
        .zls => {
            if (std.mem.eql(u8, value, "default")) {
                zvm.settings.resetZlsVMU(allocator, zvm.io) catch {};
                console.println(.stdout, "Reset ZLS VMU to default.", .{});
            } else {
                try zvm.settings.setZlsVMU(allocator, zvm.io, value);
                console.println(.stdout, "Set ZLS VMU to {s}", .{value});
            }
        },
    }
    console.flush(.stdout);
}
