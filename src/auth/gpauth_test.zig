const std = @import("std");
const gpauth = @import("gpauth.zig");

test "parseResult: success with prelogin cookie" {
    const raw =
        \\{"Success":{"username":"alice","preloginCookie":"abcdef","portalUserauthcookie":"empty","token":null}}
    ;
    var parsed = try gpauth.parseResult(std.testing.allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("alice", parsed.value.username);
    try std.testing.expectEqualStrings("abcdef", parsed.value.prelogin_cookie.?);
    try std.testing.expect(parsed.value.token == null);
}

test "parseResult: lowercase 'success' from gpauth 2.5+" {
    const raw =
        \\{"success":{"username":"bob","preloginCookie":"xyz"}}
    ;
    var parsed = try gpauth.parseResult(std.testing.allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bob", parsed.value.username);
}

test "parseResult: failure variant maps to AuthFailed" {
    const raw =
        \\{"Failure":"timed out"}
    ;
    try std.testing.expectError(
        error.AuthFailed,
        gpauth.parseResult(std.testing.allocator, raw),
    );
}

test "parseResult: garbage rejected" {
    try std.testing.expectError(
        error.MalformedOutput,
        gpauth.parseResult(std.testing.allocator, "not json"),
    );
}

test "parseResult: missing username rejected" {
    const raw =
        \\{"Success":{"preloginCookie":"abcdef"}}
    ;
    try std.testing.expectError(
        error.MalformedOutput,
        gpauth.parseResult(std.testing.allocator, raw),
    );
}
