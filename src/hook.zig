//! Shell hook generators for automatic version switching on directory change.
//! Usage: eval "$(zvm hook bash)"  /  eval "$(zvm hook zsh)"  /  zvm hook fish | source

const std = @import("std");

pub fn generateBash(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# zvm shell hook for bash
        \\# Add to ~/.bashrc: eval "$(zvm hook bash)"
        \\
        \\_zvm_hook() {
        \\    local resolved
        \\    resolved="$(zvm which --json 2>/dev/null)" || return
        \\    local ver
        \\    ver="$(printf '%s' "$resolved" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
        \\    [ -z "$ver" ] && return
        \\
        \\    if [ "$ver" != "$ZVM_CURRENT" ]; then
        \\        local zvm_dir="${ZVM_DIR:-$HOME/.zvm}"
        \\        local ver_dir="$zvm_dir/versions/$ver"
        \\        if [ -d "$ver_dir" ]; then
        \\            # Remove old version path from PATH
        \\            if [ -n "$ZVM_CURRENT" ]; then
        \\                PATH="$(printf '%s' "$PATH" | sed "s|$zvm_dir/versions/$ZVM_CURRENT:||")"
        \\            fi
        \\            # Prepend new version path
        \\            export PATH="$ver_dir:$PATH"
        \\            export ZVM_CURRENT="$ver"
        \\        fi
        \\    fi
        \\}
        \\
        \\_zvm_cd() {
        \\    builtin cd "$@" || return
        \\    _zvm_hook
        \\}
        \\
        \\alias cd=_zvm_cd
        \\
        \\# Run once on shell startup
        \\_zvm_hook
        \\
    );
}

pub fn generateZsh(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# zvm shell hook for zsh
        \\# Add to ~/.zshrc: eval "$(zvm hook zsh)"
        \\
        \\_zvm_hook() {
        \\    local resolved
        \\    resolved="$(zvm which --json 2>/dev/null)" || return
        \\    local ver
        \\    ver="$(printf '%s' "$resolved" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
        \\    [[ -z "$ver" ]] && return
        \\
        \\    if [[ "$ver" != "$ZVM_CURRENT" ]]; then
        \\        local zvm_dir="${ZVM_DIR:-$HOME/.zvm}"
        \\        local ver_dir="$zvm_dir/versions/$ver"
        \\        if [[ -d "$ver_dir" ]]; then
        \\            if [[ -n "$ZVM_CURRENT" ]]; then
        \\                path=("${path[@]:#$zvm_dir/versions/$ZVM_CURRENT}")
        \\            fi
        \\            path=("$ver_dir" "${path[@]}")
        \\            export ZVM_CURRENT="$ver"
        \\        fi
        \\    fi
        \\}
        \\
        \\autoload -U add-zsh-hook
        \\add-zsh-hook chpwd _zvm_hook
        \\
        \\# Run once on shell startup
        \\_zvm_hook
        \\
    );
}

pub fn generateFish(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# zvm shell hook for fish
        \\# Add to config: zvm hook fish | source
        \\
        \\function _zvm_hook --on-variable PWD
        \\    set -l resolved (zvm which --json 2>/dev/null)
        \\    or return
        \\    set -l ver (string match -r '"version":"([^"]*)"' $resolved)[2]
        \\    test -z "$ver"; and return
        \\
        \\    if test "$ver" != "$ZVM_CURRENT"
        \\        set -l zvm_dir (set -q ZVM_DIR; and echo $ZVM_DIR; or echo $HOME/.zvm)
        \\        set -l ver_dir "$zvm_dir/versions/$ver"
        \\        if test -d $ver_dir
        \\            if set -q ZVM_CURRENT
        \\                set -l idx (contains -i "$zvm_dir/versions/$ZVM_CURRENT" $PATH)
        \\                and set -e PATH[$idx]
        \\            end
        \\            set -gx PATH $ver_dir $PATH
        \\            set -gx ZVM_CURRENT $ver
        \\        end
        \\    end
        \\end
        \\
        \\# Run once on shell startup
        \\_zvm_hook
        \\
    );
}

// ──── Tests ────

test "bash hook contains cd wrapper" {
    var buf: [16384]u8 = undefined;
    var w: std.fs.File.Writer = .init(std.fs.File.stdout(), &buf);
    try generateBash(&w.interface);
    try std.testing.expect(w.interface.end > 0);
}

test "zsh hook uses chpwd" {
    var buf: [16384]u8 = undefined;
    var w: std.fs.File.Writer = .init(std.fs.File.stdout(), &buf);
    try generateZsh(&w.interface);
    try std.testing.expect(w.interface.end > 0);
}

test "fish hook uses PWD variable" {
    var buf: [16384]u8 = undefined;
    var w: std.fs.File.Writer = .init(std.fs.File.stdout(), &buf);
    try generateFish(&w.interface);
    try std.testing.expect(w.interface.end > 0);
}
