//! ChaCha20-Poly1305 envelope: `nonce(12) || ciphertext(N) || tag(16)`.
//! Matches `crates/gpapi/src/utils/crypto.rs` upstream.

const std = @import("std");
const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const key_length = ChaCha.key_length;
pub const nonce_length = ChaCha.nonce_length;
pub const tag_length = ChaCha.tag_length;

pub const Error = error{
    InvalidCiphertext,
    AuthenticationFailed,
} || std.mem.Allocator.Error;

/// Caller owns the returned buffer.
pub fn seal(
    allocator: std.mem.Allocator,
    key: [key_length]u8,
    plaintext: []const u8,
) ![]u8 {
    var nonce: [nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const out = try allocator.alloc(u8, nonce_length + plaintext.len + tag_length);
    errdefer allocator.free(out);

    @memcpy(out[0..nonce_length], &nonce);
    var tag: [tag_length]u8 = undefined;
    ChaCha.encrypt(
        out[nonce_length .. nonce_length + plaintext.len],
        &tag,
        plaintext,
        &.{},
        nonce,
        key,
    );
    @memcpy(out[nonce_length + plaintext.len ..], &tag);
    return out;
}

/// Caller owns the returned buffer.
pub fn open(
    allocator: std.mem.Allocator,
    key: [key_length]u8,
    sealed: []const u8,
) Error![]u8 {
    if (sealed.len < nonce_length + tag_length) return error.InvalidCiphertext;

    const ct_end = sealed.len - tag_length;
    const nonce: [nonce_length]u8 = sealed[0..nonce_length].*;
    const ciphertext = sealed[nonce_length..ct_end];
    const tag: [tag_length]u8 = sealed[ct_end..][0..tag_length].*;

    const out = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(out);
    ChaCha.decrypt(out, ciphertext, tag, &.{}, nonce, key) catch
        return error.AuthenticationFailed;
    return out;
}
