#!/bin/sh
# zvm installer — downloads a prebuilt binary (no Zig required) or falls back
# to building from source if Zig is available.
set -eu

ZVM_DIR="${ZVM_DIR:-$HOME/.zvm}"
REPO_OWNER="Turrain"
REPO_NAME="zvm"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
RELEASE_TAG="${ZVM_RELEASE_TAG:-latest}"

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

http_get() {
    url="$1"
    out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$out"
    else
        die "need curl or wget to download prebuilt binaries"
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

try_download_release() {
    ASSET="zvm-${PLATFORM}.tar.gz"

    if [ "$RELEASE_TAG" = "latest" ]; then
        BASE="${REPO_URL}/releases/latest/download"
    else
        BASE="${REPO_URL}/releases/download/${RELEASE_TAG}"
    fi

    TMP="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$TMP'" EXIT INT TERM

    info "download:" "fetching $ASSET from $RELEASE_TAG release..."
    if ! http_get "$BASE/$ASSET" "$TMP/$ASSET" 2>/dev/null; then
        warn "download:" "no prebuilt binary for $PLATFORM at $RELEASE_TAG"
        return 1
    fi

    if http_get "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" 2>/dev/null; then
        expected="$(awk -v f="$ASSET" '$2 == f || $2 == "*"f {print $1; exit}' "$TMP/SHA256SUMS")"
        if [ -n "$expected" ]; then
            actual="$(sha256_of "$TMP/$ASSET")"
            if [ -z "$actual" ]; then
                warn "verify:" "no sha256sum/shasum available; skipping"
            elif [ "$actual" != "$expected" ]; then
                die "SHA256 mismatch for $ASSET (expected $expected, got $actual)"
            else
                info "verify:" "sha256 ok"
            fi
        else
            warn "verify:" "$ASSET not listed in SHA256SUMS"
        fi
    else
        warn "verify:" "SHA256SUMS unavailable; skipping"
    fi

    tar -xzf "$TMP/$ASSET" -C "$TMP"
    [ -f "$TMP/zvm" ] || die "archive missing zvm binary"
    install -m 755 "$TMP/zvm" "$ZVM_DIR/bin/zvm"
    if [ -f "$TMP/zvm-proxy" ]; then
        install -m 755 "$TMP/zvm-proxy" "$ZVM_DIR/bin/zvm-proxy"
    fi
    info "ok:" "installed zvm to $ZVM_DIR/bin/zvm"
    return 0
}

try_build_from_source() {
    SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
    [ -f "$SCRIPT_DIR/build.zig" ] || return 1
    command -v zig >/dev/null 2>&1 || return 1

    info "build:" "building zvm from source with $(zig version)..."
    ( cd "$SCRIPT_DIR" && zig build -Doptimize=ReleaseSafe ) || die "build failed"
    install -m 755 "$SCRIPT_DIR/zig-out/bin/zvm" "$ZVM_DIR/bin/zvm"
    if [ -f "$SCRIPT_DIR/zig-out/bin/zvm-proxy" ]; then
        install -m 755 "$SCRIPT_DIR/zig-out/bin/zvm-proxy" "$ZVM_DIR/bin/zvm-proxy"
    fi
    info "ok:" "installed zvm to $ZVM_DIR/bin/zvm"
    return 0
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
        mkdir -p "$(dirname "$PROFILE")"
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

    if try_download_release; then
        :
    elif try_build_from_source; then
        :
    else
        die "no prebuilt binary for $PLATFORM and no Zig available to build from source.
    options:
      1. install Zig from https://ziglang.org/download/ and re-run this script
      2. clone $REPO_URL and run 'zig build -Doptimize=ReleaseSafe' manually
      3. open an issue requesting a prebuilt for $PLATFORM"
    fi

    add_to_path
    echo
    info "done:" "restart your shell or run: . $PROFILE"
    info "start:" "zvm install stable"
}

main "$@"
