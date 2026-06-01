const std = @import("std");
const cli = @import("cli.zig");

test "parse: empty argv leaves defaults" {
    const argv: []const [:0]const u8 = &.{"gpgui-free"};
    const args = try cli.parse(argv);
    try std.testing.expect(!args.api_key_on_stdin);
    try std.testing.expect(!args.minimized);
    try std.testing.expect(!args.show_version);
}

test "parse: --api-key-on-stdin and --minimized together" {
    const argv: []const [:0]const u8 = &.{ "gpgui-free", "--api-key-on-stdin", "--minimized" };
    const args = try cli.parse(argv);
    try std.testing.expect(args.api_key_on_stdin);
    try std.testing.expect(args.minimized);
}

test "parse: short and long --version are equivalent" {
    const long: []const [:0]const u8 = &.{ "gpgui-free", "--version" };
    const short: []const [:0]const u8 = &.{ "gpgui-free", "-V" };
    try std.testing.expect((try cli.parse(long)).show_version);
    try std.testing.expect((try cli.parse(short)).show_version);
}

test "parse: unknown argument errors" {
    const argv: []const [:0]const u8 = &.{ "gpgui-free", "--nope" };
    try std.testing.expectError(error.UnknownArgument, cli.parse(argv));
}

test "versionString matches gpservice's probe regex" {
    var buf: [128]u8 = undefined;
    const s = try cli.versionString(&buf);
    var it = std.mem.tokenizeAny(u8, s, " ");
    try std.testing.expectEqualStrings("gpgui-free", it.next().?);
    try std.testing.expect(it.next().?.len > 0);
}
