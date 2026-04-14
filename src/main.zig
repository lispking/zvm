//! zvm - Zig Version Manager
//! A fast, dependency-free version manager for Zig written in Zig 0.15.x.
//! Manages multiple Zig compiler installations, switches between versions,
//! and provides shell completion support.

const std = @import("std");
const cli = @import("cli.zig");
const zvm_mod = @import("zvm.zig");
const terminal = @import("terminal.zig");
const errors = @import("errors.zig");
const platform = @import("platform.zig");
const build_options = @import("build_options");

/// Current version of zvm, injected at build time from git tag or -Dversion=.
const VERSION = build_options.version;

/// Full version string with 'v' prefix and git commit hash.
fn fullVersion() []const u8 {
    return "v" ++ VERSION ++ " (" ++ build_options.git_commit ++ ")";
}

/// Application entry point.
/// Sets up memory allocators, parses CLI arguments, initializes the ZVM environment,
/// and dispatches the requested command.
pub fn main() !void {
    // Use DebugAllocator (formerly GPA) for leak detection in debug builds
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // Arena allocator for CLI parsing — all parse-time allocations are freed at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Parse CLI arguments
    const parsed = cli.parse(arena.allocator()) catch {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        try terminal.printError(&stderr_writer.interface, "Failed to parse arguments");
        try cli.printHelp(&stderr_writer.interface);
        std.process.exit(1);
    };

    // Initialize ZVM environment (~/.zvm, settings, etc.)
    var zvm = zvm_mod.ZVM.init(allocator) catch {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        try terminal.printError(&stderr_writer.interface, "Failed to initialize ZVM");
        std.process.exit(1);
    };
    defer zvm.deinit();

    // Apply global flags from CLI
    if (parsed.global.color) |color_val| {
        zvm.settings.use_color = color_val;
    }

    // Setup buffered stdout/stderr writers
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // Dispatch to the appropriate command handler
    switch (parsed.cmd) {
        .help => {
            try cli.printHelp(stdout);
        },
        .version => {
            try stdout.print("zvm {s}\n", .{fullVersion()});
            try stdout.flush();
        },
        .install => |inst| {
            const install = @import("install.zig");
            install.run(&zvm, allocator, inst.version, inst.flags, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .use => |use_cmd| {
            const use_mod = @import("use.zig");
            const ver = use_cmd.version orelse {
                try terminal.printError(stderr, "No version specified. Use 'zvm use <version>'");
                try stderr.flush();
                std.process.exit(1);
            };
            use_mod.run(&zvm, allocator, ver, use_cmd.flags, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .list => |list_cmd| {
            const list = @import("list.zig");
            list.run(&zvm, allocator, list_cmd.flags, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .uninstall => |uninst| {
            const uninstall = @import("uninstall.zig");
            uninstall.run(&zvm, allocator, uninst.version, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .clean => {
            const clean = @import("clean.zig");
            clean.run(&zvm, allocator, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .run => |run_cmd| {
            const run_mod = @import("run.zig");
            run_mod.run(&zvm, allocator, run_cmd.version, run_cmd.args, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .upgrade => {
            const upgrade = @import("upgrade.zig");
            upgrade.run(&zvm, allocator, VERSION, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .vmu => |vmu_cmd| {
            const vmu = @import("vmu.zig");
            vmu.run(&zvm, allocator, vmu_cmd.target, vmu_cmd.value, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .mirrorlist => |ml_cmd| {
            const mirrorlist = @import("mirrorlist.zig");
            mirrorlist.run(&zvm, allocator, ml_cmd.url, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .proxy => |proxy_cmd| {
            const proxy_mod = @import("proxy.zig");
            proxy_mod.run(&zvm, allocator, proxy_cmd.url, stdout, stderr) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .completion => |comp_cmd| {
            const completion = @import("completion.zig");
            completion.run(comp_cmd.shell, stdout) catch |err| {
                try terminal.printError(stderr, @errorName(err));
                try stderr.flush();
                std.process.exit(1);
            };
        },
    }
}
