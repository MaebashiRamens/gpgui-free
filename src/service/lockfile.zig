//! `"<pid>:<port>"` lockfile written by gpservice
//! (`crates/gpapi/src/utils/lock_file.rs` upstream).

const std = @import("std");

pub const default_path: []const u8 = "/var/run/gpservice.lock";

pub const LockInfo = struct {
    pid: u32,
    port: u16,
};

pub const Error = error{
    LockFileMissing,
    LockFileMalformed,
} || std.fs.File.OpenError || std.fs.File.ReadError;

pub fn read(path: []const u8) Error!LockInfo {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.LockFileMissing,
        else => return err,
    };
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    return parse(buf[0..n]);
}

pub fn parse(content: []const u8) error{LockFileMalformed}!LockInfo {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    var parts = std.mem.splitScalar(u8, trimmed, ':');

    const pid_s = parts.next() orelse return error.LockFileMalformed;
    const port_s = parts.next() orelse return error.LockFileMalformed;
    if (parts.next() != null) return error.LockFileMalformed;

    return .{
        .pid = std.fmt.parseInt(u32, pid_s, 10) catch return error.LockFileMalformed,
        .port = std.fmt.parseInt(u16, port_s, 10) catch return error.LockFileMalformed,
    };
}
