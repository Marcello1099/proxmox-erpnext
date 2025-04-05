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
# Maintainer Note: This script utilizes the tteck template for ERPNext v15 installation on Ubuntu Latest LTS.
#                  It excludes local Nginx setup, intended for use with an external proxy like Nginx Proxy Manager.

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

  msg_info "Installing prerequisites (Python, Git, MariaDB, Redis, Node.js, Yarn, etc.)"
  # Package names are generally the same between recent Debian and Ubuntu
  $STD apt-get install -y git python3 python3-dev python3-pip python3-venv \
    mariadb-server mariadb-client libmysqlclient-dev \
    redis-server \
    curl sudo \
    software-properties-common \
    xvfb libfontconfig1 libxrender1 fontconfig libjpeg-dev \
    build-essential libffi-dev libssl-dev
  msg_ok "Installed base prerequisites"

  msg_info "Configuring MariaDB (setting root password to 'admin' - CHANGE THIS LATER!)"
  local db_root_password="admin" # <- VERY INSECURE, CHANGE THIS POST-INSTALLATION
  # Ensure MariaDB service is running before attempting configuration
  $STD systemctl enable mariadb
  $STD systemctl start mariadb
  # Use mysql_secure_installation concepts non-interactively if possible, or set password directly
  # The debconf method might not always work reliably post-install, especially on upgrades/reinstalls.
  # Attempting direct password set:
  $STD mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$db_root_password'; FLUSH PRIVILEGES;" || msg_warn "Could not set MariaDB root password directly (maybe already set?). Continuing..."
  # Setting debconf selections as a fallback/initial setup method
  $STD debconf-set-selections <<< "mariadb-server mysql-server/root_password password $db_root_password"
  $STD debconf-set-selections <<< "mariadb-server mysql-server/root_password_again password $db_root_password"
  # Apply global settings needed by Frappe
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

  msg_info "Installing Node.js 18.x and Yarn"
  # NodeSource script generally works well on Ubuntu too
  $STD curl -fsSL https://deb.nodesource.com/setup_18.x | $STD bash -
  $STD apt-get update # Update lists after adding repo
  $STD apt-get install -y nodejs
  $STD npm install -g yarn
  msg_ok "Node.js and Yarn installed"

  msg_info "Installing wkhtmltopdf 0.12.6 (patched version)"
  ARCH=$(dpkg --print-architecture)
  # Using the same version number but targeting jammy builds, hoping for compatibility on noble
  # Check https://github.com/wkhtmltopdf/packaging/releases/ for available builds
  WKHTMLTOPDF_VERSION="0.12.6.1-3"
  WKHTMLTOPDF_DISTRO="jammy" # Targeting jammy (Ubuntu 22.04) build for potential compatibility
  WKHTMLTOPDF_PKG=""
  case $ARCH in
    amd64) WKHTMLTOPDF_PKG="wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb" ;;
    arm64) WKHTMLTOPDF_PKG="wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb" ;;
     *) msg_error "Unsupported architecture: $ARCH for wkhtmltopdf download."; exit 1 ;;
  esac

  WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${WKHTMLTOPDF_PKG}"
  msg_info "Attempting to download wkhtmltopdf from ${WKHTMLTOPDF_URL}"
  $STD curl -fsSL -o "/tmp/$WKHTMLTOPDF_PKG" "$WKHTMLTOPDF_URL"
  # Check if download was successful
  if [ ! -f "/tmp/$WKHTMLTOPDF_PKG" ] || [ ! -s "/tmp/$WKHTMLTOPDF_PKG" ]; then
       msg_error "Failed to download wkhtmltopdf package from $WKHTMLTOPDF_URL. Check URL or network. Exiting."
       # As an alternative, you could try installing the repo version:
       # msg_warn "Falling back to repository version of wkhtmltopdf (may not be recommended for ERPNext)"
       # $STD apt-get install -y wkhtmltopdf
       # if [ $? -ne 0 ]; then msg_error "Failed to install wkhtmltopdf from repository."; exit 1; fi
       exit 1
  fi
  # Install the downloaded package, allowing downgrades if necessary, handle dependencies
  $STD apt-get install -y --allow-downgrades /tmp/$WKHTMLTOPDF_PKG
  if [ $? -ne 0 ]; then
    msg_warn "Failed to install downloaded wkhtmltopdf package directly. Attempting to fix broken dependencies..."
    $STD apt --fix-broken install -y
    # Retry installing the package after fixing dependencies
    $STD apt-get install -y --allow-downgrades /tmp/$WKHTMLTOPDF_PKG
    if [ $? -ne 0 ]; then
        msg_error "Failed to install wkhtmltopdf even after attempting to fix dependencies. Check compatibility. Exiting."
        rm -f "/tmp/$WKHTMLTOPDF_PKG"
        exit 1
    fi
  fi
  rm -f "/tmp/$WKHTMLTOPDF_PKG"
  msg_ok "wkhtmltopdf installed"

  msg_info "Creating dedicated 'frappe' user"
  if id "frappe" &>/dev/null; then
    msg_info "'frappe' user already exists."
  else
    $STD useradd -m -s /bin/bash frappe
    # Ensure the sudoers file for frappe is correctly permissioned
    echo "frappe ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/frappe
    $STD chmod 0440 /etc/sudoers.d/frappe
    msg_ok "Frappe user created and granted passwordless sudo"
  fi


  msg_info "Installing Frappe Bench"
  # Run pip install as root first, then handle permissions/symlinks if needed
  $STD pip3 install frappe-bench
  # Check if bench is in PATH, if not, try common locations
  if ! command -v bench &>/dev/null; then
    msg_info "Bench command not found in default PATH, attempting to locate..."
    # Search common pip install locations for the current user (root) and the frappe user
    BENCH_PATH=$(find /usr/local/bin /root/.local/bin /home/frappe/.local/bin -name bench 2>/dev/null | head -n 1)
    if [ -n "$BENCH_PATH" ] && [ -x "$BENCH_PATH" ]; then
        # Ensure /usr/local/bin is in the system PATH and create symlink
        if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
            export PATH="/usr/local/bin:$PATH" # Add to current session PATH
            # Consider adding to system-wide PATH definitions if needed persistently across reboots
        fi
        # Remove existing link if it points elsewhere or is broken
        [ -L /usr/local/bin/bench ] && rm -f /usr/local/bin/bench
        ln -s "$BENCH_PATH" /usr/local/bin/bench || msg_warn "Could not create symlink for bench in /usr/local/bin/"
        msg_ok "Bench found at $BENCH_PATH and linked/available."
    else
        msg_error "Failed to install or locate Frappe Bench CLI after installation. Exiting."
        exit 1
    fi
  fi
   # Verify bench command again after potential linking
  if ! command -v bench &>/dev/null; then
       msg_error "Bench command still not found after installation and linking attempts. Check Python environment and PATH. Exiting."
       exit 1
  fi
  msg_ok "Frappe Bench installed and accessible"


  msg_info "Initializing Frappe Bench directory (/home/frappe/frappe-bench)"
  # Ensure the target directory exists and frappe user owns it
  $STD mkdir -p /home/frappe
  $STD chown frappe:frappe /home/frappe
  # Execute bench init as the frappe user
  $STD sudo -H -u frappe bash -c "cd /home/frappe && bench init --skip-redis-config-generation --frappe-path https://github.com/frappe/frappe --frappe-branch version-15 frappe-bench"
  if [ $? -ne 0 ]; then msg_error "Frappe bench initialization failed. Check logs. Exiting."; exit 1; fi
  msg_ok "Frappe Bench initialized"

  msg_info "Creating default site 'site1.local'"
  # Execute bench new-site as the frappe user within the bench directory
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench new-site site1.local --db-root-username root --db-root-password $db_root_password --admin-password admin --mariadb-host 127.0.0.1 --install-app erpnext --set-default"
  if [ $? -ne 0 ]; then msg_error "Failed to create site 'site1.local' or install ERPNext app. Check logs. Exiting."; exit 1; fi
  msg_ok "Default site 'site1.local' created, ERPNext installed, and set as default"

  msg_info "Setting up Production Environment (Systemd services only)"
  # Execute bench setup production as the frappe user
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench setup production frappe --yes"
  if [ $? -ne 0 ]; then msg_error "Bench setup production failed. Check logs. Exiting."; exit 1; fi
  # Ensure generated systemd files are correctly placed and readable by systemd
  # Note: bench setup production might not generate supervisor/nginx files if not detected/intended
  # $STD cp /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf || msg_warn "Could not copy supervisor config (Supervisor likely not used/installed as intended)"
  # $STD cp /home/frappe/frappe-bench/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf || msg_warn "Could not copy nginx config (Nginx likely not used/installed as intended)"
  # Setup systemd (This is the primary goal for this script version)
  $STD sudo -H -u frappe bash -c "cd /home/frappe/frappe-bench && bench setup systemd --user frappe" # Specify user for systemd units
  # Link the generated unit files to the systemd directory
  $STD ln -sf /home/frappe/frappe-bench/config/systemd/frappe-*.service /etc/systemd/system/
  $STD ln -sf /home/frappe/frappe-bench/config/systemd/frappe-*.target /etc/systemd/system/
  $STD systemctl daemon-reload
  msg_ok "Production services (systemd) configured"

  msg_info "Enabling and starting services (Redis, Frappe systemd units)"
  $STD systemctl enable redis-server
  $STD systemctl start redis-server
  # Enable and start the Frappe target which manages the individual services
  $STD systemctl enable frappe-bench.target
  $STD systemctl start frappe-bench.target
  # Optional: Enable/start individual services if target doesn't work as expected
  # FRAРPE_SERVICES=$(ls /home/frappe/frappe-bench/config/systemd/frappe-*.service | xargs -n 1 basename | sed 's/\.service//')
  # for service in $FRAРPE_SERVICES; do
  #   msg_info "Enabling systemd service: ${service}.service"
  #   $STD systemctl enable ${service}.service
  #   msg_info "Starting systemd service: ${service}.service"
  #   $STD systemctl start ${service}.service
  # done

  # Verify status briefly
  sleep 5 # Give services a moment to start
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
echo -e "${INFO}${YW}Configure your external Nginx Proxy (e.g., Nginx Proxy Manager) to forward requests to:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW}(ERPNext's web service (gunicorn/frappe-web) listens on port 8000 by default)${CL}"
echo -e "---"
echo -e "${INFO}${YW}Default Site Name:${CL} ${BGN}site1.local${CL}"
echo -e "${INFO}${YW}Default ERPNext Admin Username:${CL} ${BGN}Administrator${CL}"
echo -e "${INFO}${YW}Default ERPNext Admin Password:${CL} ${BGN}admin${CL} ${CRED}(CHANGE IMMEDIATELY! Access http://${IP}:8000)${CL}"
echo -e "${INFO}${YW}MariaDB root password set to:${CL} ${BGN}admin${CL} ${CRED}(CHANGE THIS SECURELY! e.g., using 'mysql_secure_installation' or direct SQL command)${CL}"
echo -e "${INFO}${GN}It may take a minute or two for all services to fully start and the site to be accessible.${CL}"
