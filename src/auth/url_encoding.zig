//! Percent-encoding for `application/x-www-form-urlencoded` payloads.

const std = @import("std");

pub fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (isUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

pub fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}
