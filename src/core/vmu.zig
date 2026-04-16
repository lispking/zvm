//! VMU (Version Map URL) command — manage version map sources.
//! Allows switching between official, Mach engine, or custom version maps
//! for both Zig and ZLS releases.

const std = @import("std");
const zvm_mod = @import("zvm.zig");
const cli = @import("../cli.zig");

/// Set the version map source for Zig or ZLS.
/// Special values: "default" resets to official, "mach" (Zig only) uses Mach engine builds.
/// Any other value is treated as a custom URL.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    target: cli.VmuTarget,
    value: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stderr;

    switch (target) {
        .zig => {
            if (std.mem.eql(u8, value, "default")) {
                zvm.settings.resetVersionMap(allocator, zvm.io) catch {};
                try stdout.print("Reset Zig version map to default.\n", .{});
            } else if (std.mem.eql(u8, value, "mach")) {
                try zvm.settings.setVersionMapUrl(allocator, zvm.io, "https://machengine.org/zig/index.json");
                try stdout.print("Set Zig version map to Mach engine.\n", .{});
            } else {
                try zvm.settings.setVersionMapUrl(allocator, zvm.io, value);
                try stdout.print("Set Zig version map to {s}\n", .{value});
            }
        },
        .zls => {
            if (std.mem.eql(u8, value, "default")) {
                zvm.settings.resetZlsVMU(allocator, zvm.io) catch {};
                try stdout.print("Reset ZLS VMU to default.\n", .{});
            } else {
                try zvm.settings.setZlsVMU(allocator, zvm.io, value);
                try stdout.print("Set ZLS VMU to {s}\n", .{value});
            }
        },
    }
    try stdout.flush();
}
