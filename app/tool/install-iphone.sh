#!/bin/sh
# Builds a release for an iPhone, renews its development signing profile and
# installs it with roamrun, a separate tool the author uses to install over
# Tailscale, so the phone can be on another network. The script is optional
# and roamrun isn't part of Switchboard: without it, install with
# `flutter run --release` or from Xcode.
# Usage: tool/install-iphone.sh [roamrun device name, default iPhone]
set -eu
DEVICE="${1:-iPhone}"
command -v roamrun >/dev/null ||
  { echo "roamrun not found: install with 'flutter run --release' or from Xcode instead"; exit 1; }
cd "$(dirname "$0")/.."
. tool/local-env.sh
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Over SSH the login keychain is locked, and codesign can't reach the key.
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security show-keychain-info "$KEYCHAIN" 2>/dev/null || security unlock-keychain "$KEYCHAIN"

# Xcode reuses a cached profile until it expires. Moving this app's aside
# makes the build fetch a new one, so each install gets a profile's full life
# (7 days on a free personal team, a year on a paid team).
PBX=ios/Runner.xcodeproj/project.pbxproj
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' ios/Flutter/Local.xcconfig 2>/dev/null | head -1)
[ -n "$TEAM" ] || { echo "No team: put 'DEVELOPMENT_TEAM = <your team ID>' in ios/Flutter/Local.xcconfig"; exit 1; }
APP_ID=$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER = \([a-zA-Z0-9.]*\);.*/\1/p' "$PBX" | grep -v RunnerTests | head -1)
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for p in "$PROFILES"/*.mobileprovision; do
  [ -f "$p" ] || continue
  id=$(security cms -D -i "$p" 2>/dev/null | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)
  if [ "$id" = "$TEAM.$APP_ID" ]; then
    mkdir -p build/replaced-profiles && mv "$p" build/replaced-profiles/
    echo "Renewing the signing profile (moved $(basename "$p") to build/replaced-profiles)"
  fi
done

flutter build ios --release --dart-define=SB_DEFAULT_SERVER="$SB_DEFAULT_SERVER"
APP=build/ios/iphoneos/Runner.app
EXPIRES=$(security cms -D -i "$APP/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -)
echo "Built $APP_ID, profile expires $EXPIRES"

# Exits non-zero unless the bridge is ready.
roamrun status "$DEVICE" --wait 90 >/dev/null ||
  { roamrun status "$DEVICE"; echo "Phone not reachable: is it on Wi-Fi, unlocked, with Tailscale on?"; exit 1; }
# A locked phone, or on a free team a fourth app from that team, refuses the
# install; say why.
OUT=$(roamrun install "$DEVICE" "$APP" 2>&1) || true
echo "$OUT" | grep -q "App installed" || { echo "$OUT" | tail -5; exit 1; }
echo "App installed"
UDID=$(roamrun status "$DEVICE" --json | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['udid'])")
xcrun devicectl device process launch --device "$UDID" "$APP_ID" 2>&1 | tail -1
