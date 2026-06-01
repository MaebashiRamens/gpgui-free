//! PRELOGIN-COOKIE cache so repeat connects can skip SAML.

const std = @import("std");

pub const Entry = struct {
    portal: []const u8,
    user: []const u8,
    cookie: []const u8,
    /// Hint only; the portal makes the final call.
    expires_at_unix: i64,
};

pub const Error = error{
    KeyringUnavailable,
    EntryNotFound,
    EntryExpired,
} || std.mem.Allocator.Error;

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        save: *const fn (ctx: *anyopaque, e: Entry) Error!void,
        load: *const fn (ctx: *anyopaque, portal: []const u8, user: []const u8) Error!Entry,
        forget: *const fn (ctx: *anyopaque, portal: []const u8, user: []const u8) Error!void,
    };

    pub fn save(self: Store, e: Entry) Error!void {
        return self.vtable.save(self.ptr, e);
    }
    pub fn load(self: Store, portal: []const u8, user: []const u8) Error!Entry {
        return self.vtable.load(self.ptr, portal, user);
    }
    pub fn forget(self: Store, portal: []const u8, user: []const u8) Error!void {
        return self.vtable.forget(self.ptr, portal, user);
    }
};

/// 60 s skew guard against portal clock drift.
pub fn isUsable(entry: Entry, now_unix: i64) bool {
    return entry.expires_at_unix > now_unix + 60;
}

pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(OwnedEntry),

    const OwnedEntry = struct {
        portal: []u8,
        user: []u8,
        cookie: []u8,
        expires_at_unix: i64,
    };

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *MemoryStore) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.portal);
            self.allocator.free(e.user);
            self.allocator.free(e.cookie);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn store(self: *MemoryStore) Store {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .save = saveImpl,
                .load = loadImpl,
                .forget = forgetImpl,
            },
        };
    }

    fn findIndex(self: *MemoryStore, portal: []const u8, user: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.portal, portal) and std.mem.eql(u8, e.user, user)) return i;
        }
        return null;
    }

    fn saveImpl(ctx: *anyopaque, e: Entry) Error!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        if (self.findIndex(e.portal, e.user)) |i| {
            self.allocator.free(self.entries.items[i].cookie);
            self.entries.items[i].cookie = try self.allocator.dupe(u8, e.cookie);
            self.entries.items[i].expires_at_unix = e.expires_at_unix;
            return;
        }
        try self.entries.append(self.allocator, .{
            .portal = try self.allocator.dupe(u8, e.portal),
            .user = try self.allocator.dupe(u8, e.user),
            .cookie = try self.allocator.dupe(u8, e.cookie),
            .expires_at_unix = e.expires_at_unix,
        });
    }

    fn loadImpl(ctx: *anyopaque, portal: []const u8, user: []const u8) Error!Entry {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        const i = self.findIndex(portal, user) orelse return error.EntryNotFound;
        const e = self.entries.items[i];
        return .{
            .portal = e.portal,
            .user = e.user,
            .cookie = e.cookie,
            .expires_at_unix = e.expires_at_unix,
        };
    }

    fn forgetImpl(ctx: *anyopaque, portal: []const u8, user: []const u8) Error!void {
        const self: *MemoryStore = @ptrCast(@alignCast(ctx));
        const i = self.findIndex(portal, user) orelse return error.EntryNotFound;
        const e = self.entries.swapRemove(i);
        self.allocator.free(e.portal);
        self.allocator.free(e.user);
        self.allocator.free(e.cookie);
    }
};
