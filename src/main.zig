//! zvm - Zig Version Manager
//! A fast, dependency-free version manager for Zig written in Zig 0.16.x.
//! Manages multiple Zig compiler installations, switches between versions,
//! and provides shell completion support.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const cli = @import("cli.zig");
const Console = @import("core/Console.zig");
const errors = @import("core/errors.zig");
const platform = @import("core/platform.zig");
const update_check = @import("core/update_check.zig");
const zvm_mod = @import("core/zvm.zig");

/// Current version of zvm, injected at build time from git tag or -Dversion=.
const VERSION = build_options.version;

/// Full version string with 'v' prefix and git commit hash.
fn fullVersion() []const u8 {
    return "v" ++ VERSION ++ " (" ++ build_options.git_commit ++ ")";
}

/// Print error and exit on command failure.
fn commandFail(console: Console, err: anyerror) noreturn {
    console.fatal("{s}", .{@errorName(err)});
}

/// Application entry point.
/// Receives std.process.Init from the Zig runtime which provides
/// pre-initialized allocator, I/O context, and environment map.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Arena allocator for CLI parsing — all parse-time allocations are freed at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Parse CLI arguments
    const parsed = cli.parse(arena.allocator(), init.minimal) catch |err| {
        std.log.err("Failed to parse arguments: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Setup console with appropriate color mode based on terminal capabilities
    const console: Console = blk: {
        var stdout_buffer: [8192]u8 = undefined;
        var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        const stdout = &stdout_file_writer.interface;

        var stderr_buffer: [4096]u8 = undefined;
        var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        const stderr = &stderr_file_writer.interface;

        const no_color, const clicolor_force = if (parsed.global.color) |val| .{ !val, val } else .{ false, true };
        const mode = std.Io.Terminal.Mode.detect(init.io, .stderr(), no_color, clicolor_force) catch null;
        break :blk .init(stdout, stderr, mode);
    };

    // Initialize ZVM environment (XDG dirs, settings, etc.)
    var zvm = zvm_mod.ZVM.init(allocator, init.io, init.environ_map) catch |err| {
        console.err("Failed to initialize ZVM: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zvm.deinit();

    // Apply global flags from CLI
    if (parsed.global.color) |color_val| {
        zvm.settings.use_color = color_val;
    }

    // Dispatch to the appropriate command handler
    switch (parsed.cmd) {
        .help => {
            try cli.printHelp(console.stdout.writer);
        },
        .version => {
            console.plain("zvm {s}", .{fullVersion()});
        },
        .install => |inst| {
            const install = @import("command/install.zig");
            install.run(&zvm, allocator, inst.version, inst.flags, console) catch |err| commandFail(console, err);
            update_check.printUpdateHint(allocator, zvm.io, zvm.environ_map, zvm.cache_dir, zvm.settings.proxy, console);
        },
        .use => |use_cmd| {
            const use_mod = @import("command/use.zig");
            const ver = use_cmd.version orelse {
                console.err("No version specified. Use 'zvm use <version>'", .{});
                std.process.exit(1);
            };
            use_mod.run(&zvm, allocator, ver, use_cmd.flags, console) catch |err| commandFail(console, err);
        },
        .list => |list_cmd| {
            const list = @import("command/list.zig");
            list.run(&zvm, allocator, list_cmd.flags, console) catch |err| commandFail(console, err);
        },
        .uninstall => |uninst| {
            const uninstall = @import("command/uninstall.zig");
            uninstall.run(&zvm, allocator, uninst.version, console) catch |err| commandFail(console, err);
        },
        .clean => {
            const clean = @import("command/clean.zig");
            clean.run(&zvm, allocator, console) catch |err| commandFail(console, err);
        },
        .run => |run_cmd| {
            const run_mod = @import("command/run.zig");
            run_mod.run(&zvm, allocator, run_cmd.version, run_cmd.args, console) catch |err| commandFail(console, err);
        },
        .upgrade => {
            const upgrade = @import("command/upgrade.zig");
            upgrade.run(&zvm, allocator, VERSION, console) catch |err| commandFail(console, err);
        },
        .vmu => |vmu_cmd| {
            const vmu = @import("core/vmu.zig");
            vmu.run(&zvm, allocator, vmu_cmd.target, vmu_cmd.value, console) catch |err| commandFail(console, err);
        },
        .mirrorlist => |ml_cmd| {
            const mirrorlist = @import("command/mirrorlist.zig");
            mirrorlist.run(&zvm, allocator, ml_cmd.url, console) catch |err| commandFail(console, err);
            update_check.printUpdateHint(allocator, zvm.io, zvm.environ_map, zvm.cache_dir, zvm.settings.proxy, console);
        },
        .proxy => |proxy_cmd| {
            const proxy_mod = @import("command/proxy.zig");
            proxy_mod.run(&zvm, allocator, proxy_cmd.url, console) catch |err| commandFail(console, err);
        },
        .completion => |comp_cmd| {
            const completion = @import("completion.zig");
            completion.run(comp_cmd.shell, console) catch |err| commandFail(console, err);
        },
    }
}
