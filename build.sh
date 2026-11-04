#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
export CLANG_MODULE_CACHE_PATH="$PWD/.dev/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
APP="build.noindex/DigUp Personal.app"
scripts/build-sqlite.sh
scripts/build-llama.sh
# Swift 6.4's clang-linker invocation uses --sysroot, which can incorrectly stamp the deployment target
# as the SDK version. AppKit then uses legacy controls. Pass Darwin's -isysroot explicitly; keep macOS 14
# as the deployment minimum while recording the SDK actually used to build the app.
SWIFT=(--disable-sandbox --scratch-path .build-personal --cache-path .dev/swift-cache --config-path .dev/swift-config --security-path .dev/swift-security -c release
  -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDKROOT")
swift build "${SWIFT[@]}"
BIN_DIR="$(swift build "${SWIFT[@]}" --show-bin-path)"
BUILT_SDK="$(xcrun vtool -show-build "$BIN_DIR/DigUpApp" | awk '$1 == "sdk" { print $2; exit }')"
if [[ "$BUILT_SDK" != "$SDK_VERSION" ]]; then
  echo "App SDK stamp is $BUILT_SDK; expected $SDK_VERSION. Refusing to package legacy window controls." >&2
  exit 1
fi
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
