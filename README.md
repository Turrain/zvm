# zvm

A fast, correct Zig version manager written in Zig.

Manage multiple Zig compiler versions with automatic per-project switching,
SHA256 + minisign verification, ZLS integration, and shell completions.

## Features

- **Automatic version switching** -- resolves the right Zig version from
  `ZIG_VERSION`, `.zig-version`, or `build.zig.zon` with no manual intervention
- **Proxy launcher** -- a 2 MB binary that replaces symlinks and transparently
  resolves versions, with `zig +0.13.0 build` override syntax
- **SHA256 + minisign verification** -- every download is hash-checked; optional
  Ed25519 signature verification against the ZSF public key
- **ZLS management** -- install the matching Zig Language Server alongside any
  Zig version with `--zls`
- **Partial version matching** -- `zvm install 0.14` resolves to the latest
  `0.14.x` release
- **Shell hooks** -- auto-switch on `cd` for bash, zsh, and fish
- **Shell completions** -- tab-completion for all commands, versions, and flags
- **JSON output** -- every command supports `--json` for scripting and CI
- **Index caching** -- the version index is cached for 1 hour; override with
  `--no-cache`
- **Read-only stdlib** -- installed `lib/` files are set read-only to prevent
  accidental modification
- **Mirror support** -- set `ZVM_MIRROR` for corporate or regional mirrors
- **Self-diagnosis** -- `zvm doctor` checks PATH, symlinks, config, and network
- **Upgrade** -- `zvm upgrade` jumps to the latest stable in one command
- **Minisign verification** -- automatic Ed25519 signature check when `.minisig`
  is available
- **Structured exit codes** -- 0=success, 1=error, 2=not found, 3=verification
  failed
- **Cross-platform** -- Linux, macOS, Windows, FreeBSD, NetBSD, OpenBSD on
  x86_64, aarch64, arm, riscv64, and more

## Quick start

No Zig toolchain required -- the installer downloads a prebuilt binary for
your platform from GitHub Releases:

```sh
curl -fsSL https://raw.githubusercontent.com/Turrain/zvm/main/install.sh | sh
```

Or clone and run locally:

```sh
git clone https://github.com/Turrain/zvm.git
cd zvm
./install.sh
```

The installer:
1. Detects your platform (`x86_64-linux`, `aarch64-macos`, etc.).
2. Downloads the matching asset from the latest GitHub Release.
3. Verifies the SHA256 against `SHA256SUMS`.
4. Falls back to `zig build -Doptimize=ReleaseSafe` if Zig is available and no
   prebuilt exists.

After install, restart your shell (or `source` your profile) and run:

```sh
zvm install stable
```

### Manual install from source (requires Zig 0.15+)

```sh
git clone https://github.com/Turrain/zvm.git
cd zvm
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/zvm ~/.local/bin/   # or anywhere on your PATH
```

## Usage

```
zvm <command> [options]
```

### Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `install <version>` | `i` | Install a Zig version |
| `use <version>` | `default` | Set the default Zig version |
| `list` | `ls` | List installed versions |
| `ls-remote` | `list-remote` | List available remote versions |
| `remove <version>` | `rm`, `uninstall` | Remove an installed version |
| `run <version> [-- args]` | | Run a command with a specific version |
| `which` | | Show which version would be used |
| `env` | | Show environment info |
| `pin [version]` | | Write `.zig-version` in current directory |
| `hook <shell>` | | Generate shell hook for auto-switching |
| `completions <shell>` | | Generate shell completions |
| `clean` | | Remove all non-default versions |
| `doctor` | | Diagnose PATH, symlinks, config, network |
| `upgrade` | | Upgrade to the latest stable version |
| `shell <version>` | | Activate version for current shell session |
| `help` | | Show help |

### Global flags

| Flag | Short | Description |
|------|-------|-------------|
| `--quiet` | `-q` | Suppress output |
| `--json` | | JSON output for scripting |
| `--no-color` | | Disable colored output |
| `--version` | `-v` | Print zvm version |
| `--help` | `-h` | Show help |

Flags can appear anywhere in the command -- `zvm list --json` and
`zvm --json list` both work.

### Install flags

