#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
if [ ! -x "$BUNDLE/tiaotiaohou" ]; then
  echo "没有找到 Linux 程序，先编译" >&2
  exit 1
fi
if [ ! -f "$BUNDLE/librsq_core.so" ]; then
  echo "没有找到 librsq_core.so" >&2
  exit 1
fi

VERSION=1.0.1
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
TAR="$STAGE/tiaotiaohou"
mkdir -p "$TAR"
cp -a "$BUNDLE"/. "$TAR/"
chmod 755 "$TAR/tiaotiaohou"
cat > "$TAR/install-desktop.sh" << 'EOF'
#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
mkdir -p "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
cp "$ROOT/data/flutter_assets/assets/logo.png" "$HOME/.local/share/icons/hicolor/256x256/apps/dev.rsq.rsq.png"
cat > "$HOME/.local/share/applications/dev.rsq.rsq.desktop" << DESK
[Desktop Entry]
Type=Application
Version=1.0
Name=跳跳猴
Comment=一只会跳跳的猴子
Exec=$ROOT/tiaotiaohou
Icon=$HOME/.local/share/icons/hicolor/256x256/apps/dev.rsq.rsq.png
Terminal=false
Categories=Network;
StartupWMClass=dev.rsq.rsq
StartupNotify=true
DESK
chmod +x "$ROOT/tiaotiaohou"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "已加入应用菜单。也可以直接运行 $ROOT/tiaotiaohou"
EOF
chmod 755 "$TAR/install-desktop.sh"

mkdir -p "$ROOT/dist"
tar -C "$STAGE" -czf "$ROOT/dist/tiaotiaohou-linux-x64.tar.gz" tiaotiaohou

DEB="$STAGE/deb"
mkdir -p "$DEB/DEBIAN" \
  "$DEB/usr/lib/tiaotiaohou" \
  "$DEB/usr/bin" \
  "$DEB/usr/share/applications" \
  "$DEB/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE"/. "$DEB/usr/lib/tiaotiaohou/"
chmod 755 "$DEB/usr/lib/tiaotiaohou/tiaotiaohou"
cat > "$DEB/usr/bin/tiaotiaohou" << 'EOF'
#!/bin/sh
exec /usr/lib/tiaotiaohou/tiaotiaohou "$@"
EOF
chmod 755 "$DEB/usr/bin/tiaotiaohou"
cp "$ROOT/app/assets/logo.png" "$DEB/usr/share/icons/hicolor/256x256/apps/dev.rsq.rsq.png"
cat > "$DEB/usr/share/applications/dev.rsq.rsq.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=跳跳猴
Comment=一只会跳跳的猴子
Exec=/usr/bin/tiaotiaohou
Icon=dev.rsq.rsq
Terminal=false
Categories=Network;
StartupWMClass=dev.rsq.rsq
StartupNotify=true
EOF
cat > "$DEB/DEBIAN/control" << EOF
Package: tiaotiaohou
Version: ${VERSION}
Section: net
Priority: optional
Architecture: amd64
Maintainer: TiaoTiaoHou
Depends: libgtk-3-0, libblkid1, liblzma5, libstdc++6, libc6
Recommends: fonts-noto-cjk | fonts-wqy-microhei, libayatana-appindicator3-1 | libappindicator3-1
Description: TiaoTiaoHou desktop client
 Local proxy. The browser follows the system proxy. Games use 127.0.0.1:1080.
EOF
if dpkg-deb --help 2>/dev/null | grep -q root-owner-group; then
  dpkg-deb --root-owner-group -Zxz --build "$DEB" "$ROOT/dist/tiaotiaohou-linux-amd64.deb"
else
  dpkg-deb -Zxz --build "$DEB" "$ROOT/dist/tiaotiaohou-linux-amd64.deb"
fi
ls -lh "$ROOT/dist/tiaotiaohou-linux-x64.tar.gz" "$ROOT/dist/tiaotiaohou-linux-amd64.deb"
