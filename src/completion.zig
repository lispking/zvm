//! Shell completion generation for zsh and bash.
//! Outputs completion scripts that enable tab-completion for all zvm commands,
//! flags, installed versions, and special values.

const std = @import("std");
const cli = @import("cli.zig");

/// Generate and output a shell completion script for the specified shell.
pub fn run(shell: cli.ShellType, writer: *std.Io.Writer) !void {
    switch (shell) {
        .zsh => try writeZshCompletion(writer),
        .bash => try writeBashCompletion(writer),
    }
    try writer.flush();
}

/// Generate zsh completion script.
/// Provides completion for commands, flags, installed versions, and vmu values.
fn writeZshCompletion(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef zvm
        \\
        \\_zvm_completion() {
        \\  local -a commands
        \\  commands=(
        \\    'install:Install a Zig version'
        \\    'i:Install a Zig version'
        \\    'use:Switch to an installed Zig version'
        \\    'list:List installed Zig versions'
        \\    'ls:List installed Zig versions'
        \\    'available:List all versions available for download'
        \\    'remote:List all versions available for download'
        \\    'uninstall:Remove an installed Zig version'
        \\    'rm:Remove an installed Zig version'
        \\    'clean:Remove build artifacts'
        \\    'run:Run a Zig version without switching default'
        \\    'upgrade:Upgrade zvm to the latest version'
        \\    'vmu:Set version map source (zig/zls)'
        \\    'mirrorlist:Set mirror distribution server'
        \\    'completion:Generate shell completion script'
        \\    'version:Print zvm version'
        \\    'help:Print help message'
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
        \\        install|i)
        \\          _arguments \
        \\            '--force[Force re-install]' \
        \\            '-f[Force re-install]' \
        \\            '--zls[Also install ZLS]' \
        \\            '--full[Install ZLS with full compatibility]' \
        \\            '--nomirror[Skip community mirrors]' \
        \\            '1:version:_zvm_installed_versions'
        \\          ;;
        \\        use)
        \\          _arguments \
        \\            '--sync[Use version from build.zig.zon]' \
        \\            '1:version:_zvm_installed_versions'
        \\          ;;
        \\        list|ls)
        \\          _arguments \
        \\            '--all[List all remote versions]' \
        \\            '-a[List all remote versions]' \
        \\            '--vmu[Show version map URLs]'
        \\          ;;
        \\        uninstall|rm)
        \\          _arguments \
        \\            '1:version:_zvm_installed_versions'
        \\          ;;
        \\        run)
        \\          _arguments \
        \\            '1:version:_zvm_installed_versions' \
        \\            '*::args:'
        \\          ;;
        \\        vmu)
        \\          _arguments \
        \\            '1:target:(zig zls)' \
        \\            '2:value:_zvm_vmu_values'
        \\          ;;
        \\        mirrorlist)
        \\          _arguments \
        \\            '1:url:_zvm_mirror_values'
        \\          ;;
        \\        completion)
        \\          _arguments \
        \\            '1:shell:(zsh bash)'
        \\          ;;
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
        \\  # Also suggest 'master' for install
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
        \\_zvm_mirror_values() {
        \\  local -a values
        \\  values=("default")
        \\  _describe 'value' values
        \\}
        \\
        \\compdef _zvm_completion zvm
        \\
    );
}

/// Generate bash completion script.
/// Provides completion for commands, flags, and installed versions.
fn writeBashCompletion(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#!/bin/bash
        \\
        \\_zvm_completions() {
        \\  local cur prev words cword
        \\  _init_completion || return
        \\
        \\  local commands="install i use list ls available remote uninstall rm clean run upgrade vmu mirrorlist completion version help"
        \\  local install_flags="--force -f --zls --full --nomirror"
        \\  local use_flags="--sync"
        \\  local list_flags="--all -a --vmu"
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
        \\    completion)
        \\      COMPREPLY=($(compgen -W "zsh bash" -- "$cur"))
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
        \\    mirrorlist)
        \\      COMPREPLY=($(compgen -W "default" -- "$cur"))
        \\      return
        \\      ;;
        \\  esac
        \\
        \\  local cmd=${words[1]}
        \\  case $cmd in
        \\    install|i)
        \\      if [[ "$cur" == --* ]]; then
        \\        COMPREPLY=($(compgen -W "$install_flags" -- "$cur"))
        \\      else
        \\        _zvm_list_versions
        \\      fi
        \\      return
        \\      ;;
        \\    use)
        \\      if [[ "$cur" == --* ]]; then
        \\        COMPREPLY=($(compgen -W "$use_flags" -- "$cur"))
        \\      else
        \\        _zvm_list_versions
        \\      fi
        \\      return
        \\      ;;
        \\    list|ls|available|remote)
        \\      COMPREPLY=($(compgen -W "$list_flags" -- "$cur"))
        \\      return
        \\      ;;
        \\    uninstall|rm|run)
        \\      _zvm_list_versions
        \\      return
        \\      ;;
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
        \\  # Also suggest 'master' for install
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
