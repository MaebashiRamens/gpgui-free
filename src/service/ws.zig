//! RFC 6455 WebSocket client, localhost-only, no internal locking.

const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,
};

pub const Frame = struct {
    opcode: Opcode,
    /// Lives in `Conn.arena`; invalidated on the next `readFrame`.
    payload: []u8,
};

pub const Error = error{
    HandshakeFailed,
    InvalidFrame,
    InvalidIPAddressFormat,
    FrameTooLarge,
    PeerClosed,
    UnexpectedMaskedServerFrame,
    OutOfMemory,
} || std.net.TcpConnectToAddressError || std.net.Stream.ReadError || std.net.Stream.WriteError;

const ws_guid: []const u8 = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const max_payload: u64 = 16 * 1024 * 1024;

pub const Conn = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    arena: std.heap.ArenaAllocator,
    /// Serializes every frame write — sends, auto-PONGs, and close.
    write_mu: std.Thread.Mutex = .{},
    /// Frame bytes the server coalesced with the 101 response; drained
    /// before the socket is read.
    leftover: []u8 = &.{},
    leftover_off: usize = 0,

    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
    ) Error!Conn {
        const addr = try std.net.Address.parseIp(host, port);
        const stream = try std.net.tcpConnectToAddress(addr);
        errdefer stream.close();

        var resp_buf: [4096]u8 = undefined;
        const trailing = try handshake(stream, host, port, path, &resp_buf);

        return .{
            .allocator = allocator,
            .stream = stream,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .leftover = try allocator.dupe(u8, trailing),
        };
    }

    /// Thread-safe; wakes a reader blocked in `read` so it can be joined.
    /// Resources stay valid until `deinit`.
    pub fn shutdown(self: *Conn) void {
        self.writeFrame(.close, &.{}) catch {};
        std.posix.shutdown(self.stream.handle, .both) catch {};
    }

    /// Only after the reader thread is joined — frees its read arena.
    pub fn deinit(self: *Conn) void {
        self.stream.close();
        self.arena.deinit();
        self.allocator.free(self.leftover);
    }

    pub fn writeBinary(self: *Conn, payload: []const u8) Error!void {
        return self.writeFrame(.binary, payload);
    }

    fn writeFrame(self: *Conn, opcode: Opcode, payload: []const u8) Error!void {
        self.write_mu.lock();
        defer self.write_mu.unlock();

        var header: [14]u8 = undefined;
        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));

        var header_len: usize = 2;
        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= std.math.maxInt(u16)) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], payload.len, .big);
            header_len = 10;
        }

        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);
        @memcpy(header[header_len..][0..4], &mask_key);
        header_len += 4;

        try self.stream.writeAll(header[0..header_len]);

        var buf: [4096]u8 = undefined;
        var i: usize = 0;
        while (i < payload.len) {
            const n = @min(buf.len, payload.len - i);
            for (0..n) |k| buf[k] = payload[i + k] ^ mask_key[(i + k) & 3];
            try self.stream.writeAll(buf[0..n]);
            i += n;
        }
    }

    /// Auto-replies to PING, returns `error.PeerClosed` on CLOSE,
    /// concatenates continuation frames into one payload.
    pub fn readFrame(self: *Conn) Error!Frame {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        var assembled: std.ArrayList(u8) = .empty;
        var first_opcode: ?Opcode = null;

        while (true) {
            const raw = try self.readRawFrame(a);
            switch (raw.opcode) {
                .ping => {
                    try self.writeFrame(.pong, raw.payload);
                    continue;
                },
                .pong => continue,
                .close => return error.PeerClosed,
                .text, .binary => {
                    first_opcode = raw.opcode;
                    try assembled.appendSlice(a, raw.payload);
                },
                .continuation => {
                    if (first_opcode == null) return error.InvalidFrame;
                    try assembled.appendSlice(a, raw.payload);
                },
                _ => return error.InvalidFrame,
            }
            if (raw.fin) break;
        }

        return .{
            .opcode = first_opcode orelse return error.InvalidFrame,
            .payload = assembled.items,
        };
    }

    const RawFrame = struct {
        fin: bool,
        opcode: Opcode,
        payload: []u8,
    };

    fn readRawFrame(self: *Conn, a: std.mem.Allocator) Error!RawFrame {
        var hdr: [2]u8 = undefined;
        try self.readFull(&hdr);

        const fin = (hdr[0] & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(hdr[0] & 0x0f);
        const masked = (hdr[1] & 0x80) != 0;
        if (masked) return error.UnexpectedMaskedServerFrame;

        const payload_len: u64 = switch (hdr[1] & 0x7f) {
            127 => blk: {
                var ext: [8]u8 = undefined;
                try self.readFull(&ext);
                break :blk std.mem.readInt(u64, &ext, .big);
            },
            126 => blk: {
                var ext: [2]u8 = undefined;
                try self.readFull(&ext);
                break :blk std.mem.readInt(u16, &ext, .big);
            },
            else => |n| n,
        };
        if (payload_len > max_payload) return error.FrameTooLarge;

        const payload = try a.alloc(u8, @intCast(payload_len));
        try self.readFull(payload);
        return .{ .fin = fin, .opcode = opcode, .payload = payload };
    }

    fn readFull(self: *Conn, dst: []u8) Error!void {
        var total: usize = 0;
        const pending = self.leftover[self.leftover_off..];
        if (pending.len != 0) {
            const n = @min(pending.len, dst.len);
            @memcpy(dst[0..n], pending[0..n]);
            self.leftover_off += n;
            total = n;
        }
        while (total < dst.len) {
            const n = try self.stream.read(dst[total..]);
            if (n == 0) return error.PeerClosed;
            total += n;
        }
    }
};

