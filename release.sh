#!/bin/sh
# Releases Eddy: two notarized DMGs, the leafiy.com update feed, GitHub source
# and release, optional Gitea mirror. The flow, every environment knob, and the
# usage lines live in ../leafiy-ui/scripts/macos-app-release-common.sh
# (ADR-0012); this file only declares the app.
#   sh release.sh --prepare [v1.2.3]   sh release.sh [v1.2.3]   PUSH_SOURCE=0 PUBLISH_TO_LEAFIY=0 PUBLISH_TO_GITHUB=0 sh release.sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"

APP_SLUG="eddy"
APP_EXECUTABLE_PRODUCT="eddy"
APP_ICON_SOURCE="eddy.png"
MENU_ICON_SOURCE="Sources/Eddy/Resources/eddy.png"
APP_RESOURCE_PRUNE="eddy_eddy.bundle/logo.png"
# Package.resolved is authoritative for the vendored codec packages.
SWIFT_BUILD_ARGS="--disable-automatic-resolution"
SWIFT_TEST_ARGS="--disable-automatic-resolution"
GITEA_RELEASE_SUMMARY="Image compressor for macOS 14+."
GITEA_RELEASE_NOTES_SUFFIX="Third-party notices and corresponding source are available in this repository."
RELEASE_COMMON="../leafiy-ui/scripts/macos-app-release-common.sh"
[ -r "$RELEASE_COMMON" ] || { echo "error: shared release flow not found: $RELEASE_COMMON"; exit 1; }
. "$RELEASE_COMMON"
leafiy_release_main "$@"
