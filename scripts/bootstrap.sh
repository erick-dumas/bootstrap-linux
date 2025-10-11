#!/usr/bin/env bash
# bootstrap.sh 
# Usage: sudo ./bootstrap.sh [-n|--dry-run] [-y|--yes]

set -euo pipefail
IFS=$'\n\t'

# ========================= COLORS & HELPERS =========================
Green='\033[0;32m'
Red='\033[0;31m'
Cyan='\033[1;36m'
No='\033[0m'

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

PKG_IGNORE_PACKAGEKIT=${PKG_IGNORE_PACKAGEKIT:-true}

# ===============================================================

# ========================= RUN HELPERS =========================
run() {
    # Print command then execute (array-style)
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

lockfile_is_active() {
    local file="$1"

    if [ ! -e "$file" ]; then
        return 1
    fi

    if command -v fuser &>/dev/null; then
        if fuser "$file" &>/dev/null; then
            return 0
        fi
    fi

    if command -v lsof &>/dev/null; then
        if lsof "$file" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Wait while common package manager processes are running
wait_for_pkg_mgr() {
    local max_wait=60   # Seconds to wait before giving up
    local sleep_for=5
    local waited=0
    local procs=(apt apt-get dpkg aptitude apt-key apt-get update apt-fast yum dnf pacman pacman-key zypper apk)
    if [ "$PKG_IGNORE_PACKAGEKIT" != "true" ]; then
        procs+=(packagekit packagekitd pkcon)
    fi
    local lockfiles=(/var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/apt/lists/lock /var/run/yum.pid)
    while : ; do
        local found=""
        for p in "${procs[@]}"; do
            if pgrep -f -x "$p" >/dev/null 2>&1 || pgrep -f "$p" >/dev/null 2>&1; then
                found="$p"
                break
            fi
        done
        if [ -z "$found" ]; then
            # also check lockfiles as a last resort
            local lock
            for lock in "${lockfiles[@]}"; do
                if [ -e "$lock" ]; then
                    if lockfile_is_active "$lock"; then
                        found="lockfile:$lock"
                        break
                    else
                        warn "Ignoring stale package manager lock file: $lock"
                        rm -f "$lock" 2>/dev/null || true
                    fi
                fi
            done
        fi

        if [ -z "$found" ]; then
            return 0
        fi

        if [ "$waited" -ge "$max_wait" ]; then
            warn "Package manager still busy (process: $found) after ${max_wait}s; continuing anyway."
            return 1
        fi

        warn "Package manager busy ($found). Waiting ${sleep_for}s..."
        sleep "$sleep_for"
        waited=$((waited + sleep_for))
    done
}

# Run a package manager command with retries and waiting if locked
pm_safe() {
    # usage: pm_safe <command> [args...]
    # returns 0 on success
    wait_for_pkg_mgr || true

    local max_retries=3
    local attempt=1
    local backoff=5

    while [ $attempt -le $max_retries ]; do
        if [ "$DRY_RUN" = true ]; then
            printf "%b> %s%b\n" "${Cyan}" "$*" "${No}"
            return 0
        fi

        if "$@"; then
            return 0
        fi

        warn "Comando falló (intento $attempt/$max_retries): $*"
        sleep $((backoff * attempt))
        attempt=$((attempt + 1))
    done

    error "Comando de gestor de paquetes falló tras $max_retries intentos: $*"
    return 1
}
# ================================================================

# ========================= BASIC CHECKS =========================
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root."
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    error "/etc/os-release not found; unable to determine distribution."
    exit 1
fi

# Source /etc/os-release for distro info
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
OS_ID_LIKE="${ID_LIKE:-}"

info "Detected OS: ${OS_ID} ${OS_VER} (ID_LIKE=${OS_ID_LIKE})"
info "Dry run: ${DRY_RUN}, Assume yes: ${ASSUME_YES}"
# ================================================================

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
case "$OS_ID" in
    ubuntu|debian)
        PM="apt"
        INSTALL_CMD=(apt-get install -y)
        UPDATE_CMD="apt-get update"
        UPGRADE_CMD="apt-get upgrade -y"
        ;;
    amzn)
        # Amazon Linux 2 is rpm-based but has yum and amazon-linux-extras
        PM="yum"
        INSTALL_CMD=(yum install -y)
        UPDATE_CMD="yum makecache"
        UPGRADE_CMD="yum upgrade -y"
        ;;
    fedora)
        PM="dnf"
        INSTALL_CMD=(dnf install -y)
        UPDATE_CMD="dnf makecache --refresh"
        UPGRADE_CMD="dnf upgrade -y"
        ;;
    centos|rhel)
        # Could be yum or dnf depending on version, prefer dnf if available
        if command -v dnf &>/dev/null; then
            PM="dnf"
            INSTALL_CMD=(dnf install -y)
            UPDATE_CMD="dnf makecache --refresh"
            UPGRADE_CMD="dnf upgrade -y"
        else
            PM="yum"
            INSTALL_CMD=(yum install -y)
            UPDATE_CMD="yum makecache"
            UPGRADE_CMD="yum upgrade -y"
        fi
        ;;
    arch|manjaro)
        PM="pacman"
        INSTALL_CMD=(pacman -S --noconfirm)
        UPDATE_CMD="pacman -Sy"
        UPGRADE_CMD="pacman -Syu --noconfirm"
        ;;
    alpine)
        PM="apk"
        INSTALL_CMD=(apk add --no-cache)
        UPDATE_CMD="apk update"
        UPGRADE_CMD="apk upgrade"
        ;;
    opensuse*|suse)
        PM="zypper"
        INSTALL_CMD=(zypper -n in)
        UPDATE_CMD="zypper refresh"
        UPGRADE_CMD="zypper -n up"
        ;;
    *)
        # Fallback: try to detect by available commands
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
            error "No se detectó un gestor de paquetes conocido."
            exit 1
        fi
        ;;
