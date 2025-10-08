#!/usr/bin/env bash
# hardening.sh 
# Run as root

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
fatal() { error "$*"; exit 1; }

# Run a command and display it before execution
run() {
    printf "%b> %s%b\n" "${Cyan}" "$*" "${No}"
    "$@"
}

PKG_RETRY_ATTEMPTS="${PKG_RETRY_ATTEMPTS:-3}"
PKG_RETRY_DELAY="${PKG_RETRY_DELAY:-5}"

run_with_retries() {
    local attempts="$1"
    local delay="$2"
    shift 2

    local attempt=1
    local status=0

    while [ $attempt -le "$attempts" ]; do
        set +e
        "$@"
        status=$?
        set -e

        if [ $status -eq 0 ]; then
            return 0
        fi

        if [ $attempt -lt "$attempts" ]; then
            warn "Command failed with exit $status (attempt ${attempt}/${attempts}); retrying in ${delay}s..."
            sleep "$delay"
        fi

        attempt=$((attempt + 1))
    done

    return $status
}

# Check root
if [ "$EUID" -ne 0 ]; then
    fatal "This script must be run as root."
fi

# Determine distribution from /etc/os-release
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
else
    fatal "Could not determine OS (missing /etc/os-release)."
fi

# Detect package manager and install/update commands
INSTALL_CMD=()
INSTALL_ENV=()
PKG_UPDATE_CMD=()
case "$OS_ID" in
    ubuntu|debian)
        if command -v apt-get &>/dev/null; then
            INSTALL_CMD=(apt-get install -y)
            INSTALL_ENV=(DEBIAN_FRONTEND=noninteractive)
            PKG_UPDATE_CMD=(apt-get update)
        fi
        ;;
    centos|rhel|fedora|amzn)
        if command -v dnf &>/dev/null; then
            INSTALL_CMD=(dnf install -y)
            PKG_UPDATE_CMD=(dnf makecache --refresh)
        elif command -v yum &>/dev/null; then
            INSTALL_CMD=(yum install -y)
            PKG_UPDATE_CMD=(yum makecache)
        fi
        ;;
    arch|manjaro)
        if command -v pacman &>/dev/null; then
            INSTALL_CMD=(pacman -S --noconfirm)
            PKG_UPDATE_CMD=(pacman -Sy)
        fi
        ;;
    alpine)
        if command -v apk &>/dev/null; then
            INSTALL_CMD=(apk add --no-cache)
            PKG_UPDATE_CMD=(true)
        fi
        ;;
    suse|opensuse)
        if command -v zypper &>/dev/null; then
            INSTALL_CMD=(zypper -n in)
            PKG_UPDATE_CMD=(zypper refresh)
        fi
        ;;
esac

