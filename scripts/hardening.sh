#!/usr/bin/env bash
# hardening.sh
# Run as root
# Usage: sudo ./hardening.sh

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

# ========================= BASIC CHECKS =========================
if [ "$EUID" -ne 0 ]; then
    fatal "This script must be run as root (use sudo)."
fi

if [ ! -f /etc/os-release ]; then
    fatal "/etc/os-release missing; cannot detect OS."
fi

. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
OS_ID_LIKE="${ID_LIKE:-}"

info "Detected package manager: ${OS_ID} ${OS_VER} (ID_LIKE=${OS_ID_LIKE})"
# ================================================================

# =================== PACKAGE MANAGER DETECTION ===================
INSTALL_CMD=()
PKG_UPDATE_CMD=()
INSTALL_ENV=()

case "$OS_ID" in
    ubuntu|debian)
        INSTALL_CMD=(apt-get install -y)
        PKG_UPDATE_CMD=(apt-get update)
        INSTALL_ENV=(DEBIAN_FRONTEND=noninteractive)
        ;;
    amzn)
        if command -v dnf &>/dev/null; then
            INSTALL_CMD=(dnf install -y)
            PKG_UPDATE_CMD=(dnf makecache --refresh)
        else
            INSTALL_CMD=(yum install -y)
            PKG_UPDATE_CMD=(yum makecache)
        fi
        ;;
    fedora)
        INSTALL_CMD=(dnf install -y)
        PKG_UPDATE_CMD=(dnf makecache --refresh)
        ;;
    centos|rhel)
        if command -v dnf &>/dev/null; then
            INSTALL_CMD=(dnf install -y)
            PKG_UPDATE_CMD=(dnf makecache --refresh)
        else
            INSTALL_CMD=(yum install -y)
            PKG_UPDATE_CMD=(yum makecache)
        fi
        ;;
    arch|manjaro)
        INSTALL_CMD=(pacman -S --noconfirm)
        PKG_UPDATE_CMD=(pacman -Sy)
        ;;
    alpine)
        INSTALL_CMD=(apk add --no-cache)
        PKG_UPDATE_CMD=(true)
        ;;
    opensuse*|suse)
        INSTALL_CMD=(zypper -n in)
        PKG_UPDATE_CMD=(zypper refresh)
        ;;
    *)
        if command -v apt-get &>/dev/null; then
            INSTALL_CMD=(apt-get install -y)
            PKG_UPDATE_CMD=(apt-get update)
            INSTALL_ENV=(DEBIAN_FRONTEND=noninteractive)
        elif command -v dnf &>/dev/null; then
            INSTALL_CMD=(dnf install -y)
            PKG_UPDATE_CMD=(dnf makecache --refresh)
        elif command -v yum &>/dev/null; then
            INSTALL_CMD=(yum install -y)
            PKG_UPDATE_CMD=(yum makecache)
        elif command -v pacman &>/dev/null; then
            INSTALL_CMD=(pacman -S --noconfirm)
            PKG_UPDATE_CMD=(pacman -Sy)
        elif command -v apk &>/dev/null; then
            INSTALL_CMD=(apk add --no-cache)
            PKG_UPDATE_CMD=(true)
        elif command -v zypper &>/dev/null; then
            INSTALL_CMD=(zypper -n in)
            PKG_UPDATE_CMD=(zypper refresh)
        else
            warn "No known package manager detected. Automatic installs will not be available."
            INSTALL_CMD=()
            PKG_UPDATE_CMD=()
        fi
        ;;
esac

