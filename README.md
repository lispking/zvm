# zvm — Zig Version Manager

[![Release](https://github.com/lispking/zvm/actions/workflows/release.yml/badge.svg)](https://github.com/lispking/zvm/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.15.x-orange.svg)](https://ziglang.org)

A fast, dependency-free version manager for [Zig](https://ziglang.org/), written entirely in Zig.

Manage multiple Zig compiler installations, switch between versions instantly, and keep your toolchain up to date — all with a single static binary.

## Features

- **Zero dependencies** — single static binary, no runtime requirements
- **Cross-platform** — macOS, Linux, Windows (x86_64 and aarch64)
- **Fast downloads** — latency-based mirror selection picks the fastest source automatically
- **SHA256 verification** — every download is checksum-verified
- **ZLS support** — install the Zig Language Server alongside Zig
- **Shell completion** — tab completion for zsh and bash
- **Self-updating** — `zvm upgrade` downloads the latest release

## Installation

### One-line Install (Recommended)

Automatically detects your platform, downloads zvm, sets up PATH and shell completion:

```bash
curl -L https://raw.githubusercontent.com/lispking/zvm/main/install.sh | bash
```

### Manual Install

Download the [latest release](https://github.com/lispking/zvm/releases/latest) for your platform:

```bash
# macOS (Apple Silicon)
curl -L https://github.com/lispking/zvm/releases/latest/download/zvm-aarch64-macos.tar.gz | tar xz
# macOS (Intel)
curl -L https://github.com/lispking/zvm/releases/latest/download/zvm-x86_64-macos.tar.gz | tar xz
# Linux (x86_64)
curl -L https://github.com/lispking/zvm/releases/latest/download/zvm-x86_64-linux.tar.gz | tar xz
# Linux (ARM64)
curl -L https://github.com/lispking/zvm/releases/latest/download/zvm-aarch64-linux.tar.gz | tar xz
```

```bash
cd zvm-*/ && sudo mv zvm /usr/local/bin/
```

### Build from Source

Requirements: [Zig 0.15.x](https://ziglang.org/download/)

```bash
git clone https://github.com/lispking/zvm.git
cd zvm
zig build -Doptimize=ReleaseSafe
# Binary at zig-out/bin/zvm
```

### Post-Install Setup

Add zvm's bin directory to your PATH:

```bash
export PATH="$HOME/.zvm/bin:$PATH"
```

## Quick Start

```bash
# Install a Zig version
zvm install 0.15.2

# Install latest nightly build
zvm install master

# Install with ZLS (Zig Language Server)
zvm install --zls 0.15.2

# Switch to a different version
zvm use 0.14.0

# List installed versions
zvm list

# List all available remote versions
zvm available

# Run a specific version without switching default
zvm run 0.13.0 build run

# Remove an installed version
zvm uninstall 0.13.0

# Self-update zvm
zvm upgrade
```

## Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `install` | `i` | Install a Zig version |
| `use` | | Switch to an installed version |
| `list` | `ls` | List installed versions |
| `available` | `remote` | List all remote versions |
| `uninstall` | `rm` | Remove an installed version |
| `clean` | | Remove downloaded archives |
| `run` | | Run a version without switching default |
| `upgrade` | | Upgrade zvm to the latest version |
| `vmu` | | Set version map source (zig/zls) |
| `mirrorlist` | | Set mirror distribution server |
| `proxy` | | Set HTTP/HTTPS proxy for downloads |
| `completion` | | Generate shell completion script |
| `version` | `-v` | Print zvm version |
| `help` | `-h` | Print help message |

### Global Options

```
--color=VALUE    Toggle color output (on/off/true/false)
--help, -h       Print help
--version, -v    Print version
```

### Install Options

```
--force, -f      Force re-install even if already installed
--zls            Also install ZLS (Zig Language Server)
--full           Install ZLS with full compatibility mode
--nomirror       Skip community mirror downloads
```

### List Options

```
--all, -a        List all remote versions available for download
--vmu            Show configured version map URLs
```

### Use Options

```
--sync           Use version from build.zig.zon's minimum_zig_version
```

### VMU (Version Map URL)

Change where zvm fetches version information:

```bash
# Use official Zig releases (default)
zvm vmu zig default

# Use Mach engine builds
zvm vmu zig mach

# Use a custom version map URL
zvm vmu zig https://example.com/versions.json

# Reset ZLS source
zvm vmu zls default
```

### Mirror List

Configure community mirrors for faster downloads:

```bash
# Reset to official mirrors
zvm mirrorlist default

# Set a custom mirror
zvm mirrorlist https://example.com/mirrors.txt

# Show current mirror setting
zvm mirrorlist
```

### Proxy

Configure HTTP/HTTPS proxy for all network operations (downloads, version map fetches, upgrades):

```bash
# Set a proxy
zvm proxy http://127.0.0.1:7890

# Set a SOCKS5 proxy
zvm proxy socks5://127.0.0.1:1080

# Clear proxy (auto-detect from http_proxy/https_proxy env vars)
zvm proxy default

# Show current proxy setting
zvm proxy
```

## Shell Completion

### Zsh

Add to `~/.zshrc`:

```bash
eval "$(zvm completion zsh)"
```

### Bash

Add to `~/.bashrc`:

```bash
eval "$(zvm completion bash)"
```

## How It Works

```
~/.zvm/
├── bin            → symlink/junction to the active version directory
├── .active        → marker file tracking the active version name
├── 0.15.2/        → Zig 0.15.2 installation
│   └── zig        → Zig compiler binary
├── 0.14.0/        → Zig 0.14.0 installation
│   └── zig
├── master/        → Latest nightly build
│   └── zig
├── self/          → zvm's own data
└── settings.json  → Configuration file
```

- **Version switching** uses symbolic links (junctions on Windows) — `~/.zvm/bin` points to the active version's directory
- **Downloads** are streamed to disk with SHA256 verification and latency-based mirror selection
- **Settings** are persisted immediately on every change to `~/.zvm/settings.json`
- **No background services** — zvm runs only when you invoke it

## Configuration

Settings are stored in `~/.zvm/settings.json`:

```json
{
    "version_map_url": "https://ziglang.org/download/index.json",
    "zls_vmu": "https://releases.zigtools.org/",
    "mirror_list_url": "https://ziglang.org/download/community-mirrors.txt",
    "use_color": true,
    "always_force_install": false,
    "preferred_mirror": "",
    "mirror_updated_at": 0,
    "proxy": ""
}
```

Override the default `~/.zvm` location with the `ZVM_PATH` environment variable:

```bash
export ZVM_PATH="/custom/path"
```

## CI / Releases

Pushing a `v*` tag triggers automatic CI builds for all platforms:

```bash
git tag v0.1.0
git push origin v0.1.0
```

This creates two GitHub Releases:
- **Versioned release** with `zvm-v0.1.0-<platform>.tar.gz` assets
- **`latest` release** with stable-named assets for permalink downloads

Stable download URLs (always point to the latest version):

| Platform | File |
|----------|------|
| macOS (Apple Silicon) | `zvm-aarch64-macos.tar.gz` |
| macOS (Intel) | `zvm-x86_64-macos.tar.gz` |
| Linux (x86_64) | `zvm-x86_64-linux.tar.gz` |
| Linux (ARM64) | `zvm-aarch64-linux.tar.gz` |
| Windows (x86_64) | `zvm-x86_64-windows.zip` |
| Windows (ARM64) | `zvm-aarch64-windows.zip` |

All available at `https://github.com/lispking/zvm/releases/latest/download/<file>`

## Project Structure

```
src/
├── main.zig          Entry point: allocator setup, CLI dispatch
├── cli.zig           Hand-written CLI parser with aliases and flags
├── zvm.zig           Core ZVM struct (base dir, settings, versions)
├── settings.zig      Settings persistence (JSON load/save)
├── errors.zig        Domain error definitions
├── platform.zig      OS/arch detection, symlink management
├── terminal.zig      ANSI color output helpers
├── version_map.zig   Fetch/parse Zig & ZLS version maps
├── http_client.zig   HTTP downloads with mirror and proxy support
├── crypto.zig        SHA256 file verification
├── archive.zig       Archive extraction (.tar.xz, .zip)
├── install.zig       Install command (download, verify, extract)
├── use.zig           Use command (switch active version)
├── list.zig          List command (installed, remote, VMU)
├── uninstall.zig     Uninstall command
├── clean.zig         Clean command (remove archives)
├── run.zig           Run command (execute specific version)
├── upgrade.zig       Upgrade command (self-update from GitHub)
├── vmu.zig           VMU command (version map source)
├── mirrorlist.zig    Mirrorlist command (mirror config)
├── proxy.zig         Proxy command (proxy config)
└── completion.zig    Shell completion generation (zsh/bash)
```

## Comparison with the Go Version

This is a rewrite of [tristanisham/zvm](https://github.com/tristanisham/zvm) (Go). Key differences:

| | Go (original) | Zig (this) |
|---|---|---|
| Binary size | ~10MB | ~1-2MB |
| Dependencies | Go runtime | None (static) |
| Build tool | Go compiler | Zig compiler |
| Shell completion | No | Yes (zsh, bash) |
| Mirror selection | Sequential | Latency-based |
| Proxy support | No | Yes (HTTP/SOCKS5) |
| Windows support | Yes | Yes (junctions) |

## License

MIT
