#!/bin/sh
# Builds two ready-to-use DMGs (Apple Silicon + Intel) and publishes a
# release with both attached on the Gitea server.
#
# Usage, on a Mac with the Xcode command line tools:
#   GITEA_TOKEN=xxxx sh release.sh          # version from Info.plist
#   GITEA_TOKEN=xxxx sh release.sh v1.2     # explicit version tag
#
# Token: Gitea web UI -> Settings -> Applications -> Generate Token
# (repository read/write scope).
set -eu
cd "$(dirname "$0")"

# All Leafiy apps build against the sibling leafiy-ui checkout; a stale one
# causes confusing "cannot find X in scope" compile errors.
UI_DIR="../leafiy-ui"
[ -d "$UI_DIR" ] || { echo "error: $UI_DIR not found — clone leafiy-ui next to this repo" >&2; exit 1; }
if git -C "$UI_DIR" fetch --quiet origin main 2>/dev/null; then
    if ! git -C "$UI_DIR" merge-base --is-ancestor "$(git -C "$UI_DIR" rev-parse origin/main)" "$(git -C "$UI_DIR" rev-parse HEAD)"; then
        echo "error: $UI_DIR is behind origin/main — run: git -C $UI_DIR pull" >&2
        exit 1
    fi
fi

command -v swift >/dev/null 2>&1 || { echo "error: needs macOS with Xcode command line tools"; exit 1; }
[ -n "${GITEA_TOKEN:-}" ] || { echo "error: set GITEA_TOKEN (Gitea -> Settings -> Applications -> Generate Token)"; exit 1; }

VERSION="${1:-v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
GITEA_URL="${GITEA_URL:-http://192.168.52.4:5010}"
OWNER_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')

# Optional Developer ID signing + notarization (removes all Gatekeeper
# friction for downloaders). One-time setup:
#   1. Developer ID Application certificate for team Q478GZN2AV in your keychain
#   2. xcrun notarytool store-credentials "eddy-notary" \
#          --apple-id tmly2006@gmail.com --team-id Q478GZN2AV --password <app-specific>
# Then release with:
#   NOTARY_PROFILE="eddy-notary" GITEA_TOKEN=... sh release.sh v1.1
APPLE_ID="${APPLE_ID:-tmly2006@gmail.com}"
TEAM_ID="${TEAM_ID:-Q478GZN2AV}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\".*/\1/p" \
        | head -n 1)
fi
if [ -z "$SIGN_IDENTITY" ]; then
    if [ -n "$NOTARY_PROFILE" ]; then
        echo "error: NOTARY_PROFILE is set but no 'Developer ID Application' identity for team $TEAM_ID is in the keychain"
        echo "hint: the .cer alone is not enough - import it together with its private key (.p12), then verify:"
        echo "hint:   security find-identity -v -p codesigning"
        exit 1
    fi
    SIGN_IDENTITY="-"
    echo "warning: Developer ID Application certificate for team $TEAM_ID not found; DMGs will not be notarized for public distribution"
elif [ -z "$NOTARY_PROFILE" ]; then
    echo "info: Developer ID certificate found, but notarization is disabled"
    echo "info: create credentials with: xcrun notarytool store-credentials \"eddy-notary\" --apple-id $APPLE_ID --team-id $TEAM_ID --password <app-specific>"
    echo "info: then release with: NOTARY_PROFILE=\"eddy-notary\" GITEA_TOKEN=... sh release.sh"
fi

build_dmg() { # $1 = arch
    arch="$1"
    echo "== building $arch =="
    swift build -c release --arch "$arch"
    bin_dir=$(swift build -c release --arch "$arch" --show-bin-path)

    app="build/$arch/eddy.app"
    rm -rf "build/$arch"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp Info.plist "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$app/Contents/Info.plist"
    cp "$bin_dir/eddy" "$app/Contents/MacOS/eddy"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    [ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
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

    # DMG layout: the app plus an /Applications shortcut for drag-install.
    staging="build/$arch/dmg"
    mkdir -p "$staging"
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    dmg="build/eddy-$VERSION-$arch.dmg"
    rm -f "$dmg"
    hdiutil create -volname "eddy" -srcfolder "$staging" -format UDZO -quiet "$dmg"
    if [ -n "$NOTARY_PROFILE" ]; then
        echo "notarizing $dmg (takes a few minutes)..."
        xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$dmg"
    fi
    echo "made $dmg"
}

mkdir -p build

# App icon: logo.png -> AppIcon.icns, once (arch-independent).
if [ -f logo.png ]; then
    iconset="build/AppIcon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" logo.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" logo.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o build/AppIcon.icns
    rm -rf "$iconset"
fi
build_dmg arm64
build_dmg x86_64

# ---- publish on Gitea ----
API="$GITEA_URL/api/v1/repos/$OWNER_REPO"
AUTH="Authorization: token $GITEA_TOKEN"
json_id() { /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])'; }

# Reuse the release if the tag already exists, otherwise create it (Gitea
# tags main automatically).
release_id=$(curl -sf -H "$AUTH" "$API/releases/tags/$VERSION" 2>/dev/null | json_id 2>/dev/null || true)
if [ -z "$release_id" ]; then
    body="Image compressor for macOS 13+.\n\nRecommended install:\n\n    curl -fsSL $GITEA_URL/$OWNER_REPO/raw/branch/main/install.sh | sh\n\nManual install: download eddy-$VERSION-arm64.dmg (Apple Silicon) or eddy-$VERSION-x86_64.dmg (Intel), drag eddy into Applications."
    release_id=$(curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
        -d "{\"tag_name\":\"$VERSION\",\"name\":\"eddy $VERSION\",\"body\":\"$body\",\"target_commitish\":\"main\"}" \
        "$API/releases" | json_id)
    echo "created release $VERSION (id $release_id)"
else
    echo "release $VERSION already exists (id $release_id), attaching assets"
fi

for dmg in "build/eddy-$VERSION-arm64.dmg" "build/eddy-$VERSION-x86_64.dmg"; do
    name=$(basename "$dmg")
    if curl -sf -X POST -H "$AUTH" -F "attachment=@$dmg" "$API/releases/$release_id/assets?name=$name" >/dev/null; then
        echo "uploaded $name"
    else
        echo "warning: upload of $name failed (asset with the same name already attached?)"
    fi
done

echo "release page: $GITEA_URL/$OWNER_REPO/releases"
