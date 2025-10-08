#!/usr/bin/env bash
# bootstrap.sh 
# Usage: sudo ./bootstrap.sh [-n|--dry-run] [-y|--yes]

set -euo pipefail
IFS=$'\n\t'

# ========================= COLORS & HELPERS =========================
Green='\033[0;32m'
Red='\033[0;31m'
Cyan='\033[1;36m'
No='\e[0m'

info()  { printf "%b[+] %s%b\n" "${Green}" "$*" "${No}"; }
warn()  { printf "%b[!] %s%b\n" "${Cyan}" "$*" "${No}"; }
error() { printf "%b[-] %s%b\n" "${Red}" "$*" "${No}"; }

DRY_RUN=false
ASSUME_YES=false

# Parse CLI args (simple)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; shift ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        -h|--help)
            cat <<USAGE
Usage: $0 [options]
Options:
  -n, --dry-run    Print actions without executing (safe preview)
  -y, --yes        Assume yes for all package installs/operations
  -h, --help       Show this help
USAGE
            exit 0
            ;;
        *) warn "Unknown option: $1"; shift ;;
    esac
done

run() {
    # Print command, then execute unless dry-run
    printf "%b> %s%b\n" "${Cyan}" "$*" "${No}"
    if [ "$DRY_RUN" = false ]; then
        "$@"
    fi
}

run_sh() {
    # Run a shell string (useful for complex commands)
    printf "%b> %s%b\n" "${Cyan}" "$*" "${No}"
    if [ "$DRY_RUN" = false ]; then
        bash -c "$*"
    fi
}

# ========================= BASIC CHECKS =========================
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    error "/etc/os-release not found; cannot determine distribution."
    exit 1
fi

# Source /etc/os-release for distro info
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"

info "Detected OS: ${OS_ID} ${OS_VER}"
info "Dry run: ${DRY_RUN}, Assume yes: ${ASSUME_YES}"
# ==========================================================

# ========================= BANNER =========================
echo -e "${Cyan}
  _     ___ _   _ _   ___  __
 | |   |_ _| \ | | | | \ \/ /
 | |    | ||  \| | | | |\  /
 | |___ | || |\  | |_| |/  \ 
 |_____||_||_| \_|\___//_/\_\\
  ____   ___   ___ _____ ____ _____ ____      _    ____   
 | __ ) / _ \ / _ \_   _/ ___|_   _|  _ \    / \  |  _ \  
 |  _ \| | | | | | || | \___ \ | | | |_) |  / _ \ | |_) | 
 | |_) | |_| | |_| || |  ___) || | |  _ <  / ___ \|  __/  
 |____/ \___/ \___/ |_| |____/ |_| |_| \_\/_/   \_\_|     
${No}
"
# ==========================================================

# =================== PACKAGE MANAGER DETECTION ===================
PM=""
INSTALL_CMD=()
UPDATE_CMD=""
UPGRADE_CMD=""
INSTALL_NONINTERACTIVE_SUFFIX=""

if command -v apt-get &>/dev/null; then
    PM="apt"
    INSTALL_CMD=(apt-get install -y)
    UPDATE_CMD="apt-get update"
    UPGRADE_CMD="apt-get upgrade -y"
elif command -v dnf &>/dev/null; then
    PM="dnf"
    INSTALL_CMD=(dnf install -y)
    UPDATE_CMD="dnf makecache --refresh"
    UPGRADE_CMD="dnf upgrade -y"
elif command -v yum &>/dev/null; then
    PM="yum"
    INSTALL_CMD=(yum install -y)
    UPDATE_CMD="yum makecache"
    UPGRADE_CMD="yum upgrade -y"
elif command -v pacman &>/dev/null; then
    PM="pacman"
    INSTALL_CMD=(pacman -S --noconfirm)
    UPDATE_CMD="pacman -Sy"
    UPGRADE_CMD="pacman -Syu --noconfirm"
