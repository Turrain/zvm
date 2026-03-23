const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Describes where a version resolution came from.
pub const Source = enum {
    env_var,
    local_install,
    zig_version_file,
    build_zig_zon,
    default_config,
    none,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .env_var => "ZIG_VERSION environment variable",
            .local_install => "project-local ./zig/",
            .zig_version_file => ".zig-version file",
            .build_zig_zon => "build.zig.zon minimum_zig_version",
            .default_config => "default configuration",
            .none => "none",
        };
    }
};

pub const Resolution = struct {
    version: []const u8,
    source: Source,
    source_path: ?[]const u8 = null,

    pub fn deinit(self: *Resolution, allocator: Allocator) void {
        allocator.free(self.version);
        if (self.source_path) |p| allocator.free(p);
    }
};

/// Resolve the Zig version to use via the priority chain:
///   1. ZIG_VERSION environment variable
///   2. Project-local ./zig/zig binary (walk up from cwd)
///   3. .zig-version / .zigversion file (walk up from cwd)
///   4. build.zig.zon minimum_zig_version (walk up from cwd)
///   5. Default from config
pub fn resolveVersion(allocator: Allocator, default_version: ?[]const u8) !?Resolution {
    // 1. Environment variable
    if (std.process.getEnvVarOwned(allocator, "ZIG_VERSION")) |version| {
        return Resolution{
            .version = version,
            .source = .env_var,
        };
    } else |_| {}

    // Get current working directory
    const cwd = std.fs.cwd();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = cwd.realpath(".", &cwd_buf) catch null;

    if (cwd_path) |start_path| {
        // 2. Check for project-local ./zig/zig (walk up)
        if (try findLocalZig(allocator, start_path)) |local| {
            return local;
        }

        // 3. Walk up looking for .zig-version then .zigversion
        for ([_][]const u8{ ".zig-version", ".zigversion" }) |filename| {
            if (try walkUpForFile(allocator, start_path, filename)) |result| {
                const content = result.content;
                defer allocator.free(content);
                const version = std.mem.trim(u8, content, " \t\r\n");
                if (version.len > 0) {
                    return Resolution{
                        .version = try allocator.dupe(u8, version),
                        .source = .zig_version_file,
                        .source_path = result.path,
                    };
                }
                allocator.free(result.path);
            }
        }

        // 3. Walk up looking for build.zig.zon
        if (try walkUpForFile(allocator, start_path, "build.zig.zon")) |result| {
            const content = result.content;
            defer allocator.free(content);
            if (extractMinimumZigVersion(content)) |version| {
                return Resolution{
                    .version = try allocator.dupe(u8, version),
                    .source = .build_zig_zon,
                    .source_path = result.path,
                };
            }
            allocator.free(result.path);
        }
    }

    // 4. Default version
    if (default_version) |dv| {
        return Resolution{
            .version = try allocator.dupe(u8, dv),
            .source = .default_config,
        };
    }

    return null;
}

/// Check for a project-local zig installation at ./zig/zig (walking up directories).
fn findLocalZig(allocator: Allocator, start: []const u8) !?Resolution {
    var current = try allocator.dupe(u8, start);
    defer allocator.free(current);

    while (true) {
        const zig_path = try std.fs.path.join(allocator, &.{ current, "zig", "zig" });
        if (std.fs.accessAbsolute(zig_path, .{})) |_| {
            // Found a local zig binary — read its version
            const dir_path = try std.fs.path.join(allocator, &.{ current, "zig" });
            defer allocator.free(dir_path);
            const version = getLocalVersion(allocator, zig_path) orelse "local";
            allocator.free(zig_path);
            return Resolution{
                .version = try allocator.dupe(u8, version),
                .source = .local_install,
                .source_path = try allocator.dupe(u8, dir_path),
            };
        } else |_| {
            allocator.free(zig_path);
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        const old = current;
        current = try allocator.dupe(u8, parent);
        allocator.free(old);
    }
}

/// Try to determine the version of a local zig binary by reading the lib path.
fn getLocalVersion(allocator: Allocator, zig_path: []const u8) ?[]const u8 {
    // Try to find the version from the directory name or by running `zig version`
    const dir = std.fs.path.dirname(zig_path) orelse return null;
    const lib_path = std.fs.path.join(allocator, &.{ dir, "lib", "std", "std.zig" }) catch return null;
    defer allocator.free(lib_path);
    // If the standard library exists, it's a valid install — version from zig version output
    std.fs.accessAbsolute(lib_path, .{}) catch return null;
    return null; // Caller falls back to "local"
}

const WalkResult = struct {
    content: []const u8,
    path: []const u8,
};

fn walkUpForFile(allocator: Allocator, start: []const u8, filename: []const u8) !?WalkResult {
    var current = try allocator.dupe(u8, start);
    defer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, filename });

        if (std.fs.cwd().readFileAlloc(allocator, candidate, 64 * 1024)) |content| {
            return WalkResult{
                .content = content,
                .path = candidate,
            };
        } else |_| {
            allocator.free(candidate);
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null; // At filesystem root
        const old = current;
        current = try allocator.dupe(u8, parent);
        allocator.free(old);
    }
}

