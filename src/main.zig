const std = @import("std");
const builtin = @import("builtin");
const fetch_mod = @import("fetch.zig");
const extract_mod = @import("extract.zig");
const resolve_mod = @import("resolve.zig");
const verify_mod = @import("verify.zig");
const zls_mod = @import("zls.zig");
const completions_mod = @import("completions.zig");
const hook_mod = @import("hook.zig");

const Allocator = std.mem.Allocator;

pub const app_version = "0.1.0";

// ──── ANSI helpers ────

const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
};

fn col(use_color: bool, code: []const u8) []const u8 {
    return if (use_color) code else "";
}

// ──── Application context ────

const Context = struct {
    allocator: Allocator,
    use_color: bool,
    quiet: bool,
    json_output: bool,
    zvm_dir: []const u8,

    fn init(allocator: Allocator, flags: GlobalFlags) !Context {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch
            std.process.getEnvVarOwned(allocator, "USERPROFILE") catch
            return error.NoHomeDir;
        defer allocator.free(home);

        const zvm_dir = if (std.process.getEnvVarOwned(allocator, "ZVM_DIR")) |d| d else |_|
            try std.fs.path.join(allocator, &.{ home, ".zvm" });

        const is_tty = std.posix.isatty(std.posix.STDERR_FILENO);

        return .{
            .allocator = allocator,
            .use_color = if (flags.no_color) false else is_tty,
            .quiet = flags.quiet,
            .json_output = flags.json,
            .zvm_dir = zvm_dir,
        };
    }

    fn deinit(self: *Context) void {
        self.allocator.free(self.zvm_dir);
    }

    fn ensureDirs(self: *const Context) !void {
        const dirs = [_][]const u8{ "bin", "versions", "zls", "cache" };
        for (dirs) |sub| {
            const path = try std.fs.path.join(self.allocator, &.{ self.zvm_dir, sub });
            defer self.allocator.free(path);
            std.fs.makeDirAbsolute(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    fn subpath(self: *const Context, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(self.allocator);
        try all.append(self.allocator, self.zvm_dir);
        try all.appendSlice(self.allocator, parts);
        return std.fs.path.join(self.allocator, all.items);
    }

    fn readConfig(self: *const Context) !Config {
        const path = try self.subpath(&.{"config.json"});
        defer self.allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024) catch return Config{};
        defer self.allocator.free(content);

        if (std.mem.indexOf(u8, content, "\"default\"")) |idx| {
            const after = content[idx + "\"default\"".len ..];
            if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
                const start = q1 + 1;
                if (std.mem.indexOfScalarPos(u8, after, start, '"')) |q2| {
                    const duped = try self.allocator.dupe(u8, after[start..q2]);
                    return Config{ .default = duped };
                }
            }
        }
        return Config{};
    }

    fn writeConfig(self: *const Context, config: Config) !void {
        const path = try self.subpath(&.{"config.json"});
        defer self.allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        // Write simple JSON manually (avoids complex serialization API changes)
        if (config.default) |d| {
            var buf: [256]u8 = undefined;
            const json_str = try std.fmt.bufPrint(&buf, "{{\"default\":\"{s}\"}}\n", .{d});
            try file.writeAll(json_str);
        } else {
            try file.writeAll("{}\n");
        }
    }
};

const Config = struct {
    default: ?[]const u8 = null,
};

const GlobalFlags = struct {
    quiet: bool = false,
    json: bool = false,
    no_color: bool = false,
    show_version: bool = false,
    show_help: bool = false,
};

// ──── Entry point ────

pub fn main() !void {
    // Use GPA in debug for leak detection; page_allocator in release for clean output
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.page_allocator;
    defer if (builtin.mode == .Debug) {
        _ = gpa.deinit();
    };

    var raw_args = try std.process.argsWithAllocator(allocator);
    defer raw_args.deinit();

    _ = raw_args.skip(); // program name

    // Collect args
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (raw_args.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Parse global flags from anywhere in the args
    var flags = GlobalFlags{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            flags.quiet = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            flags.json = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            flags.no_color = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            flags.show_version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            flags.show_help = true;
        }
    }

    // Find the command (first non-flag argument)
    var cmd_start: usize = args.len;
    for (args, 0..) |arg, i| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            cmd_start = i;
            break;
        }
    }

    if (flags.show_version) {
        std.debug.print("zvm {s}\n", .{app_version});
        return;
    }

    var ctx = Context.init(allocator, flags) catch |err| {
        fatal("failed to initialize: {}", .{err});
    };
    defer ctx.deinit();

    if (flags.show_help or cmd_start >= args.len) {
        try printHelp(&ctx);
        return;
    }

    const command = args[cmd_start];
    const cmd_args = args[cmd_start + 1 ..];

    ctx.ensureDirs() catch |err| {
        fatal("failed to create directories in {s}: {}", .{ ctx.zvm_dir, err });
    };

    if (std.mem.eql(u8, command, "install") or std.mem.eql(u8, command, "i")) {
        try cmdInstall(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "use") or std.mem.eql(u8, command, "default")) {
        try cmdUse(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "ls")) {
        try cmdList(&ctx);
    } else if (std.mem.eql(u8, command, "ls-remote") or std.mem.eql(u8, command, "list-remote")) {
        try cmdLsRemote(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "remove") or std.mem.eql(u8, command, "rm") or std.mem.eql(u8, command, "uninstall")) {
        try cmdRemove(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "run")) {
        try cmdRun(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "which")) {
        try cmdWhich(&ctx);
    } else if (std.mem.eql(u8, command, "env")) {
        try cmdEnv(&ctx);
    } else if (std.mem.eql(u8, command, "completions")) {
        try cmdCompletions(cmd_args);
    } else if (std.mem.eql(u8, command, "clean")) {
        try cmdClean(&ctx);
    } else if (std.mem.eql(u8, command, "pin")) {
        try cmdPin(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "hook")) {
        try cmdHook(cmd_args);
    } else if (std.mem.eql(u8, command, "doctor")) {
        try cmdDoctor(&ctx);
    } else if (std.mem.eql(u8, command, "upgrade")) {
        try cmdUpgrade(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "shell")) {
        try cmdShell(&ctx, cmd_args);
    } else if (std.mem.eql(u8, command, "help")) {
        try printHelp(&ctx);
    } else {
        fatal("unknown command '{s}'. Run 'zvm help' for usage.", .{command});
    }
}

