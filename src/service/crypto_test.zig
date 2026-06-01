const std = @import("std");
const crypto = @import("crypto.zig");

test "round-trip plaintext through seal/open" {
    const key: [crypto.key_length]u8 = @splat(0x42);
    const plaintext = "hello, gpservice";

    const sealed = try crypto.seal(std.testing.allocator, key, plaintext);
    defer std.testing.allocator.free(sealed);
    try std.testing.expectEqual(
        @as(usize, crypto.nonce_length + plaintext.len + crypto.tag_length),
        sealed.len,
    );

    const opened = try crypto.open(std.testing.allocator, key, sealed);
    defer std.testing.allocator.free(opened);
    try std.testing.expectEqualStrings(plaintext, opened);
}

test "open rejects truncated input" {
    const key: [crypto.key_length]u8 = @splat(0);
    try std.testing.expectError(error.InvalidCiphertext, crypto.open(std.testing.allocator, key, &.{ 1, 2, 3 }));
}

test "open rejects tampered tag" {
    const key: [crypto.key_length]u8 = @splat(7);
    const sealed = try crypto.seal(std.testing.allocator, key, "tamper me");
    defer std.testing.allocator.free(sealed);
    sealed[sealed.len - 1] ^= 0x01;
    try std.testing.expectError(error.AuthenticationFailed, crypto.open(std.testing.allocator, key, sealed));
}

test "open rejects wrong key" {
    const key_a: [crypto.key_length]u8 = @splat(1);
    const key_b: [crypto.key_length]u8 = @splat(2);
    const sealed = try crypto.seal(std.testing.allocator, key_a, "secret");
    defer std.testing.allocator.free(sealed);
    try std.testing.expectError(error.AuthenticationFailed, crypto.open(std.testing.allocator, key_b, sealed));
}

test "nonce is non-deterministic across calls" {
    const key: [crypto.key_length]u8 = @splat(0);
    const a = try crypto.seal(std.testing.allocator, key, "same plaintext");
    defer std.testing.allocator.free(a);
    const b = try crypto.seal(std.testing.allocator, key, "same plaintext");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a[0..crypto.nonce_length], b[0..crypto.nonce_length]));
}
