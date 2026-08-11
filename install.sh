#!/bin/bash
# Install the background watcher: normalizes your icons now, then re-applies them
# automatically after app updates. Run with sudo:
#
#   sudo ./install.sh
#
# You only need this if you want it to run automatically. For a one-off fix,
# just use ./run.sh — nothing gets installed.
#
# Env: ICON_NORMALIZER_THRESHOLD=0.90 changes the "oversized" cutoff.
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run:  sudo ./install.sh" >&2
    exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/local/icon-normalizer"
LABEL="com.icon-normalizer.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
WRAPPER="$DEST/Icon Normalizer"
THRESHOLD="${ICON_NORMALIZER_THRESHOLD:-0.92}"

# The watcher inherits the same settings you'd pass to run.sh. Threshold always
# has a value; the rest are baked in only if you set them.
ENV_XML="<key>ICON_NORMALIZER_THRESHOLD</key><string>$THRESHOLD</string>"
RUN_ENV="ICON_NORMALIZER_THRESHOLD=$THRESHOLD"
for v in ICON_NORMALIZER_SQUIRCLE ICON_NORMALIZER_CONTENT ICON_NORMALIZER_SCAN_DIRS; do
    val="${!v-}"
    if [ -n "$val" ]; then
        ENV_XML="$ENV_XML<key>$v</key><string>$val</string>"
        RUN_ENV="$RUN_ENV $v=$val"
    fi
done

echo "==> Installing to $DEST"
mkdir -p "$DEST"
cp -f "$REPO/normalizer.py" "$DEST/"
[ -x "$DEST/venv/bin/python" ] || /usr/bin/python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --quiet --upgrade pip
"$DEST/venv/bin/pip" install --quiet --disable-pip-version-check -r "$REPO/requirements.txt"
"$DEST/venv/bin/python" -c "import PIL, AppKit" && echo "    deps OK"

cat > "$WRAPPER" <<EOF
#!/bin/sh
exec "$DEST/venv/bin/python" "$DEST/normalizer.py" "\$@"
EOF
chmod 755 "$WRAPPER"
codesign --force --sign - "$WRAPPER" 2>/dev/null || true
mkdir -p /usr/local/bin
ln -sf "$WRAPPER" /usr/local/bin/icon-normalizer   # short command for manual re-runs

echo "==> Normalizing your icons now"
env $RUN_ENV "$DEST/venv/bin/python" "$DEST/normalizer.py" || true

echo "==> Installing the watcher ($LABEL)"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$WRAPPER</string></array>
    <key>EnvironmentVariables</key>
    <dict>$ENV_XML</dict>
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

# Robust (re)load: unload any existing instance by label AND path first, then
# bootstrap. "Bootstrap failed: 5" just means it was already loaded, so we fall
# back to kickstart instead of aborting.
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootout system "$PLIST"    2>/dev/null || true
launchctl enable "system/$LABEL"     2>/dev/null || true
if launchctl bootstrap system "$PLIST" 2>/dev/null; then
    launchctl kickstart -k "system/$LABEL" 2>/dev/null || true
    echo "    watcher active."
elif launchctl kickstart -k "system/$LABEL" 2>/dev/null; then
    echo "    watcher active (was already loaded)."
else
    echo "    NOTE: couldn't (re)load the watcher automatically. Try:"
    echo "      sudo launchctl bootout system/$LABEL; sudo ./install.sh"
fi

echo ""
echo "DONE. The watcher re-applies your icons after app updates."
echo "  Uninstall:  sudo ./uninstall.sh"
