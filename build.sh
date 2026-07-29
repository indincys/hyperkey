#!/usr/bin/env bash
# Builds Hyper.app — an arm64 menu-bar bundle, ad-hoc signed.
#
# Accessibility permission is keyed to the app's code signature. Ad-hoc signing
# produces a new identity on every rebuild, so macOS forgets the grant each time.
# To keep it across rebuilds, make a self-signed code-signing certificate in
# Keychain Access and build with:  SIGN_ID="My Cert Name" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Hyper.app"
BUNDLE_ID="com.indincys.hyper"
VERSION="1.0.5"
SIGN_ID="${SIGN_ID:--}"

if [ "$SIGN_ID" = "-" ]; then
    echo "注意：正在使用 ad-hoc 签名。每次重建都会产生新的签名身份，"
    echo "      于是「辅助功能」授权每次都要重新授予一次。"
    echo "      正式发布请先跑 ./make-signing-cert.sh，然后："
    echo "          SIGN_ID=\"Hyper Self-Signed\" ./build.sh"
    echo
fi

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Hyper"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hyper"

echo "==> 生成应用图标"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
# 每个尺寸都从 1024 母版重采样，避免多次缩放累积模糊
while read -r px name; do
    sips -z "$px" "$px" Resources/AppIcon.png --out "$ICONSET/icon_$name.png" >/dev/null
done <<'SIZES'
16 16x16
32 16x16@2x
32 32x32
64 32x32@2x
128 128x128
256 128x128@2x
256 256x256
512 256x256@2x
512 512x512
1024 512x512@2x
SIZES
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Hyper</string>
    <key>CFBundleDisplayName</key>       <string>Hyper</string>
    <key>CFBundleExecutable</key>        <string>Hyper</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>  <string>Hyper</string>
</dict>
</plist>
PLIST

echo "==> codesign (identity: $SIGN_ID)"
codesign --force --options runtime --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$APP"
codesign --verify --verbose=1 "$APP"

echo
echo "Built ./$APP"
echo "Install:  rm -rf /Applications/Hyper.app && cp -R $APP /Applications/"
echo "Run:      open /Applications/Hyper.app"
