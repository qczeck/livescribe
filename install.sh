#!/usr/bin/env bash
# LiveScribe v2 — Setup Script
#
# Builds LiveScribe.app and installs it to /Applications.
# No Python, no venv, no external dependencies — just Xcode.
#
# Usage: bash install.sh

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()  { echo -e "\n${RED}✗ $*${NC}" >&2; exit 1; }
step() { echo -e "\n${BOLD}[$1/2] $2${NC}"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$REPO_DIR/LiveScribe/MacApp/LiveScribe.xcodeproj"
BUILD_LOG="/tmp/livescribe-build.log"
APP_DEST="/Applications/LiveScribe.app"

echo -e "\n${BOLD}LiveScribe — Setup${NC}"
echo    "══════════════════"

# ── 1. Xcode ──────────────────────────────────────────────────────────────────
step 1 "Checking Xcode"

xcode-select -p &>/dev/null \
    || die "Xcode not found.\n  Install it from the App Store: https://apps.apple.com/app/xcode/id497799835"

xcodebuild -version &>/dev/null 2>&1 || {
    warn "Xcode licence not yet accepted — accepting now (requires sudo)."
    sudo xcodebuild -license accept
}

xcodebuild -runFirstLaunch 2>/dev/null || true

ok "$(xcodebuild -version 2>/dev/null | head -1)"

# ── 2. Build + install ────────────────────────────────────────────────────────
step 2 "Building LiveScribe (this takes a minute or two)"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

if xcodebuild \
    -project "$PROJECT" \
    -scheme LiveScribe \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build > "$BUILD_LOG" 2>&1; then

    APP_SRC="$BUILD_DIR/Build/Products/Release/LiveScribe.app"
    if [ -d "$APP_SRC" ]; then
        [ -d "$APP_DEST" ] && rm -rf "$APP_DEST"
        cp -r "$APP_SRC" "$APP_DEST"
        ok "Installed to $APP_DEST"
    else
        warn "Build succeeded but .app not found at expected path."
        warn "Check $BUILD_LOG for details."
    fi
else
    echo "  Last 20 lines of build log:"
    tail -20 "$BUILD_LOG" | sed 's/^/    /'
    echo ""
    if grep -q "runFirstLaunch" "$BUILD_LOG" 2>/dev/null; then
        warn "Xcode plugin failed to load. Run the following then re-run install.sh:"
        echo ""
        echo "    sudo xcodebuild -runFirstLaunch"
    else
        warn "xcodebuild failed — likely a code signing issue."
        warn "Fix: open LiveScribe/MacApp/LiveScribe.xcodeproj in Xcode,"
        warn "     go to Signing & Capabilities, set your Team, then hit ⌘R."
    fi
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}All done!${NC}\n"
echo "  LiveScribe is in /Applications."
echo "  On first launch, macOS may block it — right-click → Open to bypass Gatekeeper."
echo ""
echo "  On first use, macOS will prompt for Screen Recording and Speech Recognition permissions."
echo ""
