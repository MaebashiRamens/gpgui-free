//! Minimal StatusNotifierItem over GDBus. Works on KDE/XFCE/MATE/
//! Cinnamon; vanilla GNOME needs the AppIndicator extension.
//! Left/right-click both fire `on_activate` — no DBusMenu.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");

const object_path: [*:0]const u8 = "/StatusNotifierItem";
const watcher_name: [*:0]const u8 = "org.kde.StatusNotifierWatcher";
const watcher_path: [*:0]const u8 = "/StatusNotifierWatcher";
const sni_iface_name: [*:0]const u8 = "org.kde.StatusNotifierItem";

// Properties watchers actually read; ToolTip + Menu intentionally absent.
const sni_introspection_xml: [*:0]const u8 =
    \\<node>
    \\  <interface name="org.kde.StatusNotifierItem">
    \\    <property name="Category" type="s" access="read"/>
    \\    <property name="Id" type="s" access="read"/>
    \\    <property name="Title" type="s" access="read"/>
    \\    <property name="Status" type="s" access="read"/>
    \\    <property name="IconName" type="s" access="read"/>
    \\    <property name="ItemIsMenu" type="b" access="read"/>
    \\    <method name="Activate">
    \\      <arg type="i" name="x" direction="in"/>
    \\      <arg type="i" name="y" direction="in"/>
    \\    </method>
    \\    <method name="SecondaryActivate">
    \\      <arg type="i" name="x" direction="in"/>
    \\      <arg type="i" name="y" direction="in"/>
    \\    </method>
    \\    <method name="ContextMenu">
    \\      <arg type="i" name="x" direction="in"/>
    \\      <arg type="i" name="y" direction="in"/>
    \\    </method>
    \\    <signal name="NewStatus"><arg type="s" name="status"/></signal>
    \\    <signal name="NewIcon"/>
    \\  </interface>
    \\</node>
;

pub const ActivateCallback = *const fn (ctx: *anyopaque) void;

