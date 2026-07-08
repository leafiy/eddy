#!/bin/sh
# Builds Eddy.app outside the repository.
# Requires macOS with the Xcode command line tools (xcode-select --install).
set -eu
cd "$(dirname "$0")"

TEAM_ID="${TEAM_ID:-Q478GZN2AV}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

APP_ICON_DIR="icons"
MENU_ICON_PNG="$APP_ICON_DIR/Icon-iOS-Default-20@2x.png"
[ -f "$APP_ICON_DIR/Icon-iOS-Default-1024@1x.png" ] || { echo "error: $APP_ICON_DIR/Icon-iOS-Default-1024@1x.png not found"; exit 1; }
[ -f "$MENU_ICON_PNG" ] || { echo "error: $MENU_ICON_PNG not found"; exit 1; }

# Native build for this Mac's CPU by default (works on Intel and Apple
# Silicon alike). UNIVERSAL=1 sh build-app.sh builds one app for both.
ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

SCRATCH_PATH="${SCRATCH_PATH:-"${TMPDIR%/}/leafiy-swift-builds/eddy"}"
swift build -c release $ARCH_FLAGS --scratch-path "$SCRATCH_PATH"
BIN_DIR=$(swift build -c release $ARCH_FLAGS --scratch-path "$SCRATCH_PATH" --show-bin-path)

# App icon: Apple-exported icon sizes -> AppIcon assets.
compile_app_icon_assets() { # $1 = source png, $2 = destination resources dir
    src="$1"
    resources="$2"
    work="${TMPDIR%/}/leafiy-icon-builds/eddy"
    assets="$work/AppIcon.xcassets"
    appicon="$assets/AppIcon.appiconset"
    partial="$work/AppIcon.partial.plist"
    rm -rf "$work"
    mkdir -p "$appicon"
    cp "$src/Icon-iOS-Default-16@1x.png" "$appicon/icon_16x16.png"
    cp "$src/Icon-iOS-Default-16@2x.png" "$appicon/icon_16x16@2x.png"
    cp "$src/Icon-iOS-Default-32@1x.png" "$appicon/icon_32x32.png"
    cp "$src/Icon-iOS-Default-32@2x.png" "$appicon/icon_32x32@2x.png"
    cp "$src/Icon-iOS-Default-128@1x.png" "$appicon/icon_128x128.png"
    cp "$src/Icon-iOS-Default-128@2x.png" "$appicon/icon_128x128@2x.png"
    cp "$src/Icon-iOS-Default-256@1x.png" "$appicon/icon_256x256.png"
    cp "$src/Icon-iOS-Default-256@2x.png" "$appicon/icon_256x256@2x.png"
    cp "$src/Icon-iOS-Default-512@1x.png" "$appicon/icon_512x512.png"
    cp "$src/Icon-iOS-Default-1024@1x.png" "$appicon/icon_512x512@2x.png"
    cat > "$appicon/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
    xcrun actool --compile "$resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$partial" "$assets" >/dev/null
    iconset="$work/AppIcon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    cp "$appicon"/icon_*.png "$iconset/"
    iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
    rm -rf "$iconset"
}

APP="Eddy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/eddy" "$APP/Contents/MacOS/Eddy"
printf 'APPL????' > "$APP/Contents/PkgInfo"
compile_app_icon_assets "$APP_ICON_DIR" "$APP/Contents/Resources"
cp "$MENU_ICON_PNG" "$APP/Contents/Resources/eddy.png"
if [ -d "$BIN_DIR/eddy_eddy.bundle" ]; then
    cp -R "$BIN_DIR/eddy_eddy.bundle" "$APP/Contents/Resources/"
    rm -f "$APP/Contents/Resources/eddy_eddy.bundle/logo.png"
    cp "$MENU_ICON_PNG" "$APP/Contents/Resources/eddy_eddy.bundle/eddy.png"
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
