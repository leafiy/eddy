#!/bin/sh
# Builds two ready-to-use DMGs (Apple Silicon + Intel) and publishes a
# release with both attached on the Gitea server.
#
# Usage, on a Mac with the Xcode command line tools:
#   NOTARY_PROFILE="eddy-notary" sh release.sh                 # package only
#   NOTARY_PROFILE="eddy-notary" GITEA_TOKEN=xxxx sh release.sh # package + upload
#   NOTARY_PROFILE="eddy-notary" sh release.sh v1.2             # explicit version tag
#
# Token: Gitea web UI -> Settings -> Applications -> Generate Token
# (repository read/write scope). Only needed for upload.
set -eu
cd "$(dirname "$0")"

command -v swift >/dev/null 2>&1 || { echo "error: needs macOS with Xcode command line tools"; exit 1; }
APP_ICON_DIR="icons"
MENU_ICON_PNG="$APP_ICON_DIR/Icon-iOS-Default-20@2x.png"
[ -f "$APP_ICON_DIR/Icon-iOS-Default-1024@1x.png" ] || { echo "error: $APP_ICON_DIR/Icon-iOS-Default-1024@1x.png not found"; exit 1; }
[ -f "$MENU_ICON_PNG" ] || { echo "error: $MENU_ICON_PNG not found"; exit 1; }

VERSION="${1:-v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
GITEA_URL="${GITEA_URL:-http://192.168.52.4:5010}"
OWNER_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')
APP_SLUG="eddy"
WORK_ROOT="${RELEASE_WORK_ROOT:-"${TMPDIR%/}/leafiy-release-$APP_SLUG-$VERSION"}"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$HOME/Downloads/leafiy-releases/$APP_SLUG"}"

# Developer ID signing + notarization (required for public downloads without
# Gatekeeper friction). One-time setup:
#   1. Developer ID Application certificate for team Q478GZN2AV in your keychain
#   2. xcrun notarytool store-credentials "eddy-notary" \
#          --apple-id tmly2006@gmail.com --team-id Q478GZN2AV --password <app-specific>
# Then release with:
#   NOTARY_PROFILE="eddy-notary" GITEA_TOKEN=... sh release.sh v1.1
APPLE_ID="${APPLE_ID:-tmly2006@gmail.com}"
TEAM_ID="${TEAM_ID:-Q478GZN2AV}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ALLOW_UNNOTARIZED="${ALLOW_UNNOTARIZED:-0}"

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" \
        | head -n 1)
fi
if [ -z "$SIGN_IDENTITY" ]; then
    if [ "$ALLOW_UNNOTARIZED" != "1" ]; then
        echo "error: no 'Developer ID Application' identity for team $TEAM_ID is in the keychain"
        echo "hint: the .cer alone is not enough - import the certificate together with its private key (.p12), then verify:"
        echo "hint:   security find-identity -v -p codesigning"
        exit 1
    fi
    SIGN_IDENTITY="-"
    echo "warning: building ad-hoc signed DMGs because ALLOW_UNNOTARIZED=1"
fi
if [ -z "$NOTARY_PROFILE" ] && [ "$ALLOW_UNNOTARIZED" != "1" ]; then
    echo "error: NOTARY_PROFILE is required for a public DMG"
    echo "hint: create it once with:"
    echo "hint:   xcrun notarytool store-credentials \"eddy-notary\" --apple-id $APPLE_ID --team-id $TEAM_ID --password <app-specific>"
    echo "hint: then release with:"
    echo "hint:   NOTARY_PROFILE=\"eddy-notary\" GITEA_TOKEN=... sh release.sh"
    exit 1
fi

compile_app_icon_assets() { # $1 = source png, $2 = destination dir
    src="$1"
    dest="$2"
    assets="$WORK_ROOT/AppIcon.xcassets"
    appicon="$assets/AppIcon.appiconset"
    partial="$WORK_ROOT/AppIcon.partial.plist"
    rm -rf "$assets"
    mkdir -p "$appicon" "$dest"
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
    xcrun actool --compile "$dest" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$partial" "$assets" >/dev/null
    iconset="$WORK_ROOT/AppIcon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    cp "$appicon"/icon_*.png "$iconset/"
    iconutil -c icns "$iconset" -o "$dest/AppIcon.icns"
    rm -rf "$iconset"
}

