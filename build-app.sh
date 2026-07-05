#!/bin/sh
# Builds PicShrink.app next to this script.
# Requires macOS with the Xcode command line tools (xcode-select --install).
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

APP=PicShrink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/PicShrink" "$APP/Contents/MacOS/PicShrink"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so it launches on Apple Silicon.
codesign --force --sign - "$APP"

echo "Done: $(pwd)/$APP"
