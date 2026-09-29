#!/bin/sh
# Builds Zombieport.app in ./build.
#
#   --install   Copy the app to /Applications.
#   --notarize  Send the app to Apple's notary service and staple the ticket.
#               Needs CODESIGN_IDENTITY and NOTARY_PROFILE.
#
# Environment:
#   CODESIGN_IDENTITY  Signing identity, such as "Developer ID Application: Name (TEAMID)".
#                      Without it, the app gets an ad hoc signature that works only on this Mac.
#   NOTARY_PROFILE     Keychain profile that `xcrun notarytool store-credentials` created.
set -e
cd "$(dirname "$0")"

INSTALL=0
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
if [ "$NOTARIZE" = 1 ] && { [ -z "$CODESIGN_IDENTITY" ] || [ -z "$NOTARY_PROFILE" ]; }; then
  echo "--notarize needs CODESIGN_IDENTITY and NOTARY_PROFILE." >&2
  exit 2
fi

swift build -c release
APP=build/Zombieport.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp .build/release/Zombieport "$APP/Contents/MacOS/Zombieport"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zombieport</string>
  <key>CFBundleIdentifier</key><string>com.craftatom.zombieport</string>
  <key>CFBundleExecutable</key><string>Zombieport</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 CraftAtom Technologies. Available under the MIT License.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [ -n "$CODESIGN_IDENTITY" ]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "$NOTARIZE" = 1 ]; then
  ZIP=build/Zombieport.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  # Zip the stapled app, so the archive that you share works offline too.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Notarized $APP and wrote $ZIP"
fi

if [ "$INSTALL" = 1 ]; then
  rm -rf /Applications/Zombieport.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Zombieport.app"
fi
