#!/usr/bin/env bash
# Assemble a double-clickable, ad-hoc-signed MacAIUsageBar.app from the SwiftPM
# release build. A real bundle (with a bundle identifier) is required for
# notifications and the login item to work — neither functions under `swift run`.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacAIUsageBar"
DISPLAY_NAME="AI Usage Bar"
BUNDLE_ID="io.riibotics.MacAIUsageBar"
VERSION="0.1.0"
CONFIG="release"

echo "▶︎ swift build ($CONFIG)…"
swift build -c "$CONFIG" --product "$APP_NAME"
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/$APP_NAME.app"
echo "▶︎ 번들 조립: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key><string>Personal use.</string>
</dict>
</plist>
PLIST

if [ -f "packaging/AppIcon.icns" ]; then
    cp "packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "▶︎ ad-hoc 코드서명…"
codesign --force --deep --sign - "$APP"

echo "✅ 완료: $APP"
echo "   실행:   open \"$APP\""
echo "   설치:   /Applications 로 드래그하면 로그인 항목/알림이 안정적으로 동작합니다."