elif command -v apk &>/dev/null; then
    PM="apk"
    INSTALL_CMD=(apk add --no-cache)
    UPDATE_CMD="apk update"
    UPGRADE_CMD="apk upgrade"
elif command -v zypper &>/dev/null; then
    PM="zypper"
    INSTALL_CMD=(zypper -n in)
    UPDATE_CMD="zypper refresh"
    UPGRADE_CMD="zypper -n up"
else
    error "No known package manager detected. Supported: apt, dnf, yum, pacman, apk, zypper."
    exit 1
fi

info "Using package manager: $PM"
# ==========================================================

# =================== PACKAGE PRESENCE CHECK ====================
# Map package -> command to check for presence (some packages expose different binaries)
declare -A PKG_CHECK=(
    [curl]=curl
    [git]=git
    [vim]=vim
    [fail2ban]=fail2ban-client
    [htop]=htop
    [net-tools]=ifconfig
    [sysstat]=iostat
    [iotop]=iotop
)

is_installed() {
    local pkg="$1"
    local checkcmd="${PKG_CHECK[$pkg]:-$pkg}"

    # First prefer command presence
    if command -v "$checkcmd" &>/dev/null; then
        return 0
    fi

    # Fallback to package database query if available
    if [ "$PM" = "apt" ]; then
        dpkg -s "$pkg" &>/dev/null && return 0 || return 1
    elif [ "$PM" = "dnf" ] || [ "$PM" = "yum" ] || [ "$PM" = "zypper" ]; then
        rpm -q "$pkg" &>/dev/null && return 0 || return 1
    elif [ "$PM" = "pacman" ]; then
        pacman -Qi "$pkg" &>/dev/null && return 0 || return 1
    elif [ "$PM" = "apk" ]; then
        apk info -e "$pkg" &>/dev/null && return 0 || return 1
    fi

    return 1
}

pkg_install() {
    local pkg="$1"
    if is_installed "$pkg"; then
        info "$pkg is already installed."
        return 0
    fi

    info "Installing $pkg ..."
    if [ "$DRY_RUN" = true ]; then
        # Show the install command we would run
        if [ "$PM" = "apt" ]; then
            printf "DEBIAN_FRONTEND=noninteractive "
        fi
        printf "%s " "${INSTALL_CMD[@]}"
        printf "%s\n" "$pkg"
        return 0
    fi

    set +e
    if [ "$PM" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive "${INSTALL_CMD[@]}" "$pkg"
    else
        "${INSTALL_CMD[@]}" "$pkg"
    fi
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        info "$pkg installed successfully."
        return 0
    else
        warn "Installation of $pkg failed (continuing)."
        return 1
    fi
}
# ==========================================================

# =================== SYSTEM UPDATE / UPGRADE ===================
info "Updating package cache..."
if [ "$DRY_RUN" = true ]; then
    printf "%b> %s%b\n" "${Cyan}" "$UPDATE_CMD" "${No}"
else
    run_sh "$UPDATE_CMD"
fi

info "Upgrading installed packages..."
if [ "$DRY_RUN" = true ]; then
    printf "%b> %s%b\n" "${Cyan}" "$UPGRADE_CMD" "${No}"
else
    run_sh "$UPGRADE_CMD"
fi
# ==========================================================

# =================== DEPENDENCIES INSTALLATION ===================
info "Installing basic tools..."

DEPENDENCIES=(curl git vim fail2ban htop net-tools sysstat iotop)

for pkg in "${DEPENDENCIES[@]}"; do
    pkg_install "$pkg" || warn "Continuing despite $pkg install failure."
done
# ==========================================================

# =================== FINAL MESSAGE =========================
echo
info "===================================================="
info "   Bootstrap completed (see messages above)"
if [ "$DRY_RUN" = true ]; then
    warn "This was a dry-run; no changes were actually applied."
else
    info "Please consider rebooting the system to finalize kernel/security updates if any."
fi
info "===================================================="
echo

exit 0
# =========================================================