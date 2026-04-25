#!/usr/bin/env bash
# bootstrap.sh — pull down mark's preferred tmux config, GPG key, and SSH authorized key
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/suiciety/dotfiles/main/bootstrap.sh | bash
#
# What it does:
#   1. Imports the GPG public key
#   2. Adds the SSH public key to ~/.ssh/authorized_keys (skips if already present)
#   3. Checks FIDO2 prerequisites (OpenSSH 8.2+, libfido2), deploys .pub files, prompts to
#      insert each YubiKey in sequence and exports private stubs via ssh-keygen -K
#   4. Installs tmux if missing; prompts to build 3.6 from source if version < 3.4
#   5. Writes tmux.conf (backs up any existing config first)
#   6. Installs TPM and tmux plugins directly via git (tpm, tmux-sensible, armando-rios/tmux)
#   7. Installs unzip if missing (required by oh-my-posh installer)
#   8. Installs oh-my-posh if missing
#   9. Deploys the atomic.omp.json theme
#  10. Deploys shell configs: config.fish (fish), shell_common.sh (bash/zsh/POSIX) with VS Code
#      guard, oh-my-posh prompt, and tmux auto-attach; sources shell_common.sh from rc files
#  11. Configures GPG agent for GPG operations only (not SSH); removes any old SSH_AUTH_SOCK lines

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/suiciety/dotfiles/main"
GPG_KEY_ID="7190A66213322F4A"

info()    { echo "[bootstrap] $*"; }
success() { echo "[bootstrap] ✓ $*"; }
warn()    { echo "[bootstrap] ! $*"; }

# Portable sed -i: GNU sed (Linux) uses -i; BSD sed (macOS) requires -i ''
if sed --version 2>/dev/null | grep -q GNU; then
    sedi() { sed -i "$@"; }
else
    sedi() { sed -i '' "$@"; }
fi

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

# ── 3. YubiKey FIDO2 SSH stub export ─────────────────────────────────────────
#
# Checks prerequisites, deploys .pub files from the repo, then prompts to
# insert each YubiKey in sequence and runs ssh-keygen -K to export the private
# stubs locally. Stubs are not stored in the public repo.

mkdir -p ~/.ssh
chmod 700 ~/.ssh

# -- Prerequisite checks ------------------------------------------------------

FIDO2_READY=true

# OpenSSH 8.2+ required for FIDO2
SSH_VER=$(ssh -V 2>&1 | sed -nE 's/.*OpenSSH_([0-9]+\.[0-9]+).*/\1/p')
[[ -z "${SSH_VER}" ]] && SSH_VER="0.0"
if awk -v v="${SSH_VER}" 'BEGIN { exit (v+0 >= 8.2) ? 0 : 1 }'; then
    success "OpenSSH ${SSH_VER} supports FIDO2"
else
    warn "OpenSSH ${SSH_VER} detected — FIDO2 requires 8.2+. Upgrade OpenSSH first."
    FIDO2_READY=false
fi

# libfido2 — install if missing
libfido2_present() {
    if command -v ldconfig &>/dev/null; then
        ldconfig -p 2>/dev/null | grep -q libfido2
    else
        # macOS (no ldconfig): search Homebrew and system paths for dylib
        find /opt/homebrew /usr/local /usr/lib /usr/lib64 2>/dev/null \
            -name "libfido2*" | grep -q .
    fi
}

if libfido2_present; then
    success "libfido2 present"
else
    info "libfido2 not found — installing..."
    if command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm libfido2
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y libfido2-1
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y libfido2
    elif command -v brew &>/dev/null; then
        brew install libfido2
    else
        warn "Cannot install libfido2: no supported package manager found. Install it manually."
        FIDO2_READY=false
    fi
    libfido2_present && success "libfido2 installed" || { warn "libfido2 install failed"; FIDO2_READY=false; }
fi

# -- Deploy .pub files from repo ----------------------------------------------

