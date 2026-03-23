const std = @import("std");
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;

/// Zig Software Foundation's official minisign public key.
/// Used to verify the authenticity of Zig release tarballs.
const zig_public_key_b64 = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

/// Decoded public key: 2-byte algorithm + 8-byte key_id + 32-byte ed25519 pubkey
const decoded_key = blk: {
    @setEvalBranchQuota(5000);
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var result: [42]u8 = undefined;
    var buf: [4]u8 = undefined;
    var out_idx: usize = 0;
    var buf_len: usize = 0;

    for (zig_public_key_b64) |c| {
        if (c == '=') break;
        const val: u8 = for (alphabet, 0..) |a, i| {
            if (a == c) break @intCast(i);
        } else unreachable;
        buf[buf_len] = val;
        buf_len += 1;
        if (buf_len == 4) {
            result[out_idx] = (buf[0] << 2) | (buf[1] >> 4);
            out_idx += 1;
            result[out_idx] = (buf[1] << 4) | (buf[2] >> 2);
            out_idx += 1;
            result[out_idx] = (buf[2] << 6) | buf[3];
            out_idx += 1;
            buf_len = 0;
        }
    }
    if (buf_len == 2) {
        result[out_idx] = (buf[0] << 2) | (buf[1] >> 4);
        out_idx += 1;
    } else if (buf_len == 3) {
        result[out_idx] = (buf[0] << 2) | (buf[1] >> 4);
        out_idx += 1;
        result[out_idx] = (buf[1] << 4) | (buf[2] >> 2);
        out_idx += 1;
    }

    break :blk result[0..out_idx].*;
};

const key_id: [8]u8 = decoded_key[2..10].*;
const public_key_bytes: [32]u8 = decoded_key[10..42].*;

pub const VerifyError = error{
    HashMismatch,
    SignatureVerificationFailed,
    InvalidSignatureFile,
    KeyIdMismatch,
    UnsupportedAlgorithm,
    FileReadError,
};

/// Verify a file's SHA256 hash against an expected hex string.
pub fn verifySha256(file_path: []const u8, expected_hex: []const u8) VerifyError!void {
    const file = std.fs.openFileAbsolute(file_path, .{}) catch return VerifyError.FileReadError;
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = file.read(&buf) catch return VerifyError.FileReadError;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    const digest = hasher.finalResult();
    const computed_hex = std.fmt.bytesToHex(digest, .lower);

    if (!std.mem.eql(u8, &computed_hex, expected_hex)) {
        return VerifyError.HashMismatch;
    }
}

