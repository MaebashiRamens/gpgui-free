const std = @import("std");
const portal = @import("portal_config.zig");

test "fetch refuses to send with no cookie" {
    try std.testing.expectError(error.MissingCookie, portal.fetch(std.testing.allocator, .{
        .portal = "vpn.example.com",
        .username = "alice",
        .computer = "host",
    }));
}

test "parseGateways does not borrow a later entry's description" {
    const xml =
        \\<policy><gateways><list>
        \\  <entry name="gw1.example.com"><description>First</description></entry>
        \\  <entry name="gw2.example.com"></entry>
        \\  <entry name="gw3.example.com"><description>Third</description></entry>
        \\</list></gateways></policy>
    ;
    const gws = try portal.parseGateways(std.testing.allocator, xml);
    defer portal.freeGateways(std.testing.allocator, gws);
    try std.testing.expectEqual(@as(usize, 3), gws.len);
    try std.testing.expectEqualStrings("First", gws[0].label);
    try std.testing.expectEqualStrings("gw2.example.com", gws[1].label);
    try std.testing.expectEqualStrings("Third", gws[2].label);
}
