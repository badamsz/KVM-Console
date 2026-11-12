#!/bin/bash
# Archives KVM Console for the Mac App Store and exports or uploads it.
# Called by the app-store job in .github/workflows/release.yml.
#
# Signing is automatic ("cloud signing"): Xcode uses the App Store Connect API
# key to fetch or create the Apple Distribution and Mac Installer Distribution
# certificates and the Mac App Store provisioning profile. Nothing else needs
# to be in the keychain. The key needs the Admin role, or App Manager with
# access to cloud-managed distribution certificates.
#
# Inputs (environment):
#   TEAM_ID                       10-character team ID (required)
#   ASC_KEY_PATH, ASC_KEY_ID,
#   ASC_ISSUER_ID                 App Store Connect API key (required)
#   MARKETING_VERSION             CFBundleShortVersionString, e.g. 1.0.0 (required)
#   BUILD_NUMBER                  CFBundleVersion; must grow with every upload (required)
#   UPLOAD                        "true": upload to App Store Connect (lands in
#                                 TestFlight). Anything else: export the .pkg only.
#
# Output: dist-appstore/ holds the .pkg when not uploading, plus the export log.
set -euo pipefail

: "${TEAM_ID:?}" "${ASC_KEY_PATH:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
: "${MARKETING_VERSION:?}" "${BUILD_NUMBER:?}"
UPLOAD="${UPLOAD:-false}"

ARCHIVE=build/AppStore.xcarchive
EXPORT=build/appstore-export
APP="$ARCHIVE/Products/Applications/KVM Console.app"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

rm -rf "$ARCHIVE" "$EXPORT" dist-appstore
mkdir -p dist-appstore

echo "==> Archiving $MARKETING_VERSION ($BUILD_NUMBER) for the App Store"
# PIKVM_CODE_SIGN_IDENTITY feeds the app target's CODE_SIGN_IDENTITY (see
# project.yml). Overriding it rather than CODE_SIGN_IDENTITY leaves the
# Swift package targets alone.
xcodebuild archive \
  -project KVMConsole.xcodeproj \
  -scheme KVMConsole \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  PIKVM_CODE_SIGN_IDENTITY="Apple Development" \
  "${AUTH[@]}"

echo "==> Checking the archive"
codesign --display --entitlements - "$APP" > build/entitlements.txt 2>&1 || true
cat build/entitlements.txt
grep -q 'com.apple.security.app-sandbox' build/entitlements.txt \
  || { echo "::error::The archived app is not sandboxed; the App Store rejects it"; exit 1; }
[[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] \
  || { echo "::error::PrivacyInfo.xcprivacy is missing from the app bundle"; exit 1; }

destination=export
[[ "$UPLOAD" == true ]] && destination=upload
cat > build/AppStoreExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> Exporting (destination: $destination)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist build/AppStoreExportOptions.plist \
  "${AUTH[@]}"

if [[ "$destination" == export ]]; then
  find "$EXPORT" -maxdepth 1 -name '*.pkg' -exec cp {} dist-appstore/ \;
  ls -l dist-appstore
else
  echo "==> Uploaded. The build appears in App Store Connect > TestFlight after Apple processes it (usually 5 to 30 minutes)."
fi
