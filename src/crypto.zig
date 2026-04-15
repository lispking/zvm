//! SHA256 cryptographic hashing for file verification.
//! Used to verify downloaded Zig archives match their expected checksums.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
/// Length of a hex-encoded SHA256 digest (32 bytes * 2 hex chars).
const hex_len = Sha256.digest_length * 2;

/// Encode a binary digest as a lowercase hex string.
fn hexEncode(digest: *const [Sha256.digest_length]u8, buf: *[hex_len]u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return buf;
}

/// Compute SHA256 hash of a file and return as hex-encoded string.
/// Reads the entire file into memory (up to 500MB).
/// Caller owns returned memory.
pub fn computeFileSha256(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [16384]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(500 * 1024 * 1024));
    defer allocator.free(content);

    var hasher = Sha256.init(.{});
    hasher.update(content);

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    var hex_buf: [hex_len]u8 = undefined;
    const hex = hexEncode(&digest, &hex_buf);
    return allocator.dupe(u8, hex);
}

/// Verify that a file's SHA256 hash matches the expected hex-encoded checksum.
/// Returns true if they match, false otherwise.
pub fn verifyFileSha256(io: std.Io, path: []const u8, expected_hex: []const u8) !bool {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [16384]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const content = try reader.interface.allocRemaining(std.heap.page_allocator, .limited(500 * 1024 * 1024));
    defer std.heap.page_allocator.free(content);

    var hasher = Sha256.init(.{});
    hasher.update(content);

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    var hex_buf: [hex_len]u8 = undefined;
    const hex = hexEncode(&digest, &hex_buf);

    return std.mem.eql(u8, hex, expected_hex);
}