| Flag | Description |
|------|-------------|
| `--zls` | Also install the matching ZLS |
| `--force`, `-f` | Reinstall even if already present |
| `--no-verify` | Skip SHA256 hash verification |
| `--no-cache` | Force a fresh index fetch (useful in CI) |
| `--local`, `-l` | Install into `./zig/` in current directory |

## Version resolution

When you run `zig` (via the proxy) or any zvm command that needs a version,
zvm resolves it using this priority chain:

| Priority | Source | Example |
|----------|--------|---------|
| 1 | `ZIG_VERSION` environment variable | `ZIG_VERSION=0.13.0 zig build` |
| 2 | `.zig-version` or `.zigversion` file | Walk up the directory tree |
| 3 | `build.zig.zon` `minimum_zig_version` | Walk up the directory tree |
| 4 | Default version | Set via `zvm use <version>` |

This matches the pattern established by rustup's toolchain resolution.

## Examples

### Install and switch versions

```sh
zvm install stable          # Latest stable release
zvm install 0.14.0          # Exact version
zvm install 0.14            # Latest 0.14.x (partial match)
zvm install master          # Nightly / dev build
zvm install stable --zls    # Stable + matching ZLS

zvm use 0.14.0              # Set as default
zvm list                    # Show installed versions
zvm ls-remote               # Show all available versions
```

### Installation scopes

zvm supports four scopes for installing and activating Zig:

**User-level** (default) -- versions live in `~/.zvm/versions/`:

```sh
zvm install stable          # Install for the current user
zvm use 0.14.0              # Set user default
```

**Project-local** -- vendor zig directly into your project at `./zig/`:

```sh
cd my-project
zvm install 0.14.0 --local  # Copies zig into ./zig/
./zig/zig build              # Hermetic: no global state needed
#   ✓ Installed zig 0.14.0 locally in ./zig/
```

