const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const DownloadInfo = struct {
    tarball: []const u8,
    shasum: []const u8,
    size: u64,
};

/// The platform key for the current system (e.g., "x86_64-linux").
pub const platform_key = blk: {
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7a",
        .x86 => "x86",
        .powerpc64le => "powerpc64le",
        .riscv64 => "riscv64",
        .loongarch64 => "loongarch64",
        .s390x => "s390x",
        else => @compileError("unsupported architecture: " ++ @tagName(builtin.cpu.arch)),
    };
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        .freebsd => "freebsd",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        else => @compileError("unsupported OS: " ++ @tagName(builtin.os.tag)),
    };
    break :blk arch ++ "-" ++ os;
};

const index_url = "https://ziglang.org/download/index.json";
const index_cache_ttl_ns: i128 = 3600 * std.time.ns_per_s; // 1 hour

/// Fetch the Zig version index JSON. Uses a local cache with TTL.
pub fn fetchIndex(allocator: Allocator, cache_dir: []const u8) !std.json.Parsed(std.json.Value) {
    const cache_path = try std.fs.path.join(allocator, &.{ cache_dir, "index.json" });
    defer allocator.free(cache_path);

    // Try cache first
    if (readCachedIndex(allocator, cache_path)) |cached| {
        return cached;
    } else |_| {}

    // Download fresh index
    const body = try httpGet(allocator, index_url);
    defer allocator.free(body);

    // Write to cache
    if (std.fs.createFileAbsolute(cache_path, .{})) |f| {
        defer f.close();
        f.writeAll(body) catch {};
    } else |_| {}

    return try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    });
}

fn readCachedIndex(allocator: Allocator, cache_path: []const u8) !std.json.Parsed(std.json.Value) {
    const file = try std.fs.openFileAbsolute(cache_path, .{});
    defer file.close();

    const stat = try file.stat();
    const now = std.time.nanoTimestamp();
    const age = now - stat.mtime;
    if (age > index_cache_ttl_ns) return error.CacheExpired;

    const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(content);

    return try std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .allocate = .alloc_always,
    });
}

/// Look up download info for a specific version and the current platform.
pub fn getDownloadInfo(index: std.json.Value, version_key: []const u8) !DownloadInfo {
    const root = index.object;
    const version_obj = root.get(version_key) orelse return error.VersionNotFound;
    const platform_obj = version_obj.object.get(platform_key) orelse return error.PlatformNotAvailable;

    const tarball = (platform_obj.object.get("tarball") orelse return error.MissingField).string;
    const shasum = (platform_obj.object.get("shasum") orelse return error.MissingField).string;
    const size_val = platform_obj.object.get("size") orelse return error.MissingField;

    const size: u64 = switch (size_val) {
        .integer => @intCast(size_val.integer),
        .string => std.fmt.parseInt(u64, size_val.string, 10) catch return error.MissingField,
        else => return error.MissingField,
    };

    return .{
        .tarball = tarball,
        .shasum = shasum,
        .size = size,
    };
}

/// Resolve a user-provided version string to the actual index key.
/// Supports: exact match, "stable"/"latest", "nightly"/"master", and partial
/// prefix matching ("0.14" resolves to highest "0.14.x").
pub fn resolveVersionKey(index: std.json.Value, user_version: []const u8) ![]const u8 {
    const SemVer = @import("resolve.zig").SemVer;
    const root = index.object;

    // Direct match
    if (root.contains(user_version)) return user_version;

    // Named aliases
    if (std.mem.eql(u8, user_version, "stable") or std.mem.eql(u8, user_version, "latest")) {
        return findBestStable(root, SemVer) orelse error.VersionNotFound;
    }
    if (std.mem.eql(u8, user_version, "nightly")) return "master";

    // Partial prefix matching: "0.14" → "0.14.1", "0" → latest 0.x
    // Only attempt if the input looks like a numeric prefix (starts with a digit)
    if (user_version.len > 0 and std.ascii.isDigit(user_version[0])) {
        var best: ?[]const u8 = null;
        var best_ver: ?SemVer = null;

        var it = root.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "master")) continue;
            const sv = SemVer.parse(key) orelse continue;
            if (!sv.isStable()) continue;
            if (!sv.matchesPrefix(user_version)) continue;
            if (best_ver == null or sv.order(best_ver.?) == .gt) {
                best = key;
                best_ver = sv;
            }
        }
        if (best) |b| return b;
    }

    return error.VersionNotFound;
}

fn findBestStable(root: std.json.ObjectMap, comptime SemVer: type) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_ver: ?SemVer = null;

    var it = root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "master")) continue;
        const sv = SemVer.parse(key) orelse continue;
        if (!sv.isStable()) continue;
        if (best_ver == null or sv.order(best_ver.?) == .gt) {
            best = key;
            best_ver = sv;
        }
    }
    return best;
}

/// Force-clear the cached index.
pub fn clearCache(cache_dir: []const u8, allocator: Allocator) void {
    const cache_path = std.fs.path.join(allocator, &.{ cache_dir, "index.json" }) catch return;
    defer allocator.free(cache_path);
    std.fs.deleteFileAbsolute(cache_path) catch {};
}

/// Apply mirror URL substitution if ZVM_MIRROR is set.
/// Replaces `https://ziglang.org/...` with `$ZVM_MIRROR/...`.
pub fn applyMirror(allocator: Allocator, url: []const u8) ![]const u8 {
    const mirror = std.process.getEnvVarOwned(allocator, "ZVM_MIRROR") catch return try allocator.dupe(u8, url);
    defer allocator.free(mirror);

    const prefix = "https://ziglang.org/";
    if (std.mem.startsWith(u8, url, prefix)) {
        const suffix = url[prefix.len..];
        const trimmed = std.mem.trimRight(u8, mirror, "/");
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, suffix });
    }

    return try allocator.dupe(u8, url);
}

