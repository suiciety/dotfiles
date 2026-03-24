#!/usr/bin/env bash
# yubikey-enroll.sh
# Enroll one or more YubiKeys for U2F/FIDO2 PAM authentication.
# Handles package installation, key enrollment, and PAM file configuration.
# Must be run as root: sudo ./yubikey-enroll.sh

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
step()  { printf "\n${BLUE}══> %s${NC}\n" "$*"; }
die()   { error "$*"; exit 1; }

MAPPINGS_FILE="/etc/u2f_mappings"

# ── Root check ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Must be run as root: sudo $0"

# ── Package installation ───────────────────────────────────────────────────────
step "Checking packages"

install_packages() {
    if command -v pacman &>/dev/null; then
        info "Detected: Arch/Manjaro/CachyOS (pacman)"
        pacman -S --noconfirm --needed pam-u2f libfido2 yubikey-manager
    elif command -v apt-get &>/dev/null; then
        info "Detected: Debian/Ubuntu (apt)"
        apt-get update -qq
        apt-get install -y libpam-u2f libfido2-1 yubikey-manager
    elif command -v dnf &>/dev/null; then
        info "Detected: Fedora/RHEL (dnf)"
        dnf install -y pam-u2f libfido2 yubikey-manager
    elif command -v zypper &>/dev/null; then
        info "Detected: openSUSE (zypper)"
        zypper install -y pam_u2f libfido2-1
    else
        die "No supported package manager found (pacman/apt/dnf/zypper). Install pam-u2f and libfido2 manually then re-run."
    fi
}

if ! command -v pamu2fcfg &>/dev/null; then
    info "pamu2fcfg not found — installing required packages..."
    install_packages
else
    info "pamu2fcfg already installed."
fi

# Locate pam_u2f.so
PAM_U2F_SO=""
for candidate in \
        /usr/lib/security/pam_u2f.so \
        /usr/lib64/security/pam_u2f.so \
        /lib/security/pam_u2f.so \
        /lib/x86_64-linux-gnu/security/pam_u2f.so \
        /lib/aarch64-linux-gnu/security/pam_u2f.so; do
    if [[ -f "$candidate" ]]; then
        PAM_U2F_SO="$candidate"
        break
    fi
done
[[ -z "$PAM_U2F_SO" ]] && die "pam_u2f.so not found after installation. Check package output above."
info "pam_u2f.so: $PAM_U2F_SO"

# ── Username ───────────────────────────────────────────────────────────────────
step "User configuration"

while true; do
    read -rp "Username to enroll: " USERNAME
    id "$USERNAME" &>/dev/null && break
    error "User '$USERNAME' does not exist. Try again."
done
info "Enrolling for user: $USERNAME"

# ── PAM origin/appid ───────────────────────────────────────────────────────────
step "PAM origin"

echo
echo "  A fixed PAM origin makes the mapping file portable across machines."
echo "  Use a consistent value everywhere (e.g. pam://yourdomain)."
echo "  Leave blank to use the default hostname-based ID (machine-specific)."
echo
read -rp "PAM origin [blank = hostname-based]: " PAM_ORIGIN

if [[ -z "$PAM_ORIGIN" ]]; then
    ORIGIN_ARGS=()
    PAM_MODULE_SUFFIX=""
    info "Using hostname-based enrollment."
else
    ORIGIN_ARGS=(-o "$PAM_ORIGIN" -i "$PAM_ORIGIN")
    PAM_MODULE_SUFFIX=" origin=${PAM_ORIGIN} appid=${PAM_ORIGIN}"
    info "Using portable origin: $PAM_ORIGIN"
fi

PAM_U2F_LINE="auth sufficient pam_u2f.so authfile=${MAPPINGS_FILE}${PAM_MODULE_SUFFIX} cue"

# ── Key enrollment ─────────────────────────────────────────────────────────────
step "YubiKey enrollment"

APPENDING=false

if [[ -f "$MAPPINGS_FILE" ]] && grep -q "^${USERNAME}:" "$MAPPINGS_FILE"; then
    warn "User '$USERNAME' already has an entry in $MAPPINGS_FILE:"
    grep "^${USERNAME}:" "$MAPPINGS_FILE"
    echo
    read -rp "Replace existing entry? [y/N]: " REPLACE
    if [[ "${REPLACE,,}" == "y" ]]; then
        sed -i "/^${USERNAME}:/d" "$MAPPINGS_FILE"
        info "Existing entry removed."
    else
        APPENDING=true
        info "New key(s) will be appended to the existing entry."
    fi