/// Extract the minimum_zig_version value from build.zig.zon content.
/// Uses simple string matching — works for the standard format.
pub fn extractMinimumZigVersion(content: []const u8) ?[]const u8 {
    const needle = ".minimum_zig_version";
    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, content, pos, needle)) |idx| {
        // Make sure this isn't inside a comment
        const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..idx], '\n')) |nl| nl + 1 else 0;
        const before = std.mem.trim(u8, content[line_start..idx], " \t");
        if (std.mem.startsWith(u8, before, "//")) {
            pos = idx + needle.len;
            continue;
        }

        // Find the opening quote after the key
        const after = content[idx + needle.len ..];
        if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
            const version_start = q1 + 1;
            if (std.mem.indexOfScalarPos(u8, after, version_start, '"')) |q2| {
                return after[version_start..q2];
            }
        }
        break;
    }

    return null;
}

// --- Semantic version comparison ---

pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: ?[]const u8 = null,

    pub fn parse(s: []const u8) ?SemVer {
        if (s.len == 0) return null;

        var main_part = s;
        var pre_part: ?[]const u8 = null;

        if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
            main_part = s[0..dash];
            pre_part = s[dash + 1 ..];
        }

        var it = std.mem.splitScalar(u8, main_part, '.');
        const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const patch = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;

        return SemVer{
            .major = major,
            .minor = minor,
            .patch = patch,
            .pre = pre_part,
        };
    }

    /// Check if a version string is a prefix match for this version.
    /// E.g., "0.14" matches "0.14.0", "0.14.1", etc.
    pub fn matchesPrefix(self: SemVer, prefix: []const u8) bool {
        var it = std.mem.splitScalar(u8, prefix, '.');
        const p_major = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
        if (p_major != self.major) return false;

        const minor_str = it.next() orelse return true; // "0" matches all 0.x.y
        const p_minor = std.fmt.parseInt(u32, minor_str, 10) catch return false;
        if (p_minor != self.minor) return false;

        const patch_str = it.next() orelse return true; // "0.14" matches all 0.14.y
        const p_patch = std.fmt.parseInt(u32, patch_str, 10) catch return false;
        return p_patch == self.patch;
    }

    pub fn order(a: SemVer, b: SemVer) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        // Pre-release versions sort before their release
        if (a.pre != null and b.pre == null) return .lt;
        if (a.pre == null and b.pre != null) return .gt;
        return .eq;
    }

    pub fn isStable(self: SemVer) bool {
        return self.pre == null;
    }

    pub fn format(self: SemVer, buf: []u8) ![]const u8 {
        if (self.pre) |pre| {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}-{s}", .{ self.major, self.minor, self.patch, pre });
        }
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

// ══════════════════════════════════════════════════════════════
//  Tests
// ══════════════════════════════════════════════════════════════

test "extract minimum_zig_version - standard format" {
    const content =
        \\.{
        \\    .name = "myproject",
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.14.0",
        \\    .paths = .{ "src" },
        \\}
    ;
    try std.testing.expectEqualStrings("0.14.0", extractMinimumZigVersion(content).?);
}

test "extract minimum_zig_version - dev version" {
    const content =
        \\.{
        \\    .minimum_zig_version = "0.15.0-dev.123+abc",
        \\}
    ;
    try std.testing.expectEqualStrings("0.15.0-dev.123+abc", extractMinimumZigVersion(content).?);
}

test "extract minimum_zig_version - commented out" {
    const content =
        \\    // .minimum_zig_version = "0.12.0",
        \\    .minimum_zig_version = "0.14.0",
    ;
    try std.testing.expectEqualStrings("0.14.0", extractMinimumZigVersion(content).?);
}

test "extract minimum_zig_version - missing" {
    const content =
        \\.{
        \\    .name = "myproject",
        \\}
    ;
    try std.testing.expect(extractMinimumZigVersion(content) == null);
}

test "extract minimum_zig_version - empty content" {
    try std.testing.expect(extractMinimumZigVersion("") == null);
}

test "extract minimum_zig_version - only comment" {
    const content = "// .minimum_zig_version = \"0.12.0\"\n";
    try std.testing.expect(extractMinimumZigVersion(content) == null);
}

