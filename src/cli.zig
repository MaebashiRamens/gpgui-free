//! Mirrors gpservice's launch contract:
//!   `gpgui --api-key-on-stdin [--minimized]` + base64 key on stdin.
//! See `crates/gpapi/src/process/gui_launcher.rs` upstream.

const std = @import("std");
const build_options = @import("build_options");

pub const Args = struct {
    api_key_on_stdin: bool = false,
    minimized: bool = false,
    show_version: bool = false,
    show_help: bool = false,
};

pub const ParseError = error{UnknownArgument};

pub fn parse(argv: []const [:0]const u8) ParseError!Args {
    var out: Args = .{};
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--api-key-on-stdin")) {
            out.api_key_on_stdin = true;
        } else if (std.mem.eql(u8, arg, "--minimized")) {
            out.minimized = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            out.show_version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out.show_help = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return out;
}

/// `"<name> <version> (<metadata>)"`. The 2nd token must match
/// gpservice's `CARGO_PKG_VERSION` or gpservice spawns gpgui-helper
/// to redownload the proprietary gpgui. See `docs/DISTRIBUTION.md`.
pub fn versionString(buf: []u8) ![]const u8 {
    var spoof_buf: [64]u8 = undefined;
    const spoofed = probeGpserviceVersion(&spoof_buf) catch null;
    const reported = spoofed orelse build_options.version;
    return std.fmt.bufPrint(buf, "gpgui-free {s} (real={s})", .{
        reported,
        build_options.version,
    });
}

/// 2nd whitespace token of `gpservice --version` into `buf`.
fn probeGpserviceVersion(buf: []u8) ![]const u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "gpservice", "--version" },
        .max_output_bytes = 256,
    }) catch return error.GpserviceNotFound;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) return error.GpserviceNotFound;

    var it = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    _ = it.next() orelse return error.UnexpectedVersionFormat;
    const token = it.next() orelse return error.UnexpectedVersionFormat;
    if (token.len > buf.len) return error.UnexpectedVersionFormat;
    @memcpy(buf[0..token.len], token);
    return buf[0..token.len];
}

pub const help_text: []const u8 =
    \\Usage: gpgui-free [OPTIONS]
    \\
    \\Open source GTK4 GUI for globalprotect-openconnect.
    \\
    \\Options:
    \\  --api-key-on-stdin   Read the shared API key from stdin (base64)
    \\  --minimized          Start hidden, surface via the system tray
    \\  --version, -V        Print version and exit
    \\  --help, -h           Print this help and exit
    \\
;
