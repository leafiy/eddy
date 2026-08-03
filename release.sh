#!/bin/sh
# Builds two ready-to-use DMGs (Apple Silicon + Intel), publishes them on
# leafiy.com for in-app updates, pushes Eddy source to GitHub, and creates a
# GitHub Release. The sibling leafiy-ui repository is never included.
#
# Usage, on a Mac with the Xcode command line tools:
#   sh release.sh --prepare [v1.2.3] # update Info.plist only, defaulting to next patch
#   sh release.sh                  # test, package, commit, push, and publish the current version
#   sh release.sh v1.2.3           # set an explicit version, then package and publish
#   GH_TOKEN=xxxx sh release.sh    # use an explicit GitHub fine-grained PAT
#   PUBLISH_TO_LEAFIY=0 PUBLISH_TO_GITHUB=0 sh release.sh # local build only
#   PUBLISH_TO_GITHUB=0 sh release.sh # skip GitHub source/release publishing
#
# Publishing uses the configured SSH access to leafiy.com by default.
# LEAFIY_ADMIN_PASSWORD can use the HTTPS admin API instead. GitHub uses the
# existing `gh` login or GH_TOKEN; GITEA_TOKEN additionally mirrors to Gitea.
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

published_tag_commit() { # $1 = tag
    tag="$1"
    if git rev-parse -q --verify "$tag^{}" >/dev/null 2>&1; then
        git rev-list -n 1 "$tag"
        return
    fi
    remote="${GITHUB_REMOTE:-github}"
    git remote get-url "$remote" >/dev/null 2>&1 || return 1
    commit=$(git ls-remote "$remote" "refs/tags/$tag^{}" | awk 'NR == 1 { print $1 }')
    [ -n "$commit" ] || commit=$(git ls-remote "$remote" "refs/tags/$tag" | awk 'NR == 1 { print $1 }')
    [ -n "$commit" ] || return 1
    printf '%s\n' "$commit"
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

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: packaging the current working tree, including uncommitted changes"
fi
REQUESTED_VERSION="${1:-}"
VERSION_NUMBER="${REQUESTED_VERSION#v}"
[ -n "$VERSION_NUMBER" ] || VERSION_NUMBER="$CURRENT_VERSION"
validate_version "$VERSION_NUMBER"
printf '%s\n' "$CURRENT_BUILD" | grep -Eq '^[0-9]+$' || {
    echo "error: CFBundleVersion must be numeric (got '$CURRENT_BUILD')"
    exit 1
}
PUBLISHED_COMMIT=$(published_tag_commit "v$VERSION_NUMBER" || true)
if [ -n "$PUBLISHED_COMMIT" ]; then
    if [ -n "$REQUESTED_VERSION" ]; then
        if [ "$(git rev-parse HEAD)" != "$PUBLISHED_COMMIT" ] || [ -n "$(git status --porcelain)" ]; then
            echo "error: v$VERSION_NUMBER is already published from commit $PUBLISHED_COMMIT"
            echo "hint: use a new version for the changed source"
            exit 1
        fi
    else
        VERSION_NUMBER=$(increment_version "$CURRENT_VERSION") || {
            echo "error: cannot increment patch version '$CURRENT_VERSION'"
            exit 1
        }
        [ -z "$(published_tag_commit "v$VERSION_NUMBER" || true)" ] || {
            echo "error: next version v$VERSION_NUMBER is already published"
            exit 1
        }
        echo "v$CURRENT_VERSION is already published; preparing next release v$VERSION_NUMBER"
    fi
fi
if [ "$VERSION_NUMBER" != "$CURRENT_VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION_NUMBER" Info.plist >/dev/null
    CURRENT_BUILD=$((CURRENT_BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CURRENT_BUILD" Info.plist >/dev/null
    CURRENT_VERSION="$VERSION_NUMBER"
    echo "prepared Eddy v$VERSION_NUMBER (build $CURRENT_BUILD)"
fi
VERSION="v$VERSION_NUMBER"

GITEA_URL="${GITEA_URL:-http://192.168.52.4:5010}"
OWNER_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')
GITHUB_REPO="${GITHUB_REPO:-leafiy/eddy}"
GITHUB_REMOTE="${GITHUB_REMOTE:-github}"
GITHUB_REMOTE_URL="${GITHUB_REMOTE_URL:-git@github.com:$GITHUB_REPO.git}"
PUBLISH_TO_GITHUB="${PUBLISH_TO_GITHUB:-1}"
AUTO_COMMIT_RELEASE="${AUTO_COMMIT_RELEASE:-1}"
BUILD_ROOT="${BUILD_ROOT:-"$PWD/build.noindex"}"
WORK_ROOT="${RELEASE_WORK_ROOT:-"$BUILD_ROOT/release-work/$VERSION"}"
ARTIFACT_DIR="${ARTIFACT_DIR:-"$BUILD_ROOT/release/$VERSION"}"
API="$GITEA_URL/api/v1/repos/$OWNER_REPO"
AUTH="Authorization: token ${GITEA_TOKEN:-}"
LEAFIY_PUBLISH_URL="${LEAFIY_PUBLISH_URL:-https://leafiy.com/admin-api}"
LEAFIY_ADMIN_USER="${LEAFIY_ADMIN_USER:-leafiy}"
LEAFIY_ADMIN_PASSWORD="${LEAFIY_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-}}"
LEAFIY_SSH_TARGET="${LEAFIY_SSH_TARGET:-root@47.88.53.44}"
LEAFIY_SSH_PORT="${LEAFIY_SSH_PORT:-2222}"
LEAFIY_REMOTE_API_URL="${LEAFIY_REMOTE_API_URL:-http://127.0.0.1:8765}"
PUBLISH_TO_LEAFIY="${PUBLISH_TO_LEAFIY:-1}"
case "$PUBLISH_TO_LEAFIY" in
    0|1) ;;
    *) echo "error: PUBLISH_TO_LEAFIY must be 0 or 1"; exit 1 ;;
esac
case "$PUBLISH_TO_GITHUB" in
    0|1) ;;
    *) echo "error: PUBLISH_TO_GITHUB must be 0 or 1"; exit 1 ;;
