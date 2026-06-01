# gpgui-free

A GTK4 + libadwaita replacement, written in Zig, for the proprietary
`gpgui` that `globalprotect-openconnect` downloads from GitHub on
first run.

## Status

**Early experimental project.** Connect and disconnect have been
verified on Arch Linux with gpservice 2.5.4 against a single-host
gateway. Other topologies and edge cases are not yet tested, and the
API may break without notice.

## Build

```sh
nix develop --accept-flake-config
zig fetch --save=gobject https://github.com/ianprime0509/zig-gobject/releases/download/v0.3.1/bindings-gnome49.tar.zst
zig build
```

## License

GPL-3.0-or-later.
