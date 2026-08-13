//! Main window. Portal entry stays in-layout (no popup dialog).

const std = @import("std");
const gtk = @import("gtk");
const adw = @import("adw");

const Status = @import("state.zig").Status;
const Mode = @import("../config.zig").Mode;

pub const Callbacks = struct {
    /// `portal` is guaranteed non-empty.
    on_connect: *const fn (ctx: *anyopaque, portal: [*:0]const u8, mode: Mode) void,
    on_disconnect: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const Window = struct {
    window: *adw.ApplicationWindow,
    status_label: *gtk.Label,
    portal_entry: *gtk.Entry,
    mode_switch: *gtk.Switch,
    connect_button: *gtk.Button,
    disconnect_button: *gtk.Button,
    cbs: Callbacks,

    pub fn new(app: *adw.Application, cbs: Callbacks) *Window {
        const self = std.heap.c_allocator.create(Window) catch @panic("OOM");

        const window = adw.ApplicationWindow.new(app.as(gtk.Application));
        gtk.Window.setTitle(window.as(gtk.Window), "GlobalProtect");
        gtk.Window.setDefaultSize(window.as(gtk.Window), 420, 400);

        const root = gtk.Box.new(gtk.Orientation.vertical, 0);
        gtk.Box.append(root, adw.HeaderBar.new().as(gtk.Widget));

        const clamp = adw.Clamp.new();
        adw.Clamp.setMaximumSize(clamp, 360);
        gtk.Widget.setMarginTop(clamp.as(gtk.Widget), 24);
        gtk.Widget.setMarginBottom(clamp.as(gtk.Widget), 24);
        gtk.Widget.setMarginStart(clamp.as(gtk.Widget), 24);
        gtk.Widget.setMarginEnd(clamp.as(gtk.Widget), 24);

        const body = gtk.Box.new(gtk.Orientation.vertical, 18);

        const status_label = gtk.Label.new(Status.disconnected.label());
        gtk.Label.setXalign(status_label, 0.5);
        gtk.Widget.addCssClass(status_label.as(gtk.Widget), "title-1");
        gtk.Box.append(body, status_label.as(gtk.Widget));

        const portal_entry = gtk.Entry.new();
        gtk.Entry.setPlaceholderText(portal_entry, "vpn.example.com");
        gtk.Entry.setInputPurpose(portal_entry, gtk.InputPurpose.url);
        gtk.Box.append(body, portal_entry.as(gtk.Widget));

        const mode_row = gtk.Box.new(gtk.Orientation.horizontal, 12);
        const mode_label = gtk.Label.new("Portal mode (auto-discover gateways)");
        gtk.Label.setXalign(mode_label, 0);
        gtk.Widget.setHexpand(mode_label.as(gtk.Widget), 1);
        gtk.Box.append(mode_row, mode_label.as(gtk.Widget));
        const mode_switch = gtk.Switch.new();
        gtk.Box.append(mode_row, mode_switch.as(gtk.Widget));
        gtk.Box.append(body, mode_row.as(gtk.Widget));

        const connect = gtk.Button.newWithLabel("Connect");
        gtk.Widget.addCssClass(connect.as(gtk.Widget), "suggested-action");
        gtk.Widget.addCssClass(connect.as(gtk.Widget), "pill");
        gtk.Box.append(body, connect.as(gtk.Widget));

        const disconnect = gtk.Button.newWithLabel("Disconnect");
        gtk.Widget.addCssClass(disconnect.as(gtk.Widget), "destructive-action");
        gtk.Widget.addCssClass(disconnect.as(gtk.Widget), "pill");
        gtk.Widget.setSensitive(disconnect.as(gtk.Widget), 0);
        gtk.Box.append(body, disconnect.as(gtk.Widget));

        adw.Clamp.setChild(clamp, body.as(gtk.Widget));
        gtk.Box.append(root, clamp.as(gtk.Widget));
        adw.ApplicationWindow.setContent(window, root.as(gtk.Widget));

        self.* = .{
            .window = window,
            .status_label = status_label,
            .portal_entry = portal_entry,
            .mode_switch = mode_switch,
            .connect_button = connect,
            .disconnect_button = disconnect,
            .cbs = cbs,
        };

        _ = gtk.Button.signals.clicked.connect(connect, *Window, &onConnectClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(disconnect, *Window, &onDisconnectClicked, self, .{});
        _ = gtk.Entry.signals.activate.connect(portal_entry, *Window, &onEntryActivate, self, .{});

        return self;
    }

    /// Destroys the GTK window and frees the struct. `destroy_gtk` is
    /// false when GTK already tore the window down (close-request path).
    pub fn deinit(self: *Window, destroy_gtk: bool) void {
        if (destroy_gtk) gtk.Window.destroy(self.window.as(gtk.Window));
        std.heap.c_allocator.destroy(self);
    }

    pub fn present(self: *Window) void {
        gtk.Window.present(self.window.as(gtk.Window));
    }

    pub fn hide(self: *Window) void {
        gtk.Widget.setVisible(self.window.as(gtk.Widget), 0);
    }

    pub fn toggleVisible(self: *Window) void {
        const w = self.window.as(gtk.Widget);
        if (gtk.Widget.getVisible(w) != 0) {
            gtk.Widget.setVisible(w, 0);
        } else {
            gtk.Window.present(self.window.as(gtk.Window));
        }
    }

    pub fn setStatus(self: *Window, s: Status) void {
        gtk.Label.setLabel(self.status_label, s.label());
        const idle = s == .disconnected or s == .service_unreachable;
        const connected = s == .connected;
        gtk.Widget.setSensitive(self.portal_entry.as(gtk.Widget), @intFromBool(idle));
        gtk.Widget.setSensitive(self.mode_switch.as(gtk.Widget), @intFromBool(idle));
        gtk.Widget.setSensitive(self.connect_button.as(gtk.Widget), @intFromBool(idle));
        gtk.Widget.setSensitive(self.disconnect_button.as(gtk.Widget), @intFromBool(connected));
    }

    pub fn setPortalText(self: *Window, text: [*:0]const u8) void {
        gtk.Editable.setText(self.portal_entry.as(gtk.Editable), text);
    }

    pub fn setMode(self: *Window, mode: Mode) void {
        gtk.Switch.setActive(self.mode_switch, @intFromBool(mode == .portal));
    }

    fn portalText(self: *Window) [*:0]const u8 {
        return gtk.EntryBuffer.getText(gtk.Entry.getBuffer(self.portal_entry));
    }

    fn currentMode(self: *Window) Mode {
        return if (gtk.Switch.getActive(self.mode_switch) != 0) .portal else .gateway;
    }

    fn fireConnect(self: *Window) void {
        const text = self.portalText();
        if (std.mem.span(text).len == 0) return;
        self.cbs.on_connect(self.cbs.ctx, text, self.currentMode());
    }

    fn onConnectClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        self.fireConnect();
    }
    fn onDisconnectClicked(_: *gtk.Button, self: *Window) callconv(.c) void {
        self.cbs.on_disconnect(self.cbs.ctx);
    }
    fn onEntryActivate(_: *gtk.Entry, self: *Window) callconv(.c) void {
        self.fireConnect();
    }
};
