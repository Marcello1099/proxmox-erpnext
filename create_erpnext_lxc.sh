#!/usr/bin/env bash

# Proxmox VE ERPNext LXC Creation Script
# Author: Marcello1099 (Adapted with LXC creation wrapper by AI)
# License: MIT
# Repository: https://github.com/Marcello1099/proxmox-erpnext
# This script runs ON THE PROXMOX HOST.

# --- Helper Functions ---
ech_info() { echo -e "\e[32m[INFO] \e[0m$1"; }
ech_warn() { echo -e "\e[33m[WARN] \e[0m$1"; }
ech_error() { echo -e "\e[31m[ERROR] \e[0m$1"; }
ask() { read -p "$1 "; echo "${REPLY}"; }
ask_yes_no() { read -p "$1 (y/N) "; [[ "${REPLY,,}" =~ ^(y|yes)$ ]]; }
# ---

# --- Configuration Variables ---
DEFAULT_ADVANCED="n"
DEFAULT_CTID="auto"
DEFAULT_HOSTNAME="erpnext"
DEFAULT_DISK="30" # GB
DEFAULT_CORES="2"
DEFAULT_MEMORY="4096" # MB
DEFAULT_SWAP="4096" # MB
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE="" # Will prompt user
DEFAULT_TEMPLATE_FILENAME="debian-12-standard_12.5-1_amd64.tar.zst" # Adjust if needed
DEFAULT_USE_DHCP="y"
DEFAULT_IP=""
DEFAULT_GW=""
DEFAULT_INSTALLER_URL="https://raw.githubusercontent.com/Marcello1099/proxmox-erpnext/main/erpnext_install.sh"

# Trap errors
set -e
trap 'ech_error "An error occurred. Exiting."; exit 1' ERR

