#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/core"
cargo build --release
DYLIB="$ROOT/core/target/release/librsq_core.dylib"
install_name_tool -id "@executable_path/librsq_core.dylib" "$DYLIB"
cd "$ROOT/app"
flutter config --enable-macos-desktop
flutter pub get
flutter build macos --release
echo "built app/build/macos/Build/Products/Release/rsq.app"
sh "$ROOT/tool/package-macos-dmg.sh"
