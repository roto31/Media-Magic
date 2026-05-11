#!/usr/bin/env bash
###############################################################################
# Re-sign every MediaMagic.app under ./builds/<semver>+<build>/, refresh the
# release zip (same name as build.sh), and build a .pkg that installs to
# /Applications. Optional: upload zip + pkg to existing GitHub releases.
#
# Usage:
#   ./scripts/resign-and-package-builds.sh
#   ./scripts/resign-and-package-builds.sh --dry-run
#   ./scripts/resign-and-package-builds.sh --upload
#   ./scripts/resign-and-package-builds.sh --upload --create-release
#   ./scripts/resign-and-package-builds.sh --skip-app-sign   # zip + .pkg only (no codesign)
#
# Environment (same defaults as build.sh):
#   DEVELOPER_ID_APPLICATION, DEVELOPER_ID_TEAM, DEVELOPER_ID_SIGNING_HASH
#   DEVELOPER_ID_INSTALLER — full name; if unset, first "Developer ID Installer"
#     for DEVELOPER_ID_TEAM is used. If none, .pkg is built unsigned (warning).
#   MEDIA_MAGIC_PRERELEASE — passed to gh release create if --create-release
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${SCRIPT_DIR}/builds"

DRY_RUN=false
DO_UPLOAD=false
CREATE_RELEASE=false
SKIP_APP_SIGN=false

usage() {
    sed -n '1,24p' "$0" | tail -n +2
    echo "Options: --dry-run | --skip-app-sign | --upload [--create-release]"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) usage 0 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --upload) DO_UPLOAD=true; shift ;;
        --create-release) CREATE_RELEASE=true; shift ;;
        --skip-app-sign) SKIP_APP_SIGN=true; shift ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: Run on macOS." >&2
    exit 1
fi

if [[ ! -d "$BUILD_ROOT" ]]; then
    echo "ERROR: Missing builds directory: $BUILD_ROOT" >&2
    exit 1
fi

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-Developer ID Application: Christopher Ruter (PM529U3B66)}"
DEVELOPER_ID_TEAM="${DEVELOPER_ID_TEAM:-PM529U3B66}"

