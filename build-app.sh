#!/bin/sh
# Builds eddy.app next to this script.
# Requires macOS with the Xcode command line tools (xcode-select --install).
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

APP=eddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/eddy" "$APP/Contents/MacOS/eddy"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so it launches on Apple Silicon.
codesign --force --sign - "$APP"

echo "Done: $(pwd)/$APP"
