//! CLI argument parser for zvm.
//! Hand-written parser using std.process.argsWithAllocator with O(1) command
//! lookup via StaticStringMap. Supports aliases, flags (--flag, -f, --flag=value),
//! and subcommands (vmu zig/zls).

const std = @import("std");
const errors = @import("errors.zig");

/// Supported shell types for completion generation.
pub const ShellType = enum { zsh, bash };

/// All available zvm commands.
pub const Command = enum {
    install,
    use,
    list,
    uninstall,
    clean,
    run,
    upgrade,
    vmu,
    mirrorlist,
    proxy,
    completion,
    version,
    help,
};

/// Target for the vmu subcommand (zig or zls version map).
pub const VmuTarget = enum {
    zig,
    zls,
};

/// Flags for the install command.
pub const InstallFlags = packed struct {
    force: bool = false,
    zls: bool = false,
    full: bool = false,
    nomirror: bool = false,
};

/// Flags for the list command.
pub const ListFlags = packed struct {
    all: bool = false,
    vmu: bool = false,
};

/// Flags for the use command.
pub const UseFlags = packed struct {
    sync: bool = false,
};

/// Tagged union representing a fully parsed CLI command with its arguments.
pub const ParsedCommand = union(Command) {
    install: struct {
        flags: InstallFlags,
        version: []const u8,
    },
    use: struct {
        flags: UseFlags,
        version: ?[]const u8,
    },
    list: struct {
        flags: ListFlags,
    },
    uninstall: struct {
        version: []const u8,
    },
    clean,
    run: struct {
        version: []const u8,
        args: []const []const u8,
    },
    upgrade,
    vmu: struct {
        target: VmuTarget,
        value: []const u8,
    },
    mirrorlist: struct {
        url: ?[]const u8,
    },
    proxy: struct {
        url: ?[]const u8,
    },
    completion: struct {
        shell: ShellType,
    },
    version,
    help,
};

/// Global flags that apply before the command (e.g., --color).
pub const GlobalFlags = struct {
    color: ?bool = null,
};

/// Command name aliases for O(1) lookup via StaticStringMap.
const command_aliases = std.StaticStringMap(Command).initComptime(.{
    .{ "install", .install },
    .{ "i", .install },
    .{ "use", .use },
    .{ "list", .list },
    .{ "ls", .list },
    .{ "available", .list },
    .{ "remote", .list },
    .{ "uninstall", .uninstall },
    .{ "rm", .uninstall },
    .{ "clean", .clean },
    .{ "run", .run },
    .{ "upgrade", .upgrade },
    .{ "vmu", .vmu },
    .{ "mirrorlist", .mirrorlist },
    .{ "proxy", .proxy },
    .{ "completion", .completion },
    .{ "version", .version },
    .{ "help", .help },
    .{ "--help", .help },
    .{ "-h", .help },
    .{ "--version", .version },
    .{ "-v", .version },
});

pub fn parse(allocator: std.mem.Allocator, args_data: std.process.Args) !struct { global: GlobalFlags, cmd: ParsedCommand } {
    var args = std.process.Args.Iterator.initAllocator(args_data, allocator) catch return error.OutOfMemory;
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var global_flags: GlobalFlags = .{};

    // Parse global flags first
    var maybe_cmd: ?Command = null;
    var cmd_raw: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--color")) {
            const val = args.next() orelse return error.MissingArgument;
            global_flags.color = parseColorValue(val);
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            const val = arg["--color=".len..];
            global_flags.color = parseColorValue(val);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .{ .global = global_flags, .cmd = .help };
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            return .{ .global = global_flags, .cmd = .version };
        } else {
            // Try to match command
            maybe_cmd = command_aliases.get(arg) orelse return error.InvalidInput;
            cmd_raw = arg;
            break;
        }
    }

    const cmd = maybe_cmd orelse return .{ .global = global_flags, .cmd = .help };

    // Check if the raw command name implies --all
    const auto_all = if (cmd_raw) |raw|
        std.mem.eql(u8, raw, "available") or std.mem.eql(u8, raw, "remote")
    else
        false;

    const parsed = switch (cmd) {
        .install => try parseInstall(allocator, &args),
        .use => try parseUse(allocator, &args),
        .list => parseList(&args, auto_all),
        .uninstall => try parseUninstall(allocator, &args),
        .clean => ParsedCommand.clean,
        .run => try parseRun(allocator, &args),
        .upgrade => ParsedCommand.upgrade,
        .vmu => try parseVmu(allocator, &args),
        .mirrorlist => try parseMirrorlist(allocator, &args),
        .proxy => try parseProxy(allocator, &args),
        .completion => try parseCompletion(&args),
        .version => ParsedCommand.version,
        .help => ParsedCommand.help,
    };

    return .{ .global = global_flags, .cmd = parsed };
}

