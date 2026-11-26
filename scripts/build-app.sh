#!/bin/sh
# Build ProjectWheel.app (menu-bar app, no Dock icon) into ./build.
# --universal builds arm64 and x86_64 and merges them (for releases).
set -e
cd "$(dirname "$0")/.."
APP=build/ProjectWheel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# The default (swiftbuild) backend needs a full Xcode; native works with the CLT.
# It builds one architecture at a time, hence one build per triple and lipo.
if [ "$1" = "--universal" ]; then
  for arch in arm64 x86_64; do
    swift build -c release --build-system native --triple "$arch-apple-macosx14.0"
  done
  lipo -create -output "$APP/Contents/MacOS/ProjectWheel" \
    .build/arm64-apple-macosx/release/ProjectWheel \
    .build/x86_64-apple-macosx/release/ProjectWheel
else
  swift build -c release --build-system native
  cp .build/release/ProjectWheel "$APP/Contents/MacOS/ProjectWheel"
fi
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
