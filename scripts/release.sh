#!/bin/bash
#
# Keep Mac Awake — Developer ID signed, notarized, stapled DMG.
#
# Usage: ./scripts/release.sh [version]        (default: value in project.yml)
#
# Requires an Apple Developer account: a "Developer ID Application" certificate
# in your keychain, and notarytool credentials saved once with
#
#   xcrun notarytool store-credentials <profile> \
#     --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
#
# Configure via environment (defaults suit this repo's owner):
#
#   KMA_TEAM_ID         Apple Developer Team ID          (default: from project.yml)
#   KMA_SIGN_IDENTITY   codesign identity                (default: the only
#                                                         "Developer ID Application"
#                                                         in your keychain)
#   KMA_NOTARY_PROFILE  notarytool keychain profile name (default: keep-mac-awake)
#
# Produces:
#   build/export-devid/Keep Mac Awake.app   signed + notarized + stapled
#   build/KeepMacAwake-<version>.dmg        signed + notarized + stapled

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="Keep Mac Awake"

cd "$ROOT"

# Optional untracked overrides, so the maintainer does not have to export
# variables on every release. See .internal/release.env.example.
if [[ -f "$ROOT/.internal/release.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.internal/release.env"
fi

readonly TEAM_ID="${KMA_TEAM_ID:-$(/usr/bin/awk -F': ' '/DEVELOPMENT_TEAM:/{print $2; exit}' project.yml | tr -d ' ')}"
readonly NOTARY_PROFILE="${KMA_NOTARY_PROFILE:-keep-mac-awake}"
readonly HELPER_NAME="$(/usr/bin/awk -F': ' '/PRODUCT_BUNDLE_IDENTIFIER: .*\.helper$/{print $2; exit}' project.yml | tr -d ' ')"

# Fall back to whatever Developer ID Application identity is installed, so a
# fork works without editing this file.
if [[ -n "${KMA_SIGN_IDENTITY:-}" ]]; then
  readonly IDENTITY="$KMA_SIGN_IDENTITY"
else
  readonly IDENTITY="$(security find-identity -v -p codesigning \
    | /usr/bin/sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi

if [[ -z "$IDENTITY" ]]; then
  echo "No 'Developer ID Application' identity found in your keychain." >&2
  echo "Create one at developer.apple.com, or set KMA_SIGN_IDENTITY." >&2
  exit 1
fi

echo "identity: $IDENTITY"
echo "team:     $TEAM_ID"
echo "notary:   $NOTARY_PROFILE"
echo "helper:   $HELPER_NAME"

VERSION="${1:-$(/usr/bin/awk -F'"' '/MARKETING_VERSION:/{print $2; exit}' project.yml)}"

readonly BUILD="$ROOT/build"
readonly ARCHIVE="$BUILD/KeepMacAwake.xcarchive"
readonly EXPORT_DIR="$BUILD/export-devid"
readonly APP="$EXPORT_DIR/$APP_NAME.app"
readonly DMG="$BUILD/KeepMacAwake-$VERSION.dmg"

step() { printf '\n=== %s ===\n' "$1"; }

step "1/9 Version $VERSION + project generation"
/usr/bin/sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
# The build number must change every release: the app compares it against the
# installed helper's to detect an in-place update and re-register the daemon.
BUILD_NUMBER=$(( $(/usr/bin/awk -F'"' '/CURRENT_PROJECT_VERSION:/{print $2; exit}' project.yml) + 1 ))
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
echo "build number: $BUILD_NUMBER"
xcodegen generate

step "2/9 Unit tests"
xcodebuild -project KeepMacAwake.xcodeproj -scheme KeepMacAwakeTests \
  -destination 'platform=macOS' test | tail -3

step "3/9 Archive (universal)"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG"
xcodebuild archive \
  -project KeepMacAwake.xcodeproj \
  -scheme KeepMacAwake \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -allowProvisioningUpdates | tail -3

step "4/9 Export (Developer ID)"
cat > "$BUILD/ExportOptionsDevID.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
# PATH prefix is required: a Homebrew rsync on PATH breaks xcodebuild's copy step.
PATH="/usr/bin:$PATH" xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD/ExportOptionsDevID.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates | tail -3

step "5/9 Verify signatures and bundle layout"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority=Developer ID|flags=|TeamIdentifier'
echo "--- embedded helper ---"
codesign -dv --verbose=4 "$APP/Contents/MacOS/$HELPER_NAME" 2>&1 \
  | grep -E 'Authority=Developer ID|flags='
test -f "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME.plist" \
  || { echo "launchd plist missing"; exit 1; }
lipo -info "$APP/Contents/MacOS/$APP_NAME"
lipo -info "$APP/Contents/MacOS/$HELPER_NAME"

step "6/9 Notarize the app"
rm -f "$BUILD/app.zip"
ditto -c -k --keepParent "$APP" "$BUILD/app.zip"
xcrun notarytool submit "$BUILD/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

step "7/9 Build DMG around the stapled app"
rm -rf "$BUILD/dmg-staging"
mkdir -p "$BUILD/dmg-staging"
ditto "$APP" "$BUILD/dmg-staging/$APP_NAME.app"
ln -s /Applications "$BUILD/dmg-staging/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD/dmg-staging" \
  -ov -format UDZO "$DMG"

step "8/9 Sign + notarize DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "9/9 Verify as a downloaded file would be seen"
spctl -a -vv "$APP"

printf '\nDone: %s\n' "$DMG"
