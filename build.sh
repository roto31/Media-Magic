#!/bin/bash
###############################################################################
# build.sh — Compile MediaVault.app from the Swift sources.
#
# Run on macOS 13+ with Xcode Command Line Tools installed (xcode-select --install).
# Produces:  ./builds/<semver>+<build_number>/MediaVault.app
#
# Usage:
#   ./build.sh             # debug build
#   ./build.sh release     # optimised release build
#   ./build.sh release sign  # release build + ad-hoc codesign for Gatekeeper
###############################################################################

set -euo pipefail

CONFIG="${1:-debug}"
SHOULD_SIGN="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES="${SCRIPT_DIR}/Sources/MediaVault"
VERSION_FILE="${SCRIPT_DIR}/VERSION"
BUILD_NUMBER_FILE="${SCRIPT_DIR}/BUILD_NUMBER"
BUILD_ROOT="${SCRIPT_DIR}/builds"

SEMVER_CORE_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# Sanity checks
command -v swiftc >/dev/null 2>&1 || {
    echo "ERROR: swiftc not found. Install Xcode Command Line Tools:" >&2
    echo "       xcode-select --install" >&2
    exit 1
}

if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: This app must be built on macOS." >&2
    exit 1
fi

[[ -f "$VERSION_FILE" ]] || {
    echo "ERROR: VERSION file is missing at: $VERSION_FILE" >&2
    exit 1
}
[[ -f "$BUILD_NUMBER_FILE" ]] || {
    echo "ERROR: BUILD_NUMBER file is missing at: $BUILD_NUMBER_FILE" >&2
    exit 1
}

MARKETING_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$MARKETING_VERSION" =~ $SEMVER_CORE_REGEX ]]; then
    echo "ERROR: VERSION must be SemVer core (MAJOR.MINOR.PATCH), got: '$MARKETING_VERSION'" >&2
    exit 1
fi

CURRENT_BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
if [[ ! "$CURRENT_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "ERROR: BUILD_NUMBER must be a non-negative integer, got: '$CURRENT_BUILD_NUMBER'" >&2
    exit 1
fi

BUILD_NUMBER="$((CURRENT_BUILD_NUMBER + 1))"
BUILD_ID="${MARKETING_VERSION}+${BUILD_NUMBER}"
BUILD_DIR="${BUILD_ROOT}/${BUILD_ID}"
APP="${BUILD_DIR}/MediaVault.app"

# Determine build flags
if [[ "$CONFIG" == "release" ]]; then
    SWIFT_FLAGS=("-O" "-whole-module-optimization")
else
    SWIFT_FLAGS=("-Onone" "-g")
fi

# We target macOS 13+ to use modern SwiftUI APIs (.windowResizability, .bar, etc.)
SWIFT_FLAGS+=("-target" "$(uname -m)-apple-macosx13.0")

echo "▸ Preparing build directory: $BUILD_DIR"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

# Compile all .swift files into a single binary
echo "▸ Compiling Swift sources ($CONFIG)"
swiftc "${SWIFT_FLAGS[@]}" \
    -o "${APP}/Contents/MacOS/MediaVault" \
    "${SOURCES}"/*.swift

# Info.plist
echo "▸ Writing Info.plist"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MediaVault</string>
    <key>CFBundleDisplayName</key>
    <string>MediaVault</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.mediavault</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>MediaVault</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MediaVault — local-only video conversion orchestrator.</string>
    <!-- App calls user-installed CLI tools and downloads HandBrake/Subler
         CLIs into ~/Library/Application Support. No network entitlements
         beyond outbound HTTPS are required. -->
</dict>
</plist>
PLIST

# Strip Apple's quarantine flag so the freshly-built app launches without a
# Gatekeeper prompt on the build machine.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Optional ad-hoc code signing: required if you want the app to launch on
# Apple Silicon without "is damaged" warnings after copying off-machine.
if [[ "$SHOULD_SIGN" == "sign" ]]; then
    echo "▸ Ad-hoc code signing (no Developer ID — Gatekeeper will still warn on first launch from another Mac)"
    codesign --force --deep --sign - "$APP"
fi

# Persist the latest successful build number only after a successful build.
printf '%s\n' "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

# Sanity report
echo ""
echo "✓ Built: $APP"
echo "  Version: ${MARKETING_VERSION}"
echo "  Build:   ${BUILD_NUMBER}"
echo "  Binary: $(file "${APP}/Contents/MacOS/MediaVault" | head -1)"
echo "  Size:   $(du -sh "$APP" | cut -f1)"
echo ""
echo "To install:"
echo "  cp -R \"$APP\" /Applications/"
echo ""
echo "To run from build dir:"
echo "  open \"$APP\""
