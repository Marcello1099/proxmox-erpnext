#!/usr/bin/env bash

# Source the build functions from tteck's repository
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Copyright (c) 2021-2025 tteck (Script Template)
# Original Template Author: tteck (tteckster)
# License: MIT
# --- Modified for ERPNext Installation (No local Nginx) ---
# Author: Marcello1099
# Source Repo: https://github.com/Marcello1099/proxmox-erpnext
# ERPNext Source: https://frappeframework.com/docs/user/en/installation / https://github.com/frappe/erpnext
# Maintainer Note: This script adapts the tteck template for ERPNext v15 installation on Debian 12.
#                  It excludes local Nginx setup, intended for use with an external proxy like Nginx Proxy Manager.

APP="ERPNext (No Nginx)"
var_tags="erp"
var_cpu="4"
var_ram="4096"
var_disk="20"
var_os="debian"
var_version="12"
var_unprivileged="1"

header_info "$APP"
variables
color
catch_errors

function install_script() {
  header_info "$APP Installation"
  check_container_storage
  check_container_resources

  if command -v bench &>/dev/null && id "frappe" &>/dev/null; then
    msg_info "ERPNext/Frappe Bench appears to be already installed."
    msg_ok "Skipping installation."
    exit 0
  fi

  msg_info "Starting ERPNext Installation (without local Nginx)..."

  msg_info "Updating package lists and upgrading system"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "System updated and upgraded"

  msg_info "Installing prerequisites (Python, Git, MariaDB, Redis, Node.js, Yarn, etc.)"
  $STD apt-get install -y git python3 python3-dev python3-pip python3-venv \
    mariadb-server mariadb-client libmysqlclient-dev \
    redis-server \
    curl sudo \
    software-properties-common \
    xvfb libfontconfig1 libxrender1 fontconfig libjpeg-dev \
    build-essential libffi-dev libssl-dev
  msg_ok "Installed base prerequisites"

  msg_info "Configuring MariaDB (setting root password to 'admin' - CHANGE THIS LATER!)"
  local db_root_password="admin"
  $STD debconf-set-selections <<< "mariadb-server mysql-server/root_password password $db_root_password"
  $STD debconf-set-selections <<< "mariadb-server mysql-server/root_password_again password $db_root_password"
  $STD systemctl enable mariadb
  $STD systemctl start mariadb
  $STD mysql -u root -p"$db_root_password" -e "SET GLOBAL character_set_server = 'utf8mb4';"
  $STD mysql -u root -p"$db_root_password" -e "SET GLOBAL collation_server = 'utf8mb4_unicode_ci';"
  $STD mysql -u root -p"$db_root_password" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$db_root_password';"
  $STD mysql -u root -p"$db_root_password" -e "FLUSH PRIVILEGES;"

  cat <<EOF >/etc/mysql/mariadb.conf.d/50-frappe.cnf
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
[client]
default-character-set=utf8mb4
EOF
  $STD systemctl restart mariadb
  msg_ok "MariaDB configured"

  msg_info "Installing Node.js 18.x and Yarn"
  $STD curl -fsSL https://deb.nodesource.com/setup_18.x | $STD bash -
  $STD apt-get install -y nodejs
  $STD npm install -g yarn
  msg_ok "Node.js and Yarn installed"

  msg_info "Installing wkhtmltopdf 0.12.6"
  ARCH=$(dpkg --print-architecture)
  WKHTMLTOPDF_VERSION="0.12.6.1-3"
  WKHTMLTOPDF_PKG=""
  case $ARCH in
    amd64) WKHTMLTOPDF_PKG="wkhtmltox_${WKHTMLTOPDF_VERSION}.bullseye_amd64.deb" ;;
    arm64) WKHTMLTOPDF_PKG="wkhtmltox_${WKHTMLTOPDF_VERSION}.bullseye_arm64.deb" ;;
    *) msg_error "Unsupported architecture: $ARCH for wkhtmltopdf download."; exit 1 ;;
  esac

  $STD curl -fsSL -o "/tmp/$WKHTMLTOPDF_PKG" "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${WKHTMLTOPDF_PKG}"
  $STD apt-get install -y --allow-downgrades /tmp/$WKHTMLTOPDF_PKG
  rm -f /tmp/$WKHTMLTOPDF_PKG
  msg_ok "wkhtmltopdf installed"

  msg_info "Creating dedicated 'frappe' user"
  $STD useradd -m -s /bin/bash frappe
  $STD echo "frappe ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/frappe
  msg_ok "Frappe user created"

  msg_info "Installing Frappe Bench"
  $STD pip3 install frappe-bench
  if ! command -v bench &>/dev/null; then
    msg_info "Bench command not found in default PATH, attempting to locate..."
    BENCH_PATH=$(find /usr/local/bin /home/frappe/.local/bin -name bench 2>/dev/null | head -n 1)
    if [ -n "$BENCH_PATH" ] && [ -x "$BENCH_PATH" ]; then
        ln -s "$BENCH_PATH" /usr/local/bin/bench || true
        msg_ok "Bench found and linked."
    else
        msg_error "Failed to install or locate Frappe Bench CLI. Exiting."
        exit 1
    fi
  fi
  msg_ok "Frappe Bench installed"

  msg_info "Initializing Frappe Bench directory (~/frappe-bench)"
  $STD sudo -H -u frappe bash -c "cd /home/frappe && bench init --skip-redis-config-generation --frappe-path https://github.com/frappe/frappe --frappe-branch version-15 frappe-bench"
  msg_ok "Frappe Bench initialized"

  msg_info "Creating default site 'site1.local'"
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench new-site site1.local --db-root-username root --db-root-password $db_root_password --admin-password admin --mariadb-host 127.0.0.1 --install-app erpnext"
  msg_ok "Default site 'site1.local' created and ERPNext installed"

  msg_info "Setting up Production Environment (Systemd services only)"
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench setup production frappe --yes"
  msg_ok "Production services (systemd) configured"

  msg_info "Enabling and starting services (Redis, Frappe)"
  $STD systemctl enable redis-server
  $STD systemctl start redis-server
  $STD systemctl enable frappe-web
  $STD systemctl enable frappe-socketio
  $STD systemctl enable frappe-schedule
  $STD systemctl enable frappe-worker-default
  $STD systemctl enable frappe-worker-short
  $STD systemctl enable frappe-worker-long

  $STD systemctl start frappe-web
  $STD systemctl start frappe-socketio
  $STD systemctl start frappe-schedule
  $STD systemctl start frappe-worker-default
  $STD systemctl start frappe-worker-short
  $STD systemctl start frappe-worker-long
  msg_ok "Systemd services enabled and started"

  msg_info "Cleaning up installation files"
  $STD apt-get autoremove -y
  $STD apt-get clean
  msg_ok "Cleanup complete"

  msg_ok "ERPNext Installation Completed Successfully!"
}

# --- Main Execution ---
start
build_container
description
install_script

# --- Completion Message ---
msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} installation has been successfully completed!${CL}"
echo -e "${INFO}${YW}Nginx was NOT installed in this container.${CL}"
echo -e "${INFO}${YW}Configure your Nginx Proxy Manager to forward requests to:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW}(ERPNext's web service (gunicorn) listens on port 8000 by default)${CL}"
echo -e "---"
echo -e "${INFO}${YW}Default Site Name:${CL} ${BGN}site1.local${CL}"
echo -e "${INFO}${YW}Default ERPNext Admin Username:${CL} ${BGN}Administrator${CL}"
echo -e "${INFO}${YW}Default ERPNext Admin Password:${CL} ${BGN}admin${CL} ${CRED}(CHANGE IMMEDIATELY!)${CL}"
echo -e "${INFO}${YW}MariaDB root password set to:${CL} ${BGN}admin${CL} ${CRED}(CHANGE THIS SECURELY!)${CL}"
echo -e "${INFO}${GN}It may take a minute or two for all services to fully start.${CL}"
