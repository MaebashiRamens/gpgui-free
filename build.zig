const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Zig 0.15's self-hosted x86 backend emits `R_X86_64_PC64`
    // relocations when linking the GObject closure against glibc
    // 2.43+ CRT objects (Arch and other rolling distros). The
    // self-hosted ELF linker doesn't handle PC64 yet, so force the
    // LLVM backend by default. See `~/Git/zig-linker-bug` for repro.
    const self_hosted = b.option(bool, "self-hosted", "Use the self-hosted x86 backend (broken against glibc 2.43+)") orelse false;

    const gobject = b.dependency("gobject", .{
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", "0.1.0-dev");
    build_options.addOption([]const u8, "commit", gitCommit(b));
    const build_options_mod = build_options.createModule();

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "glib", .module = gobject.module("glib2") },
            .{ .name = "gobject", .module = gobject.module("gobject2") },
            .{ .name = "gio", .module = gobject.module("gio2") },
            .{ .name = "gdk", .module = gobject.module("gdk4") },
            .{ .name = "gtk", .module = gobject.module("gtk4") },
            .{ .name = "adw", .module = gobject.module("adw1") },
            .{ .name = "secret", .module = gobject.module("secret1") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "gpgui-free",
        .root_module = root_mod,
        .use_llvm = !self_hosted,
    });
    b.installArtifact(exe);

    b.installFile("assets/applications/gpgui-free.desktop", "share/applications/gpgui-free.desktop");
    b.installFile("assets/icons/hicolor/scalable/apps/gpgui-free.svg", "share/icons/hicolor/scalable/apps/gpgui-free.svg");
    b.installFile("assets/icons/hicolor/256x256/apps/gpgui-free.png", "share/icons/hicolor/256x256/apps/gpgui-free.png");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run gpgui-free").dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);
}

/// Empty string when there's no git checkout (CI sandbox, release tarball).
fn gitCommit(b: *std.Build) []const u8 {
    var exit_code: u8 = 0;
    const out = b.runAllowFail(
        &.{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--short=12", "HEAD" },
        &exit_code,
        .Ignore,
    ) catch return "";
    if (exit_code != 0) return "";
    return std.mem.trim(u8, out, " \t\r\n");
}