esac
case "$AUTO_COMMIT_RELEASE" in
    0|1) ;;
    *) echo "error: AUTO_COMMIT_RELEASE must be 0 or 1"; exit 1 ;;
esac

ensure_github_remote() {
    command -v gh >/dev/null 2>&1 || {
        echo "error: GitHub CLI (gh) is required for GitHub Releases"
        echo "hint: install it with 'brew install gh'"
        exit 1
    }
    gh auth status >/dev/null 2>&1 || {
        echo "error: GitHub authentication is not configured"
        echo "hint: run 'gh auth login', or set GH_TOKEN to a fine-grained PAT with Contents: write"
        exit 1
    }
    if git remote get-url "$GITHUB_REMOTE" >/dev/null 2>&1; then
        [ "$(git remote get-url "$GITHUB_REMOTE")" = "$GITHUB_REMOTE_URL" ] || {
            echo "error: remote '$GITHUB_REMOTE' does not point to $GITHUB_REMOTE_URL"
            exit 1
        }
    else
        git remote add "$GITHUB_REMOTE" "$GITHUB_REMOTE_URL"
    fi
    github_attempt=1
    while ! gh repo view "$GITHUB_REPO" >/dev/null 2>&1; do
        [ "$github_attempt" -lt 3 ] || {
            echo "error: cannot access GitHub repository $GITHUB_REPO"
            exit 1
        }
        sleep "$github_attempt"
        github_attempt=$((github_attempt + 1))
    done
    if git ls-files | grep -Eq '(^|/)leafiy-ui(/|$)'; then
        echo "error: leafiy-ui content is tracked inside Eddy; refusing GitHub publish"
        exit 1
    fi
}

github_remote_is_placeholder() {
    remote_ref="$1"
    [ "$(git rev-list --count "$remote_ref")" = "1" ] || return 1
    [ "$(git ls-tree -r --name-only "$remote_ref")" = "README.md" ] || return 1
    [ "$(git show "$remote_ref:README.md")" = "# eddy" ] || return 1
}

