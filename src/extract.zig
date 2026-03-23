const std = @import("std");
const Allocator = std.mem.Allocator;

/// Extract a .tar.xz archive to dest_path, stripping the top-level directory.
pub fn extractTarXz(allocator: Allocator, archive_path: []const u8, dest_path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(archive_path, .{});
    defer file.close();

    var dest_dir = try std.fs.openDirAbsolute(dest_path, .{});
    defer dest_dir.close();

    const old_reader = file.deprecatedReader();
    var decomp = try std.compress.xz.decompress(allocator, old_reader);
    defer decomp.deinit();

    var xz_reader = decomp.reader();
    var adapter_buf: [8192]u8 = undefined;
    var adapter = xz_reader.adaptToNewApi(&adapter_buf);

    std.tar.pipeToFileSystem(dest_dir, &adapter.new_interface, .{
        .strip_components = 1,
    }) catch |err| {
        std.log.err("tar extraction failed: {}", .{err});
        return error.ExtractionFailed;
    };
}

/// Extract a .zip archive to dest_path using std.zip.
pub fn extractZip(archive_path: []const u8, dest_path: []const u8) !void {
    var dest_dir = try std.fs.openDirAbsolute(dest_path, .{});
    defer dest_dir.close();

    var archive_file = try std.fs.openFileAbsolute(archive_path, .{});
    defer archive_file.close();

    var read_buf: [8192]u8 = undefined;
    var file_reader = archive_file.reader(&read_buf);

    std.zip.extract(dest_dir, &file_reader, .{
        .allow_backslashes = true,
    }) catch |err| {
        std.log.err("zip extraction failed: {}", .{err});
        return error.ExtractionFailed;
    };
}

/// Detect archive format from file extension and extract accordingly.
pub fn extractAuto(allocator: Allocator, archive_path: []const u8, dest_path: []const u8) !void {
    if (std.mem.endsWith(u8, archive_path, ".tar.xz")) {
        try extractTarXz(allocator, archive_path, dest_path);
    } else if (std.mem.endsWith(u8, archive_path, ".zip")) {
        try extractZip(archive_path, dest_path);
    } else {
        return error.UnsupportedFormat;
    }
}

// ──── Tests ────

test "extractAuto - unsupported format" {
    const result = extractAuto(std.testing.allocator, "/tmp/test.rar", "/tmp/out");
    try std.testing.expectError(error.UnsupportedFormat, result);
}

test "extractAuto - tar.xz extension detected" {
    if (extractAuto(std.testing.allocator, "/nonexistent/file.tar.xz", "/tmp/out")) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err != error.UnsupportedFormat);
    }
}

test "extractAuto - zip extension detected" {
    if (extractAuto(std.testing.allocator, "/nonexistent/file.zip", "/tmp/out")) |_| {
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expect(err != error.UnsupportedFormat);
    }
}

test "extractTarXz - nonexistent file returns error" {
    if (extractTarXz(std.testing.allocator, "/nonexistent/archive.tar.xz", "/tmp/out")) |_| {
        try std.testing.expect(false);
    } else |_| {}
}

test "extractZip - nonexistent file returns error" {
    if (extractZip("/nonexistent/archive.zip", "/tmp/out")) |_| {
        try std.testing.expect(false);
    } else |_| {}
}
