//! gpgui-free — open source GTK4 + libadwaita replacement for `gpgui`.

const std = @import("std");
const cli = @import("cli.zig");
const App = @import("app.zig").App;
const log_filter = @import("log_filter.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = cli.parse(argv) catch |err| switch (err) {
        error.UnknownArgument => {
            try std.fs.File.stderr().writeAll("gpgui-free: unknown argument\n");
            try std.fs.File.stderr().writeAll(cli.help_text);
            std.process.exit(2);
        },
    };

    if (args.show_version) {
        var buf: [128]u8 = undefined;
        const version = try cli.versionString(&buf);
        try std.fs.File.stdout().writeAll(version);
        try std.fs.File.stdout().writeAll("\n");
        return;
    }
    if (args.show_help) {
        try std.fs.File.stdout().writeAll(cli.help_text);
        return;
    }

    log_filter.install();

    var app = App.init(allocator, args.minimized);
    defer app.deinit();

    if (args.api_key_on_stdin) {
        var key: [32]u8 = undefined;
        try readApiKey(&key);
        app.attachApiKey(&key);
    }

    std.process.exit(@intCast(app.run()));
}

fn readApiKey(out: *[32]u8) !void {
    var encoded: [256]u8 = undefined;
    const n = try std.fs.File.stdin().read(&encoded);

    const trimmed = std.mem.trim(u8, encoded[0..n], " \t\r\n");
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(trimmed);
    if (decoded_len != out.len) return error.InvalidApiKey;
    try std.base64.standard.Decoder.decode(out, trimmed);
}