for SK_PUB in homekey_sk.pub backupkey_sk.pub ckey_sk.pub; do
    DEST="${HOME}/.ssh/${SK_PUB}"
    REMOTE_CONTENT=$(curl -fsSL "${BASE_URL}/${SK_PUB}")
    if [[ -f "${DEST}" ]]; then
        if [[ "$(cat "${DEST}")" == "${REMOTE_CONTENT}" ]]; then
            success "${SK_PUB} already up to date"
        else
            cp "${DEST}" "${DEST}.bak.$(date +%Y%m%d%H%M%S)"
            warn "Existing ${SK_PUB} backed up"
            echo "${REMOTE_CONTENT}" > "${DEST}"
            success "${SK_PUB} updated"
        fi
    else
        echo "${REMOTE_CONTENT}" > "${DEST}"
        success "${SK_PUB} deployed to ~/.ssh/"
    fi
    chmod 644 "${DEST}"
done

# -- Export private stubs from YubiKeys ---------------------------------------

export_yubikey_stub() {
    local key_name="$1"
    local dest_priv="${HOME}/.ssh/${key_name}"
    local dest_pub="${HOME}/.ssh/${key_name}.pub"

    if [[ -f "${dest_priv}" && -f "${dest_pub}" ]]; then
        success "${key_name} stub already present — skipping"
        return 0
    fi

    echo ""
    printf "[bootstrap] ? Insert your YubiKey for '%s' then press Enter (or 's' to skip): " "${key_name}"
    read -r YUBIKEY_RESPONSE </dev/tty

    if [[ "${YUBIKEY_RESPONSE}" =~ ^[Ss]$ ]]; then
        warn "Skipping ${key_name} — run 'cd ~/.ssh && ssh-keygen -K' manually when ready"
        return 0
    fi

    local tmp
    tmp=$(mktemp -d)
    info "Exporting resident keys from YubiKey (touch the key if it flashes)..."

    if ! (cd "${tmp}" && ssh-keygen -K 2>/dev/null); then
        warn "ssh-keygen -K failed — ensure YubiKey is fully inserted and try again"
        warn "Manual fallback: cd ~/.ssh && ssh-keygen -K && mv id_*_sk_rk ${key_name} && mv id_*_sk_rk.pub ${key_name}.pub"
        rm -rf "${tmp}"
        return 1
    fi

    # Collect exported private stubs (exclude .pub files)
    local priv_keys=()
    for f in "${tmp}"/id_*_sk_rk*; do
        [[ -f "${f}" && "${f}" != *.pub ]] && priv_keys+=("${f}")
    done

    local count=${#priv_keys[@]}
    if [[ ${count} -eq 0 ]]; then
        warn "No resident keys found on this YubiKey — ensure key was generated with -O resident"
        rm -rf "${tmp}"
        return 1
    fi

    if [[ ${count} -gt 1 ]]; then
        warn "${count} resident keys found — using first key for ${key_name}"
        warn "Other exported keys left in ${tmp} — review and move manually if needed"
    fi

    mv "${priv_keys[0]}" "${dest_priv}"
    mv "${priv_keys[0]}.pub" "${dest_pub}"
    chmod 600 "${dest_priv}"
    chmod 644 "${dest_pub}"
    rm -rf "${tmp}"
    success "${key_name} stub exported to ~/.ssh/"
}

if [[ "${FIDO2_READY}" == true ]]; then
    export_yubikey_stub "homekey_sk"
    export_yubikey_stub "backupkey_sk"
    export_yubikey_stub "ckey_sk"
else
    warn "Skipping YubiKey stub export — fix prerequisites above first"
    warn "Manual fallback: cd ~/.ssh && ssh-keygen -K"
fi

# -- SSH client config --------------------------------------------------------

SSH_CONFIG="${HOME}/.ssh/config"
FIDO2_CONFIG="Host *
    SecurityKeyProvider internal
    PreferredAuthentications publickey,password
    IdentityFile ~/.ssh/ckey_sk
    IdentityFile ~/.ssh/homekey_sk
    IdentityFile ~/.ssh/backupkey_sk
    IdentitiesOnly yes"

if [[ -f "${SSH_CONFIG}" ]]; then
    if grep -q "SecurityKeyProvider" "${SSH_CONFIG}"; then
        success "SSH config already has FIDO2 settings"
    else
        BACKUP="${SSH_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        cp "${SSH_CONFIG}" "${BACKUP}"
        warn "Existing SSH config backed up to ${BACKUP}"
        printf '%s\n\n' "${FIDO2_CONFIG}" | cat - "${SSH_CONFIG}" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "${SSH_CONFIG}"
        success "SSH config updated with FIDO2 settings"
    fi
else
    echo "${FIDO2_CONFIG}" > "${SSH_CONFIG}"
    chmod 600 "${SSH_CONFIG}"
    success "SSH config created with FIDO2 settings"
fi

# ── 4. Install tmux ───────────────────────────────────────────────────────────

TMUX_MIN_VERSION="3.4"
TMUX_BUILD_VERSION="3.6"

tmux_build_from_source() {
    # macOS: brew always has a recent tmux; build-from-source is a Linux path
    if command -v brew &>/dev/null; then
        info "On macOS: upgrading tmux via brew..."
        brew upgrade tmux 2>/dev/null || brew install tmux
        success "tmux $(tmux -V) installed via brew"
        return 0
    fi
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
    TMUX_VER=$(tmux -V | sed -E 's/[^0-9]*([0-9]+\.[0-9]+).*/\1/')
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
#
# Deploys a managed file for each shell, then injects a source line into rc files.
# All files include: VS Code guard, PATH setup, oh-my-posh, tmux auto-attach.
#
#   fish          → ~/.config/fish/config.fish  (native fish syntax, from repo)
#   bash/zsh/etc. → ~/.config/sh/shell_common.sh (POSIX sh, from repo)
#                   sourced via ~/.bashrc and ~/.zshrc

# Helper: fetch a file from the repo and deploy it, backing up on change
deploy_managed_file() {
    local src_url="$1" dest="$2"
    local remote
    remote=$(curl -fsSL "${src_url}")
    mkdir -p "$(dirname "${dest}")"
    if [[ -f "${dest}" ]]; then
        if [[ "$(cat "${dest}")" == "${remote}" ]]; then
            success "${dest##*/} already up to date"
            return 0
        fi
        local backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
        cp "${dest}" "${backup}"
        warn "Existing ${dest##*/} backed up to ${backup}"
    fi
    echo "${remote}" > "${dest}"
    success "${dest##*/} deployed"
}

# Helper: inject a '. shell_common.sh' source line into an rc file.
# Cleans up any old directly-appended oh-my-posh/tmux lines from prior bootstrap versions.
SHELL_COMMON="${HOME}/.config/sh/shell_common.sh"
SHELL_COMMON_MARKER="# bootstrap:shell_common"

inject_source_line() {
    local rc_file="$1"
    local source_line=". \"${SHELL_COMMON}\"  ${SHELL_COMMON_MARKER}"

    [[ -f "${rc_file}" ]] || touch "${rc_file}"

    if grep -qF "${SHELL_COMMON_MARKER}" "${rc_file}" 2>/dev/null; then
        success "${rc_file##*/} already sources shell_common.sh"
        return 0
    fi

    # Remove any oh-my-posh/tmux lines appended directly by older bootstrap versions
    if grep -qE "oh-my-posh|tmux attach|tmux new -s" "${rc_file}" 2>/dev/null; then
        grep -vE "oh-my-posh|tmux attach|tmux new -s" "${rc_file}" > "${rc_file}.tmp" \
            && mv "${rc_file}.tmp" "${rc_file}"
        warn "Removed old bootstrap shell lines from ${rc_file##*/}"
    fi

    # Remove old PATH_LINE that used to be appended directly
    if grep -qF '.local/bin' "${rc_file}" 2>/dev/null; then
        grep -vF '.local/bin' "${rc_file}" > "${rc_file}.tmp" \
            && mv "${rc_file}.tmp" "${rc_file}"
    fi

    { echo ""; echo "${source_line}"; } >> "${rc_file}"
    success "shell_common.sh sourced in ${rc_file##*/}"
}

# fish — native fish syntax (VS Code guard uses fish 'return', not sh syntax)
if command -v fish &>/dev/null; then
    deploy_managed_file "${BASE_URL}/config.fish" "${HOME}/.config/fish/config.fish"
fi

# bash/zsh/POSIX — deploy shared shell_common.sh and inject source line into rc files
deploy_managed_file "${BASE_URL}/shell_common.sh" "${SHELL_COMMON}"
chmod +x "${SHELL_COMMON}"

# bash (Linux servers, WSL, macOS fallback)
inject_source_line "${HOME}/.bashrc"

# zsh (macOS default since Catalina; common on Linux)
if command -v zsh &>/dev/null; then
    inject_source_line "${HOME}/.zshrc"
fi

# ── 11. GPG agent (signing/encryption only) ───────────────────────────────────
#
# GPG agent is configured for GPG operations only (signing, encryption).
# SSH_AUTH_SOCK is intentionally NOT pointed at the GPG agent — FIDO2 keys
# are used directly via the SSH client config (IdentityFile + IdentitiesOnly)
# without going through an agent.

# Install pinentry if missing (required for GPG agent in terminal sessions)
# macOS uses pinentry (brew) or pinentry-mac; Linux uses pinentry-curses
if ! command -v pinentry-curses &>/dev/null && ! command -v pinentry-mac &>/dev/null && ! command -v pinentry &>/dev/null; then
    info "pinentry not found, installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y pinentry-curses
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm pinentry
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y pinentry
    elif command -v brew &>/dev/null; then
        brew install pinentry-mac 2>/dev/null || brew install pinentry
    else
        warn "Cannot install pinentry: no supported package manager found."
    fi
fi

# Write gpg-agent.conf enabling SSH support
GNUPG_DIR="${HOME}/.gnupg"
GPG_AGENT_CONF="${GNUPG_DIR}/gpg-agent.conf"
mkdir -p "${GNUPG_DIR}"
chmod 700 "${GNUPG_DIR}"

PINENTRY_PATH=$(command -v pinentry-curses 2>/dev/null || command -v pinentry 2>/dev/null || echo "")

if [[ -f "${GPG_AGENT_CONF}" ]] && grep -q "enable-ssh-support" "${GPG_AGENT_CONF}"; then
    warn "gpg-agent.conf has enable-ssh-support — removing to avoid conflict with FIDO2 SSH"
    sedi '/enable-ssh-support/d' "${GPG_AGENT_CONF}"
    success "Removed enable-ssh-support from gpg-agent.conf"
else
    success "gpg-agent.conf does not have SSH support enabled (correct)"
fi

if [[ -n "${PINENTRY_PATH}" ]]; then
    if grep -q "pinentry-program" "${GPG_AGENT_CONF}" 2>/dev/null; then
        success "pinentry-program already set in gpg-agent.conf"
    else
        echo "pinentry-program ${PINENTRY_PATH}" >> "${GPG_AGENT_CONF}"
        success "pinentry-program set in gpg-agent.conf"
    fi
fi

# Remove any GPG agent SSH socket lines added by older versions of this script
for SHELL_CONFIG in "${HOME}/.config/fish/config.fish" "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    if [[ -f "${SHELL_CONFIG}" ]] && grep -qE "gpg-agent|agent-ssh-socket|SSH_AUTH_SOCK" "${SHELL_CONFIG}"; then
        grep -vE "gpg-agent|agent-ssh-socket|SSH_AUTH_SOCK" "${SHELL_CONFIG}" > "${SHELL_CONFIG}.tmp" \
            && mv "${SHELL_CONFIG}.tmp" "${SHELL_CONFIG}"
        warn "Removed GPG agent SSH lines from ${SHELL_CONFIG} (no longer needed with FIDO2)"
    fi
done

# Launch GPG agent for GPG operations only (not SSH)
if command -v gpgconf &>/dev/null; then
    gpgconf --launch gpg-agent
    success "GPG agent launched for GPG operations"
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