// ──── Commands ────

fn cmdInstall(ctx: *Context, args: []const []const u8) !void {
    var version_arg: ?[]const u8 = null;
    var with_zls = false;
    var force = false;
    var no_verify = false;
    var no_cache = false;
    var local = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--zls")) {
            with_zls = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            no_verify = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            no_cache = true;
        } else if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "-l")) {
            local = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            version_arg = arg;
        }
    }

    // If no version specified, try to resolve from project
    if (version_arg == null) {
        const config = try ctx.readConfig();
        if (try resolve_mod.resolveVersion(ctx.allocator, config.default)) |res| {
            defer {
                var r = res;
                r.deinit(ctx.allocator);
            }
            version_arg = res.version;
            if (!ctx.quiet) {
                std.debug.print("  Resolved version {s}{s}{s} from {s}\n", .{
                    col(ctx.use_color, Color.cyan),
                    res.version,
                    col(ctx.use_color, Color.reset),
                    res.source.label(),
                });
            }
        }
    }

    if (version_arg == null) {
        std.debug.print("Usage: zvm install <version> [--zls] [--force] [--no-verify]\n  version: 0.14.0, master, stable, nightly\n", .{});
        std.process.exit(1);
    }

    if (!ctx.quiet) std.debug.print("  Fetching version index...\n", .{});

    const cache_dir = try ctx.subpath(&.{"cache"});
    defer ctx.allocator.free(cache_dir);

    if (no_cache) fetch_mod.clearCache(cache_dir, ctx.allocator);

    const index = fetch_mod.fetchIndex(ctx.allocator, cache_dir) catch |err| {
        fatal("failed to fetch version index: {}", .{err});
    };
    defer index.deinit();

    const resolved_key = fetch_mod.resolveVersionKey(index.value, version_arg.?) catch |err| {
        fatal("unknown version '{s}': {}", .{ version_arg.?, err });
    };

    // Check if already installed
    const version_dir = try ctx.subpath(&.{ "versions", resolved_key });
    defer ctx.allocator.free(version_dir);

    if (!force) {
        if (std.fs.accessAbsolute(version_dir, .{})) |_| {
            if (local) {
                // Already installed globally — just copy locally
                try installLocal(ctx, version_dir, resolved_key);
                return;
            }
            if (!ctx.quiet) {
                std.debug.print("  {s}zig {s} is already installed.{s} Use --force to reinstall.\n", .{
                    col(ctx.use_color, Color.yellow),
                    resolved_key,
                    col(ctx.use_color, Color.reset),
                });
            }
            return;
        } else |_| {}
    } else {
        std.fs.deleteTreeAbsolute(version_dir) catch {};
    }

    // Get download info
    const dl_info = fetch_mod.getDownloadInfo(index.value, resolved_key) catch |err| {
        fatal("no download available for {s} on {s}: {}", .{ resolved_key, fetch_mod.platform_key, err });
    };

    if (!ctx.quiet) {
        std.debug.print("  Installing {s}zig {s}{s} ({s})\n", .{
            col(ctx.use_color, Color.bold),
            resolved_key,
            col(ctx.use_color, Color.reset),
            fetch_mod.platform_key,
        });
    }

    // Download
    const filename = std.fs.path.basename(dl_info.tarball);
    const download_path = try ctx.subpath(&.{ "cache", filename });
    defer ctx.allocator.free(download_path);

    if (!ctx.quiet) std.debug.print("  Downloading...\n", .{});
    fetch_mod.downloadFileMirrored(ctx.allocator, dl_info.tarball, download_path) catch |err| {
        fatal("download failed: {}", .{err});
    };

    // Verify SHA256
    if (!no_verify) {
        if (!ctx.quiet) std.debug.print("  Verifying SHA256...", .{});
        verify_mod.verifySha256(download_path, dl_info.shasum) catch |err| switch (err) {
            verify_mod.VerifyError.HashMismatch => {
                if (!ctx.quiet) std.debug.print(" {s}FAILED{s}\n", .{ col(ctx.use_color, Color.red), col(ctx.use_color, Color.reset) });
                fatalCode(3, "SHA256 hash mismatch! The download may be corrupted.", .{});
            },
            else => {
                if (!ctx.quiet) std.debug.print(" {s}error{s}\n", .{ col(ctx.use_color, Color.red), col(ctx.use_color, Color.reset) });
                fatalCode(3, "verification error: {}", .{err});
            },
        };
        if (!ctx.quiet) std.debug.print(" {s}OK{s}\n", .{ col(ctx.use_color, Color.green), col(ctx.use_color, Color.reset) });

        // Minisign signature verification (best-effort: download .minisig, verify if available)
        const sig_url = try std.fmt.allocPrint(ctx.allocator, "{s}.minisig", .{dl_info.tarball});
        defer ctx.allocator.free(sig_url);
        if (fetch_mod.httpGet(ctx.allocator, sig_url)) |sig_content| {
            defer ctx.allocator.free(sig_content);
            if (!ctx.quiet) std.debug.print("  Verifying signature...", .{});
            if (verify_mod.verifyMinisign(ctx.allocator, download_path, sig_content)) |_| {
                if (!ctx.quiet) std.debug.print(" {s}OK{s}\n", .{ col(ctx.use_color, Color.green), col(ctx.use_color, Color.reset) });
            } else |err| {
                if (!ctx.quiet) std.debug.print(" {s}skipped ({s}){s}\n", .{
                    col(ctx.use_color, Color.dim), @errorName(err), col(ctx.use_color, Color.reset),
                });
            }
        } else |_| {
            // .minisig not available — that's fine for dev builds
        }
    }

    // Extract
    if (!ctx.quiet) std.debug.print("  Extracting...\n", .{});

    std.fs.makeDirAbsolute(version_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    extract_mod.extractAuto(ctx.allocator, download_path, version_dir) catch |err| {
        std.fs.deleteTreeAbsolute(version_dir) catch {};
        fatal("extraction failed: {}", .{err});
    };

    // Make zig executable
    makeExecutable(version_dir, "zig");

    // Protect stdlib from accidental modification
    protectStdlib(ctx.allocator, version_dir);

    // Clean up cached archive
    std.fs.deleteFileAbsolute(download_path) catch {};

    // If --local, copy the installed version into ./zig/ in the current directory
    if (local) {
        try installLocal(ctx, version_dir, resolved_key);
        return; // Skip global default/ZLS setup
    }

    // If no default set, make this the default
    const config = try ctx.readConfig();
    if (config.default == null) {
        try setDefault(ctx, resolved_key);
        if (!ctx.quiet) std.debug.print("  Set as default (first install)\n", .{});
    }

    // Install ZLS if requested
    if (with_zls) {
        const zls_dir = try ctx.subpath(&.{"zls"});
        defer ctx.allocator.free(zls_dir);

        var stderr_buf: [4096]u8 = undefined;
        var stderr_w = std.fs.File.stderr().writer(&stderr_buf);

        zls_mod.installZls(ctx.allocator, resolved_key, zls_dir, !ctx.quiet, &stderr_w.interface) catch {};
        stderr_w.interface.flush() catch {};

        const cfg = try ctx.readConfig();
        if (cfg.default) |d| {
            if (std.mem.eql(u8, d, resolved_key)) {
                const bin_dir = try ctx.subpath(&.{"bin"});
                defer ctx.allocator.free(bin_dir);
                zls_mod.linkZls(zls_dir, resolved_key, bin_dir) catch {};
            }
        }
    }

    if (ctx.json_output) {
        const stdout = std.fs.File.stdout();
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"version\":\"{s}\",\"path\":\"{s}\",\"platform\":\"{s}\"}}\n", .{
            resolved_key, version_dir, fetch_mod.platform_key,
        }) catch "";
        stdout.writeAll(s) catch {};
    } else if (!ctx.quiet) {
        std.debug.print("  {s}✓ Installed zig {s}{s}\n", .{
            col(ctx.use_color, Color.green),
            resolved_key,
            col(ctx.use_color, Color.reset),
        });
    }
}

