#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export CLANG_MODULE_CACHE_PATH="$PWD/.dev/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
APP="build.noindex/DigUp Personal.app"
scripts/build-sqlite.sh
scripts/build-llama.sh
SWIFT=(--disable-sandbox --scratch-path .build-personal --cache-path .dev/swift-cache --config-path .dev/swift-config --security-path .dev/swift-security -c release)
swift build "${SWIFT[@]}"
BIN_DIR="$(swift build "${SWIFT[@]}" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/DigUpApp" "$APP/Contents/MacOS/DigUp Personal"
cp "$BIN_DIR/digup" "$BIN_DIR/digup-mcp" "$APP/Contents/Helpers/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Acknowledgements.txt Resources/AppIcon/tray*.png "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
if xcrun actool --compile "$APP/Contents/Resources" --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$(mktemp -d)/AppIcon.plist" --enable-on-demand-resources NO \
  --development-region en "$PWD/Resources/AppIcon/AppIcon.icon" > /dev/null 2>&1; then
  true
else
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${SIGN_ID:--}"
for code in "$APP/Contents/Helpers/digup" "$APP/Contents/Helpers/digup-mcp"; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$code"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements Resources/DigUp.entitlements "$APP"
echo "Built $APP"