push_github_main() {
    remote_sha=$(git ls-remote "$GITHUB_REMOTE" refs/heads/main | awk 'NR == 1 { print $1 }')
    if [ -z "$remote_sha" ]; then
        git push "$GITHUB_REMOTE" HEAD:main
        return
    fi
    git fetch "$GITHUB_REMOTE" main
    if git merge-base --is-ancestor "$GITHUB_REMOTE/main" HEAD; then
        git push "$GITHUB_REMOTE" HEAD:main
    elif github_remote_is_placeholder "$GITHUB_REMOTE/main"; then
        echo "replacing GitHub's one-file placeholder history with Eddy source..."
        git push --force-with-lease="refs/heads/main:$remote_sha" "$GITHUB_REMOTE" HEAD:main
    else
        echo "merging GitHub-only history while keeping Eddy's canonical source tree..."
        git merge -s ours --no-edit "$GITHUB_REMOTE/main"
        HEAD_SHA=$(git rev-parse HEAD)
        git push origin HEAD:main
        git push "$GITHUB_REMOTE" HEAD:main
    fi
}

leafiy_api_get() { # $1 = endpoint
    endpoint="$1"
    leafiy_attempt=1
    while [ "$leafiy_attempt" -le 3 ]; do
        if [ -n "$LEAFIY_ADMIN_PASSWORD" ]; then
            curl -fsS -u "$LEAFIY_ADMIN_USER:$LEAFIY_ADMIN_PASSWORD" "$LEAFIY_PUBLISH_URL/$endpoint" && return 0
        else
            ssh -p "$LEAFIY_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
                "$LEAFIY_SSH_TARGET" "curl -fsS '$LEAFIY_REMOTE_API_URL/$endpoint'" && return 0
        fi
        sleep "$leafiy_attempt"
        leafiy_attempt=$((leafiy_attempt + 1))
    done
    return 1
}

leafiy_api_write() { # $1 = method, $2 = endpoint, $3 = file, $4 = content type, $5 = output
    method="$1"
    endpoint="$2"
    source_file="$3"
    content_type="$4"
    output_file="$5"
    leafiy_attempt=1
    while [ "$leafiy_attempt" -le 3 ]; do
        if [ -n "$LEAFIY_ADMIN_PASSWORD" ]; then
            if curl -fsS -u "$LEAFIY_ADMIN_USER:$LEAFIY_ADMIN_PASSWORD" \
                -X "$method" -H "Content-Type: $content_type" \
                --data-binary "@$source_file" "$LEAFIY_PUBLISH_URL/$endpoint" \
                -o "$output_file"; then
                return 0
            fi
        else
            content_length=$(wc -c < "$source_file" | tr -d ' ')
            if ssh -p "$LEAFIY_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
                "$LEAFIY_SSH_TARGET" \
                "curl -fsS -X '$method' -H 'Content-Type: $content_type' -H 'Content-Length: $content_length' --data-binary @- '$LEAFIY_REMOTE_API_URL/$endpoint'" \
                < "$source_file" > "$output_file"; then
                return 0
            fi
        fi
        sleep "$leafiy_attempt"
        leafiy_attempt=$((leafiy_attempt + 1))
    done
    return 1
}

if [ "$PUBLISH_TO_LEAFIY" = "1" ]; then
    leafiy_health=$(leafiy_api_get health) || {
        echo "error: cannot reach the leafiy.com release API"
        echo "hint: set LEAFIY_ADMIN_PASSWORD, or check SSH access to $LEAFIY_SSH_TARGET:$LEAFIY_SSH_PORT"
        exit 1
    }
    printf '%s' "$leafiy_health" | /usr/bin/python3 -c 'import json, sys
value = json.load(sys.stdin)
capabilities = set(value.get("capabilities", []))
if not value.get("ok") or not capabilities.intersection({"oss-releases", "releases"}):
    raise SystemExit(1)
' || {
        echo "error: leafiy.com does not expose the release publishing API"
        echo "hint: deploy the current ../leafiy.com first, then retry"
        exit 1
    }
fi

if [ "$PUBLISH_TO_GITHUB" = "1" ]; then
    ensure_github_remote
fi

