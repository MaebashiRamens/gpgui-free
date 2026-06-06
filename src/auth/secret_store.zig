//! libsecret-backed `cookie_cache.Store`. Keyed by `(portal, user)`;
//! cookie + expiry are JSON-packed into the password field so they
//! don't appear in attribute searches.

const std = @import("std");
const glib = @import("glib");
const secret = @import("secret");

const cache = @import("cookie_cache.zig");

const schema_name: [*:0]const u8 = "org.gpguifree.PreloginCookie";

const schema: secret.Schema = .{
    .f_name = schema_name,
    .f_flags = .{},
    .f_attributes = blk: {
        var arr = [_]secret.SchemaAttribute{.{ .f_name = null, .f_type = .string }} ** 32;
        arr[0] = .{ .f_name = "portal", .f_type = .string };
        arr[1] = .{ .f_name = "user", .f_type = .string };
        break :blk arr;
    },
    .f_reserved = 0,
    .f_reserved1 = null,
    .f_reserved2 = null,
    .f_reserved3 = null,
    .f_reserved4 = null,
    .f_reserved5 = null,
    .f_reserved6 = null,
    .f_reserved7 = null,
};

pub const SecretStore = struct {
    allocator: std.mem.Allocator,
    /// Strings returned by `load` live here; reset on each call.
    scratch: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) SecretStore {
        return .{
            .allocator = allocator,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *SecretStore) void {
        self.scratch.deinit();
    }

    pub fn store(self: *SecretStore) cache.Store {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .save = saveImpl,
                .load = loadImpl,
                .forget = forgetImpl,
            },
        };
    }

    fn buildAttributes(portal_z: [*:0]const u8, user_z: [*:0]const u8) *glib.HashTable {
        const hash_fn: *const fn (?*const anyopaque) callconv(.c) c_uint = @ptrCast(&glib.strHash);
        const equal_fn: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int = @ptrCast(&glib.strEqual);
        const tbl = glib.HashTable.new(hash_fn, equal_fn);
        _ = glib.HashTable.insert(tbl, @ptrCast(@constCast(@as([*:0]const u8, "portal"))), @ptrCast(@constCast(portal_z)));
        _ = glib.HashTable.insert(tbl, @ptrCast(@constCast(@as([*:0]const u8, "user"))), @ptrCast(@constCast(user_z)));
        return tbl;
    }

    fn saveImpl(ctx: *anyopaque, e: cache.Entry) cache.Error!void {
        const self: *SecretStore = @ptrCast(@alignCast(ctx));
        _ = self.scratch.reset(.retain_capacity);
        const arena = self.scratch.allocator();

        const portal_z = try arena.dupeZ(u8, e.portal);
        const user_z = try arena.dupeZ(u8, e.user);

        var aw: std.Io.Writer.Allocating = .init(arena);
        defer aw.deinit();
        std.json.Stringify.value(StoredBlob{
            .cookie = e.cookie,
            .expires_at_unix = e.expires_at_unix,
        }, .{}, &aw.writer) catch return error.KeyringUnavailable;
        const password_z = try arena.dupeZ(u8, aw.written());

        const label_z = try std.fmt.allocPrintSentinel(
            arena,
            "GlobalProtect cookie — {s}@{s}",
            .{ e.user, e.portal },
            0,
        );

        const tbl = buildAttributes(portal_z, user_z);
        defer glib.HashTable.destroy(tbl);

        var err: ?*glib.Error = null;
        const ok = secret.passwordStorevSync(&schema, tbl, null, label_z, password_z, null, &err);
        if (ok == 0) {
            logGlibError("password store", err);
            if (err) |e2| glib.Error.free(e2);
            return error.KeyringUnavailable;
        }
    }

    fn loadImpl(ctx: *anyopaque, portal: []const u8, user: []const u8) cache.Error!cache.Entry {
        const self: *SecretStore = @ptrCast(@alignCast(ctx));
        _ = self.scratch.reset(.retain_capacity);
        const arena = self.scratch.allocator();

        const portal_z = try arena.dupeZ(u8, portal);
        const user_z = try arena.dupeZ(u8, user);

        const tbl = buildAttributes(portal_z, user_z);
        defer glib.HashTable.destroy(tbl);

        var err: ?*glib.Error = null;
        const raw_password = secret.passwordLookupvSync(&schema, tbl, null, &err) orelse {
            if (err) |e| {
                logGlibError("password lookup", err);
                glib.Error.free(e);
                return error.KeyringUnavailable;
            }
            return error.EntryNotFound;
        };
        defer secret.passwordFree(raw_password);

        const password = std.mem.span(raw_password);
        const parsed = std.json.parseFromSlice(StoredBlob, arena, password, .{
            .ignore_unknown_fields = true,
        }) catch return error.EntryNotFound;
        defer parsed.deinit();

        return .{
            .portal = try arena.dupe(u8, portal),
            .user = try arena.dupe(u8, user),
            .cookie = try arena.dupe(u8, parsed.value.cookie),
            .expires_at_unix = parsed.value.expires_at_unix,
        };
    }

    fn forgetImpl(ctx: *anyopaque, portal: []const u8, user: []const u8) cache.Error!void {
        const self: *SecretStore = @ptrCast(@alignCast(ctx));
        _ = self.scratch.reset(.retain_capacity);
        const arena = self.scratch.allocator();

        const portal_z = try arena.dupeZ(u8, portal);
        const user_z = try arena.dupeZ(u8, user);

        const tbl = buildAttributes(portal_z, user_z);
        defer glib.HashTable.destroy(tbl);

        var err: ?*glib.Error = null;
        const removed = secret.passwordClearvSync(&schema, tbl, null, &err);
        if (err) |e| {
            logGlibError("password clear", err);
            glib.Error.free(e);
            return error.KeyringUnavailable;
        }
        if (removed == 0) return error.EntryNotFound;
    }

    const StoredBlob = struct {
        cookie: []const u8,
        expires_at_unix: i64,
    };

    fn logGlibError(op: []const u8, err: ?*glib.Error) void {
        if (err) |e| if (e.f_message) |msg| {
            std.log.warn("secret_store: {s} failed: {s}", .{ op, std.mem.span(msg) });
            return;
        };
        std.log.warn("secret_store: {s} failed (no glib message)", .{op});
    }
};
