//! gpservice client: WebSocket + ChaCha20-Poly1305 + reader thread.
//! The event callback fires on the reader thread; caller marshals to UI.

const std = @import("std");
const lockfile = @import("lockfile.zig");
const protocol = @import("protocol.zig");
const crypto = @import("crypto.zig");
const ws = @import("ws.zig");

pub const Error = error{
    ServiceNotRunning,
    InvalidApiKey,
    WriteFailed,
} || lockfile.Error || ws.Error || crypto.Error || std.Thread.SpawnError;

pub const EventCallback = *const fn (ctx: *anyopaque, event: protocol.WsEvent) void;

pub const Config = struct {
    api_key: []const u8,
    lock_path: []const u8 = lockfile.default_path,
    host: []const u8 = "127.0.0.1",
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    key: [crypto.key_length]u8,
    lock_path: []const u8,
    host: []const u8,

    state: std.atomic.Value(State) = .init(.idle),
    conn: ?ws.Conn = null,
    reader: ?std.Thread = null,
    write_mu: std.Thread.Mutex = .{},

    cb: ?struct { ctx: *anyopaque, f: EventCallback } = null,

    const State = enum(u8) { idle, running, stopping };

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Client {
        if (config.api_key.len != crypto.key_length) return error.InvalidApiKey;
        var key: [crypto.key_length]u8 = undefined;
        @memcpy(&key, config.api_key);
        return .{
            .allocator = allocator,
            .key = key,
            .lock_path = config.lock_path,
            .host = config.host,
        };
    }

    pub fn setEventCallback(self: *Client, ctx: *anyopaque, cb: EventCallback) void {
        self.cb = .{ .ctx = ctx, .f = cb };
    }

    pub fn start(self: *Client) Error!void {
        const info = lockfile.read(self.lock_path) catch |err| switch (err) {
            error.LockFileMissing => return error.ServiceNotRunning,
            else => |e| return e,
        };

        self.conn = try ws.Conn.connect(self.allocator, self.host, info.port, "/ws");
        errdefer {
            self.conn.?.close();
            self.conn = null;
            self.state.store(.idle, .release);
        }
        self.state.store(.running, .release);
        self.reader = try std.Thread.spawn(.{}, readerLoop, .{self});
    }

    pub fn stop(self: *Client) void {
        if (self.state.swap(.stopping, .acq_rel) != .running) return;
        if (self.conn) |*c| c.close();
        if (self.reader) |t| {
            t.join();
            self.reader = null;
        }
        self.conn = null;
        self.state.store(.idle, .release);
    }

    pub fn send(self: *Client, req: protocol.WsRequest) Error!void {
        const conn = if (self.conn) |*c| c else return error.ServiceNotRunning;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(req, .{}, &aw.writer);
        const plaintext = aw.written();

        const sealed = try crypto.seal(self.allocator, self.key, plaintext);
        defer self.allocator.free(sealed);

        self.write_mu.lock();
        defer self.write_mu.unlock();
        try conn.writeBinary(sealed);
    }

    fn readerLoop(self: *Client) void {
        while (self.state.load(.acquire) == .running) {
            const conn = if (self.conn) |*c| c else return;
            const frame = conn.readFrame() catch |err| {
                if (self.state.load(.acquire) == .running) {
                    std.log.warn("gpservice WS read failed: {s}", .{@errorName(err)});
                }
                return;
            };
            if (frame.opcode != .binary) continue;

            const plaintext = crypto.open(self.allocator, self.key, frame.payload) catch |err| {
                std.log.warn("gpservice frame decrypt failed: {s}", .{@errorName(err)});
                continue;
            };
            defer self.allocator.free(plaintext);

            var parsed = protocol.parseWsEvent(self.allocator, plaintext) catch |err| {
                std.log.warn("gpservice event parse failed: {s}", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();

            if (self.cb) |cb| cb.f(cb.ctx, parsed.value);
        }
    }
};
