#!/usr/bin/env bash
# install-overlay.sh — idempotently lay gpgui-free over the upstream package.
#
#   /usr/bin/gpgui            → symlink to gpgui-free
#   /usr/bin/gpgui.proprietary       ← original gpgui (when one existed)
#   /usr/bin/gpgui-helper            → no-op stub
#   /usr/bin/gpgui-helper.proprietary ← original gpgui-helper
#
# Safe to invoke repeatedly. Called from post-install + package-manager hooks.

set -eu

STUB_TAG='# gpgui-free: gpgui-helper disabled'

is_our_symlink() {
    [ -L "$1" ] && [ "$(readlink "$1")" = "gpgui-free" ]
}

is_our_stub() {
    [ -f "$1" ] && head -n 3 "$1" 2>/dev/null | grep -q "$STUB_TAG"
}

# --- /usr/bin/gpgui ---
if ! is_our_symlink /usr/bin/gpgui; then
    if [ -e /usr/bin/gpgui ] && [ ! -L /usr/bin/gpgui ] &&
        [ ! -e /usr/bin/gpgui.proprietary ]; then
        mv /usr/bin/gpgui /usr/bin/gpgui.proprietary
    else
        rm -f /usr/bin/gpgui
    fi
    ln -s gpgui-free /usr/bin/gpgui
fi

# --- /usr/bin/gpgui-helper ---
if ! is_our_stub /usr/bin/gpgui-helper; then
    if [ -e /usr/bin/gpgui-helper ] && [ ! -L /usr/bin/gpgui-helper ] &&
        [ ! -e /usr/bin/gpgui-helper.proprietary ]; then
        mv /usr/bin/gpgui-helper /usr/bin/gpgui-helper.proprietary
    else
        rm -f /usr/bin/gpgui-helper
    fi
    cat >/usr/bin/gpgui-helper <<EOF
#!/bin/sh
$STUB_TAG
# Original (if any) kept at /usr/bin/gpgui-helper.proprietary
exit 0
EOF
    chmod 755 /usr/bin/gpgui-helper
fi
