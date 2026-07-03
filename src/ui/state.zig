//! UI mirror of `protocol.VpnState` plus `service_unreachable`.

const std = @import("std");
const protocol = @import("../service/protocol.zig");

pub const Status = enum {
    disconnected,
    connecting,
    connected,
    disconnecting,
    /// Synthetic: not a `VpnState`. Set while we re-run the connect flow
    /// after a `ResumeConnection` (network came back).
    reconnecting,
    service_unreachable,

    /// Sentinel-terminated for GTK consumption.
    pub fn label(self: Status) [:0]const u8 {
        return switch (self) {
            .disconnected => "Disconnected",
            .connecting => "Connecting…",
            .connected => "Connected",
            .disconnecting => "Disconnecting…",
            .reconnecting => "Reconnecting…",
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
