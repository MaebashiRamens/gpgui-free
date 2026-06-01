const std = @import("std");
const portal = @import("portal_config.zig");

test "fetch refuses to send with no cookie" {
    try std.testing.expectError(error.MissingCookie, portal.fetch(std.testing.allocator, .{
        .portal = "vpn.example.com",
        .username = "alice",
        .computer = "host",
    }));
}
