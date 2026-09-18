#!/bin/bash
# Build GH Monitor for the connected iPhone and install it.
# Usage: ios/install.sh            (iPhone plugged in via USB, unlocked, "Trust this computer" accepted)
set -euo pipefail
cd "$(dirname "$0")/GHMonitor"

UDID="${1:-00008150-001E192C11A1401C}"   # czy's iPhone 17 Pro Max; pass another UDID to override

echo "▶ Generating Xcode project"
xcodegen generate >/dev/null

echo "▶ Building Release for iOS (automatic signing, team 493WT6Z4J4)"
xcodebuild -project GHMonitor.xcodeproj -scheme GHMonitor \
  -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" || true

APP=build/Build/Products/Release-iphoneos/GHMonitor.app
[ -d "$APP" ] || { echo "build failed"; exit 1; }

rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qr ../GHMonitor.ipa Payload)
echo "▶ IPA: $(pwd)/build/GHMonitor.ipa"

echo "▶ Installing on $UDID"
if xcrun devicectl device install app --device "$UDID" "$APP"; then
  echo "▶ Launching"
  xcrun devicectl device process launch --device "$UDID" com.chenzhiyuan.ghmonitor || true
  echo "✅ done — open GH Monitor on the iPhone (allow Bluetooth when asked)"
else
  echo "❌ install failed. Is the iPhone plugged in, unlocked and trusted? Try: xcrun devicectl list devices"
  echo "   Alternative: open GHMonitor.xcodeproj in Xcode, pick your iPhone and press Run."
fi
