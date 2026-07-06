#!/usr/bin/env bash
set -eEuo pipefail

current_dir=$(cd "$(dirname "$0")" && pwd)
target_bin=/usr/bin/gpgui
backup_bin=${target_bin}.proprietary.bak

cd "$current_dir"
nix develop --accept-flake-config --command zig build

[[ -e $backup_bin ]] || sudo cp -a "$target_bin" "$backup_bin"
sudo pkill -f "(^|/)gpservice( |$)|(^|/)gpgui( |$)" 2>/dev/null || true
sudo install -m 755 "$current_dir/zig-out/bin/gpgui-free" "$target_bin"