esac

info "Using package manager: $PM"

# =================== PACKAGE PRESENCE CHECK ====================
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

    if command -v "$checkcmd" &>/dev/null; then
        return 0
    fi

    case "$PM" in
        apt)
            dpkg -s "$pkg" &>/dev/null && return 0 || return 1
            ;;
        dnf|yum|zypper)
            rpm -q "$pkg" &>/dev/null && return 0 || return 1
            ;;
        pacman)
            pacman -Qi "$pkg" &>/dev/null && return 0 || return 1
            ;;
        apk)
            apk info -e "$pkg" &>/dev/null && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac

    return 1
}

# Try to enable EPEL/extra repos for rpm-based if missing packages like fail2ban
ensure_epel_if_needed() {
    local want_pkg="$1"
    if [ "$PM" != "yum" ] && [ "$PM" != "dnf" ]; then
        return 0
    fi

    # If the package is already installed, do nothing
    if is_installed "$want_pkg"; then
        return 0
    fi

    # Try amazon-linux-extras (Amazon Linux)
    if command -v amazon-linux-extras &>/dev/null; then
        info "Trying to enable epel via amazon-linux-extras..."
        if [ "$DRY_RUN" = false ]; then
            amazon-linux-extras install epel -y || true
        else
            printf "%b> amazon-linux-extras install epel -y%b\n" "${Cyan}" "${No}"
        fi
    fi

    # Try to install epel-release via package manager
    info "Trying to install 'epel-release' to obtain additional packages..."
    if pm_safe "${INSTALL_CMD[@]}" epel-release; then
        info "epel-release installed (if it was available)."
    else
        warn "Failed to install epel-release automatically; you may need to enable EPEL manually."
    fi

    # refresh cache
    if [ "$PM" = "yum" ] || [ "$PM" = "dnf" ]; then
        pm_safe "${PM}" makecache || true
    fi
}

pkg_install() {
    local pkg="$1"
    if is_installed "$pkg"; then
        info "$pkg is already installed."
        return 0
    fi

    # special-case: for rpm systems, ensure epel if trying to install fail2ban
    if [ "$pkg" = "fail2ban" ] && { [ "$PM" = "yum" ] || [ "$PM" = "dnf" ]; }; then
        ensure_epel_if_needed "$pkg"
    fi

    info "Installing $pkg ..."
    # Build command preview
    if [ "$DRY_RUN" = true ]; then
        if [ "$PM" = "apt" ]; then
            printf "%b> DEBIAN_FRONTEND=noninteractive %s %s%b\n" "${Cyan}" "${INSTALL_CMD[*]}" "$pkg" "${No}"
        else
            printf "%b> %s %s%b\n" "${Cyan}" "${INSTALL_CMD[*]}" "$pkg" "${No}"
        fi
        return 0
    fi

    # Run real install
    if [ "$PM" = "apt" ]; then
        pm_safe env DEBIAN_FRONTEND=noninteractive "${INSTALL_CMD[@]}" "$pkg"
    else
        pm_safe "${INSTALL_CMD[@]}" "$pkg"
    fi
    local status=$?
    if [ $status -eq 0 ]; then
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
    pm_safe run_sh "$UPDATE_CMD"
fi

info "Updating installed packages (upgrade)..."
if [ "$DRY_RUN" = true ]; then
    printf "%b> %s%b\n" "${Cyan}" "$UPGRADE_CMD" "${No}"
else
    pm_safe run_sh "$UPGRADE_CMD"
fi
# =============================================================

# =================== DEPENDENCIES INSTALLATION ===================
info "Installing basic tools..."

DEPENDENCIES=(curl git vim fail2ban htop net-tools sysstat iotop)

for pkg in "${DEPENDENCIES[@]}"; do
    pkg_install "$pkg" || warn "Continuing despite installation failure of $pkg."
done
# ================================================================

# =================== FINAL MESSAGE =========================
echo
info "===================================================="
info "   Bootstrap completed (see messages above)"
if [ "$DRY_RUN" = true ]; then
    warn "This was a dry-run; no changes were applied."
else
    info "Consider rebooting the system to finalize kernel/security updates if any."
fi
info "===================================================="
echo

exit 0
# =========================================================