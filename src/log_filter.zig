//! Silences known-noisy warnings from GTK/Adwaita/Vulkan/IM stacks.
//! Anything not matching `noisy_patterns` passes through unchanged.

const std = @import("std");
const glib = @import("glib");

const noisy_patterns = [_][]const u8{
    "vkAcquireNextImageKHR",
    "No IM module matching",
    "Unable to acquire session bus",
    "Unable to get the session bus",
    "Unable to get session bus",
    "gtk-application-prefer-dark-theme",
    "Widget reports min height",
    "libayatana-appindicator is deprecated",
    "vkCreateSwapchainKHR",
};

pub fn install() void {
    glib.logSetWriterFunc(&writer, null, null);
}

fn writer(
    level: glib.LogLevelFlags,
    fields: [*]const glib.LogField,
    n_fields: usize,
    _: ?*anyopaque,
) callconv(.c) glib.LogWriterOutput {
    if (findMessage(fields[0..n_fields])) |msg| {
        for (noisy_patterns) |needle| {
            if (std.mem.indexOf(u8, msg, needle) != null) return .handled;
        }
    }
    return glib.logWriterDefault(level, fields, n_fields, null);
}

fn findMessage(fields: []const glib.LogField) ?[]const u8 {
    for (fields) |f| {
        const key = std.mem.span(f.f_key orelse continue);
        if (!std.mem.eql(u8, key, "MESSAGE")) continue;
        const raw = f.f_value orelse return null;
        // f_length >= 0 means arbitrary bytes, not NUL-terminated.
        if (f.f_length >= 0) {
            const bytes: [*]const u8 = @ptrCast(raw);
            return bytes[0..@intCast(f.f_length)];
        }
        return std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    }
    return null;
}
