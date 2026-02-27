#!/usr/bin/env bash
# LiveScribe — Uninstall Script

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
skip() { echo -e "  –  $*"; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "\n${BOLD}LiveScribe — Uninstall${NC}"
echo    "══════════════════════"
echo ""

# ── App ───────────────────────────────────────────────────────────────────────
if [ -d "/Applications/LiveScribe.app" ]; then
    rm -rf "/Applications/LiveScribe.app"
    ok "Removed /Applications/LiveScribe.app"
else
    skip "/Applications/LiveScribe.app not found"
fi

# ── Config ────────────────────────────────────────────────────────────────────
if [ -d "$HOME/.config/livescribe" ]; then
    rm -rf "$HOME/.config/livescribe"
    ok "Removed ~/.config/livescribe"
else
    skip "~/.config/livescribe not found"
fi

# ── Python venv ───────────────────────────────────────────────────────────────
VENV="$REPO_DIR/LiveScribe/PythonServer/venv"
if [ -d "$VENV" ]; then
    rm -rf "$VENV"
    ok "Removed Python venv"
else
    skip "Python venv not found"
fi

# ── Transcripts ───────────────────────────────────────────────────────────────
TRANSCRIPTS="$HOME/Documents/LiveScribe"
if [ -d "$TRANSCRIPTS" ]; then
    echo ""
    warn "Transcripts found at ~/Documents/LiveScribe"
    printf "  Delete them? [y/N] "
    read -r answer
    if [[ "${answer,,}" == "y" ]]; then
        rm -rf "$TRANSCRIPTS"
        ok "Removed ~/Documents/LiveScribe"
    else
        skip "Kept ~/Documents/LiveScribe"
    fi
fi

echo -e "\n${BOLD}${GREEN}Done.${NC} The repo folder itself was not removed.\n"
