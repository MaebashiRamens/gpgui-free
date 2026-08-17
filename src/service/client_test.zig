const std = @import("std");
const client = @import("client.zig");
const crypto = @import("crypto.zig");
const protocol = @import("protocol.zig");

test "init rejects wrong key length" {
    var dummy: [10]u8 = @splat(0);
    try std.testing.expectError(error.InvalidApiKey, client.Client.init(std.testing.allocator, .{ .api_key = &dummy }));
}

test "send before start returns ServiceNotRunning" {
    const key: [crypto.key_length]u8 = @splat(0);
    var c = try client.Client.init(std.testing.allocator, .{ .api_key = &key });
    defer c.stop();
    try std.testing.expectError(
        error.ServiceNotRunning,
        c.send(.{ .Disconnect = .{} }),
    );
}

// Fake gpservice: accepts one WS client, greets with the 101 response and
// a PING coalesced into one write (matching the real service), then talks
// sealed frames.
const FakeServer = struct {
    key: [crypto.key_length]u8,
    listener: *std.net.Server,
    got_request: std.Thread.ResetEvent = .{},
    request_json: [256]u8 = undefined,
    request_len: usize = 0,
    fail: ?anyerror = null,

    fn runHappy(self: *FakeServer) void {
        self.serveHappy() catch |err| {
            self.fail = err;
            self.got_request.set();
        };
    }

    fn serveHappy(self: *FakeServer) !void {
        const conn = try self.listener.accept();
        defer conn.stream.close();

        try handshakeAndPing(conn.stream);

        var pong: [16]u8 = undefined;
        const p = try readClientFrame(conn.stream, &pong);
        if (p.opcode != 0x0a or !std.mem.eql(u8, pong[0..p.len], "Hi")) return error.BadPong;

        const sealed = try crypto.seal(std.testing.allocator, self.key, "{\"VpnState\":\"disconnected\"}");
        defer std.testing.allocator.free(sealed);
        try writeServerBinary(conn.stream, sealed);

        var frame: [512]u8 = undefined;
        const f = try readClientFrame(conn.stream, &frame);
        if (f.opcode != 0x02) return error.BadFrame;
        const plain = try crypto.open(std.testing.allocator, self.key, frame[0..f.len]);
        defer std.testing.allocator.free(plain);
        self.request_len = @min(plain.len, self.request_json.len);
        @memcpy(self.request_json[0..self.request_len], plain[0..self.request_len]);
        self.got_request.set();

        var drain: [64]u8 = undefined;
        while (true) {
            const n = conn.stream.read(&drain) catch 0;
            if (n == 0) break;
        }
    }

    fn runDrop(self: *FakeServer) void {
        self.serveDrop() catch |err| {
            self.fail = err;
        };
    }

    fn serveDrop(self: *FakeServer) !void {
        const conn = try self.listener.accept();
        try handshakeAndPing(conn.stream);
        conn.stream.close();
    }
};

fn handshakeAndPing(stream: std.net.Stream) !void {
    var req: [1024]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, req[0..len], "\r\n\r\n") == null) {
        const n = try stream.read(req[len..]);
        if (n == 0) return error.PeerClosed;
        len += n;
    }
    const key_hdr = "Sec-WebSocket-Key: ";
    const ks = (std.mem.indexOf(u8, req[0..len], key_hdr) orelse return error.NoKey) + key_hdr.len;
    const ke = std.mem.indexOfPos(u8, req[0..len], ks, "\r\n") orelse return error.NoKey;

    var h = std.crypto.hash.Sha1.init(.{});
    h.update(req[ks..ke]);
    h.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);

    var resp: [512]u8 = undefined;
    const out = try std.fmt.bufPrint(
        &resp,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n" ++
            "\x89\x02Hi",
        .{&accept},
    );
    try stream.writeAll(out);
}