/// Verify a file's minisign signature against the ZSF public key.
pub fn verifyMinisign(allocator: Allocator, file_path: []const u8, sig_content: []const u8) VerifyError!void {
    // Parse the signature file (minisign format):
    //   Line 1: untrusted comment: ...
    //   Line 2: base64-encoded signature
    //   Line 3: trusted comment: ...
    //   Line 4: base64-encoded global signature
    var lines = std.mem.splitScalar(u8, sig_content, '\n');

    // Skip untrusted comment
    const first_line = lines.next() orelse return VerifyError.InvalidSignatureFile;
    if (!std.mem.startsWith(u8, first_line, "untrusted comment:")) {
        return VerifyError.InvalidSignatureFile;
    }

    // Decode signature
    const sig_b64 = lines.next() orelse return VerifyError.InvalidSignatureFile;
    const sig_b64_trimmed = std.mem.trimRight(u8, sig_b64, "\r\n \t");
    var sig_decoded: [74]u8 = undefined; // 2 + 8 + 64
    const sig_len = std.base64.standard.Decoder.calcSizeForSlice(sig_b64_trimmed) catch return VerifyError.InvalidSignatureFile;
    if (sig_len != 74) return VerifyError.InvalidSignatureFile;
    std.base64.standard.Decoder.decode(&sig_decoded, sig_b64_trimmed) catch return VerifyError.InvalidSignatureFile;

    // Verify algorithm (must be "Ed")
    if (sig_decoded[0] != 'E' or sig_decoded[1] != 'd') {
        return VerifyError.UnsupportedAlgorithm;
    }

    // Verify key ID matches
    if (!std.mem.eql(u8, sig_decoded[2..10], &key_id)) {
        return VerifyError.KeyIdMismatch;
    }

    const signature_bytes: [64]u8 = sig_decoded[10..74].*;

    // Read the file to verify
    const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, 512 * 1024 * 1024) catch return VerifyError.FileReadError;
    defer allocator.free(file_content);

    // Verify the Ed25519 signature
    const pk = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return VerifyError.SignatureVerificationFailed;
    const sig = Ed25519.Signature.fromBytes(signature_bytes);
    sig.verify(file_content, pk) catch return VerifyError.SignatureVerificationFailed;

    // Verify the trusted comment (global signature)
    const tc_line = lines.next() orelse return; // Trusted comment is optional
    if (!std.mem.startsWith(u8, tc_line, "trusted comment:")) return;

    const global_sig_b64 = lines.next() orelse return;
    const global_sig_trimmed = std.mem.trimRight(u8, global_sig_b64, "\r\n \t");
    var global_sig_decoded: [64]u8 = undefined;
    const gs_len = std.base64.standard.Decoder.calcSizeForSlice(global_sig_trimmed) catch return;
    if (gs_len != 64) return;
    std.base64.standard.Decoder.decode(&global_sig_decoded, global_sig_trimmed) catch return;

    // Global signature is over: signature_bytes || trusted_comment_text
    const trusted_text = std.mem.trimRight(u8, tc_line["trusted comment:".len..], "\r\n \t");
    const global_msg = allocator.alloc(u8, 64 + trusted_text.len) catch return;
    defer allocator.free(global_msg);
    @memcpy(global_msg[0..64], &signature_bytes);
    @memcpy(global_msg[64..], trusted_text);

    const global_sig = Ed25519.Signature.fromBytes(global_sig_decoded);
    global_sig.verify(global_msg, pk) catch return VerifyError.SignatureVerificationFailed;
}

test "key decoding - algorithm is Ed25519" {
    const algo = decoded_key[0..2];
    try std.testing.expectEqualStrings("Ed", algo);
}

test "key decoding - public key is 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), public_key_bytes.len);
}

test "key decoding - key_id is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), key_id.len);
}

test "key decoding - full decoded key is 42 bytes" {
    // 2 (algo) + 8 (key_id) + 32 (pubkey) = 42
    try std.testing.expectEqual(@as(usize, 42), decoded_key.len);
}

test "sha256 - known hash" {
    // Create a temp file with known content and verify its hash
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write "hello\n" (SHA256 = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03)
    const f = try tmp_dir.dir.createFile("test.txt", .{});
    try f.writeAll("hello\n");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    // Correct hash should pass
    try verifySha256(path, "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03");

    // Wrong hash should fail
    const result = verifySha256(path, "0000000000000000000000000000000000000000000000000000000000000000");
    try std.testing.expectError(VerifyError.HashMismatch, result);
}

test "sha256 - file not found" {
    const result = verifySha256("/nonexistent/file/that/does/not/exist", "deadbeef");
    try std.testing.expectError(VerifyError.FileReadError, result);
}

test "minisign - invalid signature format" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("test.txt", .{});
    try f.writeAll("test content");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    const result = verifyMinisign(std.testing.allocator, path, "not a valid sig");
    try std.testing.expectError(VerifyError.InvalidSignatureFile, result);
}

test "minisign - malformed base64 in signature" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const f = try tmp_dir.dir.createFile("test.txt", .{});
    try f.writeAll("test content");
    f.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    const sig = "untrusted comment: test\nnot_valid_base64!!!\n";
    const result = verifyMinisign(std.testing.allocator, path, sig);
    try std.testing.expectError(VerifyError.InvalidSignatureFile, result);
}