The resolution chain detects `./zig/zig` automatically, so `zvm which` and
the proxy binary both pick it up. This is the approach
[recommended by matklad](https://matklad.github.io/2023/06/02/the-worst-zig-version-manager.html)
and used by TigerBeetle.

**Shell-session** -- activate a version for the current shell only:

```sh
eval "$(zvm shell 0.13.0)"  # Prepends version to PATH, sets ZVM_CURRENT
zig version                  # 0.13.0
# ... close the terminal and it's gone
```

**System-wide** -- set `ZVM_DIR` to a shared path:

```sh
sudo ZVM_DIR=/opt/zvm zvm install stable
sudo ZVM_DIR=/opt/zvm zvm use stable
# Then each user adds: export PATH="/opt/zvm/bin:$PATH"
```

### Version resolution

The priority chain (highest wins):

| Priority | Source | Scope |
|----------|--------|-------|
| 1 | `ZIG_VERSION` env var | Shell |
| 2 | `./zig/zig` binary | Project-local |
| 3 | `.zig-version` / `.zigversion` file | Project |
| 4 | `build.zig.zon` `minimum_zig_version` | Project |
| 5 | Default (`zvm use`) | User / System |

Sources 2-4 walk up the directory tree from the current directory.

### Per-project version pinning

```sh
cd my-project
zvm pin 0.14.0              # Creates .zig-version
zvm which                   # Shows resolved version + source
#   zig 0.14.0
#   source: .zig-version file (my-project/.zig-version)
```

### Run with a specific version

```sh
zvm run 0.13.0 -- build     # Run 'zig build' with 0.13.0
zvm run master -- test       # Run 'zig test' with nightly
```

### Proxy launcher (`+version` syntax)

Install the proxy binary as `~/.zvm/bin/zig`:

```sh
cp zig-out/bin/zvm-proxy ~/.zvm/bin/zig
```

Then use the `+version` override anywhere:

```sh
zig build                   # Uses resolved version
zig +0.13.0 build           # Override to 0.13.0 for this invocation
```

The proxy works in editors, CI, Makefiles, and anywhere shell hooks do not run.

### Shell hooks (auto-switch on `cd`)

```sh
# Bash -- add to ~/.bashrc:
eval "$(zvm hook bash)"

# Zsh -- add to ~/.zshrc:
eval "$(zvm hook zsh)"

# Fish -- add to config.fish:
zvm hook fish | source
```

When you `cd` into a directory with `.zig-version` or `build.zig.zon`, the
hook automatically activates the correct Zig version.

### Shell completions

```sh
# Bash
eval "$(zvm completions bash)"

# Zsh
eval "$(zvm completions zsh)"

# Fish
zvm completions fish | source
# Or save permanently:
zvm completions fish > ~/.config/fish/completions/zvm.fish
```

### JSON output for scripting

```sh
zvm list --json
# ["0.14.1","0.14.0"]

zvm which --json
# {"version":"0.14.0","source":"zig_version_file"}

zvm env --json
# {"zvm_dir":"/home/user/.zvm","platform":"x86_64-linux","version":"0.1.0"}
```

### Diagnostics

```sh
zvm doctor
#   ✓ ZVM directory exists: /home/user/.zvm
#   ✓ /home/user/.zvm/bin is in PATH
#   ✓ Default version: 0.14.0
#   ✓ Version directory exists
#   ✓ zig symlink OK
#   ! ZLS not installed (optional)
#   ✓ Network: can reach ziglang.org
#   All checks passed.
```

### Upgrade

```sh
zvm upgrade              # Upgrade to latest stable
zvm upgrade --zls        # Also upgrade ZLS
#   Current: zig 0.14.0
#   Upgrading: 0.14.0 → 0.15.2
#   ✓ Upgraded to zig 0.15.2
```

### CI usage

```sh
zvm install stable --quiet          # Silent install
zvm install 0.14.0 --no-cache      # Skip cached index
zvm install 0.14                    # Partial match: latest 0.14.x
```

### Mirror support

```sh
# Use a mirror for downloads (China, corporate, etc.)
export ZVM_MIRROR=https://mirror.example.com/zig
zvm install stable
```

The mirror replaces `https://ziglang.org/` in download URLs. SHA256
verification still applies against the official index.

## Directory layout

```
~/.zvm/
  bin/                  # Symlinks or proxy (add to PATH)
    zig -> ../versions/0.14.0/zig
    zls -> ../zls/0.14.0/zls
  versions/             # Installed Zig versions
    0.13.0/
    0.14.0/
    master/
  zls/                  # Installed ZLS versions
    0.14.0/
  cache/                # Downloaded archives + index cache
    index.json
  config.json           # {"default":"0.14.0"}
```

## Security

Downloads are verified by default:

- **SHA256** -- hash is checked against the official index at
  `ziglang.org/download/index.json`
- **Minisign** -- optional Ed25519 signature verification using the
  [Zig Software Foundation public key](https://ziglang.org/download/)

Skip verification with `--no-verify` (not recommended).

## Building from source

Requires Zig 0.15.0 or later.

```sh
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe

# Run tests
zig build test

# Run directly
zig build run -- install stable
```

Two binaries are produced:

| Binary | Size | Purpose |
|--------|------|---------|
| `zvm` | ~7 MB | Version manager CLI |
| `zvm-proxy` | ~2 MB | Transparent proxy launcher |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZVM_DIR` | `~/.zvm` | Override the zvm data directory |
| `ZIG_VERSION` | | Force a specific Zig version (highest priority) |
| `ZVM_CURRENT` | | Set by shell hooks to track the active version |
| `ZVM_MIRROR` | | Mirror URL to replace `https://ziglang.org/` in downloads |

## Supported platforms

Architectures: x86_64, aarch64, armv7a, x86, powerpc64le, riscv64, loongarch64, s390x

Operating systems: Linux, macOS, Windows, FreeBSD, NetBSD, OpenBSD

## Project structure

```
src/
  main.zig          CLI entry point, all commands            1351 lines
  resolve.zig       Version resolution + SemVer               389 lines
  fetch.zig         HTTP downloads, mirrors, index cache      368 lines
  verify.zig        SHA256 + minisign verification            221 lines
  completions.zig   Shell completion generators               170 lines
  hook.zig          Shell hook generators                     132 lines
  zls.zig           ZLS management                            126 lines
  proxy.zig         Proxy launcher for zig/zls                103 lines
  extract.zig       tar.xz + zip extraction                    91 lines
```

~3,000 lines of Zig. 55+ unit tests. No external dependencies -- built
entirely on the Zig standard library.

## License

MIT
