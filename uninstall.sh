#!/bin/bash
# Remove the icon-normalizer daemon. By default it also restores the original
# icons it applied. Pass --keep-icons to leave the normalized icons in place.
#
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --keep-icons
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo ./uninstall.sh" >&2
    exit 1
fi

DEST="/usr/local/icon-normalizer"
LABEL="com.icon-normalizer.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

echo "==> Stopping daemon"
launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

if [ "$1" != "--keep-icons" ] && [ -x "$DEST/venv/bin/python" ]; then
    echo "==> Restoring original icons"
    "$DEST/venv/bin/python" "$DEST/normalizer.py" --revert || true
else
    echo "==> Leaving normalized icons in place"
fi

echo "==> Removing $DEST"
rm -rf "$DEST"

echo "DONE. icon-normalizer removed."