fi

touch "$MAPPINGS_FILE"
chmod 600 "$MAPPINGS_FILE"

KEY_NUM=1
FIRST_NEW_KEY=true

while true; do
    echo
    info "Insert YubiKey #${KEY_NUM} and press Enter when ready..."
    read -r
    info "Touch your YubiKey when it flashes..."

    if $FIRST_NEW_KEY && ! $APPENDING; then
        # First key on a fresh line — outputs "username:credential"
        pamu2fcfg -u "$USERNAME" "${ORIGIN_ARGS[@]+"${ORIGIN_ARGS[@]}"}" >> "$MAPPINGS_FILE"
    else
        # Appending to existing line — -n outputs just the credential (no username prefix)
        # printf avoids adding a newline so it stays on the same line
        printf ":%s" "$(pamu2fcfg -n -u "$USERNAME" "${ORIGIN_ARGS[@]+"${ORIGIN_ARGS[@]}"}")" >> "$MAPPINGS_FILE"
    fi

    FIRST_NEW_KEY=false
    info "YubiKey #${KEY_NUM} enrolled."
    KEY_NUM=$(( KEY_NUM + 1 ))

    read -rp "Enroll another YubiKey for $USERNAME? [y/N]: " ANOTHER
    [[ "${ANOTHER,,}" != "y" ]] && break
done

# Ensure file ends with a newline (printf above doesn't add one)
[[ "$(tail -c1 "$MAPPINGS_FILE" | wc -l)" -eq 0 ]] && echo >> "$MAPPINGS_FILE"

echo
info "Final mapping entry:"
grep "^${USERNAME}:" "$MAPPINGS_FILE"

# ── PAM file configuration ─────────────────────────────────────────────────────
step "PAM file configuration"

echo
echo "  Select which PAM services to configure (space-separated numbers, e.g: 1 3):"
echo
echo "  1) sudo              — privilege escalation"
echo "  2) login             — TTY login (Ctrl+Alt+F2)"
echo "  3) sddm              — KDE graphical login"
echo "  4) gdm-password      — GNOME graphical login"
echo "  5) lightdm           — LightDM graphical login"
echo "  6) system-local-login — fallback for all login methods (Arch)"
echo "  0) Skip PAM configuration"
echo
read -rp "Selection: " PAM_SELECTION

declare -A PAM_MAP=(
    [1]="sudo"
    [2]="login"
    [3]="sddm"
    [4]="gdm-password"
    [5]="lightdm"
    [6]="system-local-login"
)

configure_pam_file() {
    local service="$1"
    local pam_file="/etc/pam.d/${service}"

    if [[ ! -f "$pam_file" ]]; then
        warn "PAM file not found, skipping: $pam_file"
        return
    fi

    if grep -q "pam_u2f.so" "$pam_file"; then
        warn "$pam_file already contains a pam_u2f line — skipping."
        info "  Existing: $(grep 'pam_u2f.so' "$pam_file")"
        return
    fi

    # Backup original
    cp "$pam_file" "${pam_file}.bak"
    info "Backup saved: ${pam_file}.bak"

    # Insert before the first auth line
    awk -v line="$PAM_U2F_LINE" '
        !inserted && /^auth/ { print line; inserted=1 }
        { print }
    ' "$pam_file" > "${pam_file}.tmp" && mv "${pam_file}.tmp" "$pam_file"

    info "Updated: $pam_file"
}

for num in $PAM_SELECTION; do
    [[ "$num" == "0" ]] && continue
    if [[ -n "${PAM_MAP[$num]:-}" ]]; then
        configure_pam_file "${PAM_MAP[$num]}"
    else
        warn "Unknown selection: $num — skipping."
    fi
done

# ── Summary ────────────────────────────────────────────────────────────────────
step "Done"

echo
info "Enrollment complete for user: $USERNAME"
info "Keys enrolled: $(( KEY_NUM - 1 ))"
echo
echo "  Test sudo now (keep this terminal open until confirmed working):"
echo "    sudo -k && sudo whoami"
echo
echo "  If it fails, add 'debug' to the PAM line temporarily:"
echo "    auth sufficient pam_u2f.so authfile=/etc/u2f_mappings${PAM_MODULE_SUFFIX} cue debug"
echo "  Then re-run: sudo -k && sudo whoami"
echo
