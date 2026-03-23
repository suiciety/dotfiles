#!/usr/bin/env bash
# bootstrap.sh — pull down mark's preferred tmux config, GPG key, and SSH authorized key
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/suiciety/dotfiles/main/bootstrap.sh | bash
#
# What it does:
#   1. Imports the GPG public key
#   2. Adds the SSH public key to ~/.ssh/authorized_keys (skips if already present)
#   3. Deploys YubiKey FIDO2 SSH stub files (homekey_sk, backupkey_sk) to ~/.ssh/
#   4. Installs tmux if missing; prompts to build 3.6 from source if version < 3.4
#   5. Writes tmux.conf (backs up any existing config first)
#   6. Installs TPM and tmux plugins directly via git (tpm, tmux-sensible, armando-rios/tmux)
#   7. Installs unzip if missing (required by oh-my-posh installer)
#   8. Installs oh-my-posh if missing
#   9. Deploys the atomic.omp.json theme
#  10. Configures fish and/or bash to use oh-my-posh
#  11. Configures GPG agent for SSH auth and auto-launches it

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

# ── 3. YubiKey FIDO2 SSH stub files ──────────────────────────────────────────
#
# These are key handles only — no private key material. The actual private key
# lives on the YubiKey hardware. The stubs are required so SSH knows which
# credential to request from the attached YubiKey.

info "Deploying YubiKey FIDO2 SSH stub files..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

for SK_FILE in homekey_sk homekey_sk.pub backupkey_sk backupkey_sk.pub; do
    DEST="${HOME}/.ssh/${SK_FILE}"
    REMOTE_CONTENT=$(curl -fsSL "${BASE_URL}/${SK_FILE}")
    if [[ -f "${DEST}" ]]; then
        if [[ "$(cat "${DEST}")" == "${REMOTE_CONTENT}" ]]; then
            success "${SK_FILE} already up to date"
        else
            cp "${DEST}" "${DEST}.bak.$(date +%Y%m%d%H%M%S)"
            warn "Existing ${SK_FILE} backed up"
            echo "${REMOTE_CONTENT}" > "${DEST}"
            success "${SK_FILE} updated"
        fi
    else
        echo "${REMOTE_CONTENT}" > "${DEST}"
        success "${SK_FILE} deployed to ~/.ssh/"
    fi
    # Pub files are 644, private stubs are 600
    if [[ "${SK_FILE}" == *.pub ]]; then
        chmod 644 "${DEST}"
    else
        chmod 600 "${DEST}"
    fi
done

info "YubiKey stub files deployed. Plug in your YubiKey to use them for SSH auth."

# ── 4. Install tmux ───────────────────────────────────────────────────────────

TMUX_MIN_VERSION="3.4"
TMUX_BUILD_VERSION="3.6"

tmux_build_from_source() {
    info "Building tmux ${TMUX_BUILD_VERSION} from source..."
    local tmp
    tmp=$(mktemp -d)
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y libevent-dev libncurses-dev build-essential bison pkg-config
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y libevent-devel ncurses-devel gcc make bison pkg-config
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm libevent ncurses base-devel bison pkg-config
    else
        warn "Cannot install build dependencies: no supported package manager found."
        rm -rf "${tmp}"
        return 1
    fi
    curl -fsSL "https://github.com/tmux/tmux/releases/download/${TMUX_BUILD_VERSION}/tmux-${TMUX_BUILD_VERSION}.tar.gz" \
        | tar -xz -C "${tmp}"
    (cd "${tmp}/tmux-${TMUX_BUILD_VERSION}" && ./configure && make && sudo make install)
    rm -rf "${tmp}"
    success "tmux $(tmux -V) built and installed to /usr/local/bin"
}

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
fi

if command -v tmux &>/dev/null; then
    TMUX_VER=$(tmux -V | grep -oP '[0-9]+\.[0-9]+' | head -1)
    if awk -v v="${TMUX_VER}" -v m="${TMUX_MIN_VERSION}" 'BEGIN { exit (v >= m) ? 0 : 1 }'; then
        success "tmux ${TMUX_VER} meets minimum version requirement (${TMUX_MIN_VERSION}+)"
    else
        warn "tmux ${TMUX_VER} is below ${TMUX_MIN_VERSION} — the status bar theme may not render correctly."
        printf "[bootstrap] ? Upgrade tmux to ${TMUX_BUILD_VERSION} by building from source? [y/N] "
        read -r UPGRADE_TMUX </dev/tty
        if [[ "${UPGRADE_TMUX}" =~ ^[Yy]$ ]]; then
            tmux_build_from_source
        else
            warn "Skipping tmux upgrade. Theme rendering may be degraded."
        fi
    fi
fi

