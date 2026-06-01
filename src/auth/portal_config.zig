//! POST `/global-protect/getconfig.esp` for the gateway list.
//! Mirrors `crates/gpapi/src/portal/config.rs`.

const std = @import("std");

pub const Gateway = struct {
    /// `<description>` or, when absent, the address.
    label: []u8,
    /// `<entry name="…">` — host or host:port.
    address: []u8,
};

pub const Params = struct {
    portal: []const u8,
    username: []const u8,
    /// At least one of the two cookies must be set.
    portal_userauthcookie: ?[]const u8 = null,
    prelogin_cookie: ?[]const u8 = null,
    user_agent: []const u8 = "PAN GlobalProtect",
    os: []const u8 = "Linux",
    computer: []const u8,
};

pub const Error = error{
    HttpFailed,
    EmptyResponse,
    NoGateways,
    MissingCookie,
} || std.http.Client.RequestError || std.http.Client.FetchError ||
    std.mem.Allocator.Error || std.Io.Writer.Error;

/// Caller frees with `freeGateways`.
pub fn fetch(allocator: std.mem.Allocator, params: Params) Error![]Gateway {
    if (params.portal_userauthcookie == null and params.prelogin_cookie == null)
        return error.MissingCookie;

    const url = try std.fmt.allocPrint(allocator, "https://{s}/global-protect/getconfig.esp", .{params.portal});
    defer allocator.free(url);

    const body = try buildFormBody(allocator, params);
    defer allocator.free(body);

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const ua = std.http.Header{ .name = "User-Agent", .value = params.user_agent };
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .extra_headers = &.{ua},
        .response_writer = &response.writer,
    }) catch return error.HttpFailed;
    if (res.status != .ok) return error.HttpFailed;

    const xml = std.mem.trim(u8, response.written(), " \t\r\n");
    if (xml.len == 0) return error.EmptyResponse;
    return parseGateways(allocator, xml);
}

pub fn freeGateways(allocator: std.mem.Allocator, gws: []Gateway) void {
    for (gws) |g| {
        allocator.free(g.label);
        allocator.free(g.address);
    }
    allocator.free(gws);
}

fn buildFormBody(allocator: std.mem.Allocator, p: Params) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var first = true;

    try appendPair(&aw.writer, &first, "user", p.username);
    try appendPair(&aw.writer, &first, "passwd", "");
    if (p.prelogin_cookie) |c| try appendPair(&aw.writer, &first, "prelogin-cookie", c);
    if (p.portal_userauthcookie) |c| try appendPair(&aw.writer, &first, "portal-userauthcookie", c);
    try appendPair(&aw.writer, &first, "portal-prelogonuserauthcookie", "");
    try appendPair(&aw.writer, &first, "prot", "https:");
    try appendPair(&aw.writer, &first, "jnlpReady", "jnlpReady");
    try appendPair(&aw.writer, &first, "ok", "Login");
    try appendPair(&aw.writer, &first, "direct", "yes");
    try appendPair(&aw.writer, &first, "ipv6-support", "yes");
    try appendPair(&aw.writer, &first, "clientVer", "4100");
    try appendPair(&aw.writer, &first, "clientos", p.os);
    try appendPair(&aw.writer, &first, "computer", p.computer);
    try appendPair(&aw.writer, &first, "inputStr", "");
    try appendPair(&aw.writer, &first, "server", p.portal);

    return try allocator.dupe(u8, aw.written());
}

fn appendPair(w: *std.Io.Writer, first: *bool, key: []const u8, value: []const u8) !void {
    if (!first.*) try w.writeByte('&');
    first.* = false;
    try writeUrlEncoded(w, key);
    try w.writeByte('=');
    try writeUrlEncoded(w, value);
}

fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// Bounded to `<gateways>…</gateways>` — other `<entry name="…">`
/// elements (e.g. trusted-app lists) live elsewhere in the config.
fn parseGateways(allocator: std.mem.Allocator, xml: []const u8) ![]Gateway {
    var list: std.ArrayList(Gateway) = .empty;
    errdefer {
        for (list.items) |g| {
            allocator.free(g.label);
            allocator.free(g.address);
        }
        list.deinit(allocator);
    }

    const block_start = std.mem.indexOf(u8, xml, "<gateways>") orelse return error.NoGateways;
    const block_end = std.mem.indexOfPos(u8, xml, block_start, "</gateways>") orelse return error.NoGateways;
    const block = xml[block_start..block_end];

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, block, i, "<entry name=\"")) |start| {
        const name_start = start + "<entry name=\"".len;
        const name_end = std.mem.indexOfPos(u8, block, name_start, "\"") orelse break;
        const address = block[name_start..name_end];

        var label = address;
        if (std.mem.indexOfPos(u8, block, name_end, "<description>")) |d_start_marker| {
            const d_start = d_start_marker + "<description>".len;
            if (std.mem.indexOfPos(u8, block, d_start, "</description>")) |d_end| {
                if (d_end > d_start) label = block[d_start..d_end];
            }
        }

        try list.append(allocator, .{
            .label = try allocator.dupe(u8, label),
            .address = try allocator.dupe(u8, address),
        });
        i = name_end;
    }

    if (list.items.len == 0) return error.NoGateways;
    return try list.toOwnedSlice(allocator);
}

test "parseGateways extracts every entry inside <gateways>" {
    const xml =
        \\<policy>
        \\  <gateways>
        \\    <list>
        \\      <entry name="gw1.example.com:443"><description>Primary</description></entry>
        \\      <entry name="gw2.example.com"><description>Secondary</description></entry>
        \\    </list>
        \\  </gateways>
        \\  <other>
        \\    <entry name="ignored.example.com"><description>Trusted app</description></entry>
        \\  </other>
        \\</policy>
    ;
    const gws = try parseGateways(std.testing.allocator, xml);
    defer freeGateways(std.testing.allocator, gws);
    try std.testing.expectEqual(@as(usize, 2), gws.len);
    try std.testing.expectEqualStrings("gw1.example.com:443", gws[0].address);
    try std.testing.expectEqualStrings("Primary", gws[0].label);
    try std.testing.expectEqualStrings("gw2.example.com", gws[1].address);
    try std.testing.expectEqualStrings("Secondary", gws[1].label);
}

test "parseGateways falls back to address when description is absent" {
    const xml =
        \\<policy><gateways><list>
        \\  <entry name="solo.example.com"></entry>
        \\</list></gateways></policy>
    ;
    const gws = try parseGateways(std.testing.allocator, xml);
    defer freeGateways(std.testing.allocator, gws);
    try std.testing.expectEqual(@as(usize, 1), gws.len);
    try std.testing.expectEqualStrings("solo.example.com", gws[0].address);
    try std.testing.expectEqualStrings("solo.example.com", gws[0].label);
}

test "parseGateways errors when no <gateways> block present" {
    try std.testing.expectError(error.NoGateways, parseGateways(std.testing.allocator, "<policy/>"));
}