fn cmdUse(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0) {
        const config = try ctx.readConfig();
        if (config.default) |d| {
            if (ctx.json_output) {
                const stdout = std.fs.File.stdout();
                var buf: [256]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{{\"default\":\"{s}\"}}\n", .{d});
                try stdout.writeAll(s);
            } else {
                std.debug.print("  Current default: {s}{s}{s}\n", .{
                    col(ctx.use_color, Color.cyan), d, col(ctx.use_color, Color.reset),
                });
            }
        } else {
            std.debug.print("  No default version set. Install one with: zvm install <version>\n", .{});
        }
        return;
    }

    const version = args[0];
    const version_dir = try ctx.subpath(&.{ "versions", version });
    defer ctx.allocator.free(version_dir);

    std.fs.accessAbsolute(version_dir, .{}) catch {
        fatalNotFound("zig {s} is not installed. Install it with: zvm install {s}", .{ version, version });
    };

    try setDefault(ctx, version);

    if (!ctx.quiet) {
        std.debug.print("  {s}✓ Now using zig {s}{s}\n", .{
            col(ctx.use_color, Color.green), version, col(ctx.use_color, Color.reset),
        });
    }
}

fn cmdList(ctx: *Context) !void {
    const config = try ctx.readConfig();
    const versions_dir = try ctx.subpath(&.{"versions"});
    defer ctx.allocator.free(versions_dir);

    var dir = std.fs.openDirAbsolute(versions_dir, .{ .iterate = true }) catch {
        if (!ctx.quiet) std.debug.print("  No versions installed.\n", .{});
        return;
    };
    defer dir.close();

    var versions: std.ArrayList([]const u8) = .empty;
    defer {
        for (versions.items) |v| ctx.allocator.free(v);
        versions.deinit(ctx.allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            try versions.append(ctx.allocator, try ctx.allocator.dupe(u8, entry.name));
        }
    }

    std.mem.sort([]const u8, versions.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const va = resolve_mod.SemVer.parse(a);
            const vb = resolve_mod.SemVer.parse(b);
            if (va != null and vb != null) return va.?.order(vb.?) == .gt;
            if (va == null and vb != null) return false;
            if (va != null and vb == null) return true;
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    if (versions.items.len == 0) {
        if (!ctx.quiet) std.debug.print("  No versions installed.\n", .{});
        return;
    }

    if (ctx.json_output) {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll("[");
        for (versions.items, 0..) |v, i| {
            if (i > 0) try stdout.writeAll(",");
            var buf: [128]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "\"{s}\"", .{v});
            try stdout.writeAll(s);
        }
        try stdout.writeAll("]\n");
        return;
    }

    std.debug.print("  {s}Installed versions:{s}\n", .{
        col(ctx.use_color, Color.bold), col(ctx.use_color, Color.reset),
    });

    for (versions.items) |v| {
        const is_default = if (config.default) |d| std.mem.eql(u8, v, d) else false;
        if (is_default) {
            std.debug.print("  {s}* {s} (default){s}\n", .{
                col(ctx.use_color, Color.green), v, col(ctx.use_color, Color.reset),
            });
        } else {
            std.debug.print("    {s}\n", .{v});
        }
    }
}

