#!/bin/bash
# Build a Release Saddle.app and pack it into build/Saddle-<version>-<sha>.dmg.
# Uses a Developer ID Application certificate for team 642D33P2TL when one is
# installed (hardened runtime, notarize only if notarytool already has credentials).
# Otherwise signs with the Apple Development certificate for that team.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_ID="642D33P2TL"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Saddle.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING="$BUILD_DIR/staging"
DERIVED="$BUILD_DIR/DerivedData"
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"

mkdir -p "$BUILD_DIR"

identity_team() {
  local name="$1"
  security find-certificate -c "$name" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/.*OU=\([^,]*\).*/\1/p' \
    | head -n 1
}

select_identity() {
  local prefix="$1"
  local line name team
  while IFS= read -r line; do
    name=$(printf '%s\n' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')
    [[ -n "$name" ]] || continue
    [[ "$name" == "$prefix"* ]] || continue
    team="$(identity_team "$name" || true)"
    if [[ "$team" == "$TEAM_ID" || "$name" == *"($TEAM_ID)"* ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(security find-identity -v -p codesigning)
  return 1
}

SIGN_KIND="development"
if IDENTITY="$(select_identity "Developer ID Application")"; then
  SIGN_KIND="developer-id"
elif IDENTITY="$(select_identity "Apple Development")"; then
  SIGN_KIND="development"
else
  echo "No Developer ID Application or Apple Development identity for team $TEAM_ID." >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

echo "Signing identity ($SIGN_KIND): $IDENTITY"

rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGING"
mkdir -p "$BUILD_DIR"

ARCHIVE_ARGS=(
  -project "$ROOT/saddle.xcodeproj"
  -scheme saddle
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE"
  -derivedDataPath "$DERIVED"
  -allowProvisioningUpdates
  DEVELOPMENT_TEAM="$TEAM_ID"
)
if [[ "$SIGN_KIND" == "developer-id" ]]; then
  ARCHIVE_ARGS+=(ENABLE_HARDENED_RUNTIME=YES)
fi

echo "Archiving Release saddle…"
xcodebuild archive "${ARCHIVE_ARGS[@]}" 2>&1 | tee "$BUILD_DIR/archive.log"

write_export_plist() {
  local method="$1"
  cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>method</key>
	<string>${method}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
</dict>
</plist>
EOF
}

export_archive() {
  local method="$1"
  echo "Exporting archive with method ${method}…"
  write_export_plist "$method"
  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates \
    2>&1 | tee "$BUILD_DIR/export-${method}.log"
}

exported=0
if [[ "$SIGN_KIND" == "developer-id" ]]; then
  if export_archive developer-id; then
    exported=1
  fi
else
  # `development` still exports, and current Xcode also accepts `debugging`.
  if export_archive development; then
    exported=1
  elif export_archive debugging; then
    exported=1
  elif export_archive mac-application; then
    exported=1
  fi
fi

APP_SRC=""
if [[ "$exported" -eq 1 ]]; then
  while IFS= read -r candidate; do
    APP_SRC="$candidate"
    break
  done < <(find "$EXPORT_DIR" -maxdepth 2 -type d -name '*.app' 2>/dev/null || true)
fi
if [[ -z "$APP_SRC" ]]; then
  echo "Export did not produce an app. Using the archive product."
  while IFS= read -r candidate; do
    APP_SRC="$candidate"
    break
  done < <(find "$ARCHIVE/Products" -maxdepth 3 -type d -name '*.app' 2>/dev/null || true)
fi
if [[ -z "$APP_SRC" || ! -d "$APP_SRC" ]]; then
  echo "No .app was produced." >&2
  exit 1
fi
echo "App source: $APP_SRC"

mkdir -p "$STAGING"
ditto "$APP_SRC" "$STAGING/Saddle.app"
ln -s /Applications "$STAGING/Applications"

APP="$STAGING/Saddle.app"
APPEX="$APP/Contents/PlugIns/SaddleFileProvider.appex"
if [[ ! -d "$APPEX" ]]; then
  echo "SaddleFileProvider.appex is not embedded at Contents/PlugIns." >&2
  find "$APP" -name '*.appex' -o -name '*.app' >&2 || true
  exit 1
fi

echo "Verifying code signature…"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tee "$BUILD_DIR/codesign-verify.txt"
# `-dv --entitlements -` prints a readable dump. `:-` is the XML plist PlistBuddy can read.
codesign -dv --entitlements - "$APP" > "$BUILD_DIR/app-entitlements.txt" 2> "$BUILD_DIR/app-codesign.txt"
codesign -d --entitlements :- "$APP" > "$BUILD_DIR/app-entitlements.plist"
codesign -dv --entitlements - "$APPEX" > "$BUILD_DIR/appex-entitlements.txt" 2> "$BUILD_DIR/appex-codesign.txt"
codesign -d --entitlements :- "$APPEX" > "$BUILD_DIR/appex-entitlements.plist"

entitlement_value() {
  local file="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print ${key}" "$file"
}

APP_GROUP="$(entitlement_value "$BUILD_DIR/app-entitlements.plist" ":com.apple.security.application-groups:0")"
APP_KEYCHAIN="$(entitlement_value "$BUILD_DIR/app-entitlements.plist" ":keychain-access-groups:0")"
APPEX_GROUP="$(entitlement_value "$BUILD_DIR/appex-entitlements.plist" ":com.apple.security.application-groups:0")"
APPEX_KEYCHAIN="$(entitlement_value "$BUILD_DIR/appex-entitlements.plist" ":keychain-access-groups:0")"

echo "App group:     ${APP_GROUP}"
echo "App keychain:  ${APP_KEYCHAIN}"
echo "Appex group:   ${APPEX_GROUP}"
echo "Appex keychain:${APPEX_KEYCHAIN}"

if [[ -z "$APP_GROUP" || "$APP_GROUP" != "$APPEX_GROUP" || "$APP_KEYCHAIN" != "$APPEX_KEYCHAIN" ]]; then
  echo "App and extension entitlements do not match." >&2
  exit 1
fi
case "$APP_GROUP" in
  "$TEAM_ID."*) ;;
  *)
    echo "Application group ${APP_GROUP} is not for team ${TEAM_ID}." >&2
    exit 1
    ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
SHA="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
DMG="$BUILD_DIR/Saddle-${VERSION}-${SHA}.dmg"

echo "Creating ${DMG}…"
hdiutil create -volname Saddle -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "Signing DMG…"
if [[ "$SIGN_KIND" == "developer-id" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
else
  codesign --sign "$IDENTITY" "$DMG"
fi
codesign --verify --verbose=2 "$DMG" 2>&1 | tee "$BUILD_DIR/dmg-codesign.txt"

if [[ "$SIGN_KIND" == "developer-id" ]]; then
  if xcrun notarytool history >/dev/null 2>&1; then
    echo "Submitting DMG for notarization…"
    xcrun notarytool submit "$DMG" --wait 2>&1 | tee "$BUILD_DIR/notarize.log"
    xcrun stapler staple "$DMG"
  else
    echo "Notarization skipped: notarytool has no stored credentials."
  fi
else
  echo "Notarization skipped: signed with Apple Development, not Developer ID."
fi

echo "DMG ready: $DMG"
ls -lh "$DMG"
