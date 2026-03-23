#!/bin/sh
# zvm installer — bootstraps zvm from a pre-built binary or builds from source.
set -eu

ZVM_DIR="${ZVM_DIR:-$HOME/.zvm}"
REPO="https://github.com/Turrain/zvm"

info()  { printf '  \033[32m%s\033[0m %s\n' "$1" "$2"; }
warn()  { printf '  \033[33m%s\033[0m %s\n' "$1" "$2"; }
err()   { printf '  \033[31m%s\033[0m %s\n' "$1" "$2" >&2; }
die()   { err "error:" "$1"; exit 1; }

detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux)  OS="linux" ;;
        Darwin) OS="macos" ;;
        FreeBSD) OS="freebsd" ;;
        *) die "unsupported OS: $OS" ;;
    esac

    case "$ARCH" in
        x86_64|amd64) ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        armv7*) ARCH="armv7a" ;;
        riscv64) ARCH="riscv64" ;;
        *) die "unsupported architecture: $ARCH" ;;
    esac

    PLATFORM="${ARCH}-${OS}"
}

setup_dirs() {
    mkdir -p "$ZVM_DIR/bin"
    mkdir -p "$ZVM_DIR/versions"
    mkdir -p "$ZVM_DIR/zls"
    mkdir -p "$ZVM_DIR/cache"
}

try_build_from_source() {
    if command -v zig >/dev/null 2>&1; then
        info "build:" "building zvm from source with $(zig version)..."
        cd "$(dirname "$0")"
        zig build -Doptimize=ReleaseSafe || die "build failed"
        cp zig-out/bin/zvm "$ZVM_DIR/bin/zvm"
        chmod +x "$ZVM_DIR/bin/zvm"
        info "ok:" "installed zvm to $ZVM_DIR/bin/zvm"
        return 0
    fi
    return 1
}

add_to_path() {
    BIN_DIR="$ZVM_DIR/bin"
    SHELL_NAME="$(basename "${SHELL:-/bin/sh}")"

    case "$SHELL_NAME" in
        bash)
            PROFILE="$HOME/.bashrc"
            LINE="export PATH=\"$BIN_DIR:\$PATH\""
            ;;
        zsh)
            PROFILE="$HOME/.zshrc"
            LINE="export PATH=\"$BIN_DIR:\$PATH\""
            ;;
        fish)
            PROFILE="$HOME/.config/fish/config.fish"
            LINE="fish_add_path $BIN_DIR"
            ;;
        *)
            PROFILE="$HOME/.profile"
            LINE="export PATH=\"$BIN_DIR:\$PATH\""
            ;;
    esac

    if [ -f "$PROFILE" ] && grep -qF "$BIN_DIR" "$PROFILE" 2>/dev/null; then
        info "path:" "already configured in $PROFILE"
    else
        printf '\n# zvm\n%s\n' "$LINE" >> "$PROFILE"
        info "path:" "added to $PROFILE"
    fi
}

main() {
    info "zvm:" "Zig Version Manager installer"
    echo

    detect_platform
    info "platform:" "$PLATFORM"

    setup_dirs
    info "dirs:" "created $ZVM_DIR"

    # Try building from source if we're in the repo
    if [ -f "$(dirname "$0")/build.zig" ]; then
        if try_build_from_source; then
            add_to_path
            echo
            info "done:" "restart your shell or run: source $PROFILE"
            info "start:" "zvm install stable"
            return 0
        fi
    fi

    die "no pre-built binary available yet. Please build from source:
    git clone $REPO && cd zvm
    zig build -Doptimize=ReleaseSafe
    cp zig-out/bin/zvm $ZVM_DIR/bin/zvm"
}

main "$@"
