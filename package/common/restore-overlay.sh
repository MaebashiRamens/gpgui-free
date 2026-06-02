#!/usr/bin/env bash
# restore-overlay.sh — re-apply overlay after upstream package events
# (pacman PostTransaction / apt DPkg::Post-Invoke / RPM systemd path unit).
# No-op if gpgui-free has been uninstalled.

set -eu

if [ -x /usr/bin/gpgui-free ] && [ -x /usr/lib/gpgui-free/install-overlay.sh ]; then
    /usr/lib/gpgui-free/install-overlay.sh
fi
