#!/bin/bash
# Build a separate WidgetKit edition. Leaves build/AI额度.app untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ROOT="${AI_QUOTA_BUILD_ROOT:-$PWD/build/widget}"
APP="$BUILD_ROOT/AI额度.app"
EXT="$APP/Contents/PlugIns/AIQuotaWidget.appex"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-io.github.aiquota.monitor}"
WIDGET_BUNDLE_ID="${WIDGET_BUNDLE_ID:-$APP_BUNDLE_ID.widget}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Apple Development}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "小组件需要同团队开发签名来读取共享额度，不再支持 ad-hoc 发布。" >&2
  exit 1
fi
APP_TEAM_ID="${APP_TEAM_ID:-$(security find-certificate -c "$SIGNING_IDENTITY" -p | openssl x509 -noout -subject | sed -E 's/.*OU[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/')}"
if [[ ! "$APP_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "未找到开发证书的 Team ID，请先在 Xcode 配置 Apple Development 签名。" >&2
  exit 1
fi
APP_GROUP_ID="${APP_GROUP_ID:-$APP_TEAM_ID.$APP_BUNDLE_ID}"
if [[ "$APP_GROUP_ID" != "$APP_TEAM_ID."* ]]; then
  echo "macOS 共享组必须以当前签名团队 ID 开头。" >&2
  exit 1
fi
export APP APP_GROUP_ID APP_TEAM_ID APP_BUNDLE_ID WIDGET_BUNDLE_ID
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" build/module-cache "$BUILD_ROOT"
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 5 -O -D WIDGET_SUPPORT -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework SwiftUI -framework WebKit -framework WidgetKit -framework ServiceManagement Sources/*.swift Shared/*.swift -o "$APP/Contents/MacOS/AIQuota"
if [[ -d "$PWD/Resources" ]]; then
  /usr/bin/ditto "$PWD/Resources" "$APP/Contents/Resources"
fi
# WidgetKit requires an actual extension target and NSExtensionMain entry point.
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project WidgetExtension/AIQuotaWidget.xcodeproj -scheme AIQuotaWidget \
  -configuration Release -derivedDataPath "$BUILD_ROOT/widget-derived" \
  CODE_SIGNING_ALLOWED=NO "AI_QUOTA_APP_GROUP=$APP_GROUP_ID" \
  "PRODUCT_BUNDLE_IDENTIFIER=$WIDGET_BUNDLE_ID" build > "$BUILD_ROOT/widget-xcode.log" 2>&1
# Replace only generated extension artifacts, not user data.
/usr/bin/ditto "$BUILD_ROOT/widget-derived/Build/Products/Release/AIQuotaWidget.appex" "$EXT"
python3 - <<'PY'
import os,plistlib,pathlib
app=pathlib.Path(os.environ['APP'])/'Contents'
group=os.environ['APP_GROUP_ID']
base=dict(CFBundleShortVersionString='1.1.2',CFBundleVersion='5',LSMinimumSystemVersion='14.0',AIQuotaAppGroup=group)
main=dict(base,CFBundleExecutable='AIQuota',CFBundleIdentifier=os.environ['APP_BUNDLE_ID'],CFBundleName='AI额度',CFBundleDisplayName='AI额度',CFBundleIconFile='AppIcon',CFBundlePackageType='APPL',LSUIElement=True,NSHighResolutionCapable=True,CFBundleURLTypes=[dict(CFBundleURLName='AIQuota',CFBundleURLSchemes=['aiquota'])])

for path,value in [(app/'Info.plist',main),(pathlib.Path(os.environ['APP']).parent/'host.entitlements',{'com.apple.security.application-groups':[group]}),(pathlib.Path(os.environ['APP']).parent/'widget.entitlements',{'com.apple.security.app-sandbox':True,'com.apple.security.application-groups':[group]})]:
 path.write_bytes(plistlib.dumps(value))
PY
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$BUILD_ROOT/widget.entitlements" "$EXT"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$BUILD_ROOT/host.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
./scripts/verify-widget.sh
echo "$APP"