pub const Tray = struct {
    allocator: std.mem.Allocator,
    service_name_z: [:0]u8,
    own_id: c_uint = 0,
    register_id: c_uint = 0,
    node_info: ?*gio.DBusNodeInfo = null,
    bus: ?*gio.DBusConnection = null,
    on_activate: ActivateCallback,
    ctx: *anyopaque,

    /// Must outlive the GTK main loop; don't move after `start`.
    pub fn init(allocator: std.mem.Allocator, on_activate: ActivateCallback, ctx: *anyopaque) !*Tray {
        const pid = @as(u32, @intCast(std.os.linux.getpid()));
        const name_z = try std.fmt.allocPrintSentinel(
            allocator,
            "org.kde.StatusNotifierItem-{d}-1",
            .{pid},
            0,
        );

        const self = try allocator.create(Tray);
        self.* = .{
            .allocator = allocator,
            .service_name_z = name_z,
            .on_activate = on_activate,
            .ctx = ctx,
        };
        return self;
    }

    pub fn start(self: *Tray) !void {
        var err: ?*glib.Error = null;
        const node = gio.DBusNodeInfo.newForXml(sni_introspection_xml, &err) orelse {
            if (err) |e| {
                std.log.warn("tray: parse introspection failed: {s}", .{e.f_message orelse "?"});
                glib.Error.free(e);
            }
            return error.IntrospectionParseFailed;
        };
        self.node_info = node;

        self.own_id = gio.busOwnName(
            .session,
            self.service_name_z.ptr,
            .{},
            &onBusAcquired,
            &onNameAcquired,
            &onNameLost,
            self,
            null,
        );
    }

    pub fn deinit(self: *Tray) void {
        if (self.register_id != 0) {
            if (self.bus) |bus| _ = bus.unregisterObject(self.register_id);
            self.register_id = 0;
        }
        if (self.own_id != 0) {
            gio.busUnownName(self.own_id);
            self.own_id = 0;
        }
        if (self.node_info) |n| n.unref();
        self.allocator.free(self.service_name_z);
        self.allocator.destroy(self);
    }

    fn onBusAcquired(
        connection: *gio.DBusConnection,
        _: [*:0]const u8,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(user_data.?));
        self.bus = connection;

        const node = self.node_info orelse return;
        const iface = node.lookupInterface(sni_iface_name) orelse {
            std.log.warn("tray: interface lookup failed", .{});
            return;
        };

        var err: ?*glib.Error = null;
        // f_padding is non-nullable; leave undefined since GDBus only
        // reads the three function pointers.
        var vtable: gio.DBusInterfaceVTable = undefined;
        vtable.f_method_call = &onMethodCall;
        vtable.f_get_property = &onGetProperty;
        vtable.f_set_property = null;
        const id = connection.registerObject(object_path, iface, &vtable, self, &noDestroy, &err);
        if (id == 0) {
            if (err) |e| {
                std.log.warn("tray: registerObject failed: {s}", .{e.f_message orelse "?"});
                glib.Error.free(e);
            }
            return;
        }
        self.register_id = id;
    }

    fn onNameAcquired(
        connection: *gio.DBusConnection,
        _: [*:0]const u8,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(user_data.?));
        // Some shells discover SNI items only via the watcher.
        const name_var = glib.Variant.newString(self.service_name_z.ptr);
        const children = [_]*glib.Variant{name_var};
        const params = glib.Variant.newTuple(&children, children.len);
        var err: ?*glib.Error = null;
        _ = connection.callSync(
            watcher_name,
            watcher_path,
            "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem",
            params,
            null,
            .{},
            -1,
            null,
            &err,
        );
        if (err) |e| {
            // GNOME has no watcher by default; not fatal.
            std.log.info("tray: watcher register ignored: {s}", .{e.f_message orelse "?"});
            glib.Error.free(e);
        }
    }

    fn onNameLost(
        _: ?*gio.DBusConnection,
        name: [*:0]const u8,
        _: ?*anyopaque,
    ) callconv(.c) void {
        std.log.warn("tray: lost bus name {s}", .{name});
    }

    // `register_object` requires a non-null DestroyNotify; `self` outlives it.
    fn noDestroy(_: ?*anyopaque) callconv(.c) void {}

    fn onMethodCall(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: ?[*:0]const u8,
        method_name: [*:0]const u8,
        _: *glib.Variant,
        invocation: *gio.DBusMethodInvocation,
        user_data: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(user_data.?));
        const name = std.mem.span(method_name);
        if (std.mem.eql(u8, name, "Activate") or
            std.mem.eql(u8, name, "SecondaryActivate") or
            std.mem.eql(u8, name, "ContextMenu"))
        {
            self.on_activate(self.ctx);
            invocation.returnValue(null);
            return;
        }
        invocation.returnErrorLiteral(
            glib.quarkFromString("org.gpguifree.Tray"),
            0,
            "unknown method",
        );
    }

    fn onGetProperty(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        property_name: [*:0]const u8,
        _: **glib.Error,
        _: ?*anyopaque,
    ) callconv(.c) ?*glib.Variant {
        const name = std.mem.span(property_name);
        if (std.mem.eql(u8, name, "Category")) return glib.Variant.newString("ApplicationStatus");
        if (std.mem.eql(u8, name, "Id")) return glib.Variant.newString("gpgui-free");
        if (std.mem.eql(u8, name, "Title")) return glib.Variant.newString("GlobalProtect");
        if (std.mem.eql(u8, name, "Status")) return glib.Variant.newString("Active");
        if (std.mem.eql(u8, name, "IconName")) return glib.Variant.newString("network-vpn");
        if (std.mem.eql(u8, name, "ItemIsMenu")) return glib.Variant.newBoolean(0);
        return null;
    }
};
