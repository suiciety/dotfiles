#!/usr/bin/env bash
# deploy-keys.sh — push SSH public keys and GPG public key to remote hosts
#
# Usage:
#   ./deploy-keys.sh [user@]host [user@]host ...
#
# What it does:
#   1. Ensures ~/.ssh/authorized_keys exists with correct permissions
#   2. Adds homekey_sk.pub (primary YubiKey) if not already present
#   3. Adds backupkey_sk.pub (backup YubiKey) if not already present
#   4. Imports the GPG public key into the remote user's keyring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()    { echo "[deploy-keys] $*"; }
success() { echo "[deploy-keys] ✓ $*"; }
warn()    { echo "[deploy-keys] ! $*"; }

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [user@]host [user@]host ..."
    echo ""
    echo "Examples:"
    echo "  $0 ubuntu@forgejo.internal"
    echo "  $0 ubuntu@docker.oracle ubuntu@forgejo.internal"
    exit 1
fi

SSH_KEYS=(
    "${SCRIPT_DIR}/homekey_sk.pub"
    "${SCRIPT_DIR}/backupkey_sk.pub"
)

GPG_KEY="${SCRIPT_DIR}/marcus.gpg.pub"
GPG_KEY_ID="7190A66213322F4A"

deploy_to_host() {
    local host="$1"
    info "Deploying keys to ${host}..."

    # Ensure ~/.ssh/authorized_keys exists with correct permissions
    ssh "${host}" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'

    # ── SSH public keys ───────────────────────────────────────────────────────
    for key_file in "${SSH_KEYS[@]}"; do
        local key_name key_content
        key_name=$(basename "${key_file}")
        key_content=$(cat "${key_file}")

        if ssh "${host}" "grep -qF '${key_content}' ~/.ssh/authorized_keys 2>/dev/null"; then
            success "${key_name} already present on ${host}"
        else
            ssh "${host}" "echo '${key_content}' >> ~/.ssh/authorized_keys"
            success "${key_name} added to ${host}:~/.ssh/authorized_keys"
        fi
    done

    # ── GPG public key ────────────────────────────────────────────────────────
    if ssh "${host}" "gpg --list-keys ${GPG_KEY_ID} &>/dev/null 2>&1"; then
        success "GPG key ${GPG_KEY_ID} already imported on ${host}"
    else
        cat "${GPG_KEY}" | ssh "${host}" "gpg --import 2>&1 | grep -v '^gpg:' || true"
        success "GPG key imported on ${host}"
    fi

    success "All keys deployed to ${host}"
    echo ""
}

for host in "$@"; do
    deploy_to_host "${host}"
done

echo "[deploy-keys] Done."