# --- Get Storage Pools ---
mapfile -t STORAGE_POOLS < <(pvesm status --content images,rootdir -o json | jq -r '.[].storage')
if [[ ${#STORAGE_POOLS[@]} -eq 0 ]]; then
    ech_error "No suitable storage pools found for LXC containers (content type 'images' or 'rootdir')."
    exit 1
fi

# --- Mode Selection ---
ech_info "Select Installation Mode:"
ech_info "1. Default (Recommended): Uses standard settings."
ech_info "2. Advanced: Customize container settings."
mode=$(ask "Enter choice (1): " )
mode=${mode:-1}

if [[ "$mode" == "2" ]]; then
    ech_info "--- Advanced Configuration ---"
    ADVANCED_MODE="y"
    CTID=$(ask "Enter Container ID [${DEFAULT_CTID}]: " )
    CTID=${CTID:-$DEFAULT_CTID}
    HOSTNAME=$(ask "Enter Hostname [${DEFAULT_HOSTNAME}]: " )
    HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
    DISK=$(ask "Enter Disk Size (GB) [${DEFAULT_DISK}]: " )
    DISK=${DISK:-$DEFAULT_DISK}
    CORES=$(ask "Enter CPU Cores [${DEFAULT_CORES}]: " )
    CORES=${CORES:-$DEFAULT_CORES}
    MEMORY=$(ask "Enter Memory (MB) [${DEFAULT_MEMORY}]: " )
    MEMORY=${MEMORY:-$DEFAULT_MEMORY}
    SWAP=$(ask "Enter Swap (MB) [${DEFAULT_SWAP}]: " )
    SWAP=${SWAP:-$DEFAULT_SWAP}

    ech_info "Available Storage Pools:"
    select storage_choice in "${STORAGE_POOLS[@]}"; do
        if [[ -n "$storage_choice" ]]; then
            STORAGE=$storage_choice
            break
        else
            ech_warn "Invalid selection."
        fi
    done

    BRIDGE=$(ask "Enter Network Bridge [${DEFAULT_BRIDGE}]: " )
    BRIDGE=${BRIDGE:-$DEFAULT_BRIDGE}
    TEMPLATE_FILENAME=$(ask "Enter Template Filename [${DEFAULT_TEMPLATE_FILENAME}]: " )
    TEMPLATE_FILENAME=${TEMPLATE_FILENAME:-$DEFAULT_TEMPLATE_FILENAME}

    if ! ask_yes_no "Use DHCP for networking? [Y/n]: "; then
        USE_DHCP="n"
        while [[ -z "$IP" ]]; do IP=$(ask "Enter Static IP Address (e.g., 192.168.1.100/24): " ); done
        while [[ -z "$GW" ]]; do GW=$(ask "Enter Gateway Address (e.g., 192.168.1.1): " ); done
    else
        USE_DHCP="y"
    fi
    ech_info "-----------------------------"

else
    ech_info "--- Default Configuration ---"
    ADVANCED_MODE="n"
    CTID=$DEFAULT_CTID
    HOSTNAME=$DEFAULT_HOSTNAME
    DISK=$DEFAULT_DISK
    CORES=$DEFAULT_CORES
    MEMORY=$DEFAULT_MEMORY
    SWAP=$DEFAULT_SWAP
    BRIDGE=$DEFAULT_BRIDGE
    TEMPLATE_FILENAME=$DEFAULT_TEMPLATE_FILENAME
    USE_DHCP="y"

    ech_info "Available Storage Pools:"
    PS3="Select Storage Pool: "
    select storage_choice in "${STORAGE_POOLS[@]}"; do
        if [[ -n "$storage_choice" ]]; then
            STORAGE=$storage_choice
            break
        else
            ech_warn "Invalid selection."
        fi
    done
    ech_info "Using default settings. Storage selected: $STORAGE"
    ech_info "-----------------------------"
fi

# --- Resolve CTID ---
if [[ "$CTID" == "auto" ]]; then
    CTID=$(pvesh get /cluster/nextid)
    ech_info "Assigning next available Container ID: $CTID"
fi

# --- Check if CTID exists ---
if pct status $CTID &>/dev/null; then
    ech_error "Container ID $CTID already exists. Please choose another ID or delete the existing container."
    exit 1
fi

# --- Template Handling ---
TEMPLATE_PATH_ON_STORAGE=$(pveam list "$STORAGE" --output-format json | jq -r ".[] | select(.volid==\"$STORAGE:vztmpl/$TEMPLATE_FILENAME\") | .volid")

if [[ -z "$TEMPLATE_PATH_ON_STORAGE" ]]; then
    ech_warn "Template '$TEMPLATE_FILENAME' not found on storage '$STORAGE'."
    if ask_yes_no "Attempt to download '$TEMPLATE_FILENAME' to '$STORAGE'?"; then
        ech_info "Downloading template..."
        pveam update # Ensure list is up-to-date
        pveam download "$STORAGE" "$TEMPLATE_FILENAME"
        ech_info "Template download attempt finished."
        # Verify again
        TEMPLATE_PATH_ON_STORAGE=$(pveam list "$STORAGE" --output-format json | jq -r ".[] | select(.volid==\"$STORAGE:vztmpl/$TEMPLATE_FILENAME\") | .volid")
        if [[ -z "$TEMPLATE_PATH_ON_STORAGE" ]]; then
            ech_error "Template still not found after download attempt. Please check template name and availability."
            exit 1
        fi
    else
        ech_error "Template required. Exiting."
        exit 1
    fi
fi

# Use the full volid path for creation
TEMPLATE_FOR_CREATE="$TEMPLATE_PATH_ON_STORAGE"

# --- Create LXC ---
ech_info "Creating LXC Container $CTID..."
STORAGE_TYPE=$(pvesm status -storage $STORAGE --output-format json | jq -r '.[0].type')
if [[ "$STORAGE_TYPE" == "dir" ]] || [[ "$STORAGE_TYPE" == "btrfs" ]]; then
    # Rootfs for directory-based storage doesn't use size prefix
    ROOTFS_OPT="${STORAGE}:${DISK}"
else
    # Others (lvmthin, zfspool, cephfs etc.) use size prefix
    ROOTFS_OPT="${STORAGE}:${DISK}"
fi

pct create $CTID "$TEMPLATE_FOR_CREATE" \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "$ROOTFS_OPT" \
    --onboot 1 \
    --features nesting=1 \
    --net0 name=eth0,bridge=$BRIDGE,ip=dhcp # Start with DHCP, change later if static

if [[ "$USE_DHCP" == "n" ]]; then
    ech_info "Setting static IP configuration..."
    # Give DHCP a moment, then switch to static
    pct start $CTID
    sleep 10 # Wait a bit for initial boot/dhcp attempt
    pct set $CTID --net0 name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GW
    # May need to set DNS too, e.g. --nameserver 1.1.1.1
    # pct set $CTID --nameserver 1.1.1.1
    ech_info "Restarting container to apply static IP..."
    pct stop $CTID || true # Ignore error if already stopped
    pct start $CTID
else
    # Start container (already has DHCP from create)
    pct start $CTID
fi

ech_info "Waiting for container to boot and acquire network (up to 90 seconds)..."
NETWORK_ACQUIRED=0
for i in {1..30}; do
    # Check for a non-loopback IPv4 address
    if pct exec $CTID -- ip -4 addr show dev eth0 | grep -q 'inet '; then
        CONTAINER_IP=$(pct exec $CTID -- ip -4 addr show dev eth0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
        ech_info "Container IP detected: $CONTAINER_IP"
        NETWORK_ACQUIRED=1
        break
    fi
    sleep 3
done

if [[ $NETWORK_ACQUIRED -eq 0 ]]; then
    ech_error "Container failed to acquire network configuration after 90 seconds."
    ech_warn "Check container network settings and Proxmox networking."
    exit 1
fi

# --- Download and Execute Installer Inside LXC ---
ech_info "Downloading ERPNext installer script to the container..."
# Download to host first, then push
wget -qO "/tmp/erpnext_install_${CTID}.sh" "$DEFAULT_INSTALLER_URL"
pct push $CTID "/tmp/erpnext_install_${CTID}.sh" "/root/erpnext_install.sh" --perms 755

ech_info "Executing ERPNext installation script inside container $CTID..."
ech_warn "This will take a significant amount of time (15-30+ minutes)."
ech_warn "The script will prompt for Site Name and Admin Password INSIDE the container."
ech_warn "You might want to open the container console ('pct enter $CTID') in another window to monitor progress and respond to prompts."

# Execute the script detached inside the container
pct exec $CTID -- bash /root/erpnext_install.sh

ech_info "Installer script execution started inside LXC $CTID."
ech_info "Monitor the container console ('pct enter $CTID') for progress and prompts."

# --- Cleanup ---
rm -f "/tmp/erpnext_install_${CTID}.sh"

ech_info "LXC Creation Script finished."
ech_info "ERPNext Installation is running inside container $CTID ($HOSTNAME)."