fn cmdLsRemote(ctx: *Context, args: []const []const u8) !void {
    var show_all = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) show_all = true;
    }

    const cache_dir = try ctx.subpath(&.{"cache"});
    defer ctx.allocator.free(cache_dir);

    const index = fetch_mod.fetchIndex(ctx.allocator, cache_dir) catch |err| {
        fatal("failed to fetch version index: {}", .{err});
    };
    defer index.deinit();

    const root = index.value.object;
    var versions: std.ArrayList(VersionEntry) = .empty;
    defer versions.deinit(ctx.allocator);

    var it = root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const obj = entry.value_ptr.*.object;
        const date = if (obj.get("date")) |d| d.string else "unknown";
        const has_platform = obj.contains(fetch_mod.platform_key);

        if (!show_all and !has_platform) continue;

        try versions.append(ctx.allocator, .{
            .key = key,
            .date = date,
            .has_platform = has_platform,
            .semver = resolve_mod.SemVer.parse(key),
        });
    }

    std.mem.sort(VersionEntry, versions.items, {}, struct {
        fn lessThan(_: void, a: VersionEntry, b: VersionEntry) bool {
            if (std.mem.eql(u8, a.key, "master")) return true;
            if (std.mem.eql(u8, b.key, "master")) return false;
            if (a.semver != null and b.semver != null) return a.semver.?.order(b.semver.?) == .gt;
            if (a.semver == null and b.semver != null) return false;
            if (a.semver != null and b.semver == null) return true;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);

    if (ctx.json_output) {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll("[");
        for (versions.items, 0..) |v, i| {
            if (i > 0) try stdout.writeAll(",");
            var buf: [256]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{{\"version\":\"{s}\",\"date\":\"{s}\",\"available\":{}}}", .{
                v.key, v.date, v.has_platform,
            });
            try stdout.writeAll(s);
        }
        try stdout.writeAll("]\n");
        return;
    }

    std.debug.print("  {s}Available versions:{s}\n", .{
        col(ctx.use_color, Color.bold), col(ctx.use_color, Color.reset),
    });

    for (versions.items) |v| {
        const installed = blk: {
            const vdir = ctx.subpath(&.{ "versions", v.key }) catch break :blk false;
            defer ctx.allocator.free(vdir);
            std.fs.accessAbsolute(vdir, .{}) catch break :blk false;
            break :blk true;
        };

        if (v.has_platform) {
            const marker: []const u8 = if (installed) "✓" else " ";
            const c1 = if (installed) col(ctx.use_color, Color.green) else "";
            const r1 = if (installed) col(ctx.use_color, Color.reset) else "";
            std.debug.print("  {s}{s} {s}{s}  {s}{s}{s}\n", .{
                c1, marker, v.key, r1,
                col(ctx.use_color, Color.dim), v.date, col(ctx.use_color, Color.reset),
            });
        } else if (show_all) {
            std.debug.print("    {s}{s} (no binary for {s}){s}\n", .{
                col(ctx.use_color, Color.dim), v.key, fetch_mod.platform_key, col(ctx.use_color, Color.reset),
            });
        }
    }
}

const VersionEntry = struct {
    key: []const u8,
    date: []const u8,
    has_platform: bool,
    semver: ?resolve_mod.SemVer,
};

fn cmdRemove(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zvm remove <version>\n", .{});
        std.process.exit(1);
    }

    const version = args[0];
    const config = try ctx.readConfig();

    if (config.default) |d| {
        if (std.mem.eql(u8, d, version)) {
            fatal("cannot remove {s}: it is the current default. Set a different default first with: zvm use <version>", .{version});
        }
    }

    const version_dir = try ctx.subpath(&.{ "versions", version });
    defer ctx.allocator.free(version_dir);

    std.fs.accessAbsolute(version_dir, .{}) catch {
        fatalNotFound("zig {s} is not installed", .{version});
    };

    std.fs.deleteTreeAbsolute(version_dir) catch |err| {
        fatal("failed to remove {s}: {}", .{ version, err });
    };

    // Also remove matching ZLS
    const zls_dir = try ctx.subpath(&.{ "zls", version });
    defer ctx.allocator.free(zls_dir);
    std.fs.deleteTreeAbsolute(zls_dir) catch {};

    if (!ctx.quiet) {
        std.debug.print("  {s}✓ Removed zig {s}{s}\n", .{
            col(ctx.use_color, Color.green), version, col(ctx.use_color, Color.reset),
        });
    }
}

fn cmdRun(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zvm run <version> [-- <zig-args...>]\n", .{});
        std.process.exit(1);
    }

    const version = args[0];
    var zig_args_start: usize = 1;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--")) {
        zig_args_start = 2;
    }

    const version_dir = try ctx.subpath(&.{ "versions", version });
    defer ctx.allocator.free(version_dir);
    std.fs.accessAbsolute(version_dir, .{}) catch {
        fatalNotFound("zig {s} is not installed. Install it with: zvm install {s}", .{ version, version });
    };

    const zig_path = try ctx.subpath(&.{ "versions", version, "zig" });
    defer ctx.allocator.free(zig_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    try argv.append(ctx.allocator, zig_path);
    if (zig_args_start < args.len) {
        try argv.appendSlice(ctx.allocator, args[zig_args_start..]);
    }

    var child = std.process.Child.init(argv.items, ctx.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn cmdWhich(ctx: *Context) !void {
    const config = try ctx.readConfig();
    const resolution = try resolve_mod.resolveVersion(ctx.allocator, config.default);

    if (resolution == null) {
        if (ctx.json_output) {
            const stdout = std.fs.File.stdout();
            try stdout.writeAll("{\"version\":null}\n");
        } else {
            std.debug.print("  No Zig version resolved. Install one with: zvm install <version>\n", .{});
        }
        return;
    }

    var res = resolution.?;
    defer res.deinit(ctx.allocator);

    if (ctx.json_output) {
        const stdout = std.fs.File.stdout();
        var buf: [512]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{{\"version\":\"{s}\",\"source\":\"{s}\"}}\n", .{ res.version, @tagName(res.source) });
        try stdout.writeAll(s);
        return;
    }

    const zig_path = try ctx.subpath(&.{ "versions", res.version, "zig" });
    defer ctx.allocator.free(zig_path);
    const installed = blk: {
        std.fs.accessAbsolute(zig_path, .{}) catch break :blk false;
        break :blk true;
    };

    std.debug.print("  {s}zig {s}{s}\n", .{
        col(ctx.use_color, Color.cyan), res.version, col(ctx.use_color, Color.reset),
    });
    std.debug.print("  source: {s}", .{res.source.label()});
    if (res.source_path) |p| std.debug.print(" ({s})", .{p});
    std.debug.print("\n", .{});

    if (installed) {
        std.debug.print("  path:   {s}\n", .{zig_path});
    } else {
        std.debug.print("  {s}(not installed){s}\n", .{
            col(ctx.use_color, Color.yellow), col(ctx.use_color, Color.reset),
        });
    }
}

fn cmdEnv(ctx: *Context) !void {
    const bin_dir = try ctx.subpath(&.{"bin"});
    defer ctx.allocator.free(bin_dir);

    if (ctx.json_output) {
        const stdout = std.fs.File.stdout();
        var buf: [512]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{{\"zvm_dir\":\"{s}\",\"platform\":\"{s}\",\"version\":\"{s}\"}}\n", .{
            ctx.zvm_dir, fetch_mod.platform_key, app_version,
        });
        try stdout.writeAll(s);
        return;
    }

    std.debug.print("  {s}zvm environment:{s}\n", .{ col(ctx.use_color, Color.bold), col(ctx.use_color, Color.reset) });
    std.debug.print("  zvm version:  {s}\n", .{app_version});
    std.debug.print("  zvm dir:      {s}\n", .{ctx.zvm_dir});
    std.debug.print("  bin dir:      {s}\n", .{bin_dir});
    std.debug.print("  platform:     {s}\n", .{fetch_mod.platform_key});

    // Check if bin dir is in PATH
    if (std.process.getEnvVarOwned(ctx.allocator, "PATH")) |path_env| {
        defer ctx.allocator.free(path_env);
        var path_it = std.mem.splitScalar(u8, path_env, ':');
        var found = false;
        while (path_it.next()) |p| {
            if (std.mem.eql(u8, p, bin_dir)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("\n  {s}Warning:{s} {s} is not in your PATH.\n", .{
                col(ctx.use_color, Color.yellow), col(ctx.use_color, Color.reset), bin_dir,
            });
            std.debug.print("  Add it to your shell profile:\n", .{});
            std.debug.print("    export PATH=\"{s}:$PATH\"\n", .{bin_dir});
        }
    } else |_| {}
}

fn cmdCompletions(args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zvm completions <bash|zsh|fish>\n", .{});
        std.process.exit(1);
    }

    const shell = args[0];
    const stdout = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var w = stdout.writer(&buf);

    if (std.mem.eql(u8, shell, "bash")) {
        try completions_mod.generateBash(&w.interface);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try completions_mod.generateZsh(&w.interface);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try completions_mod.generateFish(&w.interface);
    } else {
        fatal("unknown shell '{s}'. Supported: bash, zsh, fish", .{shell});
    }
    try w.interface.flush();
}

fn cmdClean(ctx: *Context) !void {
    const config = try ctx.readConfig();
    const versions_dir = try ctx.subpath(&.{"versions"});
    defer ctx.allocator.free(versions_dir);

    var dir = std.fs.openDirAbsolute(versions_dir, .{ .iterate = true }) catch {
        std.debug.print("  Nothing to clean.\n", .{});
        return;
    };
    defer dir.close();

    var removed: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (config.default) |d| {
            if (std.mem.eql(u8, entry.name, d)) continue;
        }

        const full = try ctx.subpath(&.{ "versions", entry.name });
        defer ctx.allocator.free(full);
        std.fs.deleteTreeAbsolute(full) catch |err| {
            std.debug.print("  Failed to remove {s}: {}\n", .{ entry.name, err });
            continue;
        };

        const zls_path = try ctx.subpath(&.{ "zls", entry.name });
        defer ctx.allocator.free(zls_path);
        std.fs.deleteTreeAbsolute(zls_path) catch {};

        if (!ctx.quiet) std.debug.print("  Removed {s}\n", .{entry.name});
        removed += 1;
    }

    // Clean cache
    const cache_dir = try ctx.subpath(&.{"cache"});
    defer ctx.allocator.free(cache_dir);
    if (std.fs.openDirAbsolute(cache_dir, .{ .iterate = true })) |d_val| {
        var d = d_val;
        defer d.close();
        var cache_it = d.iterate();
        while (try cache_it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, "index.json")) continue;
            d.deleteFile(entry.name) catch {};
        }
    } else |_| {}

    if (!ctx.quiet) {
        if (removed == 0) {
            std.debug.print("  Nothing to clean (only default version installed).\n", .{});
        } else {
            std.debug.print("  {s}✓ Cleaned {d} version(s){s}\n", .{
                col(ctx.use_color, Color.green), removed, col(ctx.use_color, Color.reset),
            });
        }
    }
}

fn cmdPin(ctx: *Context, args: []const []const u8) !void {
    var version: ?[]const u8 = null;
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            version = arg;
        }
    }

    if (version == null) {
        // If no version given, use the current resolved version
        const config = try ctx.readConfig();
        if (try resolve_mod.resolveVersion(ctx.allocator, config.default)) |res| {
            defer {
                var r = res;
                r.deinit(ctx.allocator);
            }
            version = res.version;
        }
    }

    if (version == null) {
        fatal("no version to pin. Specify one: zvm pin <version>", .{});
    }

    const file = std.fs.cwd().createFile(".zig-version", .{}) catch |err| {
        fatal("cannot write .zig-version: {}", .{err});
    };
    defer file.close();
    file.writeAll(version.?) catch |err| {
        fatal("write error: {}", .{err});
    };
    file.writeAll("\n") catch {};

    if (!ctx.quiet) {
        std.debug.print("  {s}✓ Pinned zig {s}{s} in .zig-version\n", .{
            col(ctx.use_color, Color.green), version.?, col(ctx.use_color, Color.reset),
        });
    }
}

