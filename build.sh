#!/bin/bash
# Build script for TopStats

set -e

echo "Building TopStats..."

# Compile main app (release optimization: -Onone debug codegen is 5-20x slower
# on the per-tick sampling/formatting paths that run every 5 s for the app's lifetime)
swiftc -O -o TopStats TopStats.swift -framework Cocoa -framework SwiftUI -framework IOKit -framework Network

# Compile temp helper (Objective-C version for accurate Apple Silicon temperature reading)
# Uses IOHIDEventSystemClient to read actual CPU die temperature from HID sensors
clang -O2 -Wall -framework IOKit -framework Foundation -o TempHelper TempHelper.m

# Create app bundle
rm -rf TopStats.app
mkdir -p "TopStats.app/Contents/MacOS"
mkdir -p "TopStats.app/Contents/Resources"

cp TopStats "TopStats.app/Contents/MacOS/"
cp TempHelper "TopStats.app/Contents/MacOS/"
cp temp_sensor "TopStats.app/Contents/MacOS/"

# Copy app icon if it exists
if [ -f "TopStats.icns" ]; then
    cp TopStats.icns "TopStats.app/Contents/Resources/AppIcon.icns"
    echo "Added app icon"
fi

# Coding-agent row logos (CodingAgentLogo loads these by name from the bundle;
# a missing file degrades to the terminal placeholder, so fail loudly here instead)
for logo in claude-code codex; do
    if [ ! -f "assets/agent-logos/$logo.png" ]; then
        echo "ERROR: missing assets/agent-logos/$logo.png" >&2
        exit 1
    fi
    cp "assets/agent-logos/$logo.png" "TopStats.app/Contents/Resources/"
done
echo "Added coding-agent logos"

cat > "TopStats.app/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>TopStats</string>
    <key>CFBundleIdentifier</key>
    <string>com.topstats.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TopStats</string>
    <key>CFBundleDisplayName</key>
    <string>TopStats</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.7.0</string>
    <key>CFBundleVersion</key>
    <string>22</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026. MIT License.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - TopStats.app >/dev/null

echo "Build complete: TopStats.app"
echo ""
echo "To install: cp -R TopStats.app /Applications/"
