#!/bin/bash
# Builds a Release copy of KVM Console into dist/.
#
#   scripts/release.sh             Signed with your development identity. For your own Macs.
#   scripts/release.sh --notarize  Developer ID signed and notarized by Apple. For sharing.
#   scripts/release.sh --app-store Signed for the Mac App Store and uploaded to App Store
#                                  Connect (TestFlight) with the Apple ID in Xcode > Settings >
#                                  Accounts. Set BUILD_NUMBER (default: a timestamp).
#
# Both need Config/Local.xcconfig with your DEVELOPMENT_TEAM (see "Building" in the README).
# --notarize also needs a paid Apple Developer Program membership and stored
# notary credentials. Create those once with:
#
#   xcrun notarytool store-credentials kvm-console \
#       --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific password>
#
# Use another profile name by setting NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=0
APP_STORE=0
case "${1:-}" in
  "") ;;
  --notarize) NOTARIZE=1 ;;
  --app-store) APP_STORE=1 ;;
  *) echo "usage: scripts/release.sh [--notarize | --app-store]" >&2; exit 2 ;;
esac

SCHEME=KVMConsole
APP_NAME="KVM Console.app"
BUILD=build/release
NOTARY_PROFILE="${NOTARY_PROFILE:-kvm-console}"

if [[ ! -f Config/Local.xcconfig ]]; then
  echo "Config/Local.xcconfig is missing. Copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM." >&2
  exit 1
fi
TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig | head -n 1)"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == "XXXXXXXXXX" ]]; then
  echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig to your 10-character team ID." >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "xcodegen is not installed. Run: brew install xcodegen" >&2; exit 1; }
xcodegen generate

VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n 1)"
VERSION="${VERSION:-0.0.0}"

rm -rf "$BUILD" dist
mkdir -p "$BUILD" dist

if [[ "$APP_STORE" == 1 ]]; then
  # The build number must grow with every upload of the same version.
  BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
  echo "==> Archiving $SCHEME $VERSION ($BUILD_NUMBER) for the App Store"
  xcodebuild archive \
    -project KVMConsole.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$BUILD/$SCHEME.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates

  cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

  echo "==> Uploading to App Store Connect"
  xcodebuild -exportArchive \
    -archivePath "$BUILD/$SCHEME.xcarchive" \
    -exportPath "$BUILD/appstore" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -allowProvisioningUpdates
  echo "==> Uploaded $VERSION ($BUILD_NUMBER). It shows up in App Store Connect > TestFlight once processed."
  exit 0
fi

echo "==> Archiving $SCHEME $VERSION"
xcodebuild archive \
  -project KVMConsole.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD/$SCHEME.xcarchive"

if [[ "$NOTARIZE" == 0 ]]; then
  ditto "$BUILD/$SCHEME.xcarchive/Products/Applications/$APP_NAME" "dist/$APP_NAME"
  echo "==> Built dist/$APP_NAME (development signed; other Macs will warn that it is from an unidentified developer)"
  exit 0
fi

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$BUILD/$SCHEME.xcarchive" \
  -exportPath "$BUILD/export" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -allowProvisioningUpdates

echo "==> Notarizing (this can take a few minutes)"
ditto -c -k --keepParent "$BUILD/export/$APP_NAME" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$BUILD/export/$APP_NAME"

ditto -c -k --keepParent "$BUILD/export/$APP_NAME" "dist/KVMConsole-$VERSION.zip"
echo "==> Built dist/KVMConsole-$VERSION.zip (notarized)"
