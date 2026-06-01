//! Spawns the upstream `gpauth` helper and parses its `SamlAuthResult`
//! stdout: `{"success":{…}}` or `{"failure":"…"}`.

const std = @import("std");

pub const default_binary: []const u8 = "/usr/bin/gpauth";

pub const AuthData = struct {
    username: []const u8,
    /// At least one of the three cookies is set on success.
    prelogin_cookie: ?[]const u8 = null,
    portal_userauthcookie: ?[]const u8 = null,
    token: ?[]const u8 = null,
};

pub const Error = error{
    SpawnFailed,
    AuthFailed,
    MalformedOutput,
} || std.process.Child.RunError || std.mem.Allocator.Error;

/// Output is arena-allocated; deinit the returned `Parsed`.
pub fn authenticate(
    allocator: std.mem.Allocator,
    options: Options,
) Error!std.json.Parsed(AuthData) {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, options.binary);
    try argv.append(allocator, options.server);
    try argv.append(allocator, "--browser");
    try argv.append(allocator, options.browser);
    if (options.gateway) try argv.append(allocator, "--gateway");
    if (options.ignore_tls_errors) try argv.append(allocator, "--ignore-tls-errors");

    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1 * 1024 * 1024,
    }) catch return error.SpawnFailed;
    defer allocator.free(res.stderr);
    defer allocator.free(res.stdout);

    if (res.term != .Exited or res.term.Exited != 0) {
        std.log.warn("gpauth failed: term={any}", .{res.term});
        return error.AuthFailed;
    }
    return parseResult(allocator, res.stdout) catch |err| {
        std.log.warn("gpauth output unparseable: {s}", .{@errorName(err)});
        return err;
    };
}

pub const Options = struct {
    binary: []const u8 = default_binary,
    server: []const u8,
    /// `"default"` | `"firefox"` | `"chrome"` | `"chromium"` | path.
    browser: []const u8 = "default",
    gateway: bool = false,
    ignore_tls_errors: bool = false,
};

pub fn parseResult(
    allocator: std.mem.Allocator,
    raw: []const u8,
) Error!std.json.Parsed(AuthData) {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");

    var doc = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
        return error.MalformedOutput;
    defer doc.deinit();

    const obj = switch (doc.value) {
        .object => |o| o,
        else => return error.MalformedOutput,
    };

    // 2.5.x uses camelCase tags; older releases used PascalCase.
    if (obj.get("failure") orelse obj.get("Failure")) |_| return error.AuthFailed;
    const success = obj.get("success") orelse obj.get("Success") orelse return error.MalformedOutput;
    const fields = switch (success) {
        .object => |o| o,
        else => return error.MalformedOutput,
    };

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();

    const username = try a.dupe(u8, try strField(fields, "username") orelse return error.MalformedOutput);
    return .{
        .arena = arena,
        .value = .{
            .username = username,
            .prelogin_cookie = try optStr(a, fields, "preloginCookie"),
            .portal_userauthcookie = try optStr(a, fields, "portalUserauthcookie"),
            .token = try optStr(a, fields, "token"),
        },
    };
}

fn strField(o: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => error.MalformedOutput,
    };
}

fn optStr(a: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const s = try strField(o, key) orelse return null;
    return try a.dupe(u8, s);
}
