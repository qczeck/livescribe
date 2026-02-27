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

# ── Python server + venv (Application Support) ───────────────────────────────
SUPPORT_DIR="$HOME/Library/Application Support/LiveScribe"
if [ -d "$SUPPORT_DIR" ]; then
    rm -rf "$SUPPORT_DIR"
    ok "Removed ~/Library/Application Support/LiveScribe"
else
    skip "~/Library/Application Support/LiveScribe not found"
fi

# ── Transcripts ───────────────────────────────────────────────────────────────
TRANSCRIPTS="$HOME/Documents/LiveScribe"
if [ -d "$TRANSCRIPTS" ]; then
    echo ""
    warn "Transcripts found at ~/Documents/LiveScribe"
    printf "  Delete them? [y/N] "
    read -r answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        rm -rf "$TRANSCRIPTS"
        ok "Removed ~/Documents/LiveScribe"
    else
        skip "Kept ~/Documents/LiveScribe"
    fi
fi

echo -e "\n${BOLD}${GREEN}Done.${NC} The repo folder itself was not removed.\n"
