//! Tiny proxy launcher for `zig` (and optionally `zls`).
//! Resolves the correct version via the resolution chain, then execs into it.
//! Supports `+version` override syntax: `zig +0.13.0 build`
//!
//! Install to ~/.zvm/bin/zig  (replaces the symlink approach)

const std = @import("std");
const resolve_mod = @import("resolve.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var raw_args = try std.process.argsWithAllocator(allocator);
    defer raw_args.deinit();

    const argv0 = raw_args.next() orelse "zig";

    // Determine which binary we're proxying (zig or zls)
    const binary_name = std.fs.path.basename(argv0);
    const is_zls = std.mem.eql(u8, binary_name, "zls");

    // Collect remaining args, looking for +version override
    var override_version: ?[]const u8 = null;
    var pass_args: std.ArrayList([]const u8) = .empty;
    defer pass_args.deinit(allocator);

    while (raw_args.next()) |arg| {
        if (override_version == null and arg.len > 1 and arg[0] == '+') {
            override_version = arg[1..];
        } else {
            try pass_args.append(allocator, arg);
        }
    }

    // Resolve version
    const version: []const u8 = override_version orelse blk: {
        const default_ver = readDefault(allocator);
        if (resolve_mod.resolveVersion(allocator, default_ver)) |maybe_res| {
            if (maybe_res) |res| {
                break :blk res.version;
            }
        } else |_| {}
        if (default_ver) |d| break :blk d;
        std.debug.print("zvm: no Zig version configured. Run: zvm install stable\n", .{});
        std.process.exit(1);
    };

    // Build path to real binary
    const zvm_dir = getZvmDir(allocator);
    const sub_dir = if (is_zls) "zls" else "versions";
    const real_path = std.fs.path.join(allocator, &.{ zvm_dir, sub_dir, version, binary_name }) catch {
        std.debug.print("zvm: internal error building path\n", .{});
        std.process.exit(1);
    };

    // Verify it exists
    std.fs.accessAbsolute(real_path, .{}) catch {
        std.debug.print("zvm: {s} {s} is not installed. Run: zvm install {s}", .{ binary_name, version, version });
        if (is_zls) std.debug.print(" --zls", .{});
        std.debug.print("\n", .{});
        std.process.exit(1);
    };

    // Build exec argv
    var exec_argv: std.ArrayList([]const u8) = .empty;
    try exec_argv.append(allocator, real_path);
    try exec_argv.appendSlice(allocator, pass_args.items);

    // Exec
    var child = std.process.Child.init(exec_argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn getZvmDir(allocator: std.mem.Allocator) []const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZVM_DIR")) |d| return d else |_| {}
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return "/tmp/.zvm";
    return std.fs.path.join(allocator, &.{ home, ".zvm" }) catch "/tmp/.zvm";
}

fn readDefault(allocator: std.mem.Allocator) ?[]const u8 {
    const zvm_dir = getZvmDir(allocator);
    const path = std.fs.path.join(allocator, &.{ zvm_dir, "config.json" }) catch return null;
    const content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return null;
    // Simple parse - find "default":"<value>"
    if (std.mem.indexOf(u8, content, "\"default\"")) |idx| {
        const after = content[idx + "\"default\"".len ..];
        if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
            const start = q1 + 1;
            if (std.mem.indexOfScalarPos(u8, after, start, '"')) |q2| {
                return after[start..q2];
            }
        }
    }
    return null;
}
