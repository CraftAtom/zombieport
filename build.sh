#!/bin/sh
# Builds Zombieport.app in ./build. Pass --install to copy it to /Applications.
set -e
cd "$(dirname "$0")"

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
  <key>CFBundleIdentifier</key><string>dev.zombieport.app</string>
  <key>CFBundleExecutable</key><string>Zombieport</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  rm -rf /Applications/Zombieport.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Zombieport.app"
fi
