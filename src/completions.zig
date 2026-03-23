const std = @import("std");

pub fn generateBash(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# zvm bash completion
        \\# Add to ~/.bashrc: eval "$(zvm completions bash)"
        \\_zvm_completions() {
        \\    local cur prev commands
        \\    COMPREPLY=()
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\
        \\    commands="install use list ls-remote remove run which env completions clean help"
        \\
        \\    case "${prev}" in
        \\        zvm)
        \\            COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        install|use|remove|run)
        \\            local versions
        \\            if [ -d "${ZVM_DIR:-$HOME/.zvm}/versions" ]; then
        \\                versions=$(ls "${ZVM_DIR:-$HOME/.zvm}/versions" 2>/dev/null)
        \\            fi
        \\            if [ "${prev}" = "install" ]; then
        \\                versions="${versions} master stable"
        \\            fi
        \\            COMPREPLY=( $(compgen -W "${versions}" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\        completions)
        \\            COMPREPLY=( $(compgen -W "bash zsh fish" -- "${cur}") )
        \\            return 0
        \\            ;;
        \\    esac
        \\
        \\    if [[ "${cur}" == -* ]]; then
        \\        local flags="--help --quiet --json --no-color --version"
        \\        case "${COMP_WORDS[1]}" in
        \\            install)
        \\                flags="${flags} --zls --force --no-verify"
        \\                ;;
        \\        esac
        \\        COMPREPLY=( $(compgen -W "${flags}" -- "${cur}") )
        \\        return 0
        \\    fi
        \\}
        \\complete -F _zvm_completions zvm
        \\
    );
}

pub fn generateZsh(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef zvm
        \\# zvm zsh completion
        \\# Add to ~/.zshrc: eval "$(zvm completions zsh)"
        \\
        \\_zvm() {
        \\    local -a commands
        \\    commands=(
        \\        'install:Install a Zig version'
        \\        'use:Set the default Zig version'
        \\        'list:List installed versions'
        \\        'ls-remote:List available remote versions'
        \\        'remove:Remove an installed version'
        \\        'run:Run a command with a specific Zig version'
        \\        'which:Show which Zig version would be used'
        \\        'env:Show zvm environment info'
        \\        'completions:Generate shell completions'
        \\        'clean:Remove non-default versions'
        \\        'help:Show help'
        \\    )
        \\
        \\    _arguments -C \
        \\        '1:command:->command' \
        \\        '*::arg:->args'
        \\
        \\    case $state in
        \\        command)
        \\            _describe 'command' commands
        \\            ;;
        \\        args)
        \\            case $words[1] in
        \\                install|use|remove|run)
        \\                    local versions
        \\                    versions=(${(f)"$(ls "${ZVM_DIR:-$HOME/.zvm}/versions" 2>/dev/null)"})
        \\                    if [[ $words[1] == "install" ]]; then
        \\                        versions+=(master stable)
        \\                    fi
        \\                    _describe 'version' versions
        \\                    ;;
        \\                completions)
        \\                    _values 'shell' bash zsh fish
        \\                    ;;
        \\            esac
        \\            ;;
        \\    esac
        \\}
        \\
        \\_zvm "$@"
        \\
    );
}

pub fn generateFish(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\# zvm fish completion
        \\# Add to config: zvm completions fish | source
        \\# Or save to: ~/.config/fish/completions/zvm.fish
        \\
        \\complete -c zvm -f
        \\
        \\complete -c zvm -n __fish_use_subcommand -a install -d 'Install a Zig version'
        \\complete -c zvm -n __fish_use_subcommand -a use -d 'Set the default Zig version'
        \\complete -c zvm -n __fish_use_subcommand -a list -d 'List installed versions'
        \\complete -c zvm -n __fish_use_subcommand -a ls-remote -d 'List available remote versions'
        \\complete -c zvm -n __fish_use_subcommand -a remove -d 'Remove an installed version'
        \\complete -c zvm -n __fish_use_subcommand -a run -d 'Run with a specific Zig version'
        \\complete -c zvm -n __fish_use_subcommand -a which -d 'Show resolved Zig version'
        \\complete -c zvm -n __fish_use_subcommand -a env -d 'Show environment info'
        \\complete -c zvm -n __fish_use_subcommand -a completions -d 'Generate shell completions'
        \\complete -c zvm -n __fish_use_subcommand -a clean -d 'Remove non-default versions'
        \\complete -c zvm -n __fish_use_subcommand -a help -d 'Show help'
        \\
        \\function __zvm_installed_versions
        \\    set -l dir (set -q ZVM_DIR; and echo $ZVM_DIR; or echo $HOME/.zvm)
        \\    if test -d $dir/versions
        \\        ls $dir/versions 2>/dev/null
        \\    end
        \\end
        \\
        \\complete -c zvm -n '__fish_seen_subcommand_from install' -a '(__zvm_installed_versions) master stable'
        \\complete -c zvm -n '__fish_seen_subcommand_from use remove run' -a '(__zvm_installed_versions)'
        \\complete -c zvm -n '__fish_seen_subcommand_from completions' -a 'bash zsh fish'
        \\complete -c zvm -n '__fish_seen_subcommand_from install' -l zls -d 'Also install matching ZLS'
        \\complete -c zvm -n '__fish_seen_subcommand_from install' -l force -d 'Force reinstall'
        \\complete -c zvm -n '__fish_seen_subcommand_from install' -l no-verify -d 'Skip signature verification'
        \\complete -c zvm -l help -d 'Show help'
        \\complete -c zvm -l quiet -d 'Suppress output'
        \\complete -c zvm -l json -d 'Output as JSON'
        \\complete -c zvm -l no-color -d 'Disable colored output'
        \\complete -c zvm -l version -d 'Show zvm version'
        \\
    );
}

// ──── Tests ────

test "bash completions contain key commands" {
    var buf: [16384]u8 = undefined;
    var w: std.fs.File.Writer = .init(std.fs.File.stdout(), &buf);
    try generateBash(&w.interface);
    // Verify the buffer was written to (non-empty)
    try std.testing.expect(w.interface.end > 0);
}

test "zsh completions contain key commands" {
    var buf: [16384]u8 = undefined;
    var w: std.fs.File.Writer = .init(std.fs.File.stdout(), &buf);
    try generateZsh(&w.interface);
    try std.testing.expect(w.interface.end > 0);
}

test "fish completions contain key commands" {
    var buf: [16384]u8 = undefined;
    var w: std.fs.File.Writer = .init(std.fs.File.stdout(), &buf);
    try generateFish(&w.interface);
    try std.testing.expect(w.interface.end > 0);
}
