#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT/core"
cargo build --release --locked
cd "$ROOT/app"
flutter config --enable-linux-desktop
flutter pub get
flutter build linux --release
SO="$ROOT/core/target/release/librsq_core.so"
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"
if [ ! -f "$SO" ]; then
  echo "没有找到 librsq_core.so" >&2
  exit 1
fi
cp "$SO" "$BUNDLE/librsq_core.so"
cp "$SO" "$BUNDLE/lib/librsq_core.so"
chmod 755 "$BUNDLE/tiaotiaohou"
sh "$ROOT/tool/package-linux.sh"