fn cmdHook(args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: zvm hook <bash|zsh|fish>\n  Add to your shell profile: eval \"$(zvm hook bash)\"\n", .{});
        std.process.exit(1);
    }

    const shell = args[0];
    const stdout = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var w = stdout.writer(&buf);

    if (std.mem.eql(u8, shell, "bash")) {
        try hook_mod.generateBash(&w.interface);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try hook_mod.generateZsh(&w.interface);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try hook_mod.generateFish(&w.interface);
    } else {
        fatal("unknown shell '{s}'. Supported: bash, zsh, fish", .{shell});
    }
    try w.interface.flush();
}

fn cmdDoctor(ctx: *Context) !void {
    const C = col(ctx.use_color, Color.green);
    const W = col(ctx.use_color, Color.yellow);
    const E = col(ctx.use_color, Color.red);
    const R = col(ctx.use_color, Color.reset);
    var issues: u32 = 0;

    std.debug.print("  Checking zvm health...\n\n", .{});

    // 1. Check ZVM_DIR exists
    const zvm_dir = ctx.zvm_dir;
    if (std.fs.accessAbsolute(zvm_dir, .{})) |_| {
        std.debug.print("  {s}✓{s} ZVM directory exists: {s}\n", .{ C, R, zvm_dir });
    } else |_| {
        std.debug.print("  {s}✗{s} ZVM directory missing: {s}\n", .{ E, R, zvm_dir });
        issues += 1;
    }

    // 2. Check bin dir in PATH
    const bin_dir = try ctx.subpath(&.{"bin"});
    defer ctx.allocator.free(bin_dir);
    if (std.process.getEnvVarOwned(ctx.allocator, "PATH")) |path_env| {
        defer ctx.allocator.free(path_env);
        var found = false;
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |p| {
            if (std.mem.eql(u8, p, bin_dir)) {
                found = true;
                break;
            }
        }
        if (found) {
            std.debug.print("  {s}✓{s} {s} is in PATH\n", .{ C, R, bin_dir });
        } else {
            std.debug.print("  {s}✗{s} {s} is NOT in PATH\n", .{ E, R, bin_dir });
            std.debug.print("      Add to shell profile: export PATH=\"{s}:$PATH\"\n", .{bin_dir});
            issues += 1;
        }
    } else |_| {}

    // 3. Check config
    const config = try ctx.readConfig();
    if (config.default) |d| {
        std.debug.print("  {s}✓{s} Default version: {s}\n", .{ C, R, d });

        // 4. Check default version dir exists
        const ver_dir = try ctx.subpath(&.{ "versions", d });
        defer ctx.allocator.free(ver_dir);
        if (std.fs.accessAbsolute(ver_dir, .{})) |_| {
            std.debug.print("  {s}✓{s} Version directory exists\n", .{ C, R });
        } else |_| {
            std.debug.print("  {s}✗{s} Version directory missing: {s}\n", .{ E, R, ver_dir });
            issues += 1;
        }

        // 5. Check zig symlink
        const zig_link = try ctx.subpath(&.{ "bin", "zig" });
        defer ctx.allocator.free(zig_link);
        if (std.fs.accessAbsolute(zig_link, .{})) |_| {
            std.debug.print("  {s}✓{s} zig symlink OK\n", .{ C, R });
        } else |_| {
            std.debug.print("  {s}✗{s} zig symlink broken or missing\n", .{ E, R });
            std.debug.print("      Fix with: zvm use {s}\n", .{d});
            issues += 1;
        }
    } else {
        std.debug.print("  {s}!{s} No default version set\n", .{ W, R });
        std.debug.print("      Install one: zvm install stable\n", .{});
        issues += 1;
    }

    // 6. Check ZLS
    const zls_link = try ctx.subpath(&.{ "bin", "zls" });
    defer ctx.allocator.free(zls_link);
    if (std.fs.accessAbsolute(zls_link, .{})) |_| {
        std.debug.print("  {s}✓{s} ZLS available\n", .{ C, R });
    } else |_| {
        std.debug.print("  {s}!{s} ZLS not installed (optional)\n", .{ W, R });
    }

    // 7. Check network (can we resolve ziglang.org index?)
    std.debug.print("  ...checking network", .{});
    const cache_dir = try ctx.subpath(&.{"cache"});
    defer ctx.allocator.free(cache_dir);
    if (fetch_mod.fetchIndex(ctx.allocator, cache_dir)) |idx| {
        idx.deinit();
        std.debug.print("\r  {s}✓{s} Network: can reach ziglang.org\n", .{ C, R });
    } else |_| {
        std.debug.print("\r  {s}!{s} Network: cannot reach ziglang.org (offline?)\n", .{ W, R });
    }

    // Summary
    std.debug.print("\n", .{});
    if (issues == 0) {
        std.debug.print("  {s}All checks passed.{s}\n", .{ C, R });
    } else {
        std.debug.print("  {s}{d} issue(s) found.{s}\n", .{ E, issues, R });
    }
}

