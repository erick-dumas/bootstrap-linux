#!/bin/bash

# ========================= COLORS =========================
Green='\033[0;32m'        # Green
Red='\033[0;31m'          # Red
Cyan='\033[1;36m'        # Cyan
No='\e[0m'
# ==========================================================

# ========================= CHECKS =========================
# Verify that the script is run as root
set -e 

if [ "$EUID" -ne 0 ]; then
    echo -e "${Red}Please run as root${No}"
    exit
fi

# Determine the DISTRO and VERSION
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    echo -e "${Red}Cannot determine the operating system.${No}"
    exit 1
fi
# ==========================================================

# ========================= BANNER =========================
echo -e "${Cyan}  _     ___ _   _ _   ___  __ "
echo -e "${Cyan} | |   |_ _| \ | | | | \ \/ / "
echo -e "${Cyan} | |    | ||  \| | | | |\  /  "
echo -e "${Cyan} | |___ | || |\  | |_| |/  \  "
echo -e "${Cyan} |_____||_||_| \_|\___//_/\_\ "
echo -e "${Cyan}  ____   ___   ___ _____ ____ _____ ____      _    ____   "
echo -e "${Cyan} | __ ) / _ \ / _ \_   _/ ___|_   _|  _ \    / \  |  _ \  "
echo -e "${Cyan} |  _ \| | | | | | || | \___ \ | | | |_) |  / _ \ | |_) | "
echo -e "${Cyan} | |_) | |_| | |_| || |  ___) || | |  _ <  / ___ \|  __/  "
echo -e "${Cyan} |____/ \___/ \___/ |_| |____/ |_| |_| \_\/_/   \_\_|     "
echo -e "${Cyan}"
# =========================================================

# =================== PACKAGE MANAGER =====================
echo -e "${Green}Checking package manager...${No}"

case "$OS" in
    ubuntu|debian)
        if ! command -v apt &> /dev/null; then
            echo -e "${Red}apt could not be found. Please install it.${No}"
            exit 1
        fi
        echo -e "${Green}Using apt as the package manager.${No}"
        UPDATE_CMD="apt update -y"
        UPGRADE_CMD="apt upgrade -y"
        INSTALL_CMD="apt install -y"
        ;;
    centos|rhel|fedora|amzn)
        if ! command -v yum &> /dev/null && ! command -v dnf &> /dev/null; then
            echo -e "${Red}Neither yum nor dnf could be found. Please install one of them.${No}"
            exit 1
        fi
        if command -v dnf &> /dev/null; then
            echo -e "${Green}Using dnf as the package manager.${No}"
            UPDATE_CMD="dnf update -y"
            UPGRADE_CMD="dnf upgrade -y"
            INSTALL_CMD="dnf install -y"
        else
            echo -e "${Green}Using yum as the package manager.${No}"
            UPDATE_CMD="yum update -y"
            UPGRADE_CMD="yum upgrade -y"
            INSTALL_CMD="yum install -y"
        fi
        ;;
    *)
        echo -e "${Red}Unsupported operating system: $OS${No}"
        exit 1
        ;;
esac
# =========================================================

# =================== SYSTEM UPDATE =======================
echo -e "${Green}Updating system packages...${No}"
eval $UPDATE_CMD
eval $UPGRADE_CMD
# =========================================================

# =================== INSTALL DEPENDENCIES =================
echo -e "${Green}Installing basic tools...${No}"
DEPENDENCIES=(curl git vim ufw fail2ban htop)

for package in "${DEPENDENCIES[@]}"; do
    if ! command -v $package &> /dev/null; then
        echo -e "${Green}Installing $package...${No}"
        eval "$INSTALL_CMD $package"
    else
        echo -e "${Green}$package is already installed.${No}"
    fi
done
# =========================================================

# =================== FIREWALL SETUP =======================
echo -e "${Green}Setting up UFW firewall...${No}"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
# =========================================================

# =================== FAIL2BAN SETUP =======================
echo -e "${Green}Configuring Fail2Ban...${No}"
cat <<EOL > /etc/fail2ban/jail.local 
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOL
systemctl restart fail2ban
systemctl enable fail2ban
# =========================================================

# =================== FINAL MESSAGE =======================
echo -e "${Green}Bootstrap completed successfully!${No}"
echo -e "${Green}Please reboot the system to apply all changes.${No}"
# =========================================================