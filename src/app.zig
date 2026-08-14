//! `App` glues the GTK main loop to the gpservice WS reader thread
//! via `glib.idleAddOnce`.

const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gtk = @import("gtk");

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

    /// Last successful connect, replayed on `ResumeConnection`. Written by
    /// connect jobs (`attemptConnect`), read by `beginReconnect`.
    last_connect_lock: std.Thread.Mutex = .{},
    last_connect: ?LastConnect = null,

    /// GTK-thread-only mirror of the VPN status; gates auto-reconnect.
    current_status: state_mod.Status = .disconnected,
    /// True while an auto-reconnect job is in flight — dedupes a burst of
    /// `ResumeConnection` events into a single reconnect.
    reconnecting: std.atomic.Value(bool) = .init(false),
    /// Bumped per reconnect (GTK thread) so a stale watchdog can tell it
    /// was superseded and skip resetting a newer attempt.
    reconnect_gen: u64 = 0,

    const LastConnect = struct {
        portal: []u8,
        mode: Mode,
        user: ?[]u8,
        /// Resolved address — reconnects go straight here so portal-mode
        /// gateway discovery (interactive SAML) never runs unattended.
        gateway: []u8,

        fn free(self: LastConnect, allocator: std.mem.Allocator) void {
            allocator.free(self.portal);
            if (self.user) |u| allocator.free(u);
            allocator.free(self.gateway);
        }
    };

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
        if (self.window) |w| {
            self.window = null;
            w.deinit(true);
        }
        if (self.tray) |t| t.deinit();
        if (self.auth_executable) |s| self.allocator.free(s);
        if (self.vpnc_script) |s| self.allocator.free(s);
        if (self.csd_wrapper_from_env) |s| self.allocator.free(s);
        if (self.last_connect) |lc| lc.free(self.allocator);
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
        _ = gtk.Window.signals.close_request.connect(
            w.window.as(gtk.Window),
            *App,
            &onWindowClose,
            self,
            .{},
        );

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
            c.setCloseCallback(self, &onWsClosed);
            c.start() catch |err| {
                std.log.warn("gpservice connect failed: {s}", .{@errorName(err)});
                w.setStatus(.service_unreachable);
            };
        } else {
            w.setStatus(.service_unreachable);
        }
    }

    /// Reader thread; fires when the WS dies without a deliberate stop
    /// (gpservice crashed or restarted with a new port).
    fn onWsClosed(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        std.log.warn("gpservice connection lost", .{});
        self.postStatus(.service_unreachable);
    }

    /// With a tray, closing hides the window so the app keeps running
    /// (tray toggle brings it back). Without one, hiding would strand
    /// the user, so fall through to the default destroy-and-quit.
    fn onWindowClose(_: *gtk.Window, self: *App) callconv(.c) c_int {
        if (self.tray != null) {
            if (self.window) |w| w.hide();
            return 1;
        }
        if (self.window) |w| {
            self.window = null;
            w.deinit(false);
        }
        return 0;
    }

    fn onConnectClicked(ctx: *anyopaque, portal: [*:0]const u8, mode: Mode) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const portal_slice = std.mem.span(portal);

        // Read-modify-write so knobs the UI doesn't own (mtu,
        // allow_extend_session, …) survive the save.
        const parsed: ?std.json.Parsed(config.Config) = config.load(self.allocator) catch null;
        defer if (parsed) |p| p.deinit();
        var cfg: config.Config = if (parsed) |p| p.value else .{};

        // Drop last_user when the portal hostname changes — cached
        // cookie is keyed by gateway and won't fit a new one.
        if (cfg.last_portal == null or !std.mem.eql(u8, cfg.last_portal.?, portal_slice))
            cfg.last_user = null;
        const preserved_user: ?[]u8 =
            if (cfg.last_user) |u| self.allocator.dupe(u8, u) catch null else null;

        cfg.last_portal = portal_slice;
        cfg.last_mode = mode;
        config.save(self.allocator, cfg) catch |err|
            std.log.warn("config save failed: {s}", .{@errorName(err)});

        self.startConnect(portal_slice, mode, preserved_user, false, null);
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
    /// `reconnect` jobs retry unreachable gateways with backoff and clear
    /// the in-flight guard when done.
    fn startConnect(self: *App, portal: []const u8, mode: Mode, cached_user: ?[]u8, reconnect: bool, known_gateway: ?[]const u8) void {
        if (!reconnect) {
            self.current_status = .connecting;
            if (self.window) |w| w.setStatus(.connecting);
        }

        const portal_owned = self.allocator.dupe(u8, portal) catch {
            if (cached_user) |u| self.allocator.free(u);
            self.abortConnect();
            return;
        };

        const gateway_owned: ?[]u8 = if (known_gateway) |g|
            self.allocator.dupe(u8, g) catch {
                self.allocator.free(portal_owned);
                if (cached_user) |u| self.allocator.free(u);
                self.abortConnect();
                return;
            }
        else
            null;

        const job = self.allocator.create(ConnectJob) catch {
            self.allocator.free(portal_owned);
            if (gateway_owned) |g| self.allocator.free(g);
            if (cached_user) |u| self.allocator.free(u);
            self.abortConnect();
            return;
        };
        job.* = .{
            .app = self,
            .portal = portal_owned,
            .mode = mode,
            .cached_user = cached_user,
            .reconnect = reconnect,
            .known_gateway = gateway_owned,
        };

        const thread = std.Thread.spawn(.{}, runConnectJob, .{job}) catch |err| {
            std.log.err("connect thread spawn failed: {s}", .{@errorName(err)});
            self.allocator.free(portal_owned);
            if (cached_user) |u| self.allocator.free(u);
            self.abortConnect();
            self.allocator.destroy(job);
            return;
        };
        thread.detach();
    }

    /// GTK thread. Drops a stuck transitional state back to disconnected.
    fn abortConnect(self: *App) void {
        self.reconnecting.store(false, .release);
        if (self.current_status == .connecting or self.current_status == .reconnecting) {
            self.current_status = .disconnected;
            if (self.window) |w| w.setStatus(.disconnected);
        }
    }

    const ConnectJob = struct {
        app: *App,
        portal: []u8,
        mode: Mode,
        cached_user: ?[]u8,
        reconnect: bool,
        /// Skips gateway discovery when set (reconnect path).
        known_gateway: ?[]u8 = null,

        fn deinit(self: *ConnectJob) void {
            self.app.allocator.free(self.portal);
            if (self.cached_user) |u| self.app.allocator.free(u);
            if (self.known_gateway) |g| self.app.allocator.free(g);
            self.app.allocator.destroy(self);
        }
    };

    const Credential = struct {
        username: []u8,
        cookie: []u8,
        from_cache: bool,

        fn deinit(self: Credential, allocator: std.mem.Allocator) void {
            allocator.free(self.username);
            std.crypto.secureZero(u8, self.cookie);
            allocator.free(self.cookie);
        }
    };

    const Outcome = enum { connected, retry, fatal };

    /// Transient reachability gaps after a network-up event usually clear
    /// within the first retry or two.
    const reconnect_max_tries: u8 = 3;

    /// Upper bound on a reconnect (worst case: 3 tries + 2s+4s backoff +
    /// a blocking SAML fallback). Past this the watchdog unsticks the UI.
    const reconnect_watchdog_secs: c_uint = 90;

    const ReconnectWatch = struct { app: *App, gen: u64 };

    /// Backoff before the (0-based) `attempt`-th retry: 2s, 4s, 8s, …
    fn reconnectDelayNs(attempt: u6) u64 {
        return (@as(u64, 2) << attempt) * std.time.ns_per_s;
    }

    fn runConnectJob(job: *ConnectJob) void {
        defer {
            if (job.reconnect) job.app.reconnecting.store(false, .release);
            job.deinit();
        }

        const max: u8 = if (job.reconnect) reconnect_max_tries else 1;
        var tries: u8 = 0;
        while (true) {
            switch (attemptOnce(job)) {
                .connected => return,
                .fatal => break,
                .retry => {
                    tries += 1;
                    if (tries >= max) {
                        std.log.warn("gateway unreachable after {d} attempt(s); giving up", .{tries});
                        break;
                    }
                    std.Thread.sleep(reconnectDelayNs(@intCast(tries - 1)));
                },
            }
        }
        // A connect that never sent `Connect` leaves the UI on
        // "Connecting…"/"Reconnecting…" with no `VpnState` to follow, so
        // reset here — both manual and reconnect jobs.
        job.app.postStatus(.disconnected);
    }

    fn postStatus(self: *App, status: state_mod.Status) void {
        const msg = self.allocator.create(StatusUpdate) catch return;
        msg.* = .{ .app = self, .status = status };
        _ = glib.idleAddOnce(&applyStatusUpdate, msg);
    }

    test reconnectDelayNs {
        try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), reconnectDelayNs(0));
        try std.testing.expectEqual(@as(u64, 4 * std.time.ns_per_s), reconnectDelayNs(1));
        try std.testing.expectEqual(@as(u64, 8 * std.time.ns_per_s), reconnectDelayNs(2));
    }

    /// One full resolve → auth → connect pass. `.retry` is retryable
    /// (network not ready yet); `.fatal` is not (auth/config error).
    fn attemptOnce(job: *ConnectJob) Outcome {
        const auth_binary = job.app.snapshotAuthBinary() catch gpauth.default_binary;
        defer if (!std.mem.eql(u8, auth_binary, gpauth.default_binary)) job.app.allocator.free(auth_binary);

        const gateway_addr = if (job.known_gateway) |g|
            job.app.allocator.dupe(u8, g) catch return .fatal
        else
            job.app.resolveGateway(auth_binary, job.portal, job.mode) catch |err| {
                std.log.warn("gateway resolution failed for {s}: {s}", .{ job.portal, @errorName(err) });
                return .fatal;
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
                error.Unreachable => return .retry,
                else => {
                    std.log.warn("connect attempt failed: {s}", .{@errorName(err)});
                    return .fatal;
                },
            };
            if (done) return .connected;
        }
        return .fatal;
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
            // A network gap (post-resume) must not be mistaken for a bad
            // cookie — keep the cached cookie and let the caller back off.
            if (err == error.Unreachable) return error.Unreachable;
            if (cred.from_cache) {
                std.log.warn("cached cookie rejected by {s}; forgetting and retrying via SAML", .{gateway_addr});
                self.secret_store.store().forget(gateway_addr, cred.username) catch {};
                return error.CachedCookieRejected;
            }
            std.log.warn("gateway_login failed for {s}: {s}", .{ gateway_addr, @errorName(err) });
            return err;
        };
        defer {
            std.crypto.secureZero(u8, oc_cookie);
            self.allocator.free(oc_cookie);
        }

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
        const parsed: ?std.json.Parsed(config.Config) = config.load(self.allocator) catch null;
        defer if (parsed) |p| p.deinit();
        var cfg: config.Config = if (parsed) |p| p.value else .{};

        cfg.last_portal = portal;
        cfg.last_mode = if (std.mem.eql(u8, portal, gateway_addr)) .gateway else .portal;
        cfg.last_user = cred.username;
        config.save(self.allocator, cfg) catch |err|
            std.log.warn("config save failed: {s}", .{@errorName(err)});

        const env = self.snapshotVpnEnv();
        defer env.free(self.allocator);

        const gw: protocol.Gateway = .{ .name = "default", .address = gateway_addr };
        const gateways = [_]protocol.Gateway{gw};
        const req: protocol.WsRequest = .{
            .Connect = .{
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
                    .allow_extend_session = cfg.allow_extend_session,
                    .mtu = cfg.mtu,
                    .disable_ipv6 = cfg.disable_ipv6,
                    .no_dtls = cfg.no_dtls,
                },
            },
        };

        const c = if (self.client) |*p| p else return error.ServiceNotRunning;
        try c.send(req);

        const mode: Mode = if (std.mem.eql(u8, portal, gateway_addr)) .gateway else .portal;
        self.rememberConnect(portal, mode, cred.username, gateway_addr);
        return true;
    }

    /// Snapshots the parameters of a successful connect so a later
    /// `ResumeConnection` can replay it (cached cookie preferred).
    fn rememberConnect(self: *App, portal: []const u8, mode: Mode, user: []const u8, gateway: []const u8) void {
        const portal_owned = self.allocator.dupe(u8, portal) catch return;
        const user_owned = self.allocator.dupe(u8, user) catch {
            self.allocator.free(portal_owned);
            return;
        };
        const gateway_owned = self.allocator.dupe(u8, gateway) catch {
            self.allocator.free(portal_owned);
            self.allocator.free(user_owned);
            return;
        };
        self.last_connect_lock.lock();
        defer self.last_connect_lock.unlock();
        if (self.last_connect) |old| old.free(self.allocator);
        self.last_connect = .{
            .portal = portal_owned,
            .mode = mode,
            .user = user_owned,
            .gateway = gateway_owned,
        };
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

        // gpservice relays SIGUSR2 (from the NetworkManager up-hook) as
        // `ResumeConnection`; replay the last connect on the GTK thread.
        if (event == .ResumeConnection) {
            _ = glib.idleAddOnce(&handleResume, self);
            return;
        }

        // A second `gpclient launch-gui` POSTs /active-gui instead of
        // spawning; raise the (possibly hidden) window in its place.
        if (event == .ActiveGui) {
            _ = glib.idleAddOnce(&handleActiveGui, self);
            return;
        }

        const status: state_mod.Status = switch (event) {
            .VpnState => |vs| state_mod.fromVpnState(vs),
            .VpnEnv => |env| state_mod.fromVpnState(env.vpn_state),
            .ActiveGui, .ResumeConnection => return,
        };
        self.postStatus(status);
    }

    fn handleActiveGui(raw: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(raw.?));
        if (self.window) |w| w.present();
    }

    fn handleResume(raw: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(raw.?));
        self.beginReconnect();
    }

    /// GTK thread. Replays the last successful connect unless one is
    /// already up or in progress. Prefers the cached cookie; falls back
    /// to interactive SAML if it's gone.
    fn beginReconnect(self: *App) void {
        switch (self.current_status) {
            .connecting, .connected, .reconnecting => return,
            .disconnected, .disconnecting, .service_unreachable => {},
        }
        if (self.reconnecting.swap(true, .acq_rel)) return;

        self.last_connect_lock.lock();
        const portal, const mode, const user, const gateway = blk: {
            const lc = self.last_connect orelse {
                self.last_connect_lock.unlock();
                self.reconnecting.store(false, .release);
                std.log.info("ResumeConnection ignored: no prior connection to restore", .{});
                return;
            };
            const p = self.allocator.dupe(u8, lc.portal) catch {
                self.last_connect_lock.unlock();
                self.reconnecting.store(false, .release);
                return;
            };
            const g = self.allocator.dupe(u8, lc.gateway) catch {
                self.allocator.free(p);
                self.last_connect_lock.unlock();
                self.reconnecting.store(false, .release);
                return;
            };
            const u = if (lc.user) |cu| self.allocator.dupe(u8, cu) catch {
                self.allocator.free(p);
                self.allocator.free(g);
                self.last_connect_lock.unlock();
                self.reconnecting.store(false, .release);
                return;
            } else null;
            break :blk .{ p, lc.mode, u, g };
        };
        self.last_connect_lock.unlock();
        defer self.allocator.free(portal);
        defer self.allocator.free(gateway);

        std.log.info("ResumeConnection: reconnecting to {s} via {s}", .{ portal, gateway });
        self.current_status = .reconnecting;
        if (self.window) |w| w.setStatus(.reconnecting);
        self.armReconnectWatchdog();
        self.startConnect(portal, mode, user, true, gateway);
    }

    /// A reconnect can stall with no terminal `VpnState` — the job blocks
    /// on a SAML browser the user never completes, gpservice stays silent
    /// after `Connect`, or a spawn fails. The watchdog guarantees
    /// "Reconnecting…" resolves instead of freezing forever.
    fn armReconnectWatchdog(self: *App) void {
        self.reconnect_gen +%= 1;
        const watch = self.allocator.create(ReconnectWatch) catch return;
        watch.* = .{ .app = self, .gen = self.reconnect_gen };
        _ = glib.timeoutAddSecondsOnce(reconnect_watchdog_secs, &reconnectWatchdog, watch);
    }

    fn reconnectWatchdog(raw: ?*anyopaque) callconv(.c) void {
        const watch: *ReconnectWatch = @ptrCast(@alignCast(raw.?));
        const self = watch.app;
        defer self.allocator.destroy(watch);
        // Superseded by a newer reconnect, or already resolved — leave it be.
        if (watch.gen != self.reconnect_gen or self.current_status != .reconnecting) return;
        std.log.warn("reconnect watchdog: still reconnecting after {d}s; resetting", .{reconnect_watchdog_secs});
        self.abortConnect();
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
        msg.app.current_status = msg.status;
        if (msg.app.window) |w| w.setStatus(msg.status);
    }
};
