#!/bin/sh
set -eu
cd "$(dirname "$0")/../core"
cargo build --release
cd "$(dirname "$0")/../app"
flutter pub get
flutter build macos
echo "built app/build/macos/Build/Products/Release/rsq.app"
