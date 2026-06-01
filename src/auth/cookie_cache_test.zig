const std = @import("std");
const cache = @import("cookie_cache.zig");

test "round-trip via MemoryStore" {
    var mem = cache.MemoryStore.init(std.testing.allocator);
    defer mem.deinit();
    const store = mem.store();

    try store.save(.{
        .portal = "vpn.example.com",
        .user = "alice@example.com",
        .cookie = "abc123",
        .expires_at_unix = 2_000_000_000,
    });

    const got = try store.load("vpn.example.com", "alice@example.com");
    try std.testing.expectEqualStrings("abc123", got.cookie);
    try std.testing.expectEqual(@as(i64, 2_000_000_000), got.expires_at_unix);
}

test "save overwrites previous cookie for same key" {
    var mem = cache.MemoryStore.init(std.testing.allocator);
    defer mem.deinit();
    const store = mem.store();

    try store.save(.{ .portal = "p", .user = "u", .cookie = "old", .expires_at_unix = 1 });
    try store.save(.{ .portal = "p", .user = "u", .cookie = "new", .expires_at_unix = 2 });

    const got = try store.load("p", "u");
    try std.testing.expectEqualStrings("new", got.cookie);
    try std.testing.expectEqual(@as(usize, 1), mem.entries.items.len);
}

test "load on missing entry returns EntryNotFound" {
    var mem = cache.MemoryStore.init(std.testing.allocator);
    defer mem.deinit();
    try std.testing.expectError(error.EntryNotFound, mem.store().load("p", "u"));
}

test "isUsable rejects entries inside the 60s safety window" {
    const now: i64 = 1_000;
    try std.testing.expect(!cache.isUsable(.{
        .portal = "",
        .user = "",
        .cookie = "",
        .expires_at_unix = now + 30,
    }, now));
    try std.testing.expect(cache.isUsable(.{
        .portal = "",
        .user = "",
        .cookie = "",
        .expires_at_unix = now + 3600,
    }, now));
}