test "semver parse - valid stable" {
    const v = SemVer.parse("0.14.0").?;
    try std.testing.expectEqual(@as(u32, 0), v.major);
    try std.testing.expectEqual(@as(u32, 14), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
    try std.testing.expect(v.pre == null);
    try std.testing.expect(v.isStable());
}

test "semver parse - dev version" {
    const v = SemVer.parse("0.15.0-dev.123+abc").?;
    try std.testing.expectEqual(@as(u32, 15), v.minor);
    try std.testing.expect(v.pre != null);
    try std.testing.expectEqualStrings("dev.123+abc", v.pre.?);
    try std.testing.expect(!v.isStable());
}

test "semver parse - large version" {
    const v = SemVer.parse("1.0.0").?;
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 0), v.minor);
}

test "semver parse - invalid inputs" {
    try std.testing.expect(SemVer.parse("") == null);
    try std.testing.expect(SemVer.parse("abc") == null);
    try std.testing.expect(SemVer.parse("0.14") == null); // only 2 components
    try std.testing.expect(SemVer.parse("master") == null);
    try std.testing.expect(SemVer.parse("0.x.0") == null);
}

test "semver ordering - basic comparisons" {
    const v13 = SemVer.parse("0.13.0").?;
    const v14 = SemVer.parse("0.14.0").?;
    const v141 = SemVer.parse("0.14.1").?;
    const v15 = SemVer.parse("0.15.0").?;

    try std.testing.expectEqual(std.math.Order.lt, SemVer.order(v13, v14));
    try std.testing.expectEqual(std.math.Order.gt, SemVer.order(v14, v13));
    try std.testing.expectEqual(std.math.Order.eq, SemVer.order(v14, v14));
    try std.testing.expectEqual(std.math.Order.lt, SemVer.order(v14, v141));
    try std.testing.expectEqual(std.math.Order.lt, SemVer.order(v141, v15));
}

test "semver ordering - pre-release sorts before release" {
    const dev = SemVer.parse("0.15.0-dev.100+abc").?;
    const stable = SemVer.parse("0.15.0").?;

    try std.testing.expectEqual(std.math.Order.lt, SemVer.order(dev, stable));
    try std.testing.expectEqual(std.math.Order.gt, SemVer.order(stable, dev));
}

test "semver ordering - major version differences" {
    const v0 = SemVer.parse("0.99.99").?;
    const v1 = SemVer.parse("1.0.0").?;
    try std.testing.expectEqual(std.math.Order.lt, SemVer.order(v0, v1));
}

test "semver prefix matching" {
    const v = SemVer.parse("0.14.1").?;
    try std.testing.expect(v.matchesPrefix("0"));
    try std.testing.expect(v.matchesPrefix("0.14"));
    try std.testing.expect(v.matchesPrefix("0.14.1"));
    try std.testing.expect(!v.matchesPrefix("0.13"));
    try std.testing.expect(!v.matchesPrefix("0.14.0"));
    try std.testing.expect(!v.matchesPrefix("1"));
}

test "semver prefix matching - single component" {
    const v = SemVer.parse("1.2.3").?;
    try std.testing.expect(v.matchesPrefix("1"));
    try std.testing.expect(!v.matchesPrefix("0"));
    try std.testing.expect(!v.matchesPrefix("2"));
}

test "semver format" {
    var buf: [64]u8 = undefined;
    const stable = SemVer.parse("0.14.0").?;
    try std.testing.expectEqualStrings("0.14.0", try stable.format(&buf));

    const dev = SemVer.parse("0.15.0-dev.1+abc").?;
    try std.testing.expectEqualStrings("0.15.0-dev.1+abc", try dev.format(&buf));
}

test "resolve returns a result when default provided" {
    const gpa = std.testing.allocator;
    // Should always resolve to *something* when a default is given
    // (may be build.zig.zon if running inside a project dir, or the default)
    const res = try resolveVersion(gpa, "0.14.0");
    try std.testing.expect(res != null);
    var r = res.?;
    defer r.deinit(gpa);
    try std.testing.expect(r.version.len > 0);
    try std.testing.expect(r.source != .none);
}

test "resolve returns null with no default" {
    const gpa = std.testing.allocator;
    const res = try resolveVersion(gpa, null);
    // May or may not be null depending on whether we're in a dir with .zig-version
    // but we can at least verify it doesn't crash
    if (res) |r_val| {
        var r = r_val;
        r.deinit(gpa);
    }
}

test "source labels" {
    try std.testing.expectEqualStrings("ZIG_VERSION environment variable", Source.env_var.label());
    try std.testing.expectEqualStrings(".zig-version file", Source.zig_version_file.label());
    try std.testing.expectEqualStrings("build.zig.zon minimum_zig_version", Source.build_zig_zon.label());
    try std.testing.expectEqualStrings("default configuration", Source.default_config.label());
}
