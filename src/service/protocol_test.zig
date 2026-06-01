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
