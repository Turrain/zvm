const std = @import("std");
const Allocator = std.mem.Allocator;
const fetch = @import("fetch.zig");
const extract_mod = @import("extract.zig");

const zls_index_url = "https://releases.zigtools.org/v1/zls/select?zig_version={s}&compatibility=only-runtime";

pub const ZlsInfo = struct {
    version: []const u8,
    url: []const u8,
};

/// Attempt to install ZLS matching the given Zig version.
pub fn installZls(
    allocator: Allocator,
    zig_version: []const u8,
    zls_dir: []const u8,
    show_progress: bool,
    stderr: *std.Io.Writer,
) !void {
    _ = show_progress;

    const info = getZlsInfo(allocator, zig_version) catch |err| {
        try stderr.print("  Could not find matching ZLS for zig {s}: {}\n", .{ zig_version, err });
        return err;
    };
    defer allocator.free(info.version);
    defer allocator.free(info.url);

    const version_dir = try std.fs.path.join(allocator, &.{ zls_dir, info.version });
    defer allocator.free(version_dir);

    // Check if already installed
    if (std.fs.accessAbsolute(version_dir, .{})) |_| {
        try stderr.print("  ZLS {s} already installed\n", .{info.version});
        return;
    } else |_| {}

    std.fs.makeDirAbsolute(version_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try stderr.print("  Installing ZLS {s}...\n", .{info.version});

    // Download
    const filename = std.fs.path.basename(info.url);
    const download_path = try std.fs.path.join(allocator, &.{ zls_dir, filename });
    defer allocator.free(download_path);

    fetch.downloadFile(allocator, info.url, download_path) catch |err| {
        try stderr.print("  Failed to download ZLS: {}\n", .{err});
        std.fs.deleteDirAbsolute(version_dir) catch {};
        return err;
    };

    // Extract
    extract_mod.extractAuto(allocator, download_path, version_dir) catch |err| {
        try stderr.print("  Failed to extract ZLS: {}\n", .{err});
        std.fs.deleteFileAbsolute(download_path) catch {};
        std.fs.deleteTreeAbsolute(version_dir) catch {};
        return err;
    };

    // Clean up archive
    std.fs.deleteFileAbsolute(download_path) catch {};

    // Make executable
    const zls_bin = try std.fs.path.join(allocator, &.{ version_dir, "zls" });
    defer allocator.free(zls_bin);
    if (std.fs.openFileAbsolute(zls_bin, .{ .mode = .read_write })) |f| {
        defer f.close();
        f.chmod(0o755) catch {};
    } else |_| {}
}

fn getZlsInfo(allocator: Allocator, zig_version: []const u8) !ZlsInfo {
    const url = try std.fmt.allocPrint(allocator, zls_index_url, .{zig_version});
    defer allocator.free(url);

    const body = fetch.httpGet(allocator, url) catch return error.ZlsLookupFailed;
    defer allocator.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    }) catch return error.ZlsLookupFailed;
    defer parsed.deinit();

    const root = parsed.value.object;
    const version = (root.get("version") orelse return error.ZlsLookupFailed).string;
    const dl = root.get(fetch.platform_key) orelse return error.ZlsLookupFailed;
    const tarball = (dl.object.get("tarball") orelse return error.ZlsLookupFailed).string;

    return .{
        .version = try allocator.dupe(u8, version),
        .url = try allocator.dupe(u8, tarball),
    };
}

/// Create or update the ZLS symlink in bin_dir.
pub fn linkZls(zls_dir: []const u8, version: []const u8, bin_dir: []const u8) !void {
    const a = std.heap.page_allocator;

    const zls_bin = try std.fs.path.join(a, &.{ zls_dir, version, "zls" });
    defer a.free(zls_bin);

    // Check if the ZLS binary exists
    std.fs.accessAbsolute(zls_bin, .{}) catch return;

    const link_path = try std.fs.path.join(a, &.{ bin_dir, "zls" });
    defer a.free(link_path);

    // Remove existing symlink
    std.posix.unlink(link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    // Create relative symlink
    const rel_target = try std.fs.path.relative(a, bin_dir, zls_bin);
    defer a.free(rel_target);

    var bin = try std.fs.openDirAbsolute(bin_dir, .{});
    defer bin.close();
    bin.symLink(rel_target, "zls", .{}) catch {};
}
