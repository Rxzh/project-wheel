#!/bin/sh
# Build ProjectWheel.app (menu-bar app, no Dock icon) into ./build.
set -e
cd "$(dirname "$0")/.."
# The default (swiftbuild) backend needs a full Xcode; native works with the CLT.
swift build -c release --build-system native
APP=build/ProjectWheel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ProjectWheel "$APP/Contents/MacOS/ProjectWheel"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ProjectWheel</string>
    <key>CFBundleIdentifier</key><string>com.rxzh.projectwheel</string>
    <key>CFBundleExecutable</key><string>ProjectWheel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Project Wheel pilote Terminal pour amener au premier plan la fenêtre du projet choisi.</string>
</dict>
</plist>
EOF
# A stable identity keeps the macOS Accessibility grant across rebuilds; an
# ad-hoc signature changes with every build and loses it.
IDENTITY="ProjectWheel Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No \"$IDENTITY\" certificate in the keychain: ad-hoc signing (Accessibility must be re-granted after each build)"
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
