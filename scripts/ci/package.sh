#!/bin/bash
# Signs, notarizes and packages an archived "KVM Console.app" for CI.
# Called by .github/workflows/release.yml after `xcodebuild archive`.
#
# Inputs (environment):
#   APP            path to the built "KVM Console.app" (required)
#   VERSION        version string used in file names (required)
#   SIGN_IDENTITY  codesigning identity (SHA-1 or name). Empty: ad-hoc signed.
#   KEYCHAIN       keychain holding SIGN_IDENTITY (with SIGN_IDENTITY)
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                  App Store Connect API key. All set: notarize and staple.
#
# Output: dist/KVMConsole-$VERSION.zip, dist/KVMConsole-$VERSION.dmg,
# dist/SHA256SUMS.txt
set -euo pipefail

: "${APP:?}" "${VERSION:?}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ENTITLEMENTS="KVMConsole/KVMConsole.entitlements"
WORK="${RUNNER_TEMP:-build}/package"
NAME="KVMConsole-$VERSION"

rm -rf "$WORK" dist
mkdir -p "$WORK" dist

notarize() {
  [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || return 0
  local file="$1" result id status
  echo "==> Notarizing $(basename "$file") (usually a few minutes)"
  result="$(xcrun notarytool submit "$file" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 30m --output-format json)"
  echo "$result"
  id="$(jq -r '.id // empty' <<<"$result")"
  status="$(jq -r '.status // empty' <<<"$result")"
  if [[ "$status" != "Accepted" ]]; then
    echo "::error::Notarization of $(basename "$file") ended with status '${status:-unknown}'"
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" \
        --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
    fi
    exit 1
  fi
}

# --- Sign the app ------------------------------------------------------------
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing with Developer ID"
  sign() {
    codesign --force --timestamp --options runtime \
      --sign "$SIGN_IDENTITY" ${KEYCHAIN:+--keychain "$KEYCHAIN"} "$@"
  }
else
  # No certificate: ad-hoc sign so the app still launches (Apple silicon
  # refuses unsigned code). No hardened runtime: it would make library
  # validation reject the ad-hoc signed WebRTC framework.
  echo "==> No signing certificate; ad-hoc signing"
  sign() { codesign --force --sign - "$@"; }
fi

# Nested code first, innermost first. Resource-only bundles (SwiftPM .bundle)
# are sealed as resources of the app and need no signature of their own.
if [[ -d "$APP/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' item; do
    echo "    $item"
    sign "$item"
  done < <(find "$APP/Contents/Frameworks" -depth \
             \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \) -print0)
fi
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" || true

# --- Notarize and staple the app ---------------------------------------------
if [[ -n "$SIGN_IDENTITY" ]]; then
  ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
  if notarize "$WORK/notarize.zip" && [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
  fi
fi

# --- Zip ---------------------------------------------------------------------
echo "==> Packaging $NAME.zip"
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"

# --- Disk image --------------------------------------------------------------
echo "==> Packaging $NAME.dmg"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/$(basename "$APP")"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "KVM Console" -srcfolder "$WORK/dmg" -fs HFS+ \
  -format UDZO -ov "dist/$NAME.dmg"
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" ${KEYCHAIN:+--keychain "$KEYCHAIN"} "dist/$NAME.dmg"
  if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    notarize "dist/$NAME.dmg"
    xcrun stapler staple "dist/$NAME.dmg"
  fi
fi

(cd dist && shasum -a 256 ./*.zip ./*.dmg > SHA256SUMS.txt)
ls -l dist
