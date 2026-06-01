const std = @import("std");
const client = @import("client.zig");
const crypto = @import("crypto.zig");

test "init rejects wrong key length" {
    var dummy: [10]u8 = @splat(0);
    try std.testing.expectError(error.InvalidApiKey, client.Client.init(std.testing.allocator, .{ .api_key = &dummy }));
}

test "send before start returns ServiceNotRunning" {
    const key: [crypto.key_length]u8 = @splat(0);
    var c = try client.Client.init(std.testing.allocator, .{ .api_key = &key });
    defer c.stop();
    try std.testing.expectError(
        error.ServiceNotRunning,
        c.send(.{ .Disconnect = .{} }),
    );
}
