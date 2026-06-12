//! POST `/ssl-vpn/login.esp`, parse `<argument>` elements, return the
//! openconnect `--cookie` string. Mirrors `crates/gpapi/src/gateway/login.rs`.

const std = @import("std");

pub const Params = struct {
    gateway: []const u8,
    username: []const u8,
    prelogin_cookie: []const u8,
    user_agent: []const u8 = "PAN GlobalProtect",
    os: []const u8 = "Linux",
    os_version: ?[]const u8 = null,
    computer: []const u8,
};

pub const Error = error{
    HttpFailed,
    EmptyResponse,
    MissingAuthcookie,
    MissingUser,
} || std.http.Client.RequestError || std.http.Client.FetchError ||
    std.mem.Allocator.Error || std.Io.Writer.Error;

/// Returns the openconnect `--cookie` payload. Caller frees.
pub fn login(allocator: std.mem.Allocator, params: Params) Error![]u8 {
    const url = try std.fmt.allocPrint(allocator, "https://{s}/ssl-vpn/login.esp", .{params.gateway});
    defer allocator.free(url);

    const body = try buildFormBody(allocator, params);
    defer allocator.free(body);

    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const ua_header = std.http.Header{ .name = "User-Agent", .value = params.user_agent };
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .extra_headers = &.{ua_header},
        .response_writer = &response.writer,
    }) catch return error.HttpFailed;
    if (res.status != .ok) return error.HttpFailed;

    const xml = std.mem.trim(u8, response.written(), " \t\r\n");
    if (xml.len == 0) return error.EmptyResponse;
    return try buildOpenconnectCookie(allocator, xml, params.computer);
}

/// Mirrors `build_gateway_login_params` upstream.
fn buildFormBody(allocator: std.mem.Allocator, p: Params) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try appendPair(&aw.writer, true, "user", p.username);
    try appendPair(&aw.writer, false, "passwd", "");
    try appendPair(&aw.writer, false, "prelogin-cookie", p.prelogin_cookie);
    try appendPair(&aw.writer, false, "portal-userauthcookie", "");
    try appendPair(&aw.writer, false, "portal-prelogonuserauthcookie", "");
    try appendPair(&aw.writer, false, "prot", "https:");
    try appendPair(&aw.writer, false, "jnlpReady", "jnlpReady");
    try appendPair(&aw.writer, false, "ok", "Login");
    try appendPair(&aw.writer, false, "direct", "yes");
    try appendPair(&aw.writer, false, "ipv6-support", "yes");
    try appendPair(&aw.writer, false, "clientVer", "4100");
    try appendPair(&aw.writer, false, "clientos", p.os);
    try appendPair(&aw.writer, false, "computer", p.computer);
    try appendPair(&aw.writer, false, "inputStr", "");
    try appendPair(&aw.writer, false, "server", p.gateway);
    if (p.os_version) |v| try appendPair(&aw.writer, false, "os-version", v);

    return try allocator.dupe(u8, aw.written());
}

fn appendPair(w: *std.Io.Writer, first: bool, key: []const u8, value: []const u8) !void {
    if (!first) try w.writeByte('&');
    try writeUrlEncoded(w, key);
    try w.writeByte('=');
    try writeUrlEncoded(w, value);
}

const argument_keys = [_]struct { index: usize, key: []const u8, required: bool }{
    .{ .index = 1, .key = "authcookie", .required = true },
    .{ .index = 2, .key = "persistent-cookie", .required = false },
    .{ .index = 3, .key = "portal", .required = false },
    .{ .index = 4, .key = "user", .required = true },
    .{ .index = 7, .key = "domain", .required = false },
    .{ .index = 15, .key = "preferred-ip", .required = false },
    .{ .index = 18, .key = "preferred-ipv6", .required = false },
};

fn buildOpenconnectCookie(allocator: std.mem.Allocator, xml: []const u8, computer: []const u8) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try collectArguments(allocator, &args, xml);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var first = true;

    for (argument_keys) |spec| {
        const raw = if (spec.index < args.items.len) args.items[spec.index] else "";
        const normalized = normalize(raw);
        if (normalized) |value| {
            const decoded = try urlDecode(allocator, value);
            defer allocator.free(decoded);
            if (!first) try aw.writer.writeByte('&');
            first = false;
            try aw.writer.writeAll(spec.key);
            try aw.writer.writeByte('=');
            try writeUrlEncoded(&aw.writer, decoded);
        } else if (spec.required) {
            return if (std.mem.eql(u8, spec.key, "authcookie")) error.MissingAuthcookie else error.MissingUser;
        }
    }

    if (!first) try aw.writer.writeByte('&');
    try aw.writer.writeAll("computer=");
    try writeUrlEncoded(&aw.writer, computer);
    return try allocator.dupe(u8, aw.written());
}

fn normalize(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "(null)")) return null;
    if (std.mem.eql(u8, trimmed, "-1")) return null;
    return trimmed;
}

/// `<argument>` texts in document order — upstream addresses them by
/// position, so element nesting doesn't matter.
fn collectArguments(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    xml: []const u8,
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, xml, i, "<argument")) |start| {
        const tag_end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break;
        const open_end = tag_end + 1;
        if (start > 0 and xml[tag_end - 1] == '/') {
            try out.append(allocator, "");
            i = open_end;
            continue;
        }
        const close = std.mem.indexOfPos(u8, xml, open_end, "</argument>") orelse break;
        try out.append(allocator, xml[open_end..close]);
        i = close + "</argument>".len;
    }
}

fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (isUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

fn urlDecode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(allocator, s[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(allocator, s[i]);
                continue;
            };
            try out.append(allocator, hi * 16 + lo);
            i += 2;
        } else if (s[i] == '+') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, s[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "collectArguments preserves document order" {
    const xml =
        \\<response>
        \\  <argument>0</argument>
        \\  <argument>cookie123</argument>
        \\  <argument></argument>
        \\</response>
    ;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try collectArguments(std.testing.allocator, &list, xml);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("0", list.items[0]);
    try std.testing.expectEqualStrings("cookie123", list.items[1]);
    try std.testing.expectEqualStrings("", list.items[2]);
}

test "normalize: skips placeholder values" {
    try std.testing.expect(normalize("(null)") == null);
    try std.testing.expect(normalize("-1") == null);
    try std.testing.expect(normalize("  ") == null);
    try std.testing.expectEqualStrings("real", normalize(" real ").?);
}

test "buildOpenconnectCookie assembles authcookie + computer" {
    const xml =
        "<response>" ++
        "<argument>idx0</argument>" ++
        "<argument>AUTHCOOKIE</argument>" ++
        "<argument>(null)</argument>" ++
        "<argument>portalname</argument>" ++
        "<argument>j2300023</argument>" ++
        "</response>";
    const cookie = try buildOpenconnectCookie(std.testing.allocator, xml, "host");
    defer std.testing.allocator.free(cookie);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "authcookie=AUTHCOOKIE") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "user=j2300023") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "computer=host") != null);
}

test "urlDecode handles percent escapes and plus" {
    const out = try urlDecode(std.testing.allocator, "hello+world%21%2F");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world!/", out);
}