if [ -n "${GITEA_TOKEN:-}" ]; then
    REMOTE_MAIN=$(git ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')
    [ -n "$REMOTE_MAIN" ] || { echo "error: cannot resolve origin/main"; exit 1; }
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
#   2. the family-shared notary profile "daisy-notary" — notary credentials are
#      per Apple ID/team, not per app, so every Leafiy app reuses daisy's:
#      xcrun notarytool store-credentials "daisy-notary" \
#          --apple-id tmly2006@gmail.com --team-id Q478GZN2AV --password <app-specific>
# Then release with:
#   GITEA_TOKEN=... sh release.sh v1.1
APPLE_ID="${APPLE_ID:-tmly2006@gmail.com}"
TEAM_ID="${TEAM_ID:-Q478GZN2AV}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-daisy-notary}"
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
if { [ "$PUBLISH_TO_LEAFIY" = "1" ] || [ "$PUBLISH_TO_GITHUB" = "1" ] || [ -n "${GITEA_TOKEN:-}" ]; } && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "error: refusing to publish an ad-hoc signed DMG"
    echo "hint: publish only with a Developer ID identity and a successful notarization"
    exit 1
fi
if [ -z "$NOTARY_PROFILE" ] && [ "$ALLOW_UNNOTARIZED" != "1" ]; then
    echo "error: NOTARY_PROFILE is required for a public DMG"
    echo "hint: create it once with:"
    echo "hint:   xcrun notarytool store-credentials \"daisy-notary\" --apple-id $APPLE_ID --team-id $TEAM_ID --password <app-specific>"
    echo "hint: then release with:"
    echo "hint:   NOTARY_PROFILE=\"daisy-notary\" GITEA_TOKEN=... sh release.sh"
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
    scratch="$WORK_ROOT/swift-tests"
    echo "== building $arch =="
    swift build -c release --arch "$arch" --scratch-path "$scratch"
    bin_dir=$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)

    app="$WORK_ROOT/$arch/Eddy.app"
    rm -rf "${WORK_ROOT:?}/$arch"
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
    rm -rf "${WORK_ROOT:?}/$arch"
    echo "made $dmg"
}

# Commit the exact source before testing or packaging so reused artifacts can
# be tied to one immutable commit.
if [ -n "$(git status --porcelain)" ]; then
    [ "$AUTO_COMMIT_RELEASE" = "1" ] || {
        echo "error: release requires a clean working tree"
        echo "hint: commit the Eddy changes, or leave AUTO_COMMIT_RELEASE=1"
        exit 1
    }
    git add -A -- .
    git commit -m "Release $VERSION"
fi
HEAD_SHA=$(git rev-parse HEAD)

[ "${REUSE_RELEASE_WORK:-0}" = "1" ] || rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT" "$ARTIFACT_DIR"
echo "== running release tests =="
swift test -c release --scratch-path "$WORK_ROOT/swift-tests"
arm64_dmg="$ARTIFACT_DIR/eddy-$VERSION-arm64.dmg"
x86_dmg="$ARTIFACT_DIR/eddy-$VERSION-x86_64.dmg"
source_commit_file="$ARTIFACT_DIR/.source-commit"
artifacts_match_source=0
if [ "${REBUILD_RELEASE:-0}" != "1" ] && \
    [ -f "$source_commit_file" ] && [ "$(cat "$source_commit_file")" = "$HEAD_SHA" ]; then
    artifacts_match_source=1
fi
needs_build=0
for candidate_dmg in "$arm64_dmg" "$x86_dmg"; do
    if [ "$artifacts_match_source" != "1" ] || [ ! -f "$candidate_dmg" ]; then
        needs_build=1
    fi
done
if [ "$needs_build" = "1" ]; then
    compile_app_icon_assets "$APP_ICON_SOURCE" "$WORK_ROOT"
fi
for arch in arm64 x86_64; do
    existing_dmg="$ARTIFACT_DIR/eddy-$VERSION-$arch.dmg"
    if [ "$artifacts_match_source" = "1" ] && [ -f "$existing_dmg" ]; then
        echo "== reusing existing notarized $arch $VERSION artifact from $HEAD_SHA =="
        hdiutil verify "$existing_dmg" >/dev/null
        codesign --verify --verbose=2 "$existing_dmg"
        spctl -a -vv -t open --context context:primary-signature "$existing_dmg"
    else
        build_dmg "$arch"
    fi
done
printf '%s\n' "$HEAD_SHA" > "$source_commit_file"
rm -rf "$WORK_ROOT"

(
    cd "$ARTIFACT_DIR"
    shasum -a 256 \
        "eddy-$VERSION-arm64.dmg" \
        "eddy-$VERSION-x86_64.dmg" > SHA256SUMS
)

