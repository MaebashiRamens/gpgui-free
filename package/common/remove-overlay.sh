#!/usr/bin/env bash
# remove-overlay.sh — revert the gpgui-free overlay. Called from pre-remove.

set -eu

STUB_TAG='# gpgui-free: gpgui-helper disabled'

if [ -L /usr/bin/gpgui ] && [ "$(readlink /usr/bin/gpgui)" = "gpgui-free" ]; then
    rm -f /usr/bin/gpgui
    if [ -e /usr/bin/gpgui.proprietary ]; then
        mv /usr/bin/gpgui.proprietary /usr/bin/gpgui
    fi
fi

if [ -f /usr/bin/gpgui-helper ] &&
    head -n 3 /usr/bin/gpgui-helper 2>/dev/null | grep -q "$STUB_TAG"; then
    rm -f /usr/bin/gpgui-helper
    if [ -e /usr/bin/gpgui-helper.proprietary ]; then
        mv /usr/bin/gpgui-helper.proprietary /usr/bin/gpgui-helper
    fi
fi
