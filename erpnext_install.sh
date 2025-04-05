#!/usr/bin/env bash

# Source the build functions from tteck's repository
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Copyright (c) 2021-2025 tteck (Script Template)
# Original Template Author: tteck (tteckster)
# License: MIT
# --- ERPNext Installation Script ---
# Author: Marcello1099
# Source Repo: https://github.com/Marcello1099/proxmox-erpnext
# ERPNext Source: https://frappeframework.com/docs/user/en/installation / https://github.com/frappe/erpnext
# Maintainer Note: This script utilizes the tteck template for ERPNext v15 installation on Ubuntu Latest LTS,
#                  relying solely on APT repositories for Node.js and wkhtmltopdf.
#                  It excludes local Nginx setup, intended for use with an external proxy like Nginx Proxy Manager.
# WARNING: Using apt's default wkhtmltopdf may cause PDF generation issues in ERPNext.
# WARNING: Assumes Ubuntu's default Node.js version is compatible (requires v18.x for ERPNext v15).

APP="ERPNext"
var_tags="erp"
var_cpu="4"
var_ram="4096"
var_disk="20"
# --- OS Configuration: Set to Ubuntu Latest LTS ---
var_os="ubuntu"
var_version="24.04" # Targeting Ubuntu 24.04 LTS (Noble Numbat)
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

  msg_info "Starting ERPNext Installation on Ubuntu ${var_version} (without local Nginx)..."

  msg_info "Updating package lists and upgrading system"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "System updated and upgraded"

  msg_info "Installing prerequisites (Python, Git, MariaDB, Redis, Node.js, Yarn, wkhtmltopdf, etc. via APT)"
  # Installing nodejs, npm, and wkhtmltopdf directly from Ubuntu repositories.
  $STD apt-get install -y git python3 python3-dev python3-pip python3-venv \
    mariadb-server mariadb-client libmysqlclient-dev \
    redis-server \
    curl sudo \
    software-properties-common \
    xvfb libfontconfig1 libxrender1 fontconfig libjpeg-dev \
    build-essential libffi-dev libssl-dev \
    nodejs npm \
    wkhtmltopdf # WARNING: Standard repo version may cause PDF issues in ERPNext!
  msg_ok "Installed base prerequisites"

  # Verify Node.js version (Optional but recommended check)
  NODE_MAJOR_VERSION=$(node -v | sed 's/v\([0-9]*\).*/\1/')
  if [ "$NODE_MAJOR_VERSION" != "18" ]; then
      msg_warn "Installed Node.js version is $(node -v). ERPNext v15 typically requires v18.x. Installation may fail or have runtime issues."
  else
      msg_ok "Node.js version $(node -v) installed."
  fi


  msg_info "Configuring MariaDB (setting root password to 'admin' - CHANGE THIS LATER!)"
  local db_root_password="admin" # <- VERY INSECURE, CHANGE THIS POST-INSTALLATION
  $STD systemctl enable mariadb
  $STD systemctl start mariadb
  $STD mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$db_root_password'; FLUSH PRIVILEGES;" || msg_warn "Could not set MariaDB root password directly (maybe already set?). Continuing..."
  $STD debconf-set-selections <<< "mariadb-server mysql-server/root_password password $db_root_password"
  $STD debconf-set-selections <<< "mariadb-server mysql-server/root_password_again password $db_root_password"
  $STD mysql -u root -p"$db_root_password" -e "SET GLOBAL character_set_server = 'utf8mb4';" || msg_warn "Failed to set global character_set_server. Check MariaDB status and root password."
  $STD mysql -u root -p"$db_root_password" -e "SET GLOBAL collation_server = 'utf8mb4_unicode_ci';" || msg_warn "Failed to set global collation_server."
  $STD mysql -u root -p"$db_root_password" -e "FLUSH PRIVILEGES;"

  cat <<EOF >/etc/mysql/mariadb.conf.d/50-frappe.cnf
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
[client]
default-character-set=utf8mb4
EOF
  $STD systemctl restart mariadb
  msg_ok "MariaDB configured (Root password set to '$db_root_password' - CHANGE IT!)"

  msg_info "Installing Yarn using npm"
  # Install Yarn globally using the npm installed via apt
  $STD npm install -g yarn
  msg_ok "Yarn installed globally via npm"

  # wkhtmltopdf installation is now handled by the main apt install command above.
  # The section downloading the specific .deb file has been removed.
  msg_info "Using wkhtmltopdf installed from Ubuntu APT repository."
  msg_warn "Standard wkhtmltopdf version may cause PDF generation issues (e.g., missing headers/footers) in ERPNext."


  msg_info "Creating dedicated 'frappe' user"
  if id "frappe" &>/dev/null; then
    msg_info "'frappe' user already exists."
  else
    $STD useradd -m -s /bin/bash frappe
    echo "frappe ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/frappe
    $STD chmod 0440 /etc/sudoers.d/frappe
    msg_ok "Frappe user created and granted passwordless sudo"
  fi


  msg_info "Installing Frappe Bench"
  $STD pip3 install frappe-bench
  if ! command -v bench &>/dev/null; then
    msg_info "Bench command not found in default PATH, attempting to locate..."
    BENCH_PATH=$(find /usr/local/bin /root/.local/bin /home/frappe/.local/bin -name bench 2>/dev/null | head -n 1)
    if [ -n "$BENCH_PATH" ] && [ -x "$BENCH_PATH" ]; then
        if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then export PATH="/usr/local/bin:$PATH"; fi
        [ -L /usr/local/bin/bench ] && rm -f /usr/local/bin/bench
        ln -s "$BENCH_PATH" /usr/local/bin/bench || msg_warn "Could not create symlink for bench in /usr/local/bin/"
        msg_ok "Bench found at $BENCH_PATH and linked/available."
    else
        msg_error "Failed to install or locate Frappe Bench CLI after installation. Exiting."
        exit 1
    fi
  fi
  if ! command -v bench &>/dev/null; then
       msg_error "Bench command still not found after installation and linking attempts. Check Python environment and PATH. Exiting."
       exit 1
  fi
  msg_ok "Frappe Bench installed and accessible"


  msg_info "Initializing Frappe Bench directory (/home/frappe/frappe-bench)"
  $STD mkdir -p /home/frappe
  $STD chown frappe:frappe /home/frappe
  $STD sudo -H -u frappe bash -c "cd /home/frappe && bench init --skip-redis-config-generation --frappe-path https://github.com/frappe/frappe --frappe-branch version-15 frappe-bench"
  if [ $? -ne 0 ]; then msg_error "Frappe bench initialization failed. Check logs (potential Node.js version issue?). Exiting."; exit 1; fi
  msg_ok "Frappe Bench initialized"

  msg_info "Creating default site 'site1.local'"
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench new-site site1.local --db-root-username root --db-root-password $db_root_password --admin-password admin --mariadb-host 127.0.0.1 --install-app erpnext --set-default"
  if [ $? -ne 0 ]; then msg_error "Failed to create site 'site1.local' or install ERPNext app. Check logs. Exiting."; exit 1; fi
  msg_ok "Default site 'site1.local' created, ERPNext installed, and set as default"

  msg_info "Setting up Production Environment (Systemd services only)"
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench setup production frappe --yes"
  if [ $? -ne 0 ]; then msg_error "Bench setup production failed. Check logs. Exiting."; exit 1; fi
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench setup systemd --user frappe"
  $STD ln -sf /home/frappe/frappe-bench/config/systemd/frappe-*.service /etc/systemd/system/
  $STD ln -sf /home/frappe/frappe-bench/config/systemd/frappe-*.target /etc/systemd/system/
  $STD systemctl daemon-reload
  msg_ok "Production services (systemd) configured"

  msg_info "Enabling and starting services (Redis, Frappe systemd units)"
  $STD systemctl enable redis-server
  $STD systemctl start redis-server
  $STD systemctl enable frappe-bench.target
  $STD systemctl start frappe-bench.target
  sleep 5
  $STD systemctl status frappe-bench.target --no-pager || msg_warn "Frappe-bench target might not be active. Check 'systemctl status frappe-*.service'."
  $STD systemctl status frappe-web.service --no-pager || msg_warn "Frappe-web service might not be running correctly."
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
echo -e "${CREATING}${GN}${APP} installation on Ubuntu ${var_version} has been successfully completed!${CL}"
echo -e "${INFO}${YW}Nginx was NOT installed in this container.${CL}"
echo -e "${INFO}${YW}Node.js and wkhtmltopdf were installed from standard Ubuntu repositories.${CL}"
echo -e "${INFO}${CRED}Be aware that the standard wkhtmltopdf may cause PDF generation issues.${CL}"
echo -e "${INFO}${CRED}Ensure the installed Node.js version ($(node -v)) is compatible with ERPNext v15.${CL}"
echo -e "${INFO}${YW}Configure your external Nginx Proxy (e.g., Nginx Proxy Manager) to forward requests to:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW}(ERPNext's web service (gunicorn/frappe-web) listens on port 8000 by default)${CL}"
echo -e "---"
echo -e "${INFO}${YW}Default Site Name:${CL} ${BGN}site1.local${CL}"
echo -e "${INFO}${YW}Default ERPNext Admin Username:${CL} ${BGN}Administrator${CL}"
echo -e "${INFO}${YW}Default ERPNext Admin Password:${CL} ${BGN}admin${CL} ${CRED}(CHANGE IMMEDIATELY! Access http://${IP}:8000)${CL}"
echo -e "${INFO}${YW}MariaDB root password set to:${CL} ${BGN}admin${CL} ${CRED}(CHANGE THIS SECURELY! e.g., using 'mysql_secure_installation' or direct SQL command)${CL}"
echo -e "${INFO}${GN}It may take a minute or two for all services to fully start and the site to be accessible.${CL}"
