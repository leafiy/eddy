#!/bin/sh
# Builds Eddy.app in an ignored, Spotlight-excluded build directory.
# Requires macOS with the Xcode command line tools (xcode-select --install).
# The flow lives in ../leafiy-ui/scripts/macos-app-build-common.sh (ADR-0012);
# this file only declares the app. UNIVERSAL=1 builds one app for both CPUs.
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
BUILD_COMMON="../leafiy-ui/scripts/macos-app-build-common.sh"
[ -r "$BUILD_COMMON" ] || { echo "error: shared macOS build policy not found: $BUILD_COMMON"; exit 1; }
. "$BUILD_COMMON"
leafiy_build_app_main "$@"