# Publish the exact source commit used to build or validate the artifacts.
git push origin HEAD:main
REMOTE_MAIN=$(git ls-remote origin refs/heads/main | awk 'NR == 1 { print $1 }')
[ "$HEAD_SHA" = "$REMOTE_MAIN" ] || {
    echo "error: pushed release commit does not match origin/main"
    exit 1
}
if [ "$PUBLISH_TO_GITHUB" = "1" ]; then
    push_github_main
fi

publish_leafiy_release() {
    publish_dir="$ARTIFACT_DIR/.leafiy-publish"
    rm -rf "$publish_dir"
    mkdir -p "$publish_dir"

    echo "== publishing $VERSION on leafiy.com =="
    leafiy_api_get "releases?app=$APP_SLUG" > "$publish_dir/current.json"

    for arch in arm64 x86_64; do
        asset="$ARTIFACT_DIR/eddy-$VERSION-$arch.dmg"
        echo "uploading $(basename "$asset")..."
        leafiy_api_write POST \
            "release-file?app=$APP_SLUG&version=$VERSION_NUMBER&architecture=$arch" \
            "$asset" \
            "application/x-apple-diskimage" \
            "$publish_dir/$arch.json" || {
                echo "error: leafiy.com rejected $arch release upload"
                echo "hint: uploaded files are immutable; increase the version if this build differs"
                exit 1
            }
    done

    notes_zh=${RELEASE_NOTES_ZH:-"Eddy $VERSION_NUMBER 更新"}
    notes_en=${RELEASE_NOTES_EN:-"Eddy $VERSION_NUMBER release"}
    RELEASE_VERSION_NUMBER="$VERSION_NUMBER" \
    RELEASE_BUILD_NUMBER="$CURRENT_BUILD" \
    RELEASE_NOTES_ZH_VALUE="$notes_zh" \
    RELEASE_NOTES_EN_VALUE="$notes_en" \
    /usr/bin/python3 - "$publish_dir/current.json" "$publish_dir/arm64.json" "$publish_dir/x86_64.json" > "$publish_dir/manifest.json" <<'PY'
import datetime
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
with open(sys.argv[2], encoding="utf-8") as source:
    arm64 = json.load(source)
with open(sys.argv[3], encoding="utf-8") as source:
    x86_64 = json.load(source)

version = os.environ["RELEASE_VERSION_NUMBER"]
build = int(os.environ["RELEASE_BUILD_NUMBER"])
current = manifest.get("release")
published_at = (
    current["publishedAt"]
    if current and current.get("version") == version and current.get("build") == build
    else datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
)
labels = {
    "arm64": {"zh": "Apple 芯片（M 系列）", "en": "Apple Silicon (M-series)"},
    "x86_64": {"zh": "Intel 芯片（x86_64）", "en": "Intel (x86_64)"},
}
downloads = []
for uploaded in (arm64, x86_64):
    uploaded["label"] = labels[uploaded["architecture"]]
    downloads.append(uploaded)
manifest["release"] = {
    "version": version,
    "build": build,
    "publishedAt": published_at,
    "notes": {
        "zh": os.environ["RELEASE_NOTES_ZH_VALUE"].strip(),
        "en": os.environ["RELEASE_NOTES_EN_VALUE"].strip(),
    },
    "downloads": downloads,
}
json.dump(manifest, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY

    leafiy_api_write PUT \
        "releases?app=$APP_SLUG" \
        "$publish_dir/manifest.json" \
        "application/json" \
        "$publish_dir/published.json" || {
            echo "error: leafiy.com rejected the release manifest"
            exit 1
        }

    public_feed="${LEAFIY_PUBLIC_FEED_URL:-https://leafiy.com/updates/$APP_SLUG.json}"
    verified=0
    attempt=1
    while [ "$attempt" -le 5 ]; do
        if curl -fsS "$public_feed?release=$VERSION_NUMBER-$CURRENT_BUILD-$attempt" -o "$publish_dir/public.json" && \
            RELEASE_VERSION_NUMBER="$VERSION_NUMBER" RELEASE_BUILD_NUMBER="$CURRENT_BUILD" \
            /usr/bin/python3 - "$publish_dir/public.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
release = manifest.get("release") or {}
if release.get("version") != os.environ["RELEASE_VERSION_NUMBER"]:
    raise SystemExit(1)
if release.get("build") != int(os.environ["RELEASE_BUILD_NUMBER"]):
    raise SystemExit(1)
if {item.get("architecture") for item in release.get("downloads", [])} != {"arm64", "x86_64"}:
    raise SystemExit(1)
PY
        then
            verified=1
            break
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    [ "$verified" = "1" ] || {
        echo "error: published release is not visible at $public_feed"
        exit 1
    }
    rm -rf "$publish_dir"
    echo "published update feed: $public_feed"
}

if [ "$PUBLISH_TO_LEAFIY" = "1" ]; then
    publish_leafiy_release
fi

publish_github_release() {
    echo "== publishing $VERSION on GitHub =="
    github_release_exists=0
    if gh release view "$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        github_release_exists=1
    fi
    remote_tag=$(git ls-remote "$GITHUB_REMOTE" "refs/tags/$VERSION" | awk 'NR == 1 { print $1 }')
    remote_peeled=$(git ls-remote "$GITHUB_REMOTE" "refs/tags/$VERSION^{}" | awk 'NR == 1 { print $1 }')
    remote_tag_commit=${remote_peeled:-$remote_tag}
    if [ -n "$remote_tag_commit" ]; then
        [ "$remote_tag_commit" = "$HEAD_SHA" ] || {
            echo "error: GitHub tag $VERSION already points to another commit"
            exit 1
        }
    else
        if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
            [ "$(git rev-list -n 1 "$VERSION")" = "$HEAD_SHA" ] || {
                echo "error: local tag $VERSION already points to another commit"
                exit 1
            }
        else
            git tag -a "$VERSION" -m "Eddy $VERSION" "$HEAD_SHA"
        fi
        git push "$GITHUB_REMOTE" "refs/tags/$VERSION"
    fi

    github_notes="$ARTIFACT_DIR/.github-release-notes.md"
    notes_zh=${RELEASE_NOTES_ZH:-"Eddy $VERSION_NUMBER 更新"}
    notes_en=${RELEASE_NOTES_EN:-"Eddy $VERSION_NUMBER release"}
    {
        printf '## 更新\n\n%s\n\n' "$notes_zh"
        printf '## Changes\n\n%s\n\n' "$notes_en"
        printf 'Signed and notarized macOS downloads are attached for Apple Silicon and Intel.\n'
    } > "$github_notes"

    github_assets="$ARTIFACT_DIR/eddy-$VERSION-arm64.dmg $ARTIFACT_DIR/eddy-$VERSION-x86_64.dmg $ARTIFACT_DIR/SHA256SUMS"
    if [ "$github_release_exists" = "1" ]; then
        existing_names=$(gh release view "$VERSION" --repo "$GITHUB_REPO" --json assets --jq '.assets[].name')
        verify_dir="$ARTIFACT_DIR/.github-verify"
        rm -rf "$verify_dir"
        mkdir -p "$verify_dir"
        for github_asset in $github_assets; do
            asset_name=$(basename "$github_asset")
            if printf '%s\n' "$existing_names" | grep -Fx "$asset_name" >/dev/null; then
                gh release download "$VERSION" --repo "$GITHUB_REPO" --pattern "$asset_name" --dir "$verify_dir"
                cmp -s "$github_asset" "$verify_dir/$asset_name" || {
                    echo "error: GitHub asset $asset_name differs from the notarized local artifact"
                    exit 1
                }
            else
                gh release upload "$VERSION" "$github_asset" --repo "$GITHUB_REPO"
            fi
        done
        rm -rf "$verify_dir" "$github_notes"
    else
        # shellcheck disable=SC2086 # Three controlled artifact paths, none contain spaces.
        gh release create "$VERSION" $github_assets \
            --repo "$GITHUB_REPO" \
            --verify-tag \
            --latest \
            --title "Eddy $VERSION" \
            --notes-file "$github_notes"
        rm -f "$github_notes"
    fi
    github_release_url=$(gh release view "$VERSION" --repo "$GITHUB_REPO" --json url --jq .url)
    echo "GitHub release: $github_release_url"
}

if [ "$PUBLISH_TO_GITHUB" = "1" ]; then
    publish_github_release
fi

if [ -z "${GITEA_TOKEN:-}" ]; then
    echo "GITEA_TOKEN is not set; skipping optional Gitea mirror."
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
