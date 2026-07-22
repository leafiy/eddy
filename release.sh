#!/bin/sh
# Builds two ready-to-use DMGs (Apple Silicon + Intel) and publishes a
# release with both attached on the Gitea server.
#
# Usage, on a Mac with the Xcode command line tools:
#   sh release.sh --prepare v1.2.3 # update Info.plist, then review/commit/push
#   sh release.sh                  # test + package the committed version
#   GITEA_TOKEN=xxxx sh release.sh # test + package + notarize + publish
#   sh release.sh v1.2.3           # require this committed version, then package
#
# Token: Gitea web UI -> Settings -> Applications -> Generate Token
# (repository read/write scope). Only needed for upload.
set -eu
cd "$(dirname "$0")"

command -v swift >/dev/null 2>&1 || { echo "error: needs macOS with Xcode command line tools"; exit 1; }
APP_ICON_SOURCE="eddy.png"
MENU_ICON_SOURCE="Sources/Eddy/Resources/eddy.png"
ICON_COMPILER="../leafiy-ui/scripts/compile-macos-app-icon.sh"
APP_SLUG="eddy"
[ -f "$APP_ICON_SOURCE" ] || { echo "error: $APP_ICON_SOURCE not found"; exit 1; }
[ -f "$MENU_ICON_SOURCE" ] || { echo "error: $MENU_ICON_SOURCE not found"; exit 1; }
[ -x "$ICON_COMPILER" ] || { echo "error: shared icon compiler not found: $ICON_COMPILER"; exit 1; }

increment_version() {
    printf '%s\n' "$1" | awk -F. '
        BEGIN { OFS = "." }
        NF < 1 || $NF !~ /^[0-9]+$/ { exit 1 }
        { $NF = $NF + 1; print }
    '
}

CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist 2>/dev/null || printf '0')

ensure_clean_tree() {
    [ -z "$(git status --porcelain)" ] || {
        echo "error: release requires a clean working tree"
        echo "hint: commit or stash every source change before packaging"
        exit 1
    }
}

validate_version() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}([.-][0-9A-Za-z]+)*$' || {
        echo "error: invalid version '$1'"
        exit 1
    }
}

if [ "${1:-}" = "--prepare" ]; then
    ensure_clean_tree
    if [ "${2:-}" ]; then
        PREPARED_VERSION="${2#v}"
    else
        PREPARED_VERSION=$(increment_version "$CURRENT_VERSION") || {
            echo "error: cannot increment version '$CURRENT_VERSION'"
            exit 1
        }
    fi
    validate_version "$PREPARED_VERSION"
    printf '%s\n' "$CURRENT_BUILD" | grep -Eq '^[0-9]+$' || {
        echo "error: CFBundleVersion must be numeric (got '$CURRENT_BUILD')"
        exit 1
    }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PREPARED_VERSION" Info.plist >/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" Info.plist >/dev/null
    echo "prepared Eddy v$PREPARED_VERSION (build $((CURRENT_BUILD + 1)))"
    echo "review Info.plist, commit it, push main, then run:"
    echo "  GITEA_TOKEN=... sh release.sh v$PREPARED_VERSION"
    exit 0
fi

ensure_clean_tree
VERSION_NUMBER="${1#v}"
[ -n "$VERSION_NUMBER" ] || VERSION_NUMBER="$CURRENT_VERSION"
validate_version "$VERSION_NUMBER"
[ "$VERSION_NUMBER" = "$CURRENT_VERSION" ] || {
    echo "error: requested v$VERSION_NUMBER but committed Info.plist is v$CURRENT_VERSION"
    echo "hint: run 'sh release.sh --prepare v$VERSION_NUMBER', then review, commit, and push"
    exit 1
}
printf '%s\n' "$CURRENT_BUILD" | grep -Eq '^[0-9]+$' || {
    echo "error: CFBundleVersion must be numeric (got '$CURRENT_BUILD')"
    exit 1
}
VERSION="v$VERSION_NUMBER"
HEAD_SHA=$(git rev-parse HEAD)

