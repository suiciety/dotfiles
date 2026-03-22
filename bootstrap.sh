#!/usr/bin/env bash
# bootstrap.sh — pull down mark's preferred tmux config, GPG key, and SSH authorized key
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/suiciety/dotfiles/main/bootstrap.sh | bash
#
# What it does:
#   1. Imports the GPG public key
#   2. Adds the SSH public key to ~/.ssh/authorized_keys (skips if already present)
#   3. Installs tmux if missing
#   4. Writes tmux.conf (backs up any existing config first)
#   5. Installs TPM (tmux plugin manager) if missing

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/suiciety/dotfiles/main"
GPG_KEY_ID="7190A66213322F4A"

info()    { echo "[bootstrap] $*"; }
success() { echo "[bootstrap] ✓ $*"; }
warn()    { echo "[bootstrap] ! $*"; }

# ── 1. GPG public key ─────────────────────────────────────────────────────────

info "Importing GPG public key ${GPG_KEY_ID}..."
curl -fsSL "${BASE_URL}/marcus.gpg.pub" | gpg --import 2>&1 | grep -v "^gpg:" || true
success "GPG key imported"

# ── 2. SSH authorized key ──────────────────────────────────────────────────────

info "Adding SSH public key to authorized_keys..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

PUBKEY=$(curl -fsSL "${BASE_URL}/authorized_keys")

if grep -qF "${PUBKEY}" ~/.ssh/authorized_keys 2>/dev/null; then
    warn "SSH key already present in authorized_keys, skipping"
else
    echo "${PUBKEY}" >> ~/.ssh/authorized_keys
    success "SSH key added to authorized_keys"
fi

# ── 3. Install tmux ───────────────────────────────────────────────────────────

if ! command -v tmux &>/dev/null; then
    info "tmux not found, installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y tmux
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm tmux
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y tmux
    elif command -v brew &>/dev/null; then
        brew install tmux
    else
        warn "Cannot install tmux: no supported package manager found. Install it manually."
    fi
else
    success "tmux already installed ($(tmux -V))"
fi

# ── 4. tmux.conf ──────────────────────────────────────────────────────────────

TMUX_CONF="${HOME}/.tmux.conf"

if [[ -f "${TMUX_CONF}" ]]; then
    REMOTE=$(curl -fsSL "${BASE_URL}/tmux.conf")
    LOCAL=$(cat "${TMUX_CONF}")
    if [[ "${REMOTE}" == "${LOCAL}" ]]; then
        success "tmux.conf already up to date"
    else
        BACKUP="${TMUX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
        cp "${TMUX_CONF}" "${BACKUP}"
        warn "Existing tmux.conf backed up to ${BACKUP}"
        echo "${REMOTE}" > "${TMUX_CONF}"
        success "tmux.conf updated"
    fi
else
    curl -fsSL "${BASE_URL}/tmux.conf" > "${TMUX_CONF}"
    success "tmux.conf installed"
fi

# ── 5. TPM (tmux plugin manager) ──────────────────────────────────────────────

TPM_DIR="${HOME}/.tmux/plugins/tpm"

if [[ -d "${TPM_DIR}" ]]; then
    success "TPM already installed"
else
    if command -v git &>/dev/null; then
        info "Installing TPM..."
        git clone --depth=1 https://github.com/tmux-plugins/tpm "${TPM_DIR}"
        success "TPM installed"
        info "To install plugins: open tmux and press prefix + I (capital i)"
    else
        warn "git not found — TPM not installed. Install git and run: git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "[bootstrap] Done. If this is a new tmux session, run: tmux source ~/.tmux.conf"
echo "[bootstrap] Then install plugins inside tmux with: prefix + I"