/// Returns the bytes read past the response header — the server may
/// coalesce its first frame with the 101 and they must not be dropped.
fn handshake(
    stream: std.net.Stream,
    host: []const u8,
    port: u16,
    path: []const u8,
    resp: *[4096]u8,
) Error![]const u8 {
    var key_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&key_bytes);
    var key_b64: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(
        &req_buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{ path, host, port, &key_b64 },
    ) catch return error.HandshakeFailed;
    try stream.writeAll(req);

    var len: usize = 0;
    const header_end = while (len < resp.len) {
        const n = try stream.read(resp[len..]);
        if (n == 0) return error.HandshakeFailed;
        len += n;
        if (std.mem.indexOf(u8, resp[0..len], "\r\n\r\n")) |i| break i + 4;
    } else return error.HandshakeFailed;

    const header = resp[0..header_end];
    if (!std.mem.startsWith(u8, header, "HTTP/1.1 101")) return error.HandshakeFailed;

    const want_accept = expectedAccept(&key_b64);
    if (std.mem.indexOf(u8, header, &want_accept) == null) return error.HandshakeFailed;

    return resp[header_end..len];
}

// `base64(sha1(client_key ++ ws_guid))` per RFC 6455 §4.2.2.
fn expectedAccept(client_key: []const u8) [28]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(client_key);
    h.update(ws_guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

test "expectedAccept matches the RFC 6455 §1.3 sample" {
    const got = expectedAccept("dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &got);
}

// std.posix has no socketpair wrapper in 0.15; linux-only is fine here.
fn testSocketPair() ![2]std.posix.socket_t {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    if (std.os.linux.E.init(rc) != .SUCCESS) return error.SocketPairFailed;
    return .{ fds[0], fds[1] };
}

fn testConn(fd: std.posix.socket_t, leftover: []const u8) !Conn {
    return .{
        .allocator = std.testing.allocator,
        .stream = .{ .handle = fd },
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .leftover = try std.testing.allocator.dupe(u8, leftover),
    };
}

test "readFrame drains leftover bytes before the socket" {
    const fds = try testSocketPair();
    defer std.posix.close(fds[1]);
    var conn = try testConn(fds[0], &.{ 0x82, 0x03, 'a', 'b', 'c' });
    defer conn.deinit();

    const frame = try conn.readFrame();
    try std.testing.expectEqual(Opcode.binary, frame.opcode);
    try std.testing.expectEqualStrings("abc", frame.payload);
}

test "readFrame stitches a frame split across leftover and socket" {
    const fds = try testSocketPair();
    defer std.posix.close(fds[1]);
    var conn = try testConn(fds[0], &.{ 0x82, 0x03, 'a' });
    defer conn.deinit();

    _ = try std.posix.write(fds[1], "bc");
    const frame = try conn.readFrame();
    try std.testing.expectEqualStrings("abc", frame.payload);
}

test "leftover PING is answered before reading further frames" {
    const fds = try testSocketPair();
    defer std.posix.close(fds[1]);
    // gpservice's exact greeting: PING "Hi" — followed by a binary frame.
    var conn = try testConn(fds[0], &.{ 0x89, 0x02, 'H', 'i', 0x82, 0x01, 'x' });
    defer conn.deinit();

    const frame = try conn.readFrame();
    try std.testing.expectEqualStrings("x", frame.payload);

    var pong: [8]u8 = undefined;
    const n = try std.posix.read(fds[1], &pong);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqual(@as(u8, 0x8a), pong[0]);
    const mask = pong[2..6];
    try std.testing.expectEqual(@as(u8, 'H'), pong[6] ^ mask[0]);
    try std.testing.expectEqual(@as(u8, 'i'), pong[7] ^ mask[1]);
}

fn fakeUpgradeServer(fd: std.posix.socket_t) void {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") == null) {
        const n = std.posix.read(fd, buf[len..]) catch return;
        if (n == 0) return;
        len += n;
    }
    const key_hdr = "Sec-WebSocket-Key: ";
    const start = (std.mem.indexOf(u8, buf[0..len], key_hdr) orelse return) + key_hdr.len;
    const end = std.mem.indexOfPos(u8, buf[0..len], start, "\r\n") orelse return;
    const accept = expectedAccept(buf[start..end]);

    var out: [512]u8 = undefined;
    // 101 and the first frame (PING "Hi") in ONE write, like gpservice.
    const resp = std.fmt.bufPrint(
        &out,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n" ++
            "\x89\x02Hi",
        .{&accept},
    ) catch return;
    _ = std.posix.write(fd, resp) catch return;
}

test "handshake keeps bytes coalesced after the 101 response" {
    const fds = try testSocketPair();
    defer std.posix.close(fds[1]);
    const stream: std.net.Stream = .{ .handle = fds[0] };
    defer stream.close();

    const server = try std.Thread.spawn(.{}, fakeUpgradeServer, .{fds[1]});
    defer server.join();

    var resp_buf: [4096]u8 = undefined;
    const trailing = try handshake(stream, "127.0.0.1", 1, "/ws", &resp_buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x02, 'H', 'i' }, trailing);
}