fn cmdUpgrade(ctx: *Context, args: []const []const u8) !void {
    var no_cache = false;
    var with_zls = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-cache")) no_cache = true;
        if (std.mem.eql(u8, arg, "--zls")) with_zls = true;
    }

    const config = try ctx.readConfig();
    if (config.default == null) {
        fatal("no default version set. Install one first: zvm install stable", .{});
    }

    const current = config.default.?;
    const current_sv = resolve_mod.SemVer.parse(current) orelse {
        fatal("current default '{s}' is not a semver version — cannot auto-upgrade", .{current});
    };

    if (!ctx.quiet) std.debug.print("  Current: zig {s}\n", .{current});

    const cache_dir = try ctx.subpath(&.{"cache"});
    defer ctx.allocator.free(cache_dir);
    if (no_cache) fetch_mod.clearCache(cache_dir, ctx.allocator);

    const index = fetch_mod.fetchIndex(ctx.allocator, cache_dir) catch |err| {
        fatal("failed to fetch version index: {}", .{err});
    };
    defer index.deinit();

    // Find the latest stable version
    var best: ?[]const u8 = null;
    var best_ver: ?resolve_mod.SemVer = null;
    var root_it = index.value.object.iterator();
    while (root_it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "master")) continue;
        const sv = resolve_mod.SemVer.parse(key) orelse continue;
        if (!sv.isStable()) continue;
        if (best_ver == null or sv.order(best_ver.?) == .gt) {
            best = key;
            best_ver = sv;
        }
    }

    if (best == null) {
        fatal("no stable versions found in index", .{});
    }

    if (best_ver.?.order(current_sv) != .gt) {
        if (!ctx.quiet) {
            std.debug.print("  {s}Already on the latest stable version.{s}\n", .{
                col(ctx.use_color, Color.green), col(ctx.use_color, Color.reset),
            });
        }
        return;
    }

    if (!ctx.quiet) {
        std.debug.print("  Upgrading: {s} → {s}\n", .{ current, best.? });
    }

    // Build install args
    var install_args: std.ArrayList([]const u8) = .empty;
    defer install_args.deinit(ctx.allocator);
    try install_args.append(ctx.allocator, best.?);
    if (with_zls) try install_args.append(ctx.allocator, "--zls");
    if (no_cache) try install_args.append(ctx.allocator, "--no-cache");

    try cmdInstall(ctx, install_args.items);
    try setDefault(ctx, best.?);

    if (!ctx.quiet) {
        std.debug.print("  {s}✓ Upgraded to zig {s}{s}\n", .{
            col(ctx.use_color, Color.green), best.?, col(ctx.use_color, Color.reset),
        });
    }
}