/// Download a file, applying mirror URL if configured.
pub fn downloadFileMirrored(
    allocator: Allocator,
    url: []const u8,
    dest_path: []const u8,
) !void {
    const effective_url = try applyMirror(allocator, url);
    defer allocator.free(effective_url);
    try downloadFile(allocator, effective_url, dest_path);
}

// ──── Tests ────

test "platform_key is valid" {
    // Must contain a dash separating arch and OS
    try std.testing.expect(std.mem.indexOfScalar(u8, platform_key, '-') != null);
    // Must not be empty
    try std.testing.expect(platform_key.len > 0);
}

test "resolveVersionKey - direct match" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const key = try resolveVersionKey(json.value, "0.14.0");
    try std.testing.expectEqualStrings("0.14.0", key);
}

test "resolveVersionKey - stable alias" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const key = try resolveVersionKey(json.value, "stable");
    try std.testing.expectEqualStrings("0.15.0", key);
}

test "resolveVersionKey - latest alias" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const key = try resolveVersionKey(json.value, "latest");
    try std.testing.expectEqualStrings("0.15.0", key);
}

test "resolveVersionKey - nightly alias" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const key = try resolveVersionKey(json.value, "nightly");
    try std.testing.expectEqualStrings("master", key);
}

test "resolveVersionKey - partial prefix match" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const key = try resolveVersionKey(json.value, "0.14");
    try std.testing.expectEqualStrings("0.14.1", key);
}

test "resolveVersionKey - unknown version" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const result = resolveVersionKey(json.value, "9.99.99");
    try std.testing.expectError(error.VersionNotFound, result);
}

test "getDownloadInfo - valid version" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const info = try getDownloadInfo(json.value, "0.14.0");
    try std.testing.expectEqualStrings("https://example.com/zig-0.14.0.tar.xz", info.tarball);
    try std.testing.expectEqualStrings("abcdef1234567890", info.shasum);
    try std.testing.expectEqual(@as(u64, 12345678), info.size);
}

test "getDownloadInfo - missing version" {
    const allocator = std.testing.allocator;
    const json = try buildMockIndex(allocator);
    defer json.deinit();

    const result = getDownloadInfo(json.value, "9.9.9");
    try std.testing.expectError(error.VersionNotFound, result);
}

test "formatSize - various sizes" {
    var buf: [128]u8 = undefined;
    var w: std.fs.File.Writer = .init(std.fs.File.stdout(), &buf);
    // Just verify it doesn't crash with various inputs
    try formatSize(&w.interface, 0);
    try formatSize(&w.interface, 512);
    try formatSize(&w.interface, 1024);
    try formatSize(&w.interface, 1048576);
    try formatSize(&w.interface, 1073741824);
}

/// Build a minimal mock index for testing (no network needed).
fn buildMockIndex(allocator: Allocator) !std.json.Parsed(std.json.Value) {
    const mock_json =
        \\{
        \\  "master": {"version":"0.16.0-dev.1+abc","date":"2025-01-01"},
        \\  "0.15.0": {
        \\    "date": "2025-03-01",
        \\    "x86_64-linux": {"tarball":"https://example.com/zig-0.15.0.tar.xz","shasum":"aaa","size":"99999"}
        \\  },
        \\  "0.14.1": {
        \\    "date": "2025-02-01",
        \\    "x86_64-linux": {"tarball":"https://example.com/zig-0.14.1.tar.xz","shasum":"bbb","size":"88888"}
        \\  },
        \\  "0.14.0": {
        \\    "date": "2025-01-01",
        \\    "x86_64-linux": {"tarball":"https://example.com/zig-0.14.0.tar.xz","shasum":"abcdef1234567890","size":"12345678"}
        \\  }
        \\}
    ;
    return try std.json.parseFromSlice(std.json.Value, allocator, mock_json, .{
        .allocate = .alloc_always,
    });
}

/// Download a file to disk.
pub fn downloadFile(
    allocator: Allocator,
    url: []const u8,
    dest_path: []const u8,
) !void {
    const body = try httpGet(allocator, url);
    defer allocator.free(body);

    const file = try std.fs.createFileAbsolute(dest_path, .{});
    defer file.close();
    try file.writeAll(body);
}

/// Fetch a URL's content as bytes.
pub fn httpGet(allocator: Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Use an ArrayList with the adapter to bridge to new Writer API
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    var gw = body.writer(allocator);
    var adapter_buf: [16 * 1024]u8 = undefined;
    var adapter = gw.adaptToNewApi(&adapter_buf);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &adapter.new_interface,
    });

    // Flush any remaining buffered data
    adapter.new_interface.flush() catch {};

    if (result.status != .ok) {
        body.deinit(allocator);
        return error.HttpRequestFailed;
    }

    return body.toOwnedSlice(allocator);
}

pub fn formatSize(writer: *std.Io.Writer, bytes: u64) !void {
    const fb: f64 = @floatFromInt(bytes);
    if (fb >= 1024.0 * 1024.0 * 1024.0) {
        try writer.print("{d:.1} GB", .{fb / (1024.0 * 1024.0 * 1024.0)});
    } else if (fb >= 1024.0 * 1024.0) {
        try writer.print("{d:.1} MB", .{fb / (1024.0 * 1024.0)});
    } else if (fb >= 1024.0) {
        try writer.print("{d:.1} KB", .{fb / 1024.0});
    } else {
        try writer.print("{d} B", .{bytes});
    }
}