GITEA_URL="${GITEA_URL:-http://192.168.52.4:5010}"
OWNER_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')
BUILD_ROOT="${BUILD_ROOT:-"$PWD/build.noindex"}"
WORK_ROOT="${RELEASE_WORK_ROOT:-"$BUILD_ROOT/release-work/$VERSION"}"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$BUILD_ROOT/release/$VERSION"}"
API="$GITEA_URL/api/v1/repos/$OWNER_REPO"
AUTH="Authorization: token ${GITEA_TOKEN:-}"

if [ -n "${GITEA_TOKEN:-}" ]; then
    REMOTE_MAIN=$(git ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')
    [ -n "$REMOTE_MAIN" ] || { echo "error: cannot resolve origin/main"; exit 1; }
    [ "$HEAD_SHA" = "$REMOTE_MAIN" ] || {
        echo "error: local HEAD does not match origin/main"
        echo "hint: push the committed release version before publishing"
        exit 1
    }
    [ -z "$(git ls-remote origin "refs/tags/$VERSION")" ] || {
        echo "error: tag $VERSION already exists; never overwrite a published version"
        exit 1
    }
    if curl -sf -H "$AUTH" "$API/releases/tags/$VERSION" >/dev/null 2>&1; then
        echo "error: release $VERSION already exists; choose a new version"
        exit 1
    fi
fi

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
NOTARY_PROFILE="${NOTARY_PROFILE:-$APP_SLUG-notary}"
ALLOW_UNNOTARIZED="${ALLOW_UNNOTARIZED:-0}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
NOTARY_S3_ACCELERATION="${NOTARY_S3_ACCELERATION:-0}"

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
if [ -n "${GITEA_TOKEN:-}" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "error: refusing to publish an ad-hoc signed DMG"
    echo "hint: publish only with a Developer ID identity and a successful notarization"
    exit 1
fi
if [ -z "$NOTARY_PROFILE" ] && [ "$ALLOW_UNNOTARIZED" != "1" ]; then
    echo "error: NOTARY_PROFILE is required for a public DMG"
    echo "hint: create it once with:"
    echo "hint:   xcrun notarytool store-credentials \"eddy-notary\" --apple-id $APPLE_ID --team-id $TEAM_ID --password <app-specific>"
    echo "hint: then release with:"
    echo "hint:   NOTARY_PROFILE=\"eddy-notary\" GITEA_TOKEN=... sh release.sh"
    exit 1
fi
if [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" >/dev/null
fi

detach_dmg_if_attached() { # $1 = dmg path
    dmg="$1"
    hdiutil info | awk -v path="$dmg" '
        $1 == "image-path" && index($0, path) > 0 { found = 1; next }
        found && /^\/dev\/disk[0-9]+[[:space:]]/ { print $1; found = 0 }
        /^=+/ { found = 0 }
    ' | while read -r device; do
        hdiutil detach "$device" >/dev/null || hdiutil detach -force "$device" >/dev/null || true
    done
}

notarize_dmg() { # $1 = dmg path
    dmg="$1"
    detach_dmg_if_attached "$dmg"
    hdiutil verify "$dmg" >/dev/null
    detach_dmg_if_attached "$dmg"
    echo "notarizing $dmg (takes a few minutes)..."
    if [ "$NOTARY_S3_ACCELERATION" = "1" ]; then
        xcrun notarytool submit "$dmg" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait \
            --timeout "$NOTARY_TIMEOUT"
    else
        xcrun notarytool submit "$dmg" \
            --keychain-profile "$NOTARY_PROFILE" \
            --no-s3-acceleration \
            --wait \
            --timeout "$NOTARY_TIMEOUT"
    fi
    xcrun stapler staple "$dmg"
    spctl -a -vv -t open --context context:primary-signature "$dmg"
}

compile_app_icon_assets() { # $1 = source png, $2 = destination dir
    "$ICON_COMPILER" "$1" "$2" "$WORK_ROOT/AppIconAssets"
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
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$VERSION_NUMBER" ] || {
        echo "error: packaged app version does not match $VERSION_NUMBER"
        exit 1
    }
    cp "$bin_dir/eddy" "$app/Contents/MacOS/Eddy"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    cp "$WORK_ROOT/AppIcon.icns" "$WORK_ROOT/Assets.car" "$app/Contents/Resources/"
    cp "$MENU_ICON_SOURCE" "$app/Contents/Resources/eddy.png"
    if [ -d "$bin_dir/eddy_eddy.bundle" ]; then
        cp -R "$bin_dir/eddy_eddy.bundle" "$app/Contents/Resources/"
        rm -f "$app/Contents/Resources/eddy_eddy.bundle/logo.png"
    fi
    if [ -d "$bin_dir/LeafiyUI_LeafiyUI.bundle" ]; then
        cp -R "$bin_dir/LeafiyUI_LeafiyUI.bundle" "$app/Contents/Resources/"
    fi
    [ -f "$app/Contents/Resources/AppIcon.icns" ] || { echo "error: AppIcon.icns is missing"; exit 1; }
    [ -f "$app/Contents/Resources/Assets.car" ] || { echo "error: Assets.car is missing"; exit 1; }
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app/Contents/Info.plist")" = "AppIcon" ] || { echo "error: CFBundleIconName must be AppIcon"; exit 1; }
    cmp -s "$MENU_ICON_SOURCE" "$app/Contents/Resources/eddy.png" || { echo "error: menu bar icon does not match $MENU_ICON_SOURCE"; exit 1; }
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
        notarize_dmg "$dmg"
    fi
    rm -rf "$WORK_ROOT/$arch"
    echo "made $dmg"
}

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$ARTIFACT_DIR"
echo "== running release tests =="
swift test -c release --scratch-path "$WORK_ROOT/swift-tests"
# App icon: compile the same AppIcon asset catalog Xcode uses.
compile_app_icon_assets "$APP_ICON_SOURCE" "$WORK_ROOT"
build_dmg arm64
build_dmg x86_64
rm -rf "$WORK_ROOT"

(
    cd "$ARTIFACT_DIR"
    shasum -a 256 \
        "eddy-$VERSION-arm64.dmg" \
        "eddy-$VERSION-x86_64.dmg" > SHA256SUMS
)

if [ -z "${GITEA_TOKEN:-}" ]; then
    echo "GITEA_TOKEN is not set; skipping Gitea upload."
    echo "local DMGs:"
    echo "  $ARTIFACT_DIR/eddy-$VERSION-arm64.dmg"
    echo "  $ARTIFACT_DIR/eddy-$VERSION-x86_64.dmg"
    echo "  $ARTIFACT_DIR/SHA256SUMS"
    exit 0
fi

# ---- publish on Gitea ----
json_id() {
    /usr/bin/python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["id"])
except Exception:
    sys.exit(1)
'
}