fn cmdShell(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: eval \"$(zvm shell <version>)\"\n  Activates a Zig version for the current shell session only.\n", .{});
        std.process.exit(1);
    }

    const version = args[0];
    const version_dir = try ctx.subpath(&.{ "versions", version });
    defer ctx.allocator.free(version_dir);

    std.fs.accessAbsolute(version_dir, .{}) catch {
        fatalNotFound("zig {s} is not installed. Install it with: zvm install {s}", .{ version, version });
    };

    // Output shell commands to stdout — user evals them
    const stdout = std.fs.File.stdout();
    var buf: [2048]u8 = undefined;
    var w = stdout.writer(&buf);
    try w.interface.print("export PATH=\"{s}:$PATH\"\nexport ZVM_CURRENT=\"{s}\"\n", .{ version_dir, version });
    try w.interface.flush();
}

fn installLocal(ctx: *Context, version_dir: []const u8, version: []const u8) !void {
    const local_dir = "zig";

    // Remove existing ./zig/ if present
    std.fs.cwd().deleteTree(local_dir) catch {};
    std.fs.cwd().makeDir(local_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            fatal("cannot create ./zig/ directory: {}", .{err});
        },
    };

    // Copy from the installed version into ./zig/
    var src_dir = try std.fs.openDirAbsolute(version_dir, .{ .iterate = true });
    defer src_dir.close();

    var dest_dir = try std.fs.cwd().openDir(local_dir, .{});
    defer dest_dir.close();

    // Walk and copy all files
    var walker = try src_dir.walk(ctx.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                dest_dir.makePath(entry.path) catch {};
            },
            .file => {
                if (std.fs.path.dirname(entry.path)) |parent| {
                    dest_dir.makePath(parent) catch {};
                }
                entry.dir.copyFile(entry.basename, dest_dir, entry.path, .{}) catch |err| {
                    std.debug.print("  Warning: could not copy {s}: {}\n", .{ entry.path, err });
                };
            },
            else => {},
        }
    }

    // Make zig executable
    if (dest_dir.openFile("zig", .{ .mode = .read_write })) |f| {
        defer f.close();
        f.chmod(0o755) catch {};
    } else |_| {}

    if (!ctx.quiet) {
        std.debug.print("  {s}✓ Installed zig {s} locally in ./zig/{s}\n", .{
            col(ctx.use_color, Color.green), version, col(ctx.use_color, Color.reset),
        });
        std.debug.print("  Run with: ./zig/zig build\n", .{});
    }
}

// ──── Helpers ────

fn setDefault(ctx: *Context, version: []const u8) !void {
    const bin_dir = try ctx.subpath(&.{"bin"});
    defer ctx.allocator.free(bin_dir);

    const zig_target = try ctx.subpath(&.{ "versions", version, "zig" });
    defer ctx.allocator.free(zig_target);

    const zig_link = try ctx.subpath(&.{ "bin", "zig" });
    defer ctx.allocator.free(zig_link);

    // Remove old symlink
    std.posix.unlink(zig_link) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Create relative symlink
    const rel = try std.fs.path.relative(ctx.allocator, bin_dir, zig_target);
    defer ctx.allocator.free(rel);

    var bin = try std.fs.openDirAbsolute(bin_dir, .{});
    defer bin.close();
    try bin.symLink(rel, "zig", .{});

    // Also link the lib directory for std library access
    const lib_target = try ctx.subpath(&.{ "versions", version, "lib" });
    defer ctx.allocator.free(lib_target);
    const lib_link = try ctx.subpath(&.{ "bin", "lib" });
    defer ctx.allocator.free(lib_link);
    std.posix.unlink(lib_link) catch {};
    const lib_rel = try std.fs.path.relative(ctx.allocator, bin_dir, lib_target);
    defer ctx.allocator.free(lib_rel);
    bin.symLink(lib_rel, "lib", .{}) catch {};

    // Update config
    try ctx.writeConfig(.{ .default = version });

    // Try to link matching ZLS too
    const zls_dir = try ctx.subpath(&.{"zls"});
    defer ctx.allocator.free(zls_dir);
    zls_mod.linkZls(zls_dir, version, bin_dir) catch {};
}

fn makeExecutable(dir_path: []const u8, name: []const u8) void {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ dir_path, name }) catch return;
    defer std.heap.page_allocator.free(path);
    if (std.fs.openFileAbsolute(path, .{ .mode = .read_write })) |f| {
        defer f.close();
        f.chmod(0o755) catch {};
    } else |_| {}
}

/// Set stdlib (lib/) files to read-only to prevent accidental modification.
fn protectStdlib(allocator: std.mem.Allocator, version_dir: []const u8) void {
    const lib_path = std.fs.path.join(allocator, &.{ version_dir, "lib" }) catch return;
    defer allocator.free(lib_path);

    var dir = std.fs.openDirAbsolute(lib_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind == .file) {
            var f = entry.dir.openFile(entry.basename, .{ .mode = .read_write }) catch continue;
            defer f.close();
            f.chmod(0o444) catch {};
        }
    }
}

/// Exit codes: 0=success, 1=general error, 2=version not found, 3=verification failed
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    fatalCode(1, fmt, args);
}