build_dmg() { # $1 = arch
    arch="$1"
    scratch="$WORK_ROOT/swift-$arch"
    echo "== building $arch =="
    swift build -c release --arch "$arch" --scratch-path "$scratch"
    bin_dir=$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)

    app="$WORK_ROOT/$arch/Eddy.app"
    rm -rf "$WORK_ROOT/$arch"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp Info.plist "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$app/Contents/Info.plist"
    cp "$bin_dir/eddy" "$app/Contents/MacOS/Eddy"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    cp "$WORK_ROOT/AppIcon.icns" "$WORK_ROOT/Assets.car" "$app/Contents/Resources/"
    cp "$MENU_ICON_PNG" "$app/Contents/Resources/eddy.png"
    if [ -d "$bin_dir/eddy_eddy.bundle" ]; then
        cp -R "$bin_dir/eddy_eddy.bundle" "$app/Contents/Resources/"
        rm -f "$app/Contents/Resources/eddy_eddy.bundle/logo.png"
        cp "$MENU_ICON_PNG" "$app/Contents/Resources/eddy_eddy.bundle/eddy.png"
    fi
    if [ -d "$bin_dir/LeafiyUI_LeafiyUI.bundle" ]; then
        cp -R "$bin_dir/LeafiyUI_LeafiyUI.bundle" "$app/Contents/Resources/"
    fi
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - "$app"
        if [ -n "$NOTARY_PROFILE" ]; then
            echo "warning: NOTARY_PROFILE is set but signing is ad-hoc; skipping notarization"
            NOTARY_PROFILE=""
        fi
    else
        # Hardened runtime + secure timestamp are notarization requirements.
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
    fi
    codesign --verify --deep --strict --verbose=2 "$app"

    # DMG layout: the app plus an /Applications shortcut for drag-install.
    staging="$WORK_ROOT/$arch/dmg"
    mkdir -p "$staging"
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    dmg="$ARTIFACT_DIR/eddy-$VERSION-$arch.dmg"
    rm -f "$dmg"
    hdiutil create -volname "eddy" -srcfolder "$staging" -format UDZO -quiet "$dmg"
    if [ "$SIGN_IDENTITY" != "-" ]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
        codesign --verify --verbose=2 "$dmg"
    fi
    if [ -n "$NOTARY_PROFILE" ]; then
        echo "notarizing $dmg (takes a few minutes)..."
        xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$dmg"
        spctl -a -vv -t open --context context:primary-signature "$dmg"
    fi
    rm -rf "$WORK_ROOT/$arch"
    echo "made $dmg"
}

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$ARTIFACT_DIR"
# App icon: compile the same AppIcon asset catalog Xcode uses.
compile_app_icon_assets "$APP_ICON_DIR" "$WORK_ROOT"
build_dmg arm64
build_dmg x86_64

if [ -z "${GITEA_TOKEN:-}" ]; then
    echo "GITEA_TOKEN is not set; skipping Gitea upload."
    echo "local DMGs:"
    echo "  $ARTIFACT_DIR/eddy-$VERSION-arm64.dmg"
    echo "  $ARTIFACT_DIR/eddy-$VERSION-x86_64.dmg"
    exit 0
fi

# ---- publish on Gitea ----
API="$GITEA_URL/api/v1/repos/$OWNER_REPO"
AUTH="Authorization: token $GITEA_TOKEN"
json_id() {
    /usr/bin/python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["id"])
except Exception:
    sys.exit(1)
'
}

# Reuse the release if the tag already exists, otherwise create it (Gitea
# tags main automatically).
release_json=$(curl -sf -H "$AUTH" "$API/releases/tags/$VERSION" 2>/dev/null || true)
release_id=""
if [ -n "$release_json" ]; then
    release_id=$(printf '%s' "$release_json" | json_id 2>/dev/null || true)
fi
if [ -z "$release_id" ]; then
    body="Image compressor for macOS 14+.\n\nRecommended install:\n\n    curl -fsSL $GITEA_URL/$OWNER_REPO/raw/branch/main/install.sh | sh\n\nManual install: download eddy-$VERSION-arm64.dmg (Apple Silicon) or eddy-$VERSION-x86_64.dmg (Intel), drag Eddy into Applications."
    release_json=$(curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
        -d "{\"tag_name\":\"$VERSION\",\"name\":\"eddy $VERSION\",\"body\":\"$body\",\"target_commitish\":\"main\"}" \
        "$API/releases") || { echo "error: failed to create release $VERSION on $API"; exit 1; }
    release_id=$(printf '%s' "$release_json" | json_id 2>/dev/null || true)
    [ -n "$release_id" ] || { echo "error: failed to parse release id from Gitea response"; exit 1; }
    echo "created release $VERSION (id $release_id)"
else
    echo "release $VERSION already exists (id $release_id), attaching assets"
fi

for dmg in "$ARTIFACT_DIR/eddy-$VERSION-arm64.dmg" "$ARTIFACT_DIR/eddy-$VERSION-x86_64.dmg"; do
    name=$(basename "$dmg")
    if curl -sf -X POST -H "$AUTH" -F "attachment=@$dmg" "$API/releases/$release_id/assets?name=$name" >/dev/null; then
        echo "uploaded $name"
    else
        echo "warning: upload of $name failed (asset with the same name already attached?)"
    fi
done

echo "release page: $GITEA_URL/$OWNER_REPO/releases"