body="Image compressor for macOS 14+.\n\nRecommended install:\n\n    curl -fsSL $GITEA_URL/$OWNER_REPO/raw/branch/main/install.sh | sh\n\nManual install: download eddy-$VERSION-arm64.dmg (Apple Silicon) or eddy-$VERSION-x86_64.dmg (Intel), verify it with SHA256SUMS, then drag Eddy into Applications. Third-party notices and corresponding source are available in this repository."
release_json=$(curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "{\"tag_name\":\"$VERSION\",\"name\":\"eddy $VERSION\",\"body\":\"$body\",\"target_commitish\":\"$HEAD_SHA\"}" \
    "$API/releases") || { echo "error: failed to create release $VERSION on $API"; exit 1; }
release_id=$(printf '%s' "$release_json" | json_id 2>/dev/null || true)
[ -n "$release_id" ] || { echo "error: failed to parse release id from Gitea response"; exit 1; }
echo "created release $VERSION from commit $HEAD_SHA (id $release_id)"

for asset in "$ARTIFACT_DIR/eddy-$VERSION-arm64.dmg" "$ARTIFACT_DIR/eddy-$VERSION-x86_64.dmg" "$ARTIFACT_DIR/SHA256SUMS"; do
    name=$(basename "$asset")
    if curl -sf -X POST -H "$AUTH" -F "attachment=@$asset" "$API/releases/$release_id/assets?name=$name" >/dev/null; then
        echo "uploaded $name"
    else
        echo "error: upload of $name failed; release $VERSION is incomplete"
        exit 1
    fi
done

echo "release page: $GITEA_URL/$OWNER_REPO/releases"
