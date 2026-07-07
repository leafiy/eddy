#!/bin/sh
# Builds eddy.app next to this script.
# Requires macOS with the Xcode command line tools (xcode-select --install).
set -eu
cd "$(dirname "$0")"

TEAM_ID="${TEAM_ID:-Q478GZN2AV}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# Native build for this Mac's CPU by default (works on Intel and Apple
# Silicon alike). UNIVERSAL=1 sh build-app.sh builds one app for both.
ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

swift build -c release $ARCH_FLAGS
BIN_DIR=$(swift build -c release $ARCH_FLAGS --show-bin-path)

# App icon: logo.png -> AppIcon.icns (all Finder/Dock sizes).
make_icns() { # $1 = destination .icns path
    iconset="AppIcon.iconset" # iconutil requires the .iconset extension
    rm -rf "$iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" logo.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" logo.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$1"
    rm -rf "$iconset"
}

APP=eddy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/eddy" "$APP/Contents/MacOS/eddy"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f logo.png ] && make_icns "$APP/Contents/Resources/AppIcon.icns"
if [ -d "$BIN_DIR/eddy_eddy.bundle" ]; then
    cp -R "$BIN_DIR/eddy_eddy.bundle" "$APP/Contents/Resources/"
fi
if [ -d "$BIN_DIR/LeafiyUI_LeafiyUI.bundle" ]; then
    cp -R "$BIN_DIR/LeafiyUI_LeafiyUI.bundle" "$APP/Contents/Resources/"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" \
        | head -n 1)
fi

if [ -n "$SIGN_IDENTITY" ]; then
    # Hardened runtime + secure timestamp are required for notarized distribution.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    echo "warning: Developer ID Application certificate for team $TEAM_ID not found; using ad-hoc signature"
    codesign --force --sign - "$APP"
fi

echo "Done: $(pwd)/$APP"