fn parseColorValue(val: []const u8) ?bool {
    if (std.mem.eql(u8, val, "true") or
        std.mem.eql(u8, val, "on") or
        std.mem.eql(u8, val, "yes") or
        std.mem.eql(u8, val, "y") or
        std.mem.eql(u8, val, "enabled"))
        return true;

    if (std.mem.eql(u8, val, "false") or
        std.mem.eql(u8, val, "off") or
        std.mem.eql(u8, val, "no") or
        std.mem.eql(u8, val, "n") or
        std.mem.eql(u8, val, "disabled"))
        return false;

    return null;
}

fn parseInstall(allocator: std.mem.Allocator, args: anytype) !ParsedCommand {
    var flags: InstallFlags = .{};
    var version: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            flags.force = true;
        } else if (std.mem.eql(u8, arg, "--zls")) {
            flags.zls = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            flags.full = true;
        } else if (std.mem.eql(u8, arg, "--nomirror")) {
            flags.nomirror = true;
        } else {
            version = try allocator.dupe(u8, arg);
        }
    }

    return .{ .install = .{
        .flags = flags,
        .version = version orelse return error.MissingArgument,
    } };
}

fn parseUse(allocator: std.mem.Allocator, args: anytype) !ParsedCommand {
    var flags: UseFlags = .{};
    var version: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sync")) {
            flags.sync = true;
        } else {
            version = try allocator.dupe(u8, arg);
        }
    }

    return .{ .use = .{
        .flags = flags,
        .version = version,
    } };
}

fn parseList(args: anytype, auto_all: bool) ParsedCommand {
    var flags: ListFlags = .{ .all = auto_all };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            flags.all = true;
        } else if (std.mem.eql(u8, arg, "--vmu")) {
            flags.vmu = true;
        }
    }

    return .{ .list = .{ .flags = flags } };
}

fn parseUninstall(allocator: std.mem.Allocator, args: anytype) !ParsedCommand {
    const version = args.next() orelse return error.MissingArgument;
    return .{ .uninstall = .{
        .version = try allocator.dupe(u8, version),
    } };
}

fn parseRun(allocator: std.mem.Allocator, args: anytype) !ParsedCommand {
    const version = args.next() orelse return error.MissingArgument;

    var run_args: std.ArrayList([]const u8) = .empty;
    errdefer run_args.deinit(allocator);

    while (args.next()) |arg| {
        try run_args.append(allocator, try allocator.dupe(u8, arg));
    }

    return .{ .run = .{
        .version = try allocator.dupe(u8, version),
        .args = try run_args.toOwnedSlice(allocator),
    } };
}

fn parseVmu(allocator: std.mem.Allocator, args: anytype) !ParsedCommand {
    const subcmd = args.next() orelse return error.MissingArgument;
    const value = args.next() orelse return error.MissingArgument;

    const target: VmuTarget = if (std.mem.eql(u8, subcmd, "zig"))
        .zig
    else if (std.mem.eql(u8, subcmd, "zls"))
        .zls
    else
        return error.InvalidInput;

    return .{ .vmu = .{
        .target = target,
        .value = try allocator.dupe(u8, value),
    } };
}

fn parseMirrorlist(allocator: std.mem.Allocator, args: anytype) !ParsedCommand {
    const url = args.next();
    return .{ .mirrorlist = .{
        .url = if (url) |u| try allocator.dupe(u8, u) else null,
    } };
}

fn parseProxy(allocator: std.mem.Allocator, args: anytype) !ParsedCommand {
    const url = args.next();
    return .{ .proxy = .{
        .url = if (url) |u| try allocator.dupe(u8, u) else null,
    } };
}

