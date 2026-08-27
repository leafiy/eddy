#!/bin/sh
# One-line installer for Eddy. Curl avoids browser-added Gatekeeper quarantine.
#
#   curl -fsSL http://192.168.52.4:5010/leafiy/eddy/raw/branch/main/install.sh | sh
#
# Generated from leafiy-ui/templates/APP_INSTALL.sh by
# scripts/sync-app-install-scripts.sh; the family contract rejects edits here.
set -eu

GITEA_URL="${GITEA_URL:-http://192.168.52.4:5010}"
OWNER_REPO="${OWNER_REPO:-leafiy/eddy}"
APP_NAME="Eddy"
APP_SLUG="eddy"

case "$(uname -m)" in
    arm64)  ARCH=arm64 ;;
    x86_64) ARCH=x86_64 ;;
    *) echo "error: unsupported CPU $(uname -m)"; exit 1 ;;
esac

echo "fetching latest release info..."
DMG_URL=$(curl -fsSL "$GITEA_URL/api/v1/repos/$OWNER_REPO/releases/latest" \
    | /usr/bin/python3 -c "
import json, sys
release = json.load(sys.stdin)
for asset in release.get('assets', []):
    if '$ARCH' in asset['name'] and asset['name'].endswith('.dmg'):
        print(asset['browser_download_url'])
        break
")
[ -n "$DMG_URL" ] || { echo "error: no $ARCH DMG found in the latest release"; exit 1; }

TMP_DMG=$(mktemp -t "$APP_SLUG").dmg
trap 'rm -f "$TMP_DMG"' EXIT
echo "downloading $DMG_URL"
curl -fSL -o "$TMP_DMG" "$DMG_URL"

echo "installing to /Applications..."
MOUNT_POINT=$(hdiutil attach -nobrowse -readonly "$TMP_DMG" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
[ -d "$MOUNT_POINT/$APP_NAME.app" ] || { echo "error: $APP_NAME.app not found in DMG"; hdiutil detach "$MOUNT_POINT" -quiet; exit 1; }

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
# Older builds installed under the lowercase name; replace both spellings.
rm -rf "$DEST/$APP_NAME.app" "$DEST/$APP_SLUG.app"
ditto "$MOUNT_POINT/$APP_NAME.app" "$DEST/$APP_NAME.app"
hdiutil detach "$MOUNT_POINT" -quiet

# Register with LaunchServices so Launchpad/Spotlight pick it up immediately.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/$APP_NAME.app" || true
mdimport "$DEST/$APP_NAME.app" >/dev/null 2>&1 || true

echo "installed: $DEST/$APP_NAME.app"
open "$DEST/$APP_NAME.app"
