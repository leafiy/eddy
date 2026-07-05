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

command -v swift >/dev/null 2>&1 || { echo "error: needs macOS with Xcode command line tools"; exit 1; }
[ -n "${GITEA_TOKEN:-}" ] || { echo "error: set GITEA_TOKEN (Gitea -> Settings -> Applications -> Generate Token)"; exit 1; }

VERSION="${1:-v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
GITEA_URL="${GITEA_URL:-http://192.168.52.4:5010}"
OWNER_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')

build_dmg() { # $1 = arch
    arch="$1"
    echo "== building $arch =="
    swift build -c release --arch "$arch"
    bin_dir=$(swift build -c release --arch "$arch" --show-bin-path)

    app="build/$arch/eddy.app"
    rm -rf "build/$arch"
    mkdir -p "$app/Contents/MacOS"
    cp Info.plist "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$app/Contents/Info.plist"
    cp "$bin_dir/eddy" "$app/Contents/MacOS/eddy"
    printf 'APPL????' > "$app/Contents/PkgInfo"
    codesign --force --sign - "$app"

    # DMG layout: the app plus an /Applications shortcut for drag-install.
    staging="build/$arch/dmg"
    mkdir -p "$staging"
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    dmg="build/eddy-$VERSION-$arch.dmg"
    rm -f "$dmg"
    hdiutil create -volname "eddy" -srcfolder "$staging" -format UDZO -quiet "$dmg"
    echo "made $dmg"
}

mkdir -p build
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
    body="Image compressor for macOS 13+. Pick eddy-$VERSION-arm64.dmg for Apple Silicon or eddy-$VERSION-x86_64.dmg for Intel Macs, open it, drag eddy into Applications."
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
