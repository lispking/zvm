//! Shell completion generation for zsh and bash.
//! Generates completion scripts from a single comptime metadata table derived
//! from cli.zig definitions. The exhaustive switch on cli.Command ensures
//! new commands trigger a compile error here until their metadata is added.

const std = @import("std");
const cli = @import("cli.zig");
const Console = @import("core/Console.zig");

pub fn run(shell: cli.ShellType, console: Console) !void {
    const writer = console.stdout.writer;
    switch (shell) {
        .zsh => try writeZshCompletion(writer),
        .bash => try writeBashCompletion(writer),
    }
    console.flush(.stdout);
}

// ─── Comptime metadata ───────────────────────────────────

const Flag = struct { name: []const u8, desc: []const u8 };

const ArgKind = enum {
    none,
    version,
    version_rest,
    vmu_target,
    shell_type,
    url,
};

const CmdMeta = struct {
    aliases: []const []const u8 = &.{},
    desc: []const u8,
    flags: []const Flag = &.{},
    arg: ArgKind = .none,
};

/// Single source of truth for command metadata.
/// Exhaustive switch on cli.Command — adding a new command to the enum
/// will produce a compile error until its entry is added here.
fn cmdMeta(cmd: cli.Command) CmdMeta {
    return switch (cmd) {
        .install => .{
            .aliases = &.{"i"},
            .desc = "Install a Zig version",
            .flags = &.{
                .{ .name = "--force", .desc = "Force re-install" },
                .{ .name = "-f", .desc = "Force re-install" },
                .{ .name = "--zls", .desc = "Also install ZLS" },
                .{ .name = "--full", .desc = "Install ZLS with full compatibility" },
                .{ .name = "--nomirror", .desc = "Skip community mirrors" },
            },
            .arg = .version,
        },
        .use => .{
            .desc = "Switch to an installed Zig version",
            .flags = &.{
                .{ .name = "--sync", .desc = "Use version from build.zig.zon" },
            },
            .arg = .version,
        },
        .list => .{
            .aliases = &.{ "ls", "available", "remote" },
            .desc = "List installed Zig versions",
            .flags = &.{
                .{ .name = "--all", .desc = "List all remote versions" },
                .{ .name = "-a", .desc = "List all remote versions" },
                .{ .name = "--vmu", .desc = "Show version map URLs" },
            },
        },
        .uninstall => .{
            .aliases = &.{"rm"},
            .desc = "Remove an installed Zig version",
            .arg = .version,
        },
        .clean => .{
            .desc = "Remove build artifacts",
        },
        .run => .{
            .desc = "Run a Zig version without switching default",
            .arg = .version_rest,
        },
        .upgrade => .{
            .desc = "Upgrade zvm to the latest version",
        },
        .vmu => .{
            .desc = "Set version map source (zig/zls)",
            .arg = .vmu_target,
        },
        .mirrorlist => .{
            .desc = "Set mirror distribution server",
            .arg = .url,
        },
        .proxy => .{
            .desc = "Set HTTP/HTTPS proxy for downloads",
            .arg = .url,
        },
        .completion => .{
            .desc = "Generate shell completion script",
            .arg = .shell_type,
        },
        .version => .{
            .desc = "Print zvm version",
        },
        .help => .{
            .desc = "Print help message",
        },
    };
}

/// All enum fields from cli.Command — used by inline for.
const cmd_fields = @typeInfo(cli.Command).@"enum".fields;

// ─── Zsh completion ──────────────────────────────────────

