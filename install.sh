#!/bin/bash
# Install icon-normalizer as a LaunchDaemon that auto-normalizes oversized app
# icons and re-applies them after updates. Run with sudo.
#
#   sudo ./install.sh
#
# Optional: override the "oversized" threshold (default 0.92):
#   sudo ICON_NORMALIZER_THRESHOLD=0.90 ./install.sh
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo ./install.sh" >&2
    exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/local/icon-normalizer"
LABEL="com.icon-normalizer.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
WRAPPER="$DEST/Icon Normalizer"     # friendly name shown in Login Items
THRESHOLD="${ICON_NORMALIZER_THRESHOLD:-0.92}"

echo "==> Installing to $DEST"
mkdir -p "$DEST"
cp -f "$REPO/normalizer.py" "$DEST/"

echo "==> Creating self-contained venv (Pillow + pyobjc)"
[ -x "$DEST/venv/bin/python" ] || /usr/bin/python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --quiet --disable-pip-version-check -r "$REPO/requirements.txt"
"$DEST/venv/bin/python" -c "import PIL, AppKit; print('   deps OK')"

echo "==> Writing launcher wrapper"
cat > "$WRAPPER" <<EOF
#!/bin/sh
# Friendly-named launcher so the background item reads "Icon Normalizer".
exec "$DEST/venv/bin/python" "$DEST/normalizer.py" "\$@"
EOF
chmod 755 "$WRAPPER"
codesign --force --sign - "$WRAPPER" 2>/dev/null || true

echo "==> Writing LaunchDaemon ($LABEL)"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$WRAPPER</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>ICON_NORMALIZER_THRESHOLD</key><string>$THRESHOLD</string></dict>
    <key>WatchPaths</key>
    <array><string>/Applications</string></array>
    <key>StartInterval</key><integer>7200</integer>
    <key>RunAtLoad</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>$DEST/launchd.out.log</string>
    <key>StandardErrorPath</key><string>$DEST/launchd.err.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

echo "==> Loading daemon and running first scan"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL"
launchctl kickstart -k "system/$LABEL" || true

echo ""
echo "DONE. icon-normalizer is active (threshold ${THRESHOLD})."
echo "  Scanner:   $DEST/normalizer.py"
echo "  Log:       $DEST/icon-normalizer.log"
echo "  Dry-run:   sudo $DEST/venv/bin/python $DEST/normalizer.py --dry-run"
echo "  Uninstall: sudo ./uninstall.sh"