# ── 5. tmux.conf ──────────────────────────────────────────────────────────────

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

# ── 6. TPM and tmux plugins ───────────────────────────────────────────────────

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
    # TPM derives the install directory from the repo name only (after last /)
    # so armando-rios/tmux installs to ~/.tmux/plugins/tmux/
    if [[ -d "${PLUGINS_DIR}/tmux" ]]; then
        success "armando-rios/tmux already installed"
    else
        info "Installing armando-rios/tmux..."
        git clone https://github.com/armando-rios/tmux "${PLUGINS_DIR}/tmux"
        success "armando-rios/tmux installed"
    fi
else
    warn "git not found — tmux plugins not installed. Install git and re-run this script."
fi

# ── 7. unzip (required by oh-my-posh installer) ──────────────────────────────

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

# ── 8. oh-my-posh binary ──────────────────────────────────────────────────────


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

# ── 9. oh-my-posh theme ───────────────────────────────────────────────────────

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

# ── 10. Shell configuration ────────────────────────────────────────────────────

OMP_FISH_LINE='oh-my-posh init fish --config ~/.config/omp/atomic.omp.json | source'
OMP_BASH_LINE='eval "$(oh-my-posh init bash --config ~/.config/omp/atomic.omp.json)"'

# fish
if command -v fish &>/dev/null; then
    FISH_CONFIG="${HOME}/.config/fish/config.fish"
    mkdir -p "${HOME}/.config/fish"
    if grep -q "oh-my-posh" "${FISH_CONFIG}" 2>/dev/null; then
        grep -v "oh-my-posh" "${FISH_CONFIG}" > "${FISH_CONFIG}.tmp" && mv "${FISH_CONFIG}.tmp" "${FISH_CONFIG}"
        success "oh-my-posh fish init updated in config.fish"
    fi
    echo "${OMP_FISH_LINE}" >> "${FISH_CONFIG}"
    success "oh-my-posh fish init added to config.fish"
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
    grep -v "oh-my-posh" "${BASHRC}" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "${BASHRC}"
fi
echo "${OMP_BASH_LINE}" >> "${BASHRC}"
success "oh-my-posh bash init added to .bashrc"

# ── 11. GPG agent (SSH support) ───────────────────────────────────────────────

# Install pinentry-curses if missing (required for GPG agent in terminal sessions)
if ! command -v pinentry-curses &>/dev/null; then
    info "pinentry-curses not found, installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y pinentry-curses
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm pinentry
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y pinentry
    elif command -v brew &>/dev/null; then
        brew install pinentry
    else
        warn "Cannot install pinentry-curses: no supported package manager found."
    fi
fi

# Write gpg-agent.conf enabling SSH support
GNUPG_DIR="${HOME}/.gnupg"
GPG_AGENT_CONF="${GNUPG_DIR}/gpg-agent.conf"
mkdir -p "${GNUPG_DIR}"
chmod 700 "${GNUPG_DIR}"

PINENTRY_PATH=$(command -v pinentry-curses 2>/dev/null || command -v pinentry 2>/dev/null || echo "")

if [[ -f "${GPG_AGENT_CONF}" ]] && grep -q "enable-ssh-support" "${GPG_AGENT_CONF}"; then
    success "gpg-agent.conf already has SSH support enabled"
else
    {
        echo "enable-ssh-support"
        [[ -n "${PINENTRY_PATH}" ]] && echo "pinentry-program ${PINENTRY_PATH}"
    } >> "${GPG_AGENT_CONF}"
    success "gpg-agent.conf updated with SSH support"
fi

# Shell lines for GPG agent SSH socket and auto-launch
GPG_FISH_LINES='set -x SSH_AUTH_SOCK (gpgconf --list-dirs agent-ssh-socket)
gpgconf --launch gpg-agent'
GPG_BASH_LINES='export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
gpgconf --launch gpg-agent'

# fish
if command -v fish &>/dev/null; then
    FISH_CONFIG="${HOME}/.config/fish/config.fish"
    if grep -q "gpg-agent" "${FISH_CONFIG}" 2>/dev/null; then
        success "GPG agent already configured in config.fish"
    else
        echo "${GPG_FISH_LINES}" >> "${FISH_CONFIG}"
        success "GPG agent SSH config added to config.fish"
    fi
fi

# bash
if grep -q "gpg-agent" "${BASHRC}" 2>/dev/null; then
    success "GPG agent already configured in .bashrc"
else
    echo "${GPG_BASH_LINES}" >> "${BASHRC}"
    success "GPG agent SSH config added to .bashrc"
fi

# Reload the agent now so SSH_AUTH_SOCK is available in this session
if command -v gpgconf &>/dev/null; then
    gpgconf --launch gpg-agent
    success "GPG agent launched"
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
