#!/bin/zsh
# Build WinterIsComing as a macOS app bundle (required for Launch at Login).
set -e
cd "$(dirname "$0")"
APP="WinterIsComing.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WinterIsComing</string>
    <key>CFBundleDisplayName</key><string>WinterIsComing</string>
    <key>CFBundleIdentifier</key><string>com.winteriscoming.desktop</string>
    <key>CFBundleVersion</key><string>2.0.0</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleExecutable</key><string>WinterIsComing</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
swiftc -O -framework Cocoa -framework SpriteKit -framework ServiceManagement WinterIsComing.swift -o "$APP/Contents/MacOS/WinterIsComing"
codesign --force --deep --sign - "$APP"
echo "Build succeeded. Launching $APP"
open "$APP"
