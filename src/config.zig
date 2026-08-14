//! `$XDG_CONFIG_HOME/gpgui-free/config.json`. No secrets here —
//! cookies live in libsecret via `auth/secret_store.zig`.

const std = @import("std");

const dir_name = "gpgui-free";
const file_name = "config.json";

/// `gateway`: user-entered host IS the gateway.
/// `portal`: discover gateways via `/global-protect/getconfig.esp` first.
pub const Mode = enum { gateway, portal };

pub const Config = struct {
    last_portal: ?[]const u8 = null,
    last_mode: Mode = .gateway,
    /// Stale when `last_portal` changes — caller must drop it then.
    last_user: ?[]const u8 = null,
    /// Asks gpservice to extend the session instead of dropping the
    /// tunnel at `user_expires`. Wire name: `allowExtendSession`.
    allow_extend_session: bool = false,
    /// Tunnel MTU; 0 lets openconnect derive it from the interface.
    mtu: u32 = 0,
    disable_ipv6: bool = false,
    /// Forces TLS transport; slower but survives UDP-hostile networks.
    no_dtls: bool = false,
};

/// Caller calls `parsed.deinit()`.
pub fn load(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try filePath(&path_buf, allocator);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return emptyParsed(allocator),
        else => return err,
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = try file.readAll(&buf);
    // alloc_always: parsed strings must outlive the stack-local `buf`.
    return std.json.parseFromSlice(Config, allocator, buf[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.log.warn("config parse failed: {s}", .{@errorName(err)});
        return emptyParsed(allocator);
    };
}

pub fn save(allocator: std.mem.Allocator, cfg: Config) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try filePath(&path_buf, allocator);

    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(cfg, .{}, &aw.writer);

    // Write-then-rename so a crash mid-write can't corrupt the config.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    {
        const file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer file.close();
        try file.writeAll(aw.written());
    }
    try std.fs.renameAbsolute(tmp, path);
}

fn filePath(buf: []u8, allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ xdg, dir_name, file_name });
    } else |_| {}

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fmt.bufPrint(buf, "{s}/.config/{s}/{s}", .{ home, dir_name, file_name });
}

fn emptyParsed(allocator: std.mem.Allocator) !std.json.Parsed(Config) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return .{ .arena = arena, .value = .{} };
}

test "emptyParsed yields default Config" {
    var parsed = try emptyParsed(std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.last_portal == null);
}

test "parse tolerates configs written before the tunnel knobs" {
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator,
        \\{"last_portal":"vpn.example.com","last_mode":"gateway","last_user":"alice"}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 0), parsed.value.mtu);
    try std.testing.expect(!parsed.value.disable_ipv6);
    try std.testing.expect(!parsed.value.no_dtls);
    try std.testing.expect(!parsed.value.allow_extend_session);
}

test "tunnel knobs survive a stringify/parse round-trip" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(Config{
        .last_portal = "vpn.example.com",
        .mtu = 1300,
        .disable_ipv6 = true,
        .no_dtls = true,
    }, .{}, &aw.writer);

    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, aw.written(), .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1300), parsed.value.mtu);
    try std.testing.expect(parsed.value.disable_ipv6);
    try std.testing.expect(parsed.value.no_dtls);
    try std.testing.expectEqualStrings("vpn.example.com", parsed.value.last_portal.?);
}