if [ ${#INSTALL_CMD[@]} -gt 0 ]; then
    install_cmd_str="$(printf '%s ' "${INSTALL_CMD[@]}")"
    install_cmd_str="${install_cmd_str%% }"
    info "Using install command: $install_cmd_str"
fi
# ================================================================

# =================== EPEL / extra repos helper (rpm systems) ===================
ensure_epel_if_needed() {
    local want_pkg="$1"
    if [ ${#INSTALL_CMD[@]} -eq 0 ]; then
        return 0
    fi
    if ! command -v rpm &>/dev/null && ! command -v yum &>/dev/null && ! command -v dnf &>/dev/null; then
        return 0
    fi

    if command -v "$want_pkg" &>/dev/null; then
        return 0
    fi

    if command -v amazon-linux-extras &>/dev/null; then
        info "Trying amazon-linux-extras to enable EPEL..."
        set +e
        amazon-linux-extras install epel -y >/dev/null 2>&1 || true
        set -e
    fi

    if command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        info "Attempting to install epel-release..."
        if [ ${#INSTALL_ENV[@]} -gt 0 ]; then
            env "${INSTALL_ENV[@]}" "${INSTALL_CMD[@]}" epel-release || true
        else
            "${INSTALL_CMD[@]}" epel-release || true
        fi
    fi
}
# ================================================================

# =================== INSTALL HELPERS ===================
install_if_missing() {
    local pkg="$1"
    local cmd_check="${2:-$pkg}"

    if command -v "$cmd_check" &>/dev/null; then
        return 0
    fi

    if [ ${#INSTALL_CMD[@]} -eq 0 ]; then
        warn "No package manager available; cannot install $pkg automatically."
        return 1
    fi

    info "Installing required package: $pkg"
    if [ ${#PKG_UPDATE_CMD[@]} -gt 0 ]; then
        run_with_retries "$PKG_RETRY_ATTEMPTS" "$PKG_RETRY_DELAY" "${PKG_UPDATE_CMD[@]}" || warn "Failed to refresh package metadata (continuing)."
    fi

    if [ "$pkg" = "fail2ban" ] || [ "$pkg" = "iptables-services" ]; then
        ensure_epel_if_needed "$pkg"
    fi

    if [ ${#INSTALL_ENV[@]} -gt 0 ]; then
        run_with_retries "$PKG_RETRY_ATTEMPTS" "$PKG_RETRY_DELAY" env "${INSTALL_ENV[@]}" "${INSTALL_CMD[@]}" "$pkg" || {
            warn "Installation failed for $pkg"
            return 1
        }
    else
        run_with_retries "$PKG_RETRY_ATTEMPTS" "$PKG_RETRY_DELAY" "${INSTALL_CMD[@]}" "$pkg" || {
            warn "Installation failed for $pkg"
            return 1
        }
    fi

    return 0
}
# ===============================================================

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
# =========================================================

# =================== SSH KEY SAFEGUARD ======================
ROOT_HOME="/root"
AUTH_KEYS="$ROOT_HOME/.ssh/authorized_keys"

if [ ! -d "$ROOT_HOME/.ssh" ]; then
    warn "Directory $ROOT_HOME/.ssh does not exist. Creating it with secure permissions."
    mkdir -p "$ROOT_HOME/.ssh"
    chmod 700 "$ROOT_HOME/.ssh"
fi

SKIP_SSH_HARDEN=false
if [ ! -s "$AUTH_KEYS" ]; then
    warn "No SSH keys found in $AUTH_KEYS. Skipping SSH hardening to avoid lockout, continuing with other tasks."
    SKIP_SSH_HARDEN=true
else
    info "SSH key(s) detected in $AUTH_KEYS. Proceeding with SSH hardening."
fi

# =================== FIREWALL SETUP =======================
info "Configuring firewall..."

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
elif command -v firewall-cmd &>/dev/null || command -v systemctl &>/dev/null; then
    info "Attempting to use firewalld..."
    if ! command -v firewall-cmd &>/dev/null; then
        install_if_missing firewalld firewall-cmd || warn "Could not install firewalld; will try iptables fallback."
    fi

    if command -v firewall-cmd &>/dev/null; then
        run systemctl enable --now firewalld || warn "Could not enable/start firewalld via systemctl."

        if firewall-cmd --set-default-zone=public >/dev/null 2>&1; then
            info "Default zone set to public (runtime)."
        else
            run firewall-cmd --permanent --set-default-zone=public || warn "Could not set default zone to public (permanent)."
        fi

        # add services
        if ! firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1; then
            warn "Could not add ssh service permanently; trying zone-specific add."
            run firewall-cmd --permanent --zone=public --add-service=ssh || warn "Could not add ssh service to firewalld."
        else
            info "ssh service added (permanent)."
        fi
        run firewall-cmd --permanent --add-service=http || warn "Could not add http service to firewalld."
        run firewall-cmd --permanent --add-service=https || warn "Could not add https service to firewalld."

        run firewall-cmd --reload || warn "firewalld reload failed."
    else
        warn "firewalld not available; falling back to iptables."
        :
    fi

# 3) iptables fallback
else
    info "No UFW/firewalld detected; using iptables/nftables fallback..."
    install_if_missing iptables iptables || warn "iptables package may not be available."

    run iptables -P INPUT DROP || warn "Could not set default INPUT policy"
    run iptables -P FORWARD DROP || warn "Could not set default FORWARD policy"
    run iptables -P OUTPUT ACCEPT || warn "Could not set default OUTPUT policy"
    run iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
    run iptables -A INPUT -p tcp --dport 22 -j ACCEPT || true
    run iptables -A INPUT -p tcp --dport 80 -j ACCEPT || true
    run iptables -A INPUT -p tcp --dport 443 -j ACCEPT || true

    if [ -d /etc/sysconfig ]; then
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/sysconfig/iptables || warn "Could not save /etc/sysconfig/iptables"
        fi
    else
        install_if_missing iptables-persistent iptables-restore || warn "Could not install iptables-persistent"
        if command -v netfilter-persistent &>/dev/null; then
            run netfilter-persistent save || warn "Could not save iptables via netfilter-persistent"
        fi
    fi
    info "iptables rules applied (best-effort)."
fi
# ================================================================

# =================== FAIL2BAN SETUP =======================
info "Configuring Fail2Ban..."
if ! command -v fail2ban-client &>/dev/null; then
    ensure_epel_if_needed fail2ban
    install_if_missing fail2ban fail2ban-client || warn "fail2ban installation failed or package not available; skipping configuration."
fi

if command -v fail2ban-client &>/dev/null; then
    mkdir -p /etc/fail2ban
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
    chmod 0644 /etc/fail2ban/jail.local
    info "Wrote /etc/fail2ban/jail.local"

    if command -v systemctl &>/dev/null && systemctl list-unit-files | grep -qi fail2ban; then
        run systemctl restart fail2ban || warn "Could not restart fail2ban with systemd"
        run systemctl enable fail2ban || true
    elif command -v service &>/dev/null; then
        run service fail2ban restart || warn "service fail2ban restart failed"
    else
        warn "No service manager; attempting to start fail2ban via fail2ban-client"
        # start in background, then check process presence
        run nohup fail2ban-client -x start >/var/log/fail2ban-manual.log 2>&1 &
        sleep 0.5
        if ! pgrep -f fail2ban >/dev/null 2>&1; then
            warn "Could not start fail2ban manually (no running process detected). Check /var/log/fail2ban-manual.log"
        else
            info "fail2ban started (manual background start)."
        fi
    fi
else
    warn "fail2ban-client not available; skipping fail2ban configuration."
fi
# ================================================================

# =================== SSH HARDENING ========================
if [ "$SKIP_SSH_HARDEN" = true ]; then
    warn "SSH hardening skipped (authorized_keys missing). No changes to sshd_config will be made."
else
    info "Applying SSH hardening (backups and tests included)..."

    SSHD_CONF="/etc/ssh/sshd_config"
    if [ ! -f "$SSHD_CONF" ]; then
        warn "sshd_config not found at $SSHD_CONF; skipping SSH hardening."
    else
        BACKUP="${SSHD_CONF}.$(date +%Y%m%d%H%M%S).bak"
        cp -a "$SSHD_CONF" "$BACKUP"
        info "Created sshd_config backup at $BACKUP"

        upsert_sshd_config() {
            local key="$1"
            local value="$2"
            if grep -qiE "^\s*${key}\b" "$SSHD_CONF"; then
                sed -ri "s#^\s*${key}\b.*#${key} ${value}#Ig" "$SSHD_CONF"
            else
                echo "${key} ${value}" >> "$SSHD_CONF"
            fi
        }

        upsert_sshd_config "PermitRootLogin" "no"
        upsert_sshd_config "PasswordAuthentication" "no"
        upsert_sshd_config "ChallengeResponseAuthentication" "no"
        upsert_sshd_config "UsePAM" "yes"

        set +e
        sshd -t -f "$SSHD_CONF" 2>/tmp/sshd_test.err
        test_status=$?
        set -e

        if [ $test_status -eq 0 ]; then
            info "sshd_config test passed. Restarting SSH service..."
            if command -v systemctl &>/dev/null; then
                run systemctl restart sshd || run systemctl restart ssh || warn "Could not restart sshd/ssh with systemctl"
            elif command -v service &>/dev/null; then
                run service sshd restart || run service ssh restart || warn "Could not restart sshd/ssh with service"
            else
                warn "No service manager available to restart SSH; please restart SSH manually."
            fi
        else
            error "New sshd configuration failed test. Restoring backup and aborting changes."
            error "Test output (first 200 lines):"
            sed -n '1,200p' /tmp/sshd_test.err || true
            cp -a "$BACKUP" "$SSHD_CONF"
            fatal "sshd_config restored from $BACKUP. Check /tmp/sshd_test.err for details."
        fi
    fi
fi

# Ensure secure permissions
chmod 700 "$ROOT_HOME" || warn "Could not chmod $ROOT_HOME"
chmod 700 "$ROOT_HOME/.ssh" || warn "Could not chmod $ROOT_HOME/.ssh"
if [ -s "$AUTH_KEYS" ]; then
    chmod 600 "$AUTH_KEYS" || warn "Could not chmod $AUTH_KEYS"
fi
info "Adjusted permissions for /root and .ssh."
# ================================================================

# =================== AUTOMATIC UPDATES =======================
info "Configuring automatic security updates..."
case "$OS_ID" in
    ubuntu|debian)
        install_if_missing unattended-upgrades unattended-upgrades || warn "unattended-upgrades not available"
        if command -v dpkg-reconfigure &>/dev/null; then
            run dpkg-reconfigure -plow unattended-upgrades || true
        fi
        ;;
    centos|rhel|fedora|amzn)
        if command -v dnf &>/dev/null; then
            install_if_missing dnf-automatic dnf-automatic || warn "dnf-automatic not available"
            run systemctl enable --now dnf-automatic.timer || warn "Could not enable dnf-automatic.timer"
        elif command -v yum &>/dev/null; then
            install_if_missing yum-cron yum-cron || warn "yum-cron not available"
            run systemctl enable --now yum-cron || warn "Could not enable yum-cron"
        fi
        ;;
    *)
        warn "Automatic updates support not implemented for $OS_ID"
        ;;
esac
# ===========================================================

# =================== SYSTEMD JOURNALING =====================
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then
    info "Configuring persistent journald and limiting disk usage..."
    mkdir -p /var/log/journal
    if [ -f /etc/systemd/journald.conf ]; then
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
# ===========================================================

# =================== FINAL MESSAGE =========================
info "Hardening completed successfully."
echo
info "IMPORTANT: Before closing your session, verify you can open a new SSH connection from another terminal."
if [ "$SKIP_SSH_HARDEN" = true ]; then
    warn "SSH hardening was skipped because no authorized_keys were found. No changes were made to sshd_config."
else
    if [ -n "${BACKUP:-}" ]; then
        info "SSH root login and password authentication have been disabled (if sshd_config was present)."
        info "To revert SSH changes: restore from the backup created at: $BACKUP"
    else
        info "SSH hardening may have been applied (no sshd_config backup recorded)."
    fi
fi
echo

cat <<SUMMARY
Summary of changes made (best-effort):
 - Firewall configured (UFW / firewalld / iptables fallback).
 - Fail2Ban installed/configured if available.
 - SSH hardening applied (unless authorized_keys missing) with backup and config test.
 - Permissions for /root and .ssh fixed.
 - Automatic security updates configured for supported OS families.
 - Journald configured with limited disk usage (if systemd is active).
SUMMARY

exit 0
# ===========================================================
