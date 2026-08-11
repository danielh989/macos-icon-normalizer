#!/bin/bash
# Set up icon-normalizer. Run with sudo.
#
#   sudo ./install.sh            # install the scanner + normalize now (on-demand)
#   sudo ./install.sh --watcher  # ALSO install the background watcher (auto re-apply)
#
# The watcher is optional: without it, nothing runs in the background — you
# re-apply from the GUI or CLI whenever you like. Add --watcher for a launchd
# service that re-normalizes automatically after app updates.
#
# Env: ICON_NORMALIZER_THRESHOLD=0.90 changes the "oversized" cutoff.
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo:  sudo ./install.sh [--watcher]" >&2
    exit 1
fi

WATCHER=0; [ "$1" = "--watcher" ] && WATCHER=1
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/local/icon-normalizer"
LABEL="com.icon-normalizer.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
WRAPPER="$DEST/Icon Normalizer"
THRESHOLD="${ICON_NORMALIZER_THRESHOLD:-0.92}"

echo "==> Installing scanner to $DEST"
mkdir -p "$DEST"
cp -f "$REPO/normalizer.py" "$DEST/"

echo "==> Creating self-contained venv (Pillow + pyobjc)"
[ -x "$DEST/venv/bin/python" ] || /usr/bin/python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --quiet --upgrade pip
"$DEST/venv/bin/pip" install --quiet --disable-pip-version-check -r "$REPO/requirements.txt"
"$DEST/venv/bin/python" -c "import PIL, AppKit; print('   deps OK')"

echo "==> Writing launcher wrapper"
cat > "$WRAPPER" <<EOF
#!/bin/sh
exec "$DEST/venv/bin/python" "$DEST/normalizer.py" "\$@"
EOF
chmod 755 "$WRAPPER"
codesign --force --sign - "$WRAPPER" 2>/dev/null || true

echo "==> Normalizing current icons"
ICON_NORMALIZER_THRESHOLD="$THRESHOLD" "$DEST/venv/bin/python" "$DEST/normalizer.py" || true

if [ "$WATCHER" = "1" ]; then
    echo "==> Installing background watcher ($LABEL)"
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
    launchctl bootout system "$PLIST" 2>/dev/null || true
    launchctl bootstrap system "$PLIST"
    launchctl enable "system/$LABEL"
    launchctl kickstart -k "system/$LABEL" || true
    echo "    watcher active — will re-normalize after app updates."
else
    echo ""
    echo "Watcher NOT installed (on-demand mode)."
    echo "Enable auto re-apply with:  sudo ./install.sh --watcher"
fi

echo ""
echo "DONE (threshold ${THRESHOLD}).  Uninstall: sudo ./uninstall.sh"
