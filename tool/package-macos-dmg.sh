#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN="${MAC_SIGN_IDENTITY:-Developer ID Application: MILLIONICE INVESTMENT LIMITED (J7HH8632RD)}"
ENT="$ROOT/app/macos/Runner/Release.entitlements"
SRC="$ROOT/app/build/macos/Build/Products/Release/rsq.app"
STAGE="$(mktemp -d /tmp/tiaotiaohou-dmg.XXXXXX)"
APP="$STAGE/跳跳猴.app"
DMG="$ROOT/dist/tiaotiaohou.dmg"
KEY="$HOME/.appstoreconnect/private_keys/AuthKey_H56YP793MB.p8"
KEY_ID="${ASC_KEY_ID:-H56YP793MB}"
ISSUER="${ASC_ISSUER_ID:-e75c7d08-eb2b-4eec-b827-1838f9c866b5}"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

if [ ! -d "$SRC" ]; then
  echo "找不到 $SRC，先编译 mac 应用" >&2
  exit 1
fi
if [ ! -f "$ENT" ]; then
  echo "找不到 $ENT" >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
rm -rf "$APP"
ditto "$SRC" "$APP"
ICON="$ROOT/app/macos/Runner/AppIcon.icns"
if [ -f "$ICON" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
fi
ln -s /Applications "$STAGE/Applications"

sign_item() {
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN" "$1"
}

sign_item "$APP/Contents/MacOS/librsq_core.dylib"
find "$APP/Contents/Frameworks" -name '*.dylib' -print0 | while IFS= read -r -d '' item; do
  sign_item "$item"
done
find "$APP/Contents/Frameworks" -name '*.framework' -maxdepth 1 -print0 | while IFS= read -r -d '' item; do
  sign_item "$item"
done
/usr/bin/codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$SIGN" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

rm -f "$DMG"
hdiutil create -volname "跳跳猴" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
/usr/bin/codesign --force --timestamp --sign "$SIGN" "$DMG"
/usr/bin/codesign --verify --strict "$DMG"

if [ -f "$KEY" ]; then
  echo "提交公证…"
  if xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait; then
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
  else
    echo "公证失败。DMG 已用 Developer ID 签名，用户仍可打开，但 Gatekeeper 可能提示无法验证开发者。" >&2
  fi
else
  echo "没有 App Store Connect API Key，跳过公证。" >&2
fi

echo "dmg $DMG"
ls -lh "$DMG"
