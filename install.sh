#!/usr/bin/env bash
# LiveScribe — Setup Script
#
# Installs the Python server to ~/Library/Application Support/LiveScribe/
# (stable, independent of the repo location), writes a config file, and
# builds + installs LiveScribe.app to /Applications.
#
# Usage: bash install.sh

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()  { echo -e "\n${RED}✗ $*${NC}" >&2; exit 1; }
step() { echo -e "\n${BOLD}[$1/5] $2${NC}"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_SERVER="$REPO_DIR/LiveScribe/PythonServer"

# Stable install location — survives repo deletion or moves
SUPPORT_DIR="$HOME/Library/Application Support/LiveScribe"
SERVER_DIR="$SUPPORT_DIR/PythonServer"
VENV="$SUPPORT_DIR/venv"

CONFIG_DIR="$HOME/.config/livescribe"
CONFIG_FILE="$CONFIG_DIR/config"
SCHEME="$REPO_DIR/LiveScribe/MacApp/LiveScribe.xcodeproj/xcshareddata/xcschemes/LiveScribe.xcscheme"
PROJECT="$REPO_DIR/LiveScribe/MacApp/LiveScribe.xcodeproj"
BUILD_LOG="/tmp/livescribe-build.log"
APP_DEST="/Applications/LiveScribe.app"

echo -e "\n${BOLD}LiveScribe — Setup${NC}"
echo    "══════════════════"

# Ensure Homebrew's bin is in PATH (not always set in non-interactive shells)
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

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

# ── 2. Python 3.11+ ───────────────────────────────────────────────────────────
step 2 "Checking Python"

PYTHON_BIN=""
for cmd in python3.13 python3.12 python3.11 python3; do
    if command -v "$cmd" &>/dev/null; then
        ver=$("$cmd" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null) || continue
        maj="${ver%%.*}"; min="${ver##*.}"
        if [ "$maj" -ge 3 ] && [ "$min" -ge 11 ]; then
            PYTHON_BIN="$(command -v "$cmd")"
            ok "Python $ver at $PYTHON_BIN"
            break
        fi
    fi
done

[ -n "$PYTHON_BIN" ] \
    || die "Python 3.11+ not found.\n  Install via Homebrew: brew install python@3.11"

# ── 3. Install Python server to Application Support ───────────────────────────
step 3 "Installing Python server"

mkdir -p "$SERVER_DIR"
cp "$REPO_SERVER"/*.py "$SERVER_DIR/"
cp "$REPO_SERVER/requirements.txt" "$SERVER_DIR/"
ok "Server files copied to $SERVER_DIR"

if [ ! -d "$VENV" ]; then
    echo "  Creating virtual environment..."
    "$PYTHON_BIN" -m venv "$VENV"
fi

echo "  Installing dependencies..."
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$SERVER_DIR/requirements.txt"
ok "Python environment ready at $VENV"

# ── 4. Write config + patch Xcode scheme ──────────────────────────────────────
step 4 "Writing config"

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
LIVESCRIBE_PYTHON_BIN=$VENV/bin/python3
LIVESCRIBE_SERVER_SCRIPT=$SERVER_DIR/server.py
EOF
ok "Config written to $CONFIG_FILE"

# Patch the Xcode scheme to the same stable paths (works for both dev and release)
sed -i '' \
    "s|value = \"[^\"]*PythonServer/venv/bin/python3\"|value = \"$VENV/bin/python3\"|g" \
    "$SCHEME"
sed -i '' \
    "s|value = \"[^\"]*PythonServer/server.py\"|value = \"$SERVER_DIR/server.py\"|g" \
    "$SCHEME"
ok "Xcode scheme patched"

# ── 5. Build + install ────────────────────────────────────────────────────────
step 5 "Building LiveScribe (this takes a minute or two)"

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
    echo ""
    warn "Python environment and config are already set up — only the build step failed."
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}All done!${NC}\n"
echo "  LiveScribe is in /Applications."
echo "  On first launch, macOS may block it — right-click → Open to bypass Gatekeeper."
echo ""
warn "First transcription downloads Whisper model weights (~500 MB). Cached after that."
echo ""
