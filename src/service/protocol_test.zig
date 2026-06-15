const std = @import("std");
const protocol = @import("protocol.zig");

test "parse Disconnected through object form" {
    const json = "{\"VpnState\":\"Disconnected\"}";
    var parsed = try std.json.parseFromSlice(protocol.WsEvent, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .VpnState);
    try std.testing.expect(parsed.value.VpnState == .Disconnected);
}

test "parse Connecting carries ConnectInfo" {
    const json =
        \\{"VpnState":{"Connecting":{
        \\  "portal":"vpn.example.com",
        \\  "gateway":{"name":"gw1","address":"203.0.113.10"},
        \\  "gateways":[{"name":"gw1","address":"203.0.113.10"}]
        \\}}}
    ;
    var parsed = try std.json.parseFromSlice(protocol.WsEvent, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("vpn.example.com", parsed.value.VpnState.Connecting.portal);
    try std.testing.expectEqualStrings("gw1", parsed.value.VpnState.Connecting.gateway.name);
}

test "parseWsEvent handles bare-string unit variants" {
    var parsed = try protocol.parseWsEvent(std.testing.allocator, "\"ActiveGui\"");
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .ActiveGui);
}

test "parseWsEvent rejects unknown unit variant" {
    try std.testing.expectError(
        error.UnknownVariant,
        protocol.parseWsEvent(std.testing.allocator, "\"NotAThing\""),
    );
}

fn stringify(value: anytype) !std.Io.Writer.Allocating {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return aw;
}

test "ConnectArgs.jsonStringify renames allow_extend_session" {
    var aw = try stringify(protocol.ConnectArgs{
        .cookie = "c",
        .hip = true,
        .allow_extend_session = true,
    });
    defer aw.deinit();
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"allowExtendSession\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "allow_extend_session") == null);
}

test "Gateway.jsonStringify emits priorityRules" {
    var aw = try stringify(protocol.Gateway{
        .name = "gw1",
        .address = "203.0.113.10",
        .priority_rules = &.{.{ .name = "r1", .priority = 1 }},
    });
    defer aw.deinit();
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"priorityRules\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "priority_rules") == null);
}

test "DisconnectRequest serializes to null" {
    var aw = try stringify(protocol.DisconnectRequest{});
    defer aw.deinit();
    try std.testing.expectEqualStrings("null", aw.written());
}
