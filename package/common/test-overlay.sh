#!/usr/bin/env bash
# test-overlay.sh — overlay lifecycle scenarios in a throwaway root.
# Exercises the upgrade path that used to discard the new upstream binary.

set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/usr/bin" "$S/usr/lib/gpgui-free"

# Retarget /usr/bin to the sandbox; line 1 (shebang) must stay untouched.
for f in install-overlay.sh remove-overlay.sh; do
    sed "2,\$s|/usr/bin|$S/usr/bin|g" "$REPO/package/common/$f" >"$S/usr/lib/gpgui-free/$f"
done

install_overlay() { bash "$S/usr/lib/gpgui-free/install-overlay.sh"; }
remove_overlay() { bash "$S/usr/lib/gpgui-free/remove-overlay.sh"; }

fail=0

echo "=== 1. v1 install -> overlay -> upstream v2 upgrade -> hook -> uninstall ==="
echo "upstream-v1" >"$S/usr/bin/gpgui"
echo "helper-v1" >"$S/usr/bin/gpgui-helper"
echo "gpgui-free-bin" >"$S/usr/bin/gpgui-free"
install_overlay
rm -f "$S/usr/bin/gpgui" "$S/usr/bin/gpgui-helper"
echo "upstream-v2" >"$S/usr/bin/gpgui"
echo "helper-v2" >"$S/usr/bin/gpgui-helper"
install_overlay
remove_overlay
if [ "$(cat "$S/usr/bin/gpgui")" = "upstream-v2" ] && [ "$(cat "$S/usr/bin/gpgui-helper")" = "helper-v2" ]; then
    echo "PASS 1: newest upstream restored on uninstall"
else
    echo "FAIL 1"
    fail=1
fi

echo "=== 2. idempotency: overlay twice, backup survives ==="
echo "upstream-v1" >"$S/usr/bin/gpgui"
echo "gpgui-free-bin" >"$S/usr/bin/gpgui-free"
install_overlay
install_overlay
if [ "$(cat "$S/usr/bin/gpgui.proprietary")" = "upstream-v1" ] &&
    [ "$(readlink "$S/usr/bin/gpgui")" = "gpgui-free" ]; then
    echo "PASS 2: idempotent, backup intact"
else
    echo "FAIL 2"
    fail=1
fi

echo "=== 3. fresh install with no upstream binary ==="
rm -rf "$S/usr/bin"
mkdir -p "$S/usr/bin"
echo "gpgui-free-bin" >"$S/usr/bin/gpgui-free"
install_overlay
if [ "$(readlink "$S/usr/bin/gpgui")" = "gpgui-free" ] && [ ! -e "$S/usr/bin/gpgui.proprietary" ]; then
    echo "PASS 3: clean install, no phantom backup"
else
    echo "FAIL 3"
    fail=1
fi

echo "=== 4. foreign dangling symlink is replaced, not backed up ==="
rm -f "$S/usr/bin/gpgui"
ln -s /nonexistent "$S/usr/bin/gpgui"
install_overlay
if [ "$(readlink "$S/usr/bin/gpgui")" = "gpgui-free" ] && [ ! -e "$S/usr/bin/gpgui.proprietary" ]; then
    echo "PASS 4: foreign symlink replaced"
else
    echo "FAIL 4"
    fail=1
fi

exit $fail