if [ ${#INSTALL_CMD[@]} -eq 0 ]; then
    warn "No known package manager detected. Automatic installations will not be available."
else
    install_cmd_str="$(printf '%s ' "${INSTALL_CMD[@]}")"
    install_cmd_str="${install_cmd_str%% }"
    info "Detected package manager: $OS_ID - using: $install_cmd_str"
fi
# ==========================================================

# ========================= INIT HELPERS =========================
# Return 0 if systemd is PID 1
is_systemd_active() {
    [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]
}

# Return 0 if `service` command exists
has_service_cmd() {
    command -v service &>/dev/null
}

# Restart a service using systemd or service command fallback
service_restart() {
    local svc="$1"
    if is_systemd_active; then
        systemctl restart "$svc"
    elif has_service_cmd; then
        service "$svc" restart || true
    else
        warn "No known service manager to restart $svc"
    fi
}

# Enable & start a service (systemd preferred)
service_enable_start() {
    local svc="$1"
    if is_systemd_active; then
        systemctl enable --now "$svc" || true
    elif has_service_cmd; then
        service "$svc" start || true
    else
        warn "Could not enable/start $svc (no systemd/service available)"
    fi
}
# ==========================================================

# ========================= BANNER =========================
echo -e "${Cyan}
  _     ___ _   _ _   ___  __ 
 | |   |_ _| \ | | | | \ \/ / 
 | |    | ||  \| | | | |\  /  
 | |___ | || |\  | |_| |/  \  
 |_____||_||_| \_|\___//_/\_\ 
  _   _    _    ____  ____  _____ _   _ ___ _   _  ____  
 | | | |  / \  |  _ \|  _ \| ____| \ | |_ _| \ | |/ ___| 
 | |_| | / _ \ | |_) | | | |  _| |  \| || ||  \| | |  _  
 |  _  |/ ___ \|  _ <| |_| | |___| |\  || || |\  | |_| | 
 |_| |_/_/   \_\_| \_\____/|_____|_| \_|___|_| \_|\____| 
${No}
"
# ==========================================================

# =================== SSH KEY SAFEGUARD ======================
# Root home and authorized_keys path
ROOT_HOME="/root"
AUTH_KEYS="$ROOT_HOME/.ssh/authorized_keys"

# If .ssh doesn't exist, create it temporarily with secure permissions
if [ ! -d "$ROOT_HOME/.ssh" ]; then
    warn "Directory $ROOT_HOME/.ssh does not exist. Creating it with permissions 700."
    mkdir -p "$ROOT_HOME/.ssh"
    chmod 700 "$ROOT_HOME/.ssh"
fi

# If authorized_keys is missing or empty, skip SSH hardening but continue with other tasks
SKIP_SSH_HARDEN=false
if [ ! -s "$AUTH_KEYS" ]; then
    warn "No SSH keys found in $AUTH_KEYS. Skipping SSH hardening to avoid lockout, continuing with other tasks."
    SKIP_SSH_HARDEN=true
else
    info "SSH key(s) detected in $AUTH_KEYS. Proceeding with SSH hardening."
fi
# ==========================================================

# =================== FIREWALL SETUP =======================
info "Configuring firewall..."

# Helper to install if missing
install_if_missing() {
    local pkg="$1"
    local cmd_check="$2"
    local attempts="$PKG_RETRY_ATTEMPTS"
    local delay="$PKG_RETRY_DELAY"
    local install_status=0

    if command -v "$cmd_check" &>/dev/null; then
        return 0
    fi

    if [ ${#INSTALL_CMD[@]} -eq 0 ]; then
        warn "Package manager unavailable; cannot install $pkg automatically."
        return 1
    fi

    info "Installing required package: $pkg"

    if [ ${#PKG_UPDATE_CMD[@]} -gt 0 ]; then
        if ! run_with_retries "$attempts" "$delay" "${PKG_UPDATE_CMD[@]}"; then
            warn "Failed to refresh package metadata (continuing anyway)."
        fi
    fi

    if [ ${#INSTALL_ENV[@]} -gt 0 ]; then
        if ! run_with_retries "$attempts" "$delay" env "${INSTALL_ENV[@]}" "${INSTALL_CMD[@]}" "$pkg"; then
            install_status=1
        fi
    else
        if ! run_with_retries "$attempts" "$delay" "${INSTALL_CMD[@]}" "$pkg"; then
            install_status=1
        fi
    fi

    if [ $install_status -ne 0 ]; then
        warn "Failed to install $pkg after ${attempts} attempt(s)."
        return $install_status
    fi

    return 0
}

# 1) UFW
if command -v ufw &>/dev/null; then
    info "Using UFW..."
    run ufw default deny incoming
    run ufw default allow outgoing
    run ufw allow 22/tcp
    run ufw allow 80/tcp
    run ufw allow 443/tcp
    if ufw status | grep -qi inactive; then
        run ufw --force enable
    else
        info "UFW is already active."
    fi

# 2) firewalld (systemd)
elif is_systemd_active; then
    info "Attempting to use firewalld..."
    if ! command -v firewall-cmd &>/dev/null; then
        install_if_missing firewalld firewall-cmd
    fi
    if command -v firewall-cmd &>/dev/null; then
        run systemctl enable --now firewalld
        run firewall-cmd --permanent --set-default-zone=public
        run firewall-cmd --permanent --add-service=ssh
        run firewall-cmd --permanent --add-service=http
        run firewall-cmd --permanent --add-service=https
        run firewall-cmd --reload
    else
        warn "firewalld is not available even after attempting installation."
    fi

# 3) iptables fallback
else
    info "No systemd/firewalld detected; using iptables directly..."
    install_if_missing iptables iptables
    # Set safe default policies
    run iptables -P INPUT DROP
    run iptables -P FORWARD DROP
    run iptables -P OUTPUT ACCEPT
    run iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    run iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    run iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    run iptables -A INPUT -p tcp --dport 443 -j ACCEPT

    # Persistency: Debian/Ubuntu -> iptables-persistent; RHEL -> iptables-services
    if [ -d /etc/sysconfig ]; then
        iptables-save > /etc/sysconfig/iptables || warn "Could not save /etc/sysconfig/iptables"
    else
        if [ ${#INSTALL_CMD[@]} -gt 0 ]; then
            install_if_missing iptables-persistent iptables-restore
        fi
        if command -v netfilter-persistent &>/dev/null; then
            run netfilter-persistent save || true
        fi
    fi
    info "iptables rules applied."
fi
# ==========================================================

# =================== FAIL2BAN SETUP =======================
info "Configuring Fail2Ban..."
if ! command -v fail2ban-client &>/dev/null; then
    install_if_missing fail2ban fail2ban-client
fi

# Write jail.local atomically
JAIL_LOCAL_TMP="$(mktemp)"
cat > "$JAIL_LOCAL_TMP" <<'EOL'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOL

mv "$JAIL_LOCAL_TMP" /etc/fail2ban/jail.local
chmod 644 /etc/fail2ban/jail.local
info "Wrote /etc/fail2ban/jail.local"

# Restart service if available
if command -v fail2ban-client &>/dev/null; then
    if is_systemd_active; then
        run systemctl restart fail2ban || warn "Could not restart fail2ban with systemd"
        run systemctl enable fail2ban || true
    elif has_service_cmd; then
        run service fail2ban restart || warn "service fail2ban restart failed"
    else
        warn "No service manager; restarting fail2ban manually."
        run nohup fail2ban-client -x start >/var/log/fail2ban-manual.log 2>&1 &
    fi
else
    warn "fail2ban-client not available; skipping restart."
fi
# ==========================================================

# =================== SSH HARDENING ========================
if [ "$SKIP_SSH_HARDEN" = true ]; then
    warn "SSH hardening skipped (authorized_keys missing). No changes to sshd_config will be made."
else
    info "Applying SSH hardening (backups and tests included)..."

    SSHD_CONF="/etc/ssh/sshd_config"
    BACKUP="${SSHD_CONF}.$(date +%Y%m%d%H%M%S).bak"
    cp -a "$SSHD_CONF" "$BACKUP"
    info "Created sshd_config backup at $BACKUP"

    # Function to safely replace or append directives in sshd_config
    upsert_sshd_config() {
        local key="$1"
        local value="$2"
        if grep -qiE "^\s*${key}\b" "$SSHD_CONF"; then
            # Replace existing directive (case-insensitive)
            sed -ri "s#^\s*${key}\b.*#${key} ${value}#Ig" "$SSHD_CONF"
        else
            echo "${key} ${value}" >> "$SSHD_CONF"
        fi
    }

    upsert_sshd_config "PermitRootLogin" "no"
    upsert_sshd_config "PasswordAuthentication" "no"
    upsert_sshd_config "ChallengeResponseAuthentication" "no"
    upsert_sshd_config "UsePAM" "yes"

    # Test configuration before restarting
    if sshd -t -f "$SSHD_CONF" 2>/tmp/sshd_test.err; then
        info "sshd_config test passed. Restarting SSH service..."
        service_restart sshd || service_restart ssh || warn "Could not restart sshd/ssh using common methods."
    else
        error "New sshd configuration failed test. Restoring backup and aborting changes."
        error "Test output:"
        sed -n '1,200p' /tmp/sshd_test.err || true
        cp -a "$BACKUP" "$SSHD_CONF"
        fatal "sshd_config restored from $BACKUP. Check /tmp/sshd_test.err for details."
    fi
fi

# Ensure secure permissions (always applied regardless of SSH hardening)
chmod 700 "$ROOT_HOME" || warn "Could not chmod $ROOT_HOME"
chmod 700 "$ROOT_HOME/.ssh" || warn "Could not chmod $ROOT_HOME/.ssh"
if [ -s "$AUTH_KEYS" ]; then
    chmod 600 "$AUTH_KEYS" || warn "Could not chmod $AUTH_KEYS"
fi
info "Adjusted permissions for /root and .ssh."
# ==========================================================

# =================== AUTOMATIC UPDATES =======================
info "Configuring automatic security updates..."
case "$OS_ID" in
    ubuntu|debian)
        if [ ${#INSTALL_CMD[@]} -gt 0 ]; then
            install_if_missing unattended-upgrades unattended-upgrades
            # enable unattended-upgrades
            dpkg-reconfigure -plow unattended-upgrades || true
            info "unattended-upgrades installed/configured."
        else
            warn "Cannot install unattended-upgrades (no package manager detected)."
        fi
        ;;
    centos|rhel|fedora|amzn)
        if command -v dnf &>/dev/null; then
            install_if_missing dnf-automatic dnf-automatic
            run systemctl enable --now dnf-automatic.timer || true
        elif command -v yum &>/dev/null; then
            install_if_missing yum-cron yum-cron
            run systemctl enable --now yum-cron || true
        fi
        ;;
    *)
        warn "Automatic updates support not implemented for $OS_ID"
        ;;
esac
# ==========================================================

# =================== SYSTEMD JOURNALING =====================
if is_systemd_active; then
    info "Configuring persistent journald and limiting disk usage..."
    mkdir -p /var/log/journal
    if [ -f /etc/systemd/journald.conf ]; then
        # Edit or add SystemMaxUse
        if grep -q "^\s*SystemMaxUse" /etc/systemd/journald.conf; then
            sed -ri 's#^\s*SystemMaxUse.*#SystemMaxUse=100M#' /etc/systemd/journald.conf
        else
            echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
        fi
        run systemctl restart systemd-journald || warn "Could not restart systemd-journald"
    else
        warn "/etc/systemd/journald.conf not found; skipping journald configuration."
    fi
fi
# ==========================================================

# =================== FINAL MESSAGE =========================
info "Hardening completed successfully."
echo
info "IMPORTANT: Before closing your session, verify you can open a new SSH connection from another terminal."
if [ "$SKIP_SSH_HARDEN" = true ]; then
    warn "SSH hardening was skipped because no authorized_keys were found. No changes were made to sshd_config."
else
    info "SSH root login and password authentication have been disabled."
    info "To revert SSH changes: restore from the backup created at: $BACKUP"
fi
echo

# short summary of changes
cat <<SUMMARY
Summary of changes made:
 - Firewall configured (UFW / firewalld / iptables depending on availability).
 - Fail2Ban installed/configured and restarted if possible.
 - SSH hardening: ${SKIP_SSH_HARDEN:+SKIPPED (authorized_keys missing)}${SKIP_SSH_HARDEN:+" (no sshd_config changes)"}${SKIP_SSH_HARDEN:+"":+""}
   (If not skipped: PermitRootLogin no, PasswordAuthentication no, backup and configuration test applied.)
 - Permissions for /root and .ssh fixed.
 - Automatic security updates enabled (if OS is supported).
 - Journald configured with limited disk usage (if systemd is active).
SUMMARY

exit 0
