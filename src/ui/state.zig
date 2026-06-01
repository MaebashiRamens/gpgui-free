//! UI mirror of `protocol.VpnState` plus `service_unreachable`.

const std = @import("std");
const protocol = @import("../service/protocol.zig");

pub const Status = enum {
    disconnected,
    connecting,
    connected,
    disconnecting,
    service_unreachable,

    /// Sentinel-terminated for GTK consumption.
    pub fn label(self: Status) [:0]const u8 {
        return switch (self) {
            .disconnected => "Disconnected",
            .connecting => "Connecting…",
            .connected => "Connected",
            .disconnecting => "Disconnecting…",
            .service_unreachable => "gpservice unreachable",
        };
    }
};

pub fn fromVpnState(vs: protocol.VpnState) Status {
    return switch (vs) {
        .Disconnected => .disconnected,
        .Connecting => .connecting,
        .Connected => .connected,
        .Disconnecting => .disconnecting,
    };
}