fn readClientFrame(stream: std.net.Stream, payload: []u8) !struct { opcode: u8, len: usize } {
    var hdr: [2]u8 = undefined;
    try readExact(stream, &hdr);
    const opcode: u8 = hdr[0] & 0x0f;
    if (hdr[1] & 0x80 == 0) return error.UnmaskedClientFrame;
    const len: usize = hdr[1] & 0x7f;
    if (len >= 126 or len > payload.len) return error.FrameTooLong;
    var mask: [4]u8 = undefined;
    try readExact(stream, &mask);
    try readExact(stream, payload[0..len]);
    for (0..len) |i| payload[i] ^= mask[i & 3];
    return .{ .opcode = opcode, .len = len };
}

fn writeServerBinary(stream: std.net.Stream, payload: []const u8) !void {
    if (payload.len >= 126) return error.FrameTooLong;
    try stream.writeAll(&[_]u8{ 0x82, @intCast(payload.len) });
    try stream.writeAll(payload);
}

fn readExact(stream: std.net.Stream, dst: []u8) !void {
    var total: usize = 0;
    while (total < dst.len) {
        const n = try stream.read(dst[total..]);
        if (n == 0) return error.PeerClosed;
        total += n;
    }
}

const Capture = struct {
    got_event: std.Thread.ResetEvent = .{},
    closed: std.Thread.ResetEvent = .{},
    disconnected: bool = false,

    fn onEvent(ctx: *anyopaque, event: protocol.WsEvent) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (event == .VpnState and event.VpnState == .Disconnected) self.disconnected = true;
        self.got_event.set();
    }

    fn onClose(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.closed.set();
    }
};

fn writeLockFile(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator, port: u16) ![]u8 {
    var f = try tmp.dir.createFile("gpservice.lock", .{});
    defer f.close();
    var buf: [32]u8 = undefined;
    try f.writeAll(try std.fmt.bufPrint(&buf, "1:{d}", .{port}));
    return tmp.dir.realpathAlloc(allocator, "gpservice.lock");
}

test "start/event/send/stop round-trip against a fake gpservice" {
    const a = std.testing.allocator;
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock_path = try writeLockFile(&tmp, a, listener.listen_address.getPort());
    defer a.free(lock_path);

    const key: [crypto.key_length]u8 = @splat(7);
    var srv = FakeServer{ .key = key, .listener = &listener };
    const th = try std.Thread.spawn(.{}, FakeServer.runHappy, .{&srv});
    defer th.join();

    var cap = Capture{};
    var c = try client.Client.init(a, .{ .api_key = &key, .lock_path = lock_path });
    defer c.stop();
    c.setEventCallback(&cap, &Capture.onEvent);
    try c.start();

    // The event only arrives if the client answered the coalesced PING.
    try cap.got_event.timedWait(5 * std.time.ns_per_s);
    try std.testing.expect(cap.disconnected);

    try c.send(.{ .Disconnect = .{} });
    try srv.got_request.timedWait(5 * std.time.ns_per_s);
    if (srv.fail) |err| return err;
    try std.testing.expect(
        std.mem.indexOf(u8, srv.request_json[0..srv.request_len], "\"Disconnect\":null") != null,
    );
}

test "close callback fires when the service drops the connection" {
    const a = std.testing.allocator;
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock_path = try writeLockFile(&tmp, a, listener.listen_address.getPort());
    defer a.free(lock_path);

    const key: [crypto.key_length]u8 = @splat(9);
    var srv = FakeServer{ .key = key, .listener = &listener };
    const th = try std.Thread.spawn(.{}, FakeServer.runDrop, .{&srv});
    defer th.join();

    var cap = Capture{};
    var c = try client.Client.init(a, .{ .api_key = &key, .lock_path = lock_path });
    defer c.stop();
    c.setEventCallback(&cap, &Capture.onEvent);
    c.setCloseCallback(&cap, &Capture.onClose);
    try c.start();

    try cap.closed.timedWait(5 * std.time.ns_per_s);
    if (srv.fail) |err| return err;
}
