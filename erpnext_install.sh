#!/usr/bin/env bash

# Copyright (c) 2021-2025 tteck # Original helper script structure
# Author: tteck (tteckster)     # Original helper script author
# Author: Marcello1099 (Adapted for ERPNext) # Author of this ERPNext adaptation
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE # License for helper script structure
# Script Source: https://github.com/Marcello1099 # Link to script author/source
# Application Source: https://frappeframework.com/ / https://erpnext.com/ # Source of the installed application
# Version: ERPNext v15 Branch

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Base Dependencies"
$STD apt-get update
$STD apt-get install -y \
    git \
    curl \
    wget \
    sudo \
    build-essential \
    python3-dev \
    python3-setuptools \
    python3-venv \
    python3-pip \
    libffi-dev \
    libssl-dev \
    htop \
    cron \
    fontconfig \
    libxrender1 \
    xfonts-75dpi \
    xfonts-base
msg_ok "Installed Base Dependencies"

# Check and Install Specific Python Version (Ensure >= 3.10, prefer 3.11 for v15)
msg_info "Checking Python Version"
PYTHON_VERSION=$(python3 -V 2>&1 | grep -Po '(?<=Python )(\d+\.\d+)')
PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)

if [[ "$PYTHON_MAJOR" -lt 3 ]] || [[ "$PYTHON_MINOR" -lt 10 ]]; then
    msg_error "Python 3.10 or higher is required. This script requires Debian 12+ or Ubuntu 22.04+."
    echo -e "${ERROR} Please use a compatible LXC template."
    exit 1
else
    msg_ok "Found compatible Python Version ($PYTHON_VERSION)"
    # Install venv specifically for the detected version if not already covered
    $STD apt-get install -y python${PYTHON_VERSION}-venv
fi

msg_info "Installing MariaDB Database Server"
$STD apt-get install -y mariadb-server mariadb-client
msg_ok "Installed MariaDB"

msg_info "Configuring MariaDB"
# Set charset and collation
cat <<EOF >/etc/mysql/mariadb.conf.d/99-frappe.cnf
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
systemctl restart mariadb
# Secure MariaDB and set root password
DB_ROOT_PASSWORD=$(openssl rand -base64 12)
$STD mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$DB_ROOT_PASSWORD');FLUSH PRIVILEGES;"
# Remove anonymous users
$STD mysql -e "DELETE FROM mysql.user WHERE User='';"
# Remove remote root login
$STD mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
# Drop test database
$STD mysql -e "DROP DATABASE IF EXISTS test;"
$STD mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
# Reload privileges
$STD mysql -e "FLUSH PRIVILEGES;"
# Write password to .my.cnf for easier access by root (optional, but helpful for scripts)
cat <<EOF >/root/.my.cnf
[client]
user=root
password=$DB_ROOT_PASSWORD
EOF
chmod 600 /root/.my.cnf
msg_ok "Configured MariaDB (Root password generated and saved to /root/.my.cnf)"
echo -e "${INFO} MariaDB root password set to: ${BL}${DB_ROOT_PASSWORD}${CL}"
echo -e "${INFO} It's also saved in /root/.my.cnf for script access."

msg_info "Installing Redis Server"
$STD apt-get install -y redis-server
msg_ok "Installed Redis Server"

msg_info "Installing Node.js (v18.x) and Yarn"
# Using Nodesource repository
curl -fsSL https://deb.nodesource.com/setup_18.x | $STD bash -
$STD apt-get install -y nodejs
$STD npm install -g yarn
msg_ok "Installed Node.js and Yarn"

msg_info "Installing wkhtmltopdf (Patched Version)"
# Required for PDF generation
WKHTMLTOPDF_VER="0.12.6.1-3"
# Adjust architecture detection if needed, assumes amd64
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "amd64" ]]; then
    WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VER}/wkhtmltox_${WKHTMLTOPDF_VER}.bullseye_${ARCH}.deb" # Use bullseye package, works on bookworm/jammy
elif [[ "$ARCH" == "arm64" ]]; then
    # Note: Arm64 build might not be available directly from the same repo easily.
    # Check official wkhtmltopdf releases or alternative sources if needed.
    # For now, try the bullseye arm64 package if available, otherwise error out.
    WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VER}/wkhtmltox_${WKHTMLTOPDF_VER}.bullseye_${ARCH}.deb"
else
    msg_error "Unsupported architecture ($ARCH) for automatic wkhtmltopdf download."
    echo -e "${ERROR} Please install wkhtmltopdf manually for your architecture."
    exit 1
fi

wget -q $WKHTMLTOPDF_URL -O /tmp/wkhtmltox.deb
$STD apt-get install -y /tmp/wkhtmltox.deb
rm /tmp/wkhtmltox.deb
msg_ok "Installed wkhtmltopdf"

msg_info "Installing Frappe Bench"
$STD pip install frappe-bench
# Ensure bench command is in PATH for root (may not be needed, but belt-and-suspenders)
export PATH=$PATH:/root/.local/bin
msg_ok "Installed Frappe Bench"

