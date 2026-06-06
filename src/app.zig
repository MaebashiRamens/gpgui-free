//! `App` glues the GTK main loop to the gpservice WS reader thread
//! via `glib.idleAddOnce`.

const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");

const Window = @import("ui/window.zig").Window;
const Tray = @import("ui/tray.zig").Tray;
const Client = @import("service/client.zig").Client;
const protocol = @import("service/protocol.zig");
const state_mod = @import("ui/state.zig");
const gpauth = @import("auth/gpauth.zig");
const gateway_login = @import("auth/gateway_login.zig");
const portal_config = @import("auth/portal_config.zig");
const cookie_cache = @import("auth/cookie_cache.zig");
const SecretStore = @import("auth/secret_store.zig").SecretStore;
const config = @import("config.zig");
const Mode = config.Mode;

pub const app_id: [*:0]const u8 = "org.gpguifree.GpguiFree";

/// Ships with `gpclient`; used as the fallback HIP wrapper when
/// gpservice doesn't pass one via `VpnEnv.csd_wrapper`.
pub const hip_wrapper_default: []const u8 = "/usr/bin/hipreport.sh";

pub const App = struct {
    allocator: std.mem.Allocator,
    adw_app: *adw.Application,
    window: ?*Window = null,
    tray: ?*Tray = null,
    client: ?Client = null,
    minimized: bool = false,

    /// Latest `VpnEnv` — read by connect jobs, written by `onWsEvent`.
    env_lock: std.Thread.Mutex = .{},
    auth_executable: ?[]u8 = null,
    vpnc_script: ?[]u8 = null,
    csd_wrapper_from_env: ?[]u8 = null,

    secret_store: SecretStore,

    pub fn init(allocator: std.mem.Allocator, minimized: bool) App {
        return .{
            .allocator = allocator,
            .adw_app = adw.Application.new(app_id, .{}),
            .minimized = minimized,
            .secret_store = SecretStore.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.client) |*c| c.stop();
        if (self.tray) |t| t.deinit();
        if (self.auth_executable) |s| self.allocator.free(s);
        if (self.vpnc_script) |s| self.allocator.free(s);
        if (self.csd_wrapper_from_env) |s| self.allocator.free(s);
        self.secret_store.deinit();
        self.adw_app.unref();
    }

    pub fn attachApiKey(self: *App, api_key: []const u8) void {
        self.client = Client.init(self.allocator, .{ .api_key = api_key }) catch |err| {
            std.log.err("client init failed: {s}", .{@errorName(err)});
            return;
        };
    }

    pub fn run(self: *App) i32 {
        _ = gio.Application.signals.activate.connect(
            self.adw_app,
            *App,
            &onActivate,
            self,
            .{},
        );
        // Zig slice headers don't fit C argv; argv is parsed in cli.zig anyway.
        return @intCast(gio.Application.run(self.adw_app.as(gio.Application), 0, null));
    }

    fn onActivate(_: *adw.Application, self: *App) callconv(.c) void {
        const w = Window.new(self.adw_app, .{
            .on_connect = &onConnectClicked,
            .on_disconnect = &onDisconnectClicked,
            .ctx = self,
        });
        self.window = w;

        if (config.load(self.allocator)) |parsed| {
            defer parsed.deinit();
            if (parsed.value.last_portal) |p| {
                if (self.allocator.dupeZ(u8, p)) |z| {
                    defer self.allocator.free(z);
                    w.setPortalText(z);
                } else |_| {}
            }
            w.setMode(parsed.value.last_mode);
        } else |err| std.log.warn("config load failed: {s}", .{@errorName(err)});

        if (!self.minimized) w.present();

        if (Tray.init(self.allocator, &onTrayActivate, self)) |t| {
            t.start() catch |err| std.log.warn("tray start failed: {s}", .{@errorName(err)});
            self.tray = t;
        } else |err| std.log.warn("tray init failed: {s}", .{@errorName(err)});

        if (self.client) |*c| {
            c.setEventCallback(self, &onWsEvent);
            c.start() catch |err| {
                std.log.warn("gpservice connect failed: {s}", .{@errorName(err)});
                w.setStatus(.service_unreachable);
            };
        } else {
            w.setStatus(.service_unreachable);
        }
    }

    fn onConnectClicked(ctx: *anyopaque, portal: [*:0]const u8, mode: Mode) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const portal_slice = std.mem.span(portal);

        // Drop last_user when the portal hostname changes — cached
        // cookie is keyed by gateway and won't fit a new one.
        var preserved_user: ?[]u8 = null;
        if (config.load(self.allocator)) |p| {
            defer p.deinit();
            if (p.value.last_user) |u| {
                if (p.value.last_portal) |old| {
                    if (std.mem.eql(u8, old, portal_slice)) {
                        preserved_user = self.allocator.dupe(u8, u) catch null;
                    }
                }
            }
        } else |_| {}

        config.save(self.allocator, .{
            .last_portal = portal_slice,
            .last_mode = mode,
            .last_user = preserved_user,
        }) catch |err|
            std.log.warn("config save failed: {s}", .{@errorName(err)});

        self.startConnect(portal_slice, mode, preserved_user);
    }

    fn onDisconnectClicked(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const c = if (self.client) |*p| p else return;
        c.send(.{ .Disconnect = .{} }) catch |err|
            std.log.warn("disconnect request failed: {s}", .{@errorName(err)});
    }

    fn onTrayActivate(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const w = self.window orelse return;
        w.toggleVisible();
    }

    /// Spawns the SAML/login worker so the UI thread stays responsive.
    fn startConnect(self: *App, portal: []const u8, mode: Mode, cached_user: ?[]u8) void {
        const portal_owned = self.allocator.dupe(u8, portal) catch {
            if (cached_user) |u| self.allocator.free(u);
            return;
        };

        const job = self.allocator.create(ConnectJob) catch {
            self.allocator.free(portal_owned);
            if (cached_user) |u| self.allocator.free(u);
            return;
        };
        job.* = .{ .app = self, .portal = portal_owned, .mode = mode, .cached_user = cached_user };

        const thread = std.Thread.spawn(.{}, runConnectJob, .{job}) catch |err| {
            std.log.err("connect thread spawn failed: {s}", .{@errorName(err)});
            self.allocator.free(portal_owned);
            if (cached_user) |u| self.allocator.free(u);
            self.allocator.destroy(job);
            return;
        };
        thread.detach();
    }

    const ConnectJob = struct {
        app: *App,
        portal: []u8,
        mode: Mode,
        cached_user: ?[]u8,

        fn deinit(self: *ConnectJob) void {
            self.app.allocator.free(self.portal);
            if (self.cached_user) |u| self.app.allocator.free(u);
            self.app.allocator.destroy(self);
        }
    };

    const Credential = struct {
        username: []u8,
        cookie: []u8,
        from_cache: bool,

        fn deinit(self: Credential, allocator: std.mem.Allocator) void {
            allocator.free(self.username);
            allocator.free(self.cookie);
        }
    };

    fn runConnectJob(job: *ConnectJob) void {
        defer job.deinit();

        const auth_binary = job.app.snapshotAuthBinary() catch gpauth.default_binary;
        defer if (!std.mem.eql(u8, auth_binary, gpauth.default_binary)) job.app.allocator.free(auth_binary);

        const gateway_addr = job.app.resolveGateway(auth_binary, job.portal, job.mode) catch |err| {
            std.log.warn("gateway resolution failed for {s}: {s}", .{ job.portal, @errorName(err) });
            return;
        };
        defer job.app.allocator.free(gateway_addr);

        // First attempt may use a cached cookie; on gateway rejection
        // we forget it and retry once via fresh SAML.
        var hint_user = job.cached_user;
        var attempts: u2 = 0;
        while (attempts < 2) : (attempts += 1) {
            const done = job.app.attemptConnect(auth_binary, job.portal, gateway_addr, hint_user) catch |err| switch (err) {
                error.CachedCookieRejected => {
                    hint_user = null;
                    continue;
                },
                else => {
                    std.log.warn("connect attempt failed: {s}", .{@errorName(err)});
                    return;
                },
            };
            if (done) return;
        }
    }

    /// `error.CachedCookieRejected` means a cached cookie was rejected;
    /// caller should retry once with `hint_user=null`.
    fn attemptConnect(
        self: *App,
        auth_binary: []const u8,
        portal: []const u8,
        gateway_addr: []const u8,
        hint_user: ?[]const u8,
    ) !bool {
        var cred = try self.obtainCredential(auth_binary, gateway_addr, hint_user);
        defer cred.deinit(self.allocator);

        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&hostname_buf) catch "localhost";
        const oc_cookie = gateway_login.login(self.allocator, .{
            .gateway = gateway_addr,
            .username = cred.username,
            .prelogin_cookie = cred.cookie,
            .computer = hostname,
        }) catch |err| {
            if (cred.from_cache) {
                std.log.warn("cached cookie rejected by {s}; forgetting and retrying via SAML", .{gateway_addr});
                self.secret_store.store().forget(gateway_addr, cred.username) catch {};
                return error.CachedCookieRejected;
            }
            std.log.warn("gateway_login failed for {s}: {s}", .{ gateway_addr, @errorName(err) });
            return err;
        };
        defer self.allocator.free(oc_cookie);

        // Gateway accepted the cookie; persist so the next Connect can skip SAML.
        if (!cred.from_cache) {
            const expires_at = std.time.timestamp() + 14 * 24 * 60 * 60;
            self.secret_store.store().save(.{
                .portal = gateway_addr,
                .user = cred.username,
                .cookie = cred.cookie,
                .expires_at_unix = expires_at,
            }) catch |err|
                std.log.warn("cookie cache save failed: {s}", .{@errorName(err)});
        }
        // Preserve user-set value across the save below.
        var allow_extend_session = false;
        if (config.load(self.allocator)) |parsed| {
            defer parsed.deinit();
            allow_extend_session = parsed.value.allow_extend_session;
        } else |_| {}

        config.save(self.allocator, .{
            .last_portal = portal,
            .last_mode = if (std.mem.eql(u8, portal, gateway_addr)) .gateway else .portal,
            .last_user = cred.username,
            .allow_extend_session = allow_extend_session,
        }) catch |err|
            std.log.warn("config save failed: {s}", .{@errorName(err)});

        const env = self.snapshotVpnEnv();
        defer env.free(self.allocator);

        const gw: protocol.Gateway = .{ .name = "default", .address = gateway_addr };
        const gateways = [_]protocol.Gateway{gw};
        const req: protocol.WsRequest = .{ .Connect = .{
            .info = .{ .portal = portal, .gateway = gw, .gateways = &gateways },
            .args = .{
                .cookie = oc_cookie,
                .user_agent = "PAN GlobalProtect",
                .client_version = "6.3.0-33",
                .os = "Linux",
                .vpnc_script = env.vpnc_script,
                // gpservice drops csd_wrapper when `hip` is false.
                .hip = true,
                .csd_wrapper = env.csd_wrapper orelse hip_wrapper_default,
                .allow_extend_session = allow_extend_session,
            },
        } };

        const c = if (self.client) |*p| p else return error.ServiceNotRunning;
        try c.send(req);
        return true;
    }

    /// libsecret lookup if `hint_user` is set, gateway-scoped SAML otherwise.
    fn obtainCredential(
        self: *App,
        auth_binary: []const u8,
        gateway_addr: []const u8,
        hint_user: ?[]const u8,
    ) !Credential {
        if (hint_user) |u| {
            if (self.secret_store.store().load(gateway_addr, u)) |entry| {
                if (cookie_cache.isUsable(entry, std.time.timestamp())) {
                    return .{
                        .username = try self.allocator.dupe(u8, entry.user),
                        .cookie = try self.allocator.dupe(u8, entry.cookie),
                        .from_cache = true,
                    };
                }
            } else |err| switch (err) {
                error.EntryNotFound => {},
                else => std.log.warn("cookie cache load failed: {s}", .{@errorName(err)}),
            }
        }

        var auth = try gpauth.authenticate(self.allocator, .{
            .binary = auth_binary,
            .server = gateway_addr,
            .gateway = true,
        });
        defer auth.deinit();

        const cookie_src = auth.value.prelogin_cookie orelse auth.value.portal_userauthcookie orelse
            return error.NoCookie;
        return .{
            .username = try self.allocator.dupe(u8, auth.value.username),
            .cookie = try self.allocator.dupe(u8, cookie_src),
            .from_cache = false,
        };
    }

    /// `.gateway` mode: user hostname IS the gateway.
    /// `.portal` mode: portal-scoped SAML + `getconfig.esp` discovery.
    fn resolveGateway(self: *App, auth_binary: []const u8, portal: []const u8, mode: Mode) ![]u8 {
        if (mode == .gateway) return try self.allocator.dupe(u8, portal);

        var portal_auth = try gpauth.authenticate(self.allocator, .{
            .binary = auth_binary,
            .server = portal,
            .gateway = false,
        });
        defer portal_auth.deinit();

        const cookie = portal_auth.value.portal_userauthcookie orelse
            portal_auth.value.prelogin_cookie orelse return error.NoPortalCookie;

        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&hostname_buf) catch "localhost";

        const gateways = try portal_config.fetch(self.allocator, .{
            .portal = portal,
            .username = portal_auth.value.username,
            .portal_userauthcookie = portal_auth.value.portal_userauthcookie,
            .prelogin_cookie = portal_auth.value.prelogin_cookie,
            .computer = hostname,
        });
        defer portal_config.freeGateways(self.allocator, gateways);
        _ = cookie;

        if (gateways.len == 0) return error.NoGateways;
        // TODO: surface a picker when len > 1.
        if (gateways.len > 1) {
            std.log.warn("portal returned {d} gateways; picking {s}", .{ gateways.len, gateways[0].address });
        }
        return try self.allocator.dupe(u8, gateways[0].address);
    }

    fn snapshotAuthBinary(self: *App) ![]const u8 {
        self.env_lock.lock();
        defer self.env_lock.unlock();
        if (self.auth_executable) |s| return try self.allocator.dupe(u8, s);
        return gpauth.default_binary;
    }

    const VpnEnvSnapshot = struct {
        vpnc_script: ?[]u8,
        csd_wrapper: ?[]u8,

        fn free(self: VpnEnvSnapshot, allocator: std.mem.Allocator) void {
            if (self.vpnc_script) |s| allocator.free(s);
            if (self.csd_wrapper) |s| allocator.free(s);
        }
    };

    fn snapshotVpnEnv(self: *App) VpnEnvSnapshot {
        self.env_lock.lock();
        defer self.env_lock.unlock();
        return .{
            .vpnc_script = if (self.vpnc_script) |s| self.allocator.dupe(u8, s) catch null else null,
            .csd_wrapper = if (self.csd_wrapper_from_env) |s| self.allocator.dupe(u8, s) catch null else null,
        };
    }

    /// WS reader thread → GTK main thread via `glib.idleAddOnce`.
    fn onWsEvent(ctx: *anyopaque, event: protocol.WsEvent) void {
        const self: *App = @ptrCast(@alignCast(ctx));

        if (event == .VpnEnv) self.cacheEnv(event.VpnEnv);

        const status: state_mod.Status = switch (event) {
            .VpnState => |vs| state_mod.fromVpnState(vs),
            .VpnEnv => |env| state_mod.fromVpnState(env.vpn_state),
            .ActiveGui, .ResumeConnection => return,
        };

        const msg = self.allocator.create(StatusUpdate) catch return;
        msg.* = .{ .app = self, .status = status };
        _ = glib.idleAddOnce(&applyStatusUpdate, msg);
    }

    fn cacheEnv(self: *App, env: protocol.VpnEnv) void {
        self.env_lock.lock();
        defer self.env_lock.unlock();
        if (self.auth_executable) |old| self.allocator.free(old);
        self.auth_executable = self.allocator.dupe(u8, env.auth_executable) catch null;
        if (env.vpnc_script) |s| {
            if (self.vpnc_script) |old| self.allocator.free(old);
            self.vpnc_script = self.allocator.dupe(u8, s) catch null;
        }
        if (env.csd_wrapper) |s| {
            if (self.csd_wrapper_from_env) |old| self.allocator.free(old);
            self.csd_wrapper_from_env = self.allocator.dupe(u8, s) catch null;
        }
    }

    const StatusUpdate = struct {
        app: *App,
        status: state_mod.Status,
    };

    fn applyStatusUpdate(raw: ?*anyopaque) callconv(.c) void {
        const msg: *StatusUpdate = @ptrCast(@alignCast(raw.?));
        defer msg.app.allocator.destroy(msg);
        if (msg.app.window) |w| w.setStatus(msg.status);
    }
};
