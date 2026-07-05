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

# The app compresses via the same engines ImageOptim bundles; check they exist.
missing=""
check() { # binary formula
    if ! [ -x "/opt/homebrew/bin/$1" ] && ! [ -x "/usr/local/bin/$1" ] && ! command -v "$1" >/dev/null 2>&1; then
        missing="$missing $2"
    fi
}
check pngquant  pngquant
check oxipng    oxipng
check jpegoptim jpegoptim
check gifsicle  gifsicle
check avifenc   libavif

if [ -n "$missing" ]; then
    echo ""
    echo "WARNING: optimizer engines missing. For real compression run:"
    echo "    brew install$missing"
fi