fn parseCompletion(args: anytype) !ParsedCommand {
    const shell_str = args.next() orelse return error.MissingArgument;
    const shell: ShellType = if (std.mem.eql(u8, shell_str, "zsh"))
        .zsh
    else if (std.mem.eql(u8, shell_str, "bash"))
        .bash
    else
        return error.InvalidInput;
    return .{ .completion = .{ .shell = shell } };
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\zvm - Zig Version Manager
        \\
        \\Usage:
        \\  zvm <command> [options] [arguments]
        \\
        \\Commands:
        \\  install, i        Install a Zig version
        \\  use               Switch to an installed Zig version
        \\  list, ls          List installed Zig versions
        \\  available, remote List all versions available for download
        \\  uninstall, rm     Remove an installed Zig version
        \\  clean             Remove build artifacts
        \\  run               Run a Zig version without switching default
        \\  upgrade           Upgrade zvm to the latest version
        \\  vmu               Set version map source (zig/zls)
        \\  mirrorlist        Set mirror distribution server
        \\  proxy             Set HTTP/HTTPS proxy for downloads
        \\  completion        Generate shell completion script
        \\  version           Print zvm version
        \\  help              Print this help message
        \\
        \\Global Options:
        \\  --color=VALUE  Toggle color output (on/off/true/false)
        \\  --help, -h     Print help
        \\  --version, -v  Print version
        \\
        \\Use "zvm <command> --help" for more info on a command.
        \\
    );
    try writer.flush();
}

pub fn printCommandHelp(writer: *std.Io.Writer, cmd: Command) !void {
    switch (cmd) {
        .install => try writer.writeAll(
            \\Install a Zig version.
            \\
            \\Usage:
            \\  zvm install [options] <version>
            \\
            \\Options:
            \\  --force, -f   Force re-install even if already installed
            \\  --zls         Also install ZLS (Zig Language Server)
            \\  --full        Install ZLS with full compatibility mode
            \\  --nomirror    Skip community mirror downloads
            \\
            \\Examples:
            \\  zvm install master     Install latest nightly
            \\  zvm install 0.13.0     Install specific version
            \\  zvm i --zls master     Install with ZLS
            \\
        ),
        .use => try writer.writeAll(
            \\Switch to an installed Zig version.
            \\
            \\Usage:
            \\  zvm use [options] [version]
            \\
            \\Options:
            \\  --sync    Use version from build.zig.zon's minimum_zig_version
            \\
            \\Examples:
            \\  zvm use master
            \\  zvm use 0.13.0
            \\  zvm use --sync
            \\
        ),
        .list => try writer.writeAll(
            \\List installed Zig versions.
            \\
            \\Usage:
            \\  zvm list [options]
            \\
            \\Options:
            \\  --all, -a    List all remote versions available for download
            \\  --vmu        Show configured version map URLs
            \\
        ),
        .uninstall => try writer.writeAll(
            \\Remove an installed Zig version.
            \\
            \\Usage:
            \\  zvm uninstall <version>
            \\  zvm rm <version>
            \\
        ),
        .clean => try writer.writeAll(
            \\Remove build artifacts from the cache directory.
            \\
            \\Usage:
            \\  zvm clean
            \\
        ),
        .run => try writer.writeAll(
            \\Run a specific Zig version without switching default.
            \\
            \\Usage:
            \\  zvm run <version> [args...]
            \\
            \\Examples:
            \\  zvm run 0.11.0 version
            \\
        ),
        .upgrade => try writer.writeAll(
            \\Upgrade zvm to the latest version.
            \\
            \\Usage:
            \\  zvm upgrade
            \\
        ),
        .vmu => try writer.writeAll(
            \\Set version map source for Zig or ZLS.
            \\
            \\Usage:
            \\  zvm vmu zig <url|default|mach>
            \\  zvm vmu zls <url|default>
            \\
            \\Examples:
            \\  zvm vmu zig default              Reset to official Zig releases
            \\  zvm vmu zig mach                 Use Mach engine Zig builds
            \\  zvm vmu zig https://example.com  Use custom URL
            \\  zvm vmu zls default              Reset to official ZLS releases
            \\
        ),
        .mirrorlist => try writer.writeAll(
            \\Set mirror distribution server.
            \\
            \\Usage:
            \\  zvm mirrorlist <url|default>
            \\
        ),
        .proxy => try writer.writeAll(
            \\Set HTTP/HTTPS proxy for downloads.
            \\
            \\Usage:
            \\  zvm proxy <url|default>
            \\
            \\Examples:
            \\  zvm proxy http://127.0.0.1:7890     Set proxy URL
            \\  zvm proxy socks5://127.0.0.1:1080   Set SOCKS5 proxy
            \\  zvm proxy default                   Clear proxy (auto-detect from env)
            \\  zvm proxy                           Show current proxy setting
            \\
        ),
        .version, .help => printHelp(writer) catch {},
    }
    try writer.flush();
}