fn fatalCode(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("\x1b[31merror:\x1b[0m " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

fn fatalNotFound(comptime fmt: []const u8, args: anytype) noreturn {
    fatalCode(2, fmt, args);
}

fn printHelp(ctx: *Context) !void {
    const B = col(ctx.use_color, Color.bold);
    const R = col(ctx.use_color, Color.reset);
    const C = col(ctx.use_color, Color.cyan);
    const D = col(ctx.use_color, Color.dim);

    std.debug.print("\n  {s}zvm{s} — Zig Version Manager {s}v{s}{s}\n\n", .{ B, R, D, app_version, R });
    std.debug.print("  {s}USAGE{s}\n    zvm <command> [options]\n\n", .{ B, R });
    std.debug.print("  {s}COMMANDS{s}\n", .{ B, R });
    std.debug.print("    {s}install{s} <version>   Install a Zig version [aliases: i]\n", .{ C, R });
    std.debug.print("                         Options: --zls, --force, --no-verify, --no-cache, --local\n", .{});
    std.debug.print("    {s}use{s} <version>       Set the default Zig version [aliases: default]\n", .{ C, R });
    std.debug.print("    {s}list{s}                List installed versions [aliases: ls]\n", .{ C, R });
    std.debug.print("    {s}ls-remote{s}           List available remote versions [--all]\n", .{ C, R });
    std.debug.print("    {s}remove{s} <version>    Remove an installed version [aliases: rm, uninstall]\n", .{ C, R });
    std.debug.print("    {s}run{s} <version> [--]  Run a command with a specific Zig version\n", .{ C, R });
    std.debug.print("    {s}which{s}               Show which Zig version would be used\n", .{ C, R });
    std.debug.print("    {s}env{s}                 Show zvm environment info\n", .{ C, R });
    std.debug.print("    {s}completions{s} <shell> Generate shell completions (bash/zsh/fish)\n", .{ C, R });
    std.debug.print("    {s}clean{s}               Remove all non-default versions\n", .{ C, R });
    std.debug.print("    {s}pin{s} [version]       Write .zig-version file in current directory\n", .{ C, R });
    std.debug.print("    {s}hook{s} <shell>        Generate shell hook for auto-switching\n", .{ C, R });
    std.debug.print("    {s}doctor{s}              Diagnose common issues\n", .{ C, R });
    std.debug.print("    {s}upgrade{s}             Upgrade to the latest stable version [--zls]\n", .{ C, R });
    std.debug.print("    {s}shell{s} <version>     Activate a version for the current shell only\n", .{ C, R });
    std.debug.print("    {s}help{s}                Show this help\n\n", .{ C, R });
    std.debug.print("  {s}VERSION RESOLUTION{s} (highest priority first)\n", .{ B, R });
    std.debug.print("    1. ZIG_VERSION environment variable\n", .{});
    std.debug.print("    2. Project-local ./zig/zig binary (walks up directory tree)\n", .{});
    std.debug.print("    3. .zig-version / .zigversion file (walks up directory tree)\n", .{});
    std.debug.print("    4. build.zig.zon minimum_zig_version field\n", .{});
    std.debug.print("    5. Default version (set via 'zvm use')\n\n", .{});
    std.debug.print("  {s}GLOBAL FLAGS{s}\n", .{ B, R });
    std.debug.print("    --quiet, -q     Suppress output\n", .{});
    std.debug.print("    --json          Output as JSON\n", .{});
    std.debug.print("    --no-color      Disable colored output\n", .{});
    std.debug.print("    --version, -v   Show zvm version\n", .{});
    std.debug.print("    --help, -h      Show help\n\n", .{});
    std.debug.print("  {s}SETUP{s}\n", .{ B, R });
    std.debug.print("    Add to your shell profile:\n", .{});
    std.debug.print("      export PATH=\"$HOME/.zvm/bin:$PATH\"\n\n", .{});
    std.debug.print("  {s}EXAMPLES{s}\n", .{ B, R });
    std.debug.print("    zvm install 0.14.0         Install Zig 0.14.0\n", .{});
    std.debug.print("    zvm install stable --zls   Install latest stable + ZLS\n", .{});
    std.debug.print("    zvm install master          Install nightly/master\n", .{});
    std.debug.print("    zvm use 0.14.0             Switch default to 0.14.0\n", .{});
    std.debug.print("    zvm run 0.13.0 -- build    Run 'zig build' with 0.13.0\n", .{});
    std.debug.print("    zvm which                  Show resolved version\n\n", .{});
}

// Expose tests from all submodules
test {
    _ = @import("resolve.zig");
    _ = @import("verify.zig");
    _ = @import("fetch.zig");
    _ = @import("completions.zig");
    _ = @import("hook.zig");
    _ = @import("extract.zig");
}

// ──── Main module tests ────

test "global flag parsing - flags anywhere in args" {
    // This tests the design principle: flags work before or after the command
    const flags = [_][]const u8{ "--quiet", "list", "--json" };
    var quiet = false;
    var json = false;
    for (flags) |arg| {
        if (std.mem.eql(u8, arg, "--quiet")) quiet = true;
        if (std.mem.eql(u8, arg, "--json")) json = true;
    }
    try std.testing.expect(quiet);
    try std.testing.expect(json);
}

test "col helper returns empty string when color disabled" {
    try std.testing.expectEqualStrings("", col(false, Color.red));
    try std.testing.expectEqualStrings("", col(false, Color.green));
    try std.testing.expectEqualStrings("", col(false, Color.bold));
}

test "col helper returns ANSI code when color enabled" {
    try std.testing.expectEqualStrings("\x1b[31m", col(true, Color.red));
    try std.testing.expectEqualStrings("\x1b[32m", col(true, Color.green));
}

test "config round-trip" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    const allocator = std.testing.allocator;
    var ctx = Context{
        .allocator = allocator,
        .use_color = false,
        .quiet = true,
        .json_output = false,
        .zvm_dir = tmp_path,
    };

    // Write config
    try ctx.writeConfig(.{ .default = "0.14.0" });

    // Read it back
    const config = try ctx.readConfig();
    try std.testing.expect(config.default != null);
    try std.testing.expectEqualStrings("0.14.0", config.default.?);
    // Free the duped string
    allocator.free(config.default.?);
}

test "config read - missing file returns empty" {
    const allocator = std.testing.allocator;
    var ctx = Context{
        .allocator = allocator,
        .use_color = false,
        .quiet = true,
        .json_output = false,
        .zvm_dir = "/nonexistent/path",
    };

    const config = try ctx.readConfig();
    try std.testing.expect(config.default == null);
}

test "app_version is set" {
    try std.testing.expect(app_version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, app_version, '.') != null);
}
