#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/AI额度.app"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-io.github.aiquota.monitor}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 5 -O -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework SwiftUI -framework WebKit -framework ServiceManagement Sources/*.swift -o "$APP/Contents/MacOS/AIQuota"
if [[ -d "$PWD/Resources" ]]; then
  /usr/bin/ditto "$PWD/Resources" "$APP/Contents/Resources"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIQuota</string>
<key>CFBundleIdentifier</key><string>$APP_BUNDLE_ID</string>
<key>CFBundleName</key><string>AI额度</string>
<key>CFBundleDisplayName</key><string>AI额度</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
