#!/usr/bin/env bash
#
# install.sh — one-line installer for zvm (Zig Version Manager)
#
# Usage:
#   curl -L https://github.com/lispking/zvm/releases/latest/download/install.sh | bash
#   or: curl -L https://raw.githubusercontent.com/lispking/zvm/main/install.sh | bash
#
set -euo pipefail

REPO="lispking/zvm"
INSTALL_DIR="${ZVM_INSTALL:-$HOME/.local/bin}"
ZVM_DIR="${ZVM_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/zvm}"

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${CYAN}>>>${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN} ✓${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW} !${RESET} %s\n" "$*"; }
err()   { printf "${RED} ✗${RESET} %s\n" "$*" >&2; }

# ── Detect platform ─────────────────────────────────────────────────────
detect_platform() {
    local os arch

    case "$(uname -s)" in
        Darwin) os="macos" ;;
        Linux)  os="linux" ;;
        *)
            err "Unsupported OS: $(uname -s). Only macOS and Linux are supported by this script."
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)
            err "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    echo "${os}-${arch}"
}

# ── Download helper ─────────────────────────────────────────────────────
download() {
    local url="$1" dest="$2"

    if command -v curl &>/dev/null; then
        curl -fSL --progress-bar -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url"
    else
        err "Neither curl nor wget found. Please install one and retry."
        exit 1
    fi
}

# ── Detect current shell ────────────────────────────────────────────────
detect_shell_rc() {
    local shell_name=""

    # Prefer $SHELL (user's login shell) over version variables,
    # because the script may run under bash via shebang while the user uses zsh.
    if [ -n "${SHELL:-}" ]; then
        shell_name="$(basename "$SHELL")"
    fi

    # Fallback to the running interpreter's version
    if [ -z "$shell_name" ]; then
        if [ -n "${ZSH_VERSION:-}" ]; then
            shell_name="zsh"
        elif [ -n "${BASH_VERSION:-}" ]; then
            shell_name="bash"
        fi
    fi

    case "$shell_name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        *)    echo "" ;;
    esac
}

# ── Add string to file if not already present ───────────────────────────
append_once() {
    local file="$1" marker="$2" content="$3"

    if [ ! -f "$file" ]; then
        touch "$file"
    fi

    if ! grep -qF "$marker" "$file" 2>/dev/null; then
        printf '\n%s\n' "$content" >> "$file"
    fi
}

# ── Temp directory (script-level so EXIT trap can access it in zsh) ──
TMP_DIR=""

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# ── Main ────────────────────────────────────────────────────────────────
main() {
    echo ""
    printf "${BOLD}  zvm — Zig Version Manager${RESET}"
    echo ""
    echo ""

    # 1. Detect platform
    local platform
    platform="$(detect_platform)"
    local os="${platform%-*}"
    local arch="${platform#*-}"
    info "Detected platform: ${os} / ${arch}"

    # 2. Determine download URL
    local archive_name="zvm-${arch}-${os}.tar.gz"
    local url="https://github.com/${REPO}/releases/latest/download/${archive_name}"

    # 3. Create temp directory
    TMP_DIR="$(mktemp -d)"

    local archive_path="${TMP_DIR}/${archive_name}"

    # 4. Download
    info "Downloading ${archive_name}..."
    download "$url" "$archive_path"

    # 5. Extract
    info "Extracting..."
    tar xzf "$archive_path" -C "$TMP_DIR"

    # Find the zvm binary inside the extracted directory
    local zvm_binary=""
    for f in "${TMP_DIR}"/zvm-*/zvm "${TMP_DIR}"/zvm/zvm "${TMP_DIR}"/zvm; do
        if [ -f "$f" ] && [ -x "$f" ]; then
            zvm_binary="$f"
            break
        fi
    done

    if [ -z "$zvm_binary" ]; then
        # Fallback: search for any zvm binary
        zvm_binary="$(find "$TMP_DIR" -name zvm -type f -perm -u+x | head -n 1)"
    fi

    if [ -z "$zvm_binary" ] || [ ! -f "$zvm_binary" ]; then
        err "Could not find zvm binary in the archive"
        exit 1
    fi

    # 6. Install binary
    mkdir -p "$INSTALL_DIR"
    cp "$zvm_binary" "${INSTALL_DIR}/zvm"
    chmod +x "${INSTALL_DIR}/zvm"
    ok "Installed zvm to ${INSTALL_DIR}/zvm"

    # 7. Ensure paths are in shell rc
    local shell_rc
    shell_rc="$(detect_shell_rc)"

    local needs_local_bin=true
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) needs_local_bin=false ;;
    esac

    local needs_zvm_bin=true
    case ":${PATH}:" in
        *":${ZVM_DIR}/bin:"*) needs_zvm_bin=false ;;
    esac

    if [ "$needs_local_bin" = false ]; then
        ok "Install directory already in PATH"
    fi

    if [ -n "$shell_rc" ]; then
        if [ "$needs_local_bin" = true ]; then
            append_once "$shell_rc" "# >>> zvm >>>" \
                "# >>> zvm >>>
export PATH=\"\${HOME}/.local/bin:\$PATH\""
        fi
        if [ "$needs_zvm_bin" = true ]; then
            append_once "$shell_rc" "# <<< zvm <<<" \
                "export PATH=\"\${ZVM_PATH:-\${XDG_DATA_HOME:-\$HOME/.local/share}/zvm}/bin:\$PATH\"
# <<< zvm <<<"
        fi
        if [ "$needs_local_bin" = true ] || [ "$needs_zvm_bin" = true ]; then
            ok "Added PATH entries to ${shell_rc}"
        fi
    else
        if [ "$needs_local_bin" = true ] || [ "$needs_zvm_bin" = true ]; then
            warn "Could not detect shell config file."
            warn "Add these lines to your shell config manually:"
            echo ""
            echo '  export PATH="$HOME/.local/bin:$PATH"'
            echo '  export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/zvm/bin:$PATH"'
            echo ""
        fi
    fi

    # 8. Set up shell completion
    if [ -n "$shell_rc" ]; then
        case "$shell_rc" in
            */.zshrc)
                append_once "$shell_rc" "# zvm completion" \
                    'eval "$(zvm completion zsh 2>/dev/null)"'
                ok "Added zsh completion to ${shell_rc}"
                ;;
            */.bashrc)
                append_once "$shell_rc" "# zvm completion" \
                    'eval "$(zvm completion bash 2>/dev/null)"'
                ok "Added bash completion to ${shell_rc}"
                ;;
        esac
    fi

    # 9. Done
    echo ""
    printf "${GREEN}${BOLD}  zvm installed successfully!${RESET}"
    echo ""
    echo ""

    if [ "$needs_local_bin" = true ] || [ "$needs_zvm_bin" = true ]; then
        printf "${YELLOW}  Restart your shell or run:${RESET}"
        echo ""
        echo ""
        if [ -n "$shell_rc" ]; then
            echo "    source ${shell_rc}"
        else
            echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
            echo "    export PATH=\"\${XDG_DATA_HOME:-\$HOME/.local/share}/zvm/bin:\$PATH\""
        fi
        echo ""
    fi

    echo "  Quick start:"
    echo ""
    echo "    zvm install master"
    echo "    zvm use master"
    echo "    zig version"
    echo ""
}

main "$@"
