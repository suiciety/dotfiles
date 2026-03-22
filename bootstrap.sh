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
#   5. Installs TPM and tmux plugins directly via git (tpm, tmux-sensible, armando-rios/tmux)
#   6. Installs unzip if missing (required by oh-my-posh installer)
#   7. Installs oh-my-posh if missing
#   8. Deploys the atomic.omp.json theme
#   9. Configures fish and/or bash to use oh-my-posh

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

# ── 5. TPM and tmux plugins ───────────────────────────────────────────────────

PLUGINS_DIR="${HOME}/.tmux/plugins"
TPM_DIR="${PLUGINS_DIR}/tpm"

if command -v git &>/dev/null; then
    # TPM
    if [[ -d "${TPM_DIR}" ]]; then
        success "TPM already installed"
    else
        info "Installing TPM..."
        git clone --depth=1 https://github.com/tmux-plugins/tpm "${TPM_DIR}"
        success "TPM installed"
    fi

    # tmux-sensible
    if [[ -d "${PLUGINS_DIR}/tmux-sensible" ]]; then
        success "tmux-sensible already installed"
    else
        info "Installing tmux-sensible..."
        git clone --depth=1 https://github.com/tmux-plugins/tmux-sensible "${PLUGINS_DIR}/tmux-sensible"
        success "tmux-sensible installed"
    fi

    # armando-rios/tmux status bar theme
    if [[ -d "${PLUGINS_DIR}/armando-rios/tmux" ]]; then
        success "armando-rios/tmux already installed"
    else
        info "Installing armando-rios/tmux..."
        mkdir -p "${PLUGINS_DIR}/armando-rios"
        git clone https://github.com/armando-rios/tmux "${PLUGINS_DIR}/armando-rios/tmux"
        success "armando-rios/tmux installed"
    fi
else
    warn "git not found — tmux plugins not installed. Install git and re-run this script."
fi

# ── 6. unzip (required by oh-my-posh installer) ──────────────────────────────

if ! command -v unzip &>/dev/null; then
    info "unzip not found, installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y unzip
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm unzip
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y unzip
    elif command -v brew &>/dev/null; then
        brew install unzip
    else
        warn "Cannot install unzip: no supported package manager found. Install it manually and re-run."
        exit 1
    fi
    success "unzip installed"
else
    success "unzip already present"
fi

# ── 7. oh-my-posh binary ──────────────────────────────────────────────────────


OMP_BIN_DIR="${HOME}/.local/bin"
OMP_THEME_DIR="${HOME}/.config/omp"
OMP_THEME="${OMP_THEME_DIR}/atomic.omp.json"

if ! command -v oh-my-posh &>/dev/null; then
    info "oh-my-posh not found, installing..."
    mkdir -p "${OMP_BIN_DIR}"
    if curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "${OMP_BIN_DIR}" 2>&1; then
        success "oh-my-posh installed to ${OMP_BIN_DIR}"
        export PATH="${OMP_BIN_DIR}:${PATH}"
    else
        warn "oh-my-posh install failed. Install manually: https://ohmyposh.dev/docs/installation/linux"
    fi
else
    success "oh-my-posh already installed ($(oh-my-posh version 2>/dev/null || echo 'unknown version'))"
fi

# ── 8. oh-my-posh theme ───────────────────────────────────────────────────────

mkdir -p "${OMP_THEME_DIR}"
REMOTE_THEME=$(curl -fsSL "${BASE_URL}/atomic.omp.json")

if [[ -f "${OMP_THEME}" ]]; then
    LOCAL_THEME=$(cat "${OMP_THEME}")
    if [[ "${REMOTE_THEME}" == "${LOCAL_THEME}" ]]; then
        success "oh-my-posh theme already up to date"
    else
        BACKUP="${OMP_THEME}.bak.$(date +%Y%m%d%H%M%S)"
        cp "${OMP_THEME}" "${BACKUP}"
        warn "Existing theme backed up to ${BACKUP}"
        echo "${REMOTE_THEME}" > "${OMP_THEME}"
        success "oh-my-posh theme updated"
    fi
else
    echo "${REMOTE_THEME}" > "${OMP_THEME}"
    success "oh-my-posh theme installed to ${OMP_THEME}"
fi

# ── 9. Shell configuration ────────────────────────────────────────────────────

OMP_FISH_LINE='oh-my-posh init fish --config ~/.config/omp/atomic.omp.json | source'
OMP_BASH_LINE='eval "$(oh-my-posh init bash --config ~/.config/omp/atomic.omp.json)"'

# fish
if command -v fish &>/dev/null; then
    FISH_CONFIG="${HOME}/.config/fish/config.fish"
    mkdir -p "${HOME}/.config/fish"
    if [[ -f "${FISH_CONFIG}" ]] && grep -q "oh-my-posh" "${FISH_CONFIG}"; then
        # Replace existing oh-my-posh init line in place
        sed -i "s|.*oh-my-posh.*|${OMP_FISH_LINE}|" "${FISH_CONFIG}"
        success "oh-my-posh fish init updated in config.fish"
    else
        echo "${OMP_FISH_LINE}" >> "${FISH_CONFIG}"
        success "oh-my-posh fish init added to config.fish"
    fi
fi

# bash (for remote servers that don't have fish, and WSL Debian default shell)
BASHRC="${HOME}/.bashrc"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

# Ensure ~/.local/bin is in PATH so oh-my-posh can be found when .bashrc is sourced.
# On Debian/Ubuntu this is normally added by ~/.profile, but that only runs for
# login shells — interactive WSL sessions skip it.
if ! grep -qF '.local/bin' "${BASHRC}" 2>/dev/null; then
    echo "${PATH_LINE}" >> "${BASHRC}"
    success "~/.local/bin added to PATH in .bashrc"
fi

if grep -q "oh-my-posh" "${BASHRC}" 2>/dev/null; then
    sed -i "s|.*oh-my-posh.*|${OMP_BASH_LINE}|" "${BASHRC}"
    success "oh-my-posh bash init updated in .bashrc"
else
    echo "${OMP_BASH_LINE}" >> "${BASHRC}"
    success "oh-my-posh bash init added to .bashrc"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "[bootstrap] Done. If tmux is already running, reload config with: tmux source ~/.tmux.conf"
echo "[bootstrap] Reload your shell to activate oh-my-posh (exec \$SHELL or start a new session)"

if grep -qi microsoft /proc/version 2>/dev/null; then
    echo ""
    warn "WSL detected — Nerd Font glyphs (tmux status bar, oh-my-posh prompt arrows) require"
    warn "a Nerd Font set in Windows Terminal. Windows Terminal ships with 'CaskaydiaCove Nerd Font'"
    warn "and 'CaskaydiaMono Nerd Font' out of the box. To enable:"
    warn "  Windows Terminal → Settings → your Debian profile → Appearance → Font face"
    warn "  Set to: CaskaydiaCove Nerd Font (or any other Nerd Font you have installed)"
    warn "  Alternatively install one from: https://www.nerdfonts.com/font-downloads"
fi
