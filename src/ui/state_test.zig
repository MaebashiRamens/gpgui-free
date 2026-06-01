const std = @import("std");
const state = @import("state.zig");

test "fromVpnState covers every arm" {
    try std.testing.expectEqual(state.Status.disconnected, state.fromVpnState(.{ .Disconnected = {} }));
    try std.testing.expectEqual(state.Status.disconnecting, state.fromVpnState(.{ .Disconnecting = {} }));
}
