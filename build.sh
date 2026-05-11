#!/bin/bash
###############################################################################
# build.sh — Compile MediaVault.app from the Swift sources.
#
# Run on macOS 13+ with Xcode Command Line Tools installed (xcode-select --install).
# Produces:  ./builds/<semver>+<build_number>/MediaVault.app
#
# Usage:
#   ./build.sh             # debug build
#   ./build.sh release     # optimized release build + Developer ID sign + GitHub release upload
#   ./build.sh release sign  # alias for release (kept for compatibility)
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
ASSET_NAME="MediaVault-${BUILD_ID}-macOS.zip"
ASSET_PATH="${BUILD_DIR}/${ASSET_NAME}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Christopher Ruter (PM529U3B66)}"

# Determine build flags
if [[ "$CONFIG" == "release" ]]; then
    SWIFT_FLAGS=("-O" "-whole-module-optimization")
else
    SWIFT_FLAGS=("-Onone" "-g")
fi

package_release_asset() {
    echo "▸ Packaging release asset: $ASSET_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ASSET_PATH"
}

# Resolve a string suitable for `codesign --sign`: full identity name, or
# 40-hex SHA-1 from `security find-identity` (set DEVELOPER_ID_SIGNING_HASH to
# bypass name matching).
resolve_codesign_identity() {
    local want="${DEVELOPER_ID_APPLICATION:-}"
    local team="${DEVELOPER_ID_TEAM:-PM529U3B66}"
    local list
    list="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    if [[ -n "${DEVELOPER_ID_SIGNING_HASH:-}" ]]; then
        # 40 hex chars — paste from `security find-identity` first column after ")".
        echo "${DEVELOPER_ID_SIGNING_HASH}"
        return 0
    fi

    local line=""
    if [[ -n "$want" ]]; then
        line="$(echo "$list" | grep 'Developer ID Application' | grep -F "$want" | head -n 1 || true)"
    fi
    if [[ -z "$line" && -n "$team" ]]; then
        line="$(echo "$list" | grep 'Developer ID Application' | grep -F "$team" | head -n 1 || true)"
    fi
    if [[ -z "$line" ]]; then
        echo ""
        return 1
    fi

    # Typical line: `  1) <40-hex> "Developer ID Application: … (TEAM)"`
    if [[ "$line" =~ \"([^\"]+)\" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    # Fallback: second token is often the SHA-1 hash.
    echo "$line" | awk '{print $2}'
}

sign_release_app() {
    local signing_id
    if ! signing_id="$(resolve_codesign_identity)"; then
        signing_id=""
    fi
    if [[ -z "$signing_id" ]]; then
        local full_list
        full_list="$(security find-identity -v -p codesigning 2>/dev/null || true)"
        echo "ERROR: No usable Developer ID Application identity in your keychain." >&2
        echo "" >&2
        echo "Apple only lists identities that include a **private key**. Importing" >&2
        echo "only \`developerID_application.cer\` is not enough — you need the" >&2
        echo "certificate **with private key** (e.g. \`.p12\` from the Mac that created" >&2
        echo "the CSR, or Keychain export). Then run:" >&2
        echo "  security find-identity -v -p codesigning | grep 'Developer ID Application'" >&2
        echo "" >&2
        echo "Optional: set DEVELOPER_ID_SIGNING_HASH to the 40-character hex id from" >&2
        echo "the left column of a matching line, or adjust DEVELOPER_ID_APPLICATION /" >&2
        echo "DEVELOPER_ID_TEAM (default team id PM529U3B66)." >&2
        echo "" >&2
        if echo "$full_list" | grep -q 'Apple Development' && ! echo "$full_list" | grep -q 'Developer ID Application'; then
            echo "NOTE: You have **Apple Development** (Xcode / personal team) but not **Developer ID Application**." >&2
            echo "They are different certificate types. \`./build.sh release\` needs **Developer ID Application**" >&2
            echo "for shipping outside the App Store. Create one in Apple Developer → Certificates → + →" >&2
            echo "Developer ID → Application, then install the downloaded cert on the Mac that submitted the CSR" >&2
            echo "(or import a .p12 that contains that cert + private key)." >&2
            echo "" >&2
        fi
        echo "--- security find-identity -v -p codesigning (full list) ---" >&2
        echo "$full_list" | sed 's/^/  /' >&2 || true
        echo "------------------------------------------------------------" >&2
        exit 1
    fi

    echo "▸ Signing app with: ${signing_id}"
    codesign --force --deep --options runtime --timestamp --sign "$signing_id" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
}

upload_release_asset() {
    command -v gh >/dev/null 2>&1 || {
        echo "ERROR: gh CLI is required to upload release assets." >&2
        echo "Install: https://cli.github.com/" >&2
        exit 1
    }
    gh auth status >/dev/null 2>&1 || {
        echo "ERROR: gh authentication is required. Run: gh auth login -h github.com" >&2
        exit 1
    }
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "ERROR: Build upload must be run from inside a git repository." >&2
        exit 1
    }

    local release_notes
    release_notes="$(mktemp "${TMPDIR:-/tmp}/media_magic_release_notes.XXXXXX.md")"
    cat >"$release_notes" <<EOF
## Release ${BUILD_ID}

- Version: ${MARKETING_VERSION}
- Build: ${BUILD_NUMBER}
- Artifact: ${ASSET_NAME}
- Distribution mode: Signed with Developer ID (not notarized)
- Gatekeeper note: If blocked, open once via right-click Open, or remove quarantine:
  - \`xattr -dr com.apple.quarantine MediaVault.app\`
- Generated by \`build.sh ${CONFIG}${SHOULD_SIGN:+ ${SHOULD_SIGN}}\`
EOF
    if [[ -n "${MEDIAVAULT_PRERELEASE:-}" ]]; then
        cat >>"$release_notes" <<'PREREL'

**Pre-release:** This GitHub Release is marked *pre-release* (not promoted as latest stable). The release tag remains `<VERSION>+<BUILD_NUMBER>` per repository policy.
PREREL
    fi

    # Set MEDIAVAULT_PRERELEASE=1 to mark the GitHub Release as a pre-release
    # (does not change the tag name, which remains <VERSION>+<BUILD_NUMBER>).
    local prerelease_flag=()
    if [[ -n "${MEDIAVAULT_PRERELEASE:-}" ]]; then
        prerelease_flag=(--prerelease)
    fi

    if gh release view "$BUILD_ID" >/dev/null 2>&1; then
        echo "▸ GitHub release ${BUILD_ID} already exists; updating release notes"
        gh release edit "$BUILD_ID" --title "$BUILD_ID" --notes-file "$release_notes" "${prerelease_flag[@]}"
    else
        echo "▸ Creating GitHub release ${BUILD_ID}"
        gh release create "$BUILD_ID" --target main --title "$BUILD_ID" --notes-file "$release_notes" "${prerelease_flag[@]}"
    fi

    echo "▸ Uploading asset to GitHub release ${BUILD_ID}"
    gh release upload "$BUILD_ID" "$ASSET_PATH#$ASSET_NAME" --clobber
    rm -f "$release_notes"
}

# We target macOS 13+ to use modern SwiftUI APIs (.windowResizability, .bar, etc.)
SWIFT_FLAGS+=("-target" "$(uname -m)-apple-macosx13.0")

echo "▸ Preparing build directory: $BUILD_DIR"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

# FileBot Groovy script library (GPLv3) — https://github.com/filebot/scripts
FILEBOT_VENDOR="${SCRIPT_DIR}/ThirdParty/filebot-scripts"
if [[ ! -f "${FILEBOT_VENDOR}/amc.groovy" ]]; then
    echo "▸ Cloning FileBot scripts library (requires git + network)"
    mkdir -p "${SCRIPT_DIR}/ThirdParty"
    git clone --depth 1 https://github.com/filebot/scripts.git "${FILEBOT_VENDOR}"
fi
echo "▸ Copying FileBot scripts into app bundle"
mkdir -p "${APP}/Contents/Resources/FileBotScripts"
cp "${FILEBOT_VENDOR}/LICENSE" "${FILEBOT_VENDOR}/README.md" "${APP}/Contents/Resources/FileBotScripts/"
shopt -s nullglob
for f in "${FILEBOT_VENDOR}"/*.groovy; do
    cp "$f" "${APP}/Contents/Resources/FileBotScripts/"
done
shopt -u nullglob

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

if [[ "$CONFIG" == "release" ]]; then
    sign_release_app
    package_release_asset
    upload_release_asset
fi

# Persist build number only after all steps above succeed (release signing
# and upload must not leave a skipped counter gap on failure).
printf '%s\n' "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

# Sanity report
echo ""
echo "✓ Built: $APP"
echo "  Version: ${MARKETING_VERSION}"
echo "  Build:   ${BUILD_NUMBER}"
echo "  Binary: $(file "${APP}/Contents/MacOS/MediaVault" | head -1)"
echo "  Size:   $(du -sh "$APP" | cut -f1)"
if [[ "$CONFIG" == "release" ]]; then
    echo "  Release asset: ${ASSET_PATH}"
fi
echo ""
echo "To install:"
echo "  cp -R \"$APP\" /Applications/"
echo ""
echo "To run from build dir:"
echo "  open \"$APP\""
