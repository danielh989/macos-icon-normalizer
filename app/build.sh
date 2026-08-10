#!/bin/bash
# Build "Icon Normalizer.app" from IconNormalizerApp.swift.
# Requires the Swift toolchain (Xcode or Command Line Tools).
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

APP="Icon Normalizer.app"
BIN="Icon Normalizer"

echo "==> Compiling"
mkdir -p build
swiftc -O IconNormalizerApp.swift -o "build/$BIN" -framework AppKit

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "build/$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Icon Normalizer</string>
    <key>CFBundleDisplayName</key><string>Icon Normalizer</string>
    <key>CFBundleExecutable</key><string>$BIN</string>
    <key>CFBundleIdentifier</key><string>com.icon-normalizer.app</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# ad-hoc sign so Gatekeeper lets it run locally
codesign --force --sign - "$APP" 2>/dev/null || true

echo "DONE. Built ./$APP"
echo "Open it with:  open \"$(pwd)/$APP\""
