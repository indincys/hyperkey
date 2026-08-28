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
VERSION="1.3.3"
SIGN_ID="${SIGN_ID:--}"
# securityd keys the broker's creator partition to this CDHash. It must not move when
# only the main app changes; changing it is a separate, explicitly migrated event.
EXPECTED_BROKER_CDHASH="7cd11f860fa5379ff89acd07723f0247b48a4038"
EXPECTED_BROKER_SHA256="014458c1a003da04ba4102d02b3ccb5278b66a33cd236f8ab5725b6597d6b1fe"

if [ "$SIGN_ID" = "-" ]; then
    echo "注意：正在使用 ad-hoc 签名。每次重建都会产生新的签名身份，"
    echo "      于是「辅助功能」授权每次都要重新授予一次。"
    echo "      正式发布请先跑 ./make-signing-cert.sh，然后："
    echo "          SIGN_ID=\"Hyper Local Secure 2026\" ./build.sh"
    echo
fi

# Tests run on the host's own architecture and in debug — the point is the assertions,
# not the build flavour. `set -e` aborts the build if any of them fail.
echo "==> swift test"
swift test 2>&1 | tail -5

echo "==> swift build (release, arm64)"
swift build -c release --arch arm64 --product Hyper
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Hyper"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hyper"
cp Resources/HyperKeyBroker "$APP/Contents/Helpers/HyperKeyBroker"

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

echo "==> verify immutable signed key broker"
BROKER_SHA256="$(shasum -a 256 "$APP/Contents/Helpers/HyperKeyBroker" | awk '{print $1}')"
BROKER_CDHASH="$(codesign -dvvv "$APP/Contents/Helpers/HyperKeyBroker" 2>&1 \
    | sed -n 's/^CDHash=//p')"
BROKER_DR="$(codesign -d -r- "$APP/Contents/Helpers/HyperKeyBroker" 2>&1 \
    | sed -n 's/^designated => //p')"
EXPECTED_BROKER_DR='identifier "com.indincys.hyper.keybroker" and certificate leaf = H"b9c36646f5ddd4cb7b116e5c3baf7b3e747b377e"'
if [ "$BROKER_SHA256" != "$EXPECTED_BROKER_SHA256" ] \
    || [ "$BROKER_CDHASH" != "$EXPECTED_BROKER_CDHASH" ] \
    || [ "$BROKER_DR" != "$EXPECTED_BROKER_DR" ]; then
    echo "固定 Key Broker 校验失败；禁止构建/发布。"
    echo "SHA256=$BROKER_SHA256 CDHash=$BROKER_CDHASH DR=$BROKER_DR"
    exit 1
fi
codesign --verify --strict --verbose=1 "$APP/Contents/Helpers/HyperKeyBroker"
echo "==> codesign app (identity: $SIGN_ID)"
codesign --force --options runtime --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP/Contents/Helpers/HyperKeyBroker"
codesign --verify --deep --strict --verbose=1 "$APP"
test "$(shasum -a 256 "$APP/Contents/Helpers/HyperKeyBroker" | awk '{print $1}')" \
    = "$EXPECTED_BROKER_SHA256"

echo
echo "Built ./$APP"
echo "Install:  rm -rf /Applications/Hyper.app && cp -R $APP /Applications/"
echo "Run:      open /Applications/Hyper.app"
