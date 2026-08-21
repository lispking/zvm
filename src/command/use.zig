//! Use command — switch the active Zig version.
//! Updates the bin symlink in the data directory to point to the requested version directory.

const std = @import("std");

const Console = @import("../core/Console.zig");
const platform = @import("../core/platform.zig");
const zvm_mod = @import("../core/zvm.zig");

/// Switch to an installed Zig version by updating the bin symlink.
/// Prints an error if the requested version is not installed.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    io: std.Io,
    version_: ?[]const u8,
    flags: anytype,
    console: Console,
) !void {
    _ = flags;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const version = version_ orelse praseFromZon(arena.allocator(), io) catch {
        console.err("Field 'minimum_zig_version' was not found in build.zig.zon.", .{});
        return;
    };

    if (!zvm.isVersionInstalled(version)) {
        console.plain("Zig {s} is not installed. Run 'zvm install {s}' first.", .{ version, version });
        return;
    }

    try zvm.setBin(version);
    console.plain("Now using Zig {s}", .{version});

    // On Windows, ensure the bin directory is in the user PATH
    if (platform.isWindows()) {
        var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bin_path = zvm.binPath(&bin_buf);

        if (platform.addToUserPath(zvm.io, bin_path)) |added| {
            if (added) {
                console.plain("Added zvm bin directory to PATH. Please restart your terminal for changes to take effect.", .{});
            }
        } else |err| {
            console.warn("Failed to update PATH ({s}). Please add {s} to your PATH manually.", .{ @errorName(err), bin_path });
        }
    }
}

fn praseFromZon(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, "build.zig.zon", .{});
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);

    const zon_txt = try reader.interface.readAlloc(arena, try reader.getSize());
    var diag = std.zon.parse.Diagnostics{};
    const zon = try std.zon.parse.fromSliceAlloc(
        struct { minimum_zig_version: [:0]const u8 },
        arena,
        @ptrCast(zon_txt),
        &diag,
        .{
            .ignore_unknown_fields = true,
        },
    );
    return zon.minimum_zig_version;
}
