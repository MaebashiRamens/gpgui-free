const std = @import("std");
const lockfile = @import("lockfile.zig");

test "well-formed lockfile" {
    const info = try lockfile.parse("12345:38213\n");
    try std.testing.expectEqual(@as(u32, 12345), info.pid);
    try std.testing.expectEqual(@as(u16, 38213), info.port);
}

test "leading/trailing whitespace is ignored" {
    const info = try lockfile.parse("  77:1024  \n");
    try std.testing.expectEqual(@as(u32, 77), info.pid);
    try std.testing.expectEqual(@as(u16, 1024), info.port);
}

test "missing port" {
    try std.testing.expectError(error.LockFileMalformed, lockfile.parse("12345"));
}

test "extra fields" {
    try std.testing.expectError(error.LockFileMalformed, lockfile.parse("1:2:3"));
}

test "non-numeric pid" {
    try std.testing.expectError(error.LockFileMalformed, lockfile.parse("abc:1024"));
}

test "port out of range" {
    try std.testing.expectError(error.LockFileMalformed, lockfile.parse("1:70000"));
}
