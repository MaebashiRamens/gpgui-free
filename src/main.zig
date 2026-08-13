//! gpgui-free — open source GTK4 + libadwaita replacement for `gpgui`.

const std = @import("std");
const cli = @import("cli.zig");
const App = @import("app.zig").App;
const log_filter = @import("log_filter.zig");

// `std.process.exit` skips defers, so all cleanup-carrying scopes live
// in `run` and exit happens only after it returns.
pub fn main() !void {
    std.process.exit(try run());
}

fn run() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = cli.parse(argv) catch |err| switch (err) {
        error.UnknownArgument => {
            try std.fs.File.stderr().writeAll("gpgui-free: unknown argument\n");
            try std.fs.File.stderr().writeAll(cli.help_text);
            return 2;
        },
    };

    if (args.show_version) {
        var buf: [128]u8 = undefined;
        const version = try cli.versionString(&buf);
        try std.fs.File.stdout().writeAll(version);
        try std.fs.File.stdout().writeAll("\n");
        return 0;
    }
    if (args.show_help) {
        try std.fs.File.stdout().writeAll(cli.help_text);
        return 0;
    }

    // A write to the WS socket after gpservice dies must surface as
    // EPIPE, not kill the process.
    std.posix.sigaction(std.posix.SIG.PIPE, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    log_filter.install();

    var app = App.init(allocator, args.minimized);
    defer app.deinit();

    if (args.api_key_on_stdin) {
        var key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &key);
        try readApiKey(&key);
        app.attachApiKey(&key);
    }

    return @intCast(app.run());
}

fn readApiKey(out: *[32]u8) !void {
    var encoded: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded);
    const n = try std.fs.File.stdin().read(&encoded);

    const trimmed = std.mem.trim(u8, encoded[0..n], " \t\r\n");
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(trimmed);
    if (decoded_len != out.len) return error.InvalidApiKey;
    try std.base64.standard.Decoder.decode(out, trimmed);
}