resolve_codesign_identity() {
    local want="${DEVELOPER_ID_APPLICATION:-}"
    local team="${DEVELOPER_ID_TEAM:-}"
    local list
    list="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    if [[ -n "${DEVELOPER_ID_SIGNING_HASH:-}" ]]; then
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
    if [[ "$line" =~ \"([^\"]+)\" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "$line" | awk '{print $2}'
}

resolve_installer_identity() {
    local want="${DEVELOPER_ID_INSTALLER:-}"
    local team="${DEVELOPER_ID_TEAM:-}"
    local list
    list="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    local line=""
    if [[ -n "$want" ]]; then
        line="$(echo "$list" | grep 'Developer ID Installer' | grep -F "$want" | head -n 1 || true)"
    fi
    if [[ -z "$line" && -n "$team" ]]; then
        line="$(echo "$list" | grep 'Developer ID Installer' | grep -F "$team" | head -n 1 || true)"
    fi
    if [[ -z "$line" ]]; then
        echo ""
        return 1
    fi
    if [[ "$line" =~ \"([^\"]+)\" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "$line" | awk '{print $2}'
}

run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

APP_SIGNING_ID=""
if ! APP_SIGNING_ID="$(resolve_codesign_identity)"; then
    APP_SIGNING_ID=""
fi
if [[ -z "$APP_SIGNING_ID" ]]; then
    echo "ERROR: No Developer ID Application identity (see build.sh / DEVELOPER_ID_*)." >&2
    security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /' >&2 || true
    exit 1
fi

INSTALLER_SIGNING_ID=""
if INSTALLER_SIGNING_ID="$(resolve_installer_identity)"; then
    :
else
    INSTALLER_SIGNING_ID=""
fi
if [[ -z "$INSTALLER_SIGNING_ID" ]]; then
    echo "WARN: No Developer ID Installer identity; .pkg will be unsigned (app inside is still signed)." >&2
fi

echo "▸ App signing identity: $APP_SIGNING_ID"
if [[ -n "$INSTALLER_SIGNING_ID" ]]; then
    echo "▸ Package signing identity: $INSTALLER_SIGNING_ID"
fi

if [[ "$DO_UPLOAD" == true ]]; then
    command -v gh >/dev/null 2>&1 || {
        echo "ERROR: gh is required for --upload" >&2
        exit 1
    }
    gh auth status >/dev/null 2>&1 || {
        echo "ERROR: gh auth login required" >&2
        exit 1
    }
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "ERROR: --upload requires a git repo at $SCRIPT_DIR" >&2
        exit 1
    }
fi

# Fail once with guidance if the Developer ID private key cannot be used (errSecInternalComponent).
codesign_preflight() {
    local tmp cs_out
    tmp="$(mktemp "${TMPDIR:-/tmp}/mv.codesign.preflight.XXXXXX")"
    rm -f "$tmp"
    if ! command -v clang >/dev/null 2>&1; then
        echo "WARN: clang not found; skipping codesign preflight." >&2
        return 0
    fi
    echo 'int main(void){return 0;}' | clang -x c - -o "$tmp" 2>/dev/null || {
        echo "WARN: cannot compile preflight helper; skipping codesign preflight." >&2
        return 0
    }
    set +e
    cs_out="$(codesign --force --options runtime --timestamp --sign "$APP_SIGNING_ID" "$tmp" 2>&1)"
    cs_rc=$?
    set -e
    rm -f "$tmp"
    if [[ "$cs_rc" -eq 0 ]]; then
        return 0
    fi
    echo "" >&2
    echo "ERROR: codesign cannot use this identity (Developer ID private key / Keychain):" >&2
    echo "$cs_out" | sed 's/^/  /' >&2
    echo "" >&2
    echo "Fix (pick one):" >&2
    echo "  • Keychain Access → login → My Certificates → expand your Developer ID Application" >&2
    echo "    cert → double-click the private key → Access Control → allow /usr/bin/codesign (or" >&2
    echo "    “Allow all applications…”), then save and unlock the keychain." >&2
    echo "  • Or: security set-key-partition-list -S apple-tool:,apple: -s -k '<login keychain" >&2
    echo "    password>' -t private ~/Library/Keychains/login.keychain-db" >&2
    echo "  • If you ran this from Cursor/SSH, try again in Terminal.app (Keychain prompts)." >&2
    echo "  • If chain is broken: install Apple intermediate “Developer ID Certification Authority (G2)”" >&2
    echo "    from developer.apple.com / certificate authority; errSecInternalComponent is usually key access." >&2
    echo "" >&2
    echo "Or re-run with --skip-app-sign to only refresh .zip / .pkg from existing app signatures." >&2
    exit 1
}

if [[ "$DRY_RUN" != true && "$SKIP_APP_SIGN" != true ]]; then
    codesign_preflight
elif [[ "$SKIP_APP_SIGN" == true ]]; then
    echo "WARN: --skip-app-sign — not re-signing apps; zip/pkg only." >&2
fi

# One MediaMagic.app per builds/<semver>+<n>/ (paths may contain spaces).
BUILD_LIST="$(find "$BUILD_ROOT" -path '*/MediaMagic.app' -type d 2>/dev/null | sed 's|/MediaMagic.app$||' | LC_ALL=C sort -t+ -k1,1 -k2,2n)"
if [[ -z "$BUILD_LIST" ]]; then
    echo "No MediaMagic.app under $BUILD_ROOT" >&2
    exit 0
fi

if [[ "$CREATE_RELEASE" == true && "$DO_UPLOAD" != true ]]; then
    echo "WARN: --create-release only applies with --upload; ignoring." >&2
fi

while IFS= read -r build_dir; do
    [[ -n "$build_dir" ]] || continue
    APP="${build_dir}/MediaMagic.app"
    [[ -d "$APP" ]] || {
        echo "SKIP (no app): $build_dir"
        continue
    }

    BUILD_ID="$(basename "$build_dir")"
    ZIP_NAME="MediaMagic-${BUILD_ID}-macOS.zip"
    ZIP_PATH="${build_dir}/${ZIP_NAME}"
    PKG_NAME="MediaMagic-${BUILD_ID}-macOS.pkg"
    PKG_PATH="${build_dir}/${PKG_NAME}"

    SV="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
    BV="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
    PKG_VERSION="${SV}.${BV}"
    PKG_ID="com.local.mediamagic.pkg.${BUILD_ID//+/.}"

    echo ""
    echo "━━ ${BUILD_ID} ━━"

    run xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

    if [[ "$SKIP_APP_SIGN" != true ]]; then
        echo "▸ codesign app"
        run codesign --force --deep --options runtime --timestamp --sign "$APP_SIGNING_ID" "$APP"
        if [[ "$DRY_RUN" != true ]]; then
            codesign --verify --deep --strict --verbose=2 "$APP"
        fi
    else
        echo "▸ codesign app (skipped)"
    fi

    echo "▸ zip: $ZIP_NAME"
    run ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"

    echo "▸ pkg → /Applications: $PKG_NAME"
    if [[ -n "$INSTALLER_SIGNING_ID" ]]; then
        run productbuild \
            --identifier "$PKG_ID" \
            --version "$PKG_VERSION" \
            --component "$APP" /Applications \
            --sign "$INSTALLER_SIGNING_ID" \
            "$PKG_PATH"
    else
        run productbuild \
            --identifier "$PKG_ID" \
            --version "$PKG_VERSION" \
            --component "$APP" /Applications \
            "$PKG_PATH"
    fi

    if [[ "$DO_UPLOAD" == true ]]; then
        echo "▸ gh release upload $BUILD_ID"
        if [[ "$DRY_RUN" == true ]]; then
            echo "[dry-run] (cd \"$SCRIPT_DIR\" && gh release upload \"$BUILD_ID\" ...)"
        else
            (
                cd "$SCRIPT_DIR"
                if ! gh release view "$BUILD_ID" &>/dev/null; then
                    if [[ "$CREATE_RELEASE" == true ]]; then
                        prerelease_flag=()
                        [[ -n "${MEDIA_MAGIC_PRERELEASE:-}" ]] && prerelease_flag=(--prerelease)
                        gh release create "$BUILD_ID" --target main --title "$BUILD_ID" --notes "Packaged by scripts/resign-and-package-builds.sh" "${prerelease_flag[@]}"
                    else
                        echo "ERROR: No GitHub release tag '$BUILD_ID'. Create it or re-run with --create-release." >&2
                        exit 1
                    fi
                fi
                gh release upload "$BUILD_ID" "$ZIP_PATH#$ZIP_NAME" "$PKG_PATH#$PKG_NAME" --clobber
            )
        fi
    fi
done <<EOF
$BUILD_LIST
EOF

echo ""
echo "Done. Artifacts next to each app: MediaMagic-<VERSION>+<BUILD>-macOS.{zip,pkg}"