fn writeZshCompletion(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef zvm
        \\
        \\_zvm_completion() {
        \\  local -a commands
        \\  commands=(
        \\
    );

    // Generate command entries from metadata
    inline for (cmd_fields) |field| {
        const meta = comptime cmdMeta(@enumFromInt(field.value));
        try writer.print("    '{s}:{s}'\n", .{ field.name, meta.desc });
        inline for (meta.aliases) |alias| {
            try writer.print("    '{s}:{s}'\n", .{ alias, meta.desc });
        }
    }

    try writer.writeAll(
        \\  )
        \\
        \\  _arguments -C \
        \\    '--color[Toggle color output]:color:(on off true false)' \
        \\    '--help[Print help]' \
        \\    '-h[Print help]' \
        \\    '--version[Print version]' \
        \\    '-v[Print version]' \
        \\    '1:command:->command' \
        \\    '*::arg:->args'
        \\
        \\  case $state in
        \\    command)
        \\      _describe 'command' commands
        \\      ;;
        \\    args)
        \\      case $words[1] in
        \\
    );

    // Generate per-command argument rules
    inline for (cmd_fields) |field| {
        const meta = comptime cmdMeta(@enumFromInt(field.value));
        if (meta.flags.len == 0 and meta.arg == .none) continue;

        try writer.writeAll("        ");
        try writer.writeAll(field.name);
        inline for (meta.aliases) |alias| {
            try writer.writeAll("|");
            try writer.writeAll(alias);
        }
        try writer.writeAll(")\n");

        try writer.writeAll("          _arguments");
        inline for (meta.flags) |flag| {
            try writer.print(" \\\n            '{s}[{s}]'", .{ flag.name, flag.desc });
        }

        switch (meta.arg) {
            .version => {
                try writer.writeAll(" \\\n            '1:version:_zvm_installed_versions'\n");
            },
            .version_rest => {
                try writer.writeAll(" \\\n            '1:version:_zvm_installed_versions' \\\n");
                try writer.writeAll("            '*::args:'\n");
            },
            .vmu_target => {
                try writer.writeAll(" \\\n            '1:target:(zig zls)' \\\n");
                try writer.writeAll("            '2:value:_zvm_vmu_values'\n");
            },
            .shell_type => {
                try writer.writeAll(" \\\n            '1:shell:(zsh bash)'\n");
            },
            .url => {
                try writer.writeAll(" \\\n            '1:url:_zvm_url_values'\n");
            },
            .none => {
                try writer.writeAll("\n");
            },
        }

        try writer.writeAll("          ;;\n");
    }

    // Close case/esac and add helper functions
    try writer.writeAll(
        \\      esac
        \\      ;;
        \\  esac
        \\}
        \\
        \\_zvm_installed_versions() {
        \\  local -a versions
        \\  local zvm_dir="${ZVM_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/zvm}"
        \\  if [[ -d "$zvm_dir" ]]; then
        \\    for dir in "$zvm_dir"/*/; do
        \\      local ver=$(basename "$dir")
        \\      if [[ "$ver" != "bin" && "$ver" != "self" ]]; then
        \\        versions+=("$ver")
        \\      fi
        \\    done
        \\  fi
        \\  if [[ $words[1] == "install" || $words[1] == "i" ]]; then
        \\    versions+=("master")
        \\  fi
        \\  _describe 'version' versions
        \\}
        \\
        \\_zvm_vmu_values() {
        \\  local -a values
        \\  if [[ $words[2] == "zig" ]]; then
        \\    values=("default" "mach")
        \\  else
        \\    values=("default")
        \\  fi
        \\  _describe 'value' values
        \\}
        \\
        \\_zvm_url_values() {
        \\  local -a values
        \\  values=("default")
        \\  _describe 'value' values
        \\}
        \\
        \\compdef _zvm_completion zvm
        \\
    );
}

// ─── Bash completion ─────────────────────────────────────

fn writeBashCompletion(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#!/bin/bash
        \\
        \\_zvm_completions() {
        \\  local cur prev words cword
        \\  _init_completion || return
        \\
    );

    // Build commands string from metadata
    try writer.writeAll("  local commands=\"");
    inline for (cmd_fields, 0..) |field, i| {
        const meta = comptime cmdMeta(@enumFromInt(field.value));
        if (i > 0) try writer.writeAll(" ");
        try writer.writeAll(field.name);
        inline for (meta.aliases) |alias| {
            try writer.writeAll(" ");
            try writer.writeAll(alias);
        }
    }
    try writer.writeAll("\"\n");

    // Build per-command flag variables
    inline for (cmd_fields) |field| {
        const meta = comptime cmdMeta(@enumFromInt(field.value));
        if (meta.flags.len == 0) continue;

        try writer.print("  local {s}_flags=\"", .{field.name});
        inline for (meta.flags, 0..) |flag, i| {
            if (i > 0) try writer.writeAll(" ");
            try writer.writeAll(flag.name);
        }
        try writer.writeAll("\"\n");
    }

    // case $prev — special argument context handling
    try writer.writeAll(
        \\
        \\  if [[ $cword -eq 1 ]]; then
        \\    COMPREPLY=($(compgen -W "$commands --color --help -h --version -v" -- "$cur"))
        \\    return
        \\  fi
        \\
        \\  case $prev in
        \\    --color)
        \\      COMPREPLY=($(compgen -W "on off true false yes no" -- "$cur"))
        \\      return
        \\      ;;
        \\    vmu)
        \\      COMPREPLY=($(compgen -W "zig zls" -- "$cur"))
        \\      return
        \\      ;;
        \\    zig|zls)
        \\      if [[ ${words[$((cword-1))]} == "vmu" ]]; then
        \\        if [[ $prev == "zig" ]]; then
        \\          COMPREPLY=($(compgen -W "default mach" -- "$cur"))
        \\        else
        \\          COMPREPLY=($(compgen -W "default" -- "$cur"))
        \\        fi
        \\        return
        \\      fi
        \\      ;;
        \\
    );

    // Generate url-arg commands as a combined pattern: mirrorlist|proxy)
    {
        var first_url = true;
        inline for (cmd_fields) |field| {
            const meta = comptime cmdMeta(@enumFromInt(field.value));
            if (meta.arg == .url) {
                if (first_url) {
                    try writer.writeAll("    ");
                    first_url = false;
                } else {
                    try writer.writeAll("|");
                }
                try writer.writeAll(field.name);
            }
        }
        if (!first_url) {
            try writer.writeAll(
                \\)
                \\      COMPREPLY=($(compgen -W "default" -- "$cur"))
                \\      return
                \\      ;;
                \\
            );
        }
    }

    // Generate shell_type commands: completion)
    {
        var first_shell = true;
        inline for (cmd_fields) |field| {
            const meta = comptime cmdMeta(@enumFromInt(field.value));
            if (meta.arg == .shell_type) {
                if (first_shell) {
                    try writer.writeAll("    ");
                    first_shell = false;
                } else {
                    try writer.writeAll("|");
                }
                try writer.writeAll(field.name);
            }
        }
        if (!first_shell) {
            try writer.writeAll(
                \\)
                \\      COMPREPLY=($(compgen -W "zsh bash" -- "$cur"))
                \\      return
                \\      ;;
                \\
            );
        }
    }

    try writer.writeAll(
        \\  esac
        \\
        \\  local cmd=${words[1]}
        \\  case $cmd in
        \\
    );

    // Generate per-command case entries
    inline for (cmd_fields) |field| {
        const meta = comptime cmdMeta(@enumFromInt(field.value));
        if (meta.flags.len == 0 and meta.arg == .none) continue;

        try writer.writeAll("    ");
        try writer.writeAll(field.name);
        inline for (meta.aliases) |alias| {
            try writer.writeAll("|");
            try writer.writeAll(alias);
        }
        try writer.writeAll(")\n");

        if (meta.flags.len > 0 and meta.arg != .none) {
            // Commands with both flags and positional args (install, use)
            try writer.print(
                \\      if [[ "$cur" == --* ]]; then
                \\        COMPREPLY=($(compgen -W "${s}_flags" -- "$cur"))
                \\      else
                \\        _zvm_list_versions
                \\      fi
                \\
            , .{field.name});
        } else if (meta.flags.len > 0) {
            // Commands with only flags (list)
            try writer.print("      COMPREPLY=($(compgen -W \"${s}_flags\" -- \"$cur\"))\n", .{field.name});
        } else if (meta.arg == .version or meta.arg == .version_rest) {
            // Commands with only version args (uninstall, run)
            try writer.writeAll("      _zvm_list_versions\n");
        } else if (meta.arg == .url) {
            try writer.writeAll("      COMPREPLY=($(compgen -W \"default\" -- \"$cur\"))\n");
        }

        try writer.writeAll("      return\n");
        try writer.writeAll("      ;;\n");
    }

    try writer.writeAll(
        \\  esac
        \\}
        \\
        \\_zvm_list_versions() {
        \\  local zvm_dir="${ZVM_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/zvm}"
        \\  local -a versions=()
        \\  if [[ -d "$zvm_dir" ]]; then
        \\    for dir in "$zvm_dir"/*/; do
        \\      local ver=$(basename "$dir")
        \\      if [[ "$ver" != "bin" && "$ver" != "self" ]]; then
        \\        versions+=("$ver")
        \\      fi
        \\    done
        \\  fi
        \\  if [[ ${words[1]} == "install" || ${words[1]} == "i" ]]; then
        \\    versions+=("master")
        \\  fi
        \\  COMPREPLY=($(compgen -W "${versions[*]}" -- "$cur"))
        \\}
        \\
        \\complete -F _zvm_completions zvm
        \\
    );
}