msg_info "Creating Frappe User"
adduser --disabled-password --gecos "" frappe
usermod -aG sudo frappe
echo "frappe ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers # Allow frappe user sudo without password for bench setup
msg_ok "Created Frappe User 'frappe' and granted sudo privileges"

# --- User Interaction ---
while true; do
    read -p "Enter the Site Name (e.g., erp.mydomain.com or erp.local): " SITE_NAME
    if [[ -n "$SITE_NAME" ]]; then
        break
    else
        echo "Site Name cannot be empty."
    fi
done

while true; do
    read -s -p "Enter ERPNext Administrator Password: " ADMIN_PASSWORD
    echo
    read -s -p "Confirm ERPNext Administrator Password: " ADMIN_PASSWORD_CONFIRM
    echo
    if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]] && [[ -n "$ADMIN_PASSWORD" ]]; then
        break
    else
        echo "Passwords do not match or are empty. Please try again."
    fi
done
# --- End User Interaction ---


msg_info "Initializing Frappe Bench (v15)"
cd /home/frappe
sudo -H -u frappe bash -c "bench init --frappe-branch version-15 frappe-bench" || { msg_error "Frappe Bench initialization failed!"; exit 1; }
msg_ok "Initialized Frappe Bench"

msg_info "Creating New Site ($SITE_NAME)"
cd /home/frappe/frappe-bench
# Run new-site command, piping passwords
sudo -H -u frappe bash -c "echo -e '${DB_ROOT_PASSWORD}\n${ADMIN_PASSWORD}' | bench new-site ${SITE_NAME} --db-root-username root --db-root-password -" || { msg_error "Failed to create new site!"; exit 1; }
msg_ok "Created New Site"

msg_info "Downloading ERPNext App (v15)"
sudo -H -u frappe bash -c "bench get-app erpnext --branch version-15" || { msg_error "Failed to download ERPNext app!"; exit 1; }
msg_ok "Downloaded ERPNext App"

msg_info "Installing ERPNext App on Site"
sudo -H -u frappe bash -c "bench --site ${SITE_NAME} install-app erpnext" || { msg_error "Failed to install ERPNext app!"; exit 1; }
msg_ok "Installed ERPNext App"

msg_info "Setting up Nginx and Supervisor for Production"
# Bench setup production requires root privileges
cd /home/frappe/frappe-bench
sudo bench setup production frappe --yes || { msg_error "Bench production setup failed!"; exit 1; }
msg_ok "Production Setup Complete (Nginx, Supervisor)"

msg_info "Starting Services"
# Bench setup should have enabled/started supervisor, which manages frappe processes
$STD systemctl enable --now supervisor
$STD systemctl enable --now nginx
# Double check status
sleep 5 # Give services time to potentially fail
$STD systemctl status supervisor --no-pager
$STD systemctl status nginx --no-pager
msg_ok "Enabled and Started Supervisor and Nginx Services"

# --- Optional: Firewall Setup ---
# read -r -p "Configure Firewall (UFW) to allow HTTP/HTTPS? <y/N> " prompt_fw
# if [[ ${prompt_fw,,} =~ ^(y|yes)$ ]]; then
#   msg_info "Configuring Firewall (UFW)"
#   $STD apt-get install -y ufw
#   $STD ufw allow ssh
#   $STD ufw allow http
#   $STD ufw allow https
#   $STD ufw --force enable
#   msg_ok "Firewall Configured"
# fi
# --- End Optional Firewall ---

motd_ssh
customize

msg_info "Cleaning up"
# Revert sudoers change for frappe user for security
sed -i '/frappe ALL=(ALL) NOPASSWD: ALL/d' /etc/sudoers
$STD apt-get -y autoremove
$STD apt-get -y autoclean
rm -f /root/.my.cnf # Remove file containing root DB password
msg_ok "Cleaned up"

msg_ok "ERPNext Installation Complete!"
echo -e "${INFO} Access ERPNext at: ${BL}http://${IP_ADDRESS}${CL} (or http://${SITE_NAME} if DNS is configured)"
echo -e "${INFO} Login with username: ${BL}Administrator${CL}"
echo -e "${INFO} Password: ${BL}The password you set during installation${CL}"
echo -e "${INFO} MariaDB root password was: ${BL}${DB_ROOT_PASSWORD}${CL} (It has been removed from /root/.my.cnf)"
echo -e "${INFO} To manage services, use 'sudo supervisorctl status' and 'sudo systemctl status nginx'"
echo -e "${INFO} Frappe bench directory is: /home/frappe/frappe-bench"
echo -e "${INFO} To run bench commands: cd /home/frappe/frappe-bench && sudo -u frappe bench [command]"
echo -e "${WARN} For HTTPS/SSL, configure DNS for '${SITE_NAME}' and run: "
echo -e "${WARN} cd /home/frappe/frappe-bench && sudo bench setup lets-encrypt ${SITE_NAME}"

