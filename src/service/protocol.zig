//! gpservice WS wire types. Mirrors `crates/gpapi/src/service/*.rs`.
//! See `docs/PROTOCOL.md` for per-field serde quirks.

const std = @import("std");

pub const WsRequest = union(enum) {
    Connect: ConnectRequest,
    Disconnect: DisconnectRequest,
    UpdateLogLevel: UpdateLogLevelRequest,
};

pub const WsEvent = union(enum) {
    VpnEnv: VpnEnv,
    VpnState: VpnState,
    ActiveGui: void,
    ResumeConnection: void,
};

pub const VpnState = union(enum) {
    Disconnected: void,
    Connecting: ConnectInfo,
    Connected: ConnectedInfo,
    Disconnecting: void,

    /// std.json's union decoder rejects the bare-string unit form.
    /// Unknown variants degrade to `Disconnected` (logs a warning) so a
    /// server-side schema bump doesn't kill the event stream.
    /// Variant tags are camelCase in 2.5.x, PascalCase before — we
    /// accept both via case-insensitive matching.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !VpnState {
        const tok = try source.next();
        switch (tok) {
            .string, .allocated_string => |name| {
                if (std.ascii.eqlIgnoreCase(name, "disconnected")) return .{ .Disconnected = {} };
                if (std.ascii.eqlIgnoreCase(name, "disconnecting")) return .{ .Disconnecting = {} };
                std.log.warn("unknown VpnState unit variant: {s}", .{name});
                return .{ .Disconnected = {} };
            },
            .object_begin => {},
            else => return error.UnexpectedToken,
        }

        const name_tok = try source.next();
        const name = switch (name_tok) {
            .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (std.ascii.eqlIgnoreCase(name, "connecting")) {
            const v: VpnState = .{ .Connecting = try std.json.innerParse(ConnectInfo, allocator, source, options) };
            if (try source.next() != .object_end) return error.UnexpectedToken;
            return v;
        }
        if (std.ascii.eqlIgnoreCase(name, "connected")) {
            const v: VpnState = .{ .Connected = try std.json.innerParse(ConnectedInfo, allocator, source, options) };
            if (try source.next() != .object_end) return error.UnexpectedToken;
            return v;
        }
        std.log.warn("unknown VpnState object variant: {s}", .{name});
        try source.skipValue();
        if (try source.next() != .object_end) return error.UnexpectedToken;
        return .{ .Disconnected = {} };
    }
};

pub const VpnEnv = struct {
    vpn_state: VpnState,
    vpnc_script: ?[]const u8 = null,
    csd_wrapper: ?[]const u8 = null,
    auth_executable: []const u8,
};

pub const PriorityRule = struct {
    name: []const u8,
    priority: u32,
};

pub const Gateway = struct {
    name: []const u8,
    address: []const u8,
    priority: u32 = 0,
    /// Wire is `priorityRules` (camelCase) — emitted via `jsonStringify`.
    priority_rules: []const PriorityRule = &.{},

    pub fn jsonStringify(self: Gateway, w: anytype) !void {
        try w.beginObject();
        try w.objectField("name");
        try w.write(self.name);
        try w.objectField("address");
        try w.write(self.address);
        try w.objectField("priority");
        try w.write(self.priority);
        try w.objectField("priorityRules");
        try w.write(self.priority_rules);
        try w.endObject();
    }
};

pub const ConnectInfo = struct {
    portal: []const u8,
    gateway: Gateway,
    gateways: []const Gateway,
};

pub const ConnectedInfo = struct {
    info: ConnectInfo,
    session_info: ?SessionInfo = null,
};

pub const SessionInfo = struct {
    user_name: ?[]const u8 = null,
    portal: ?[]const u8 = null,
    gateway: ?[]const u8 = null,
};

pub const ConnectRequest = struct {
    info: ConnectInfo,
    args: ConnectArgs,
};

/// Defaults track `ConnectArgs::new` upstream.
/// `allow_extend_session` is wire-renamed via `jsonStringify`.
pub const ConnectArgs = struct {
    cookie: []const u8,
    vpnc_script: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    os: ?[]const u8 = null,
    os_version: ?[]const u8 = null,
    client_version: ?[]const u8 = null,
    certificate: ?[]const u8 = null,
    sslkey: ?[]const u8 = null,
    key_password: ?[]const u8 = null,
    hip: bool = false,
    csd_uid: u32 = 0,
    csd_wrapper: ?[]const u8 = null,
    reconnect_timeout: u32 = 300,
    mtu: u32 = 0,
    disable_ipv6: bool = false,
    no_dtls: bool = false,
    local_hostname: ?[]const u8 = null,
    force_dpd: u32 = 0,
    no_xmlpost: bool = false,
    allow_extend_session: bool = false,

    pub fn jsonStringify(self: ConnectArgs, w: anytype) !void {
        try w.beginObject();
        inline for (.{
            "cookie",            "vpnc_script",    "user_agent",   "os",
            "os_version",        "client_version", "certificate",  "sslkey",
            "key_password",      "hip",            "csd_uid",      "csd_wrapper",
            "reconnect_timeout", "mtu",            "disable_ipv6", "no_dtls",
            "local_hostname",    "force_dpd",      "no_xmlpost",
        }) |field| {
            try w.objectField(field);
            try w.write(@field(self, field));
        }
        try w.objectField("allowExtendSession");
        try w.write(self.allow_extend_session);
        try w.endObject();
    }
};

/// Upstream is a Rust unit struct — serde wire form is JSON `null`,
/// not `{}`.
pub const DisconnectRequest = struct {
    pub fn jsonStringify(_: DisconnectRequest, w: anytype) !void {
        try w.write(@as(?u8, null));
    }
};

pub const UpdateLogLevelRequest = struct {
    /// "trace" | "debug" | "info" | "warn" | "error"
    level: []const u8,
};

pub const ParseError = error{UnknownVariant} ||
    std.json.ParseError(std.json.Scanner) ||
    std.mem.Allocator.Error;

/// Accepts both `{"VpnState":…}` (object) and bare-string unit forms.
pub fn parseWsEvent(
    allocator: std.mem.Allocator,
    raw: []const u8,
) ParseError!std.json.Parsed(WsEvent) {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (asQuotedString(trimmed)) |name| {
        const value = try unitVariant(name);
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return .{ .arena = arena, .value = value };
    }
    return std.json.parseFromSlice(WsEvent, allocator, raw, .{
        .ignore_unknown_fields = true,
    });
}

fn asQuotedString(trimmed: []const u8) ?[]const u8 {
    if (trimmed.len < 2) return null;
    if (trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return null;
    return trimmed[1 .. trimmed.len - 1];
}

fn unitVariant(name: []const u8) error{UnknownVariant}!WsEvent {
    if (std.mem.eql(u8, name, "ActiveGui")) return .{ .ActiveGui = {} };
    if (std.mem.eql(u8, name, "ResumeConnection")) return .{ .ResumeConnection = {} };
    return error.UnknownVariant;
}
